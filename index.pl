#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use List::MoreUtils qw(any);
use Travel::Status::DE::DeutscheBahn;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => "experimental::smartmatch";

our $VERSION = qx{git describe --dirty} || '0.05';

my $refresh_interval = 180;

sub get_results_for {
	my ( $backend, $station ) = @_;

	my $cache = Cache::File->new(
		cache_root      => '/tmp/db-fake',
		default_expires => $refresh_interval . ' sec',
	);

	# Cache::File has UTF-8 problems, so strip it (and any other potentially
	# problematic chars).
	my $cstation = $station;
	$cstation =~ tr{[0-9a-zA-Z -]}{}cd;

	my $cache_str = "${backend}_${cstation}";

	my $results = $cache->thaw($cache_str);

	if ( not $results ) {
		if ( $backend eq 'iris' ) {
			my $status = Travel::Status::DE::IRIS->new(
				station      => $station,
				serializable => 1
			);
			$results = [ $status->results ];
			$cache->freeze( $cache_str, $results );
		}
		else {
			my $status
			  = Travel::Status::DE::DeutscheBahn->new( station => $station );
			$results = [ $status->results ];
			$cache->freeze( $cache_str, $results );
		}
	}

	return @{$results};
}

sub handle_request {
	my $self    = shift;
	my $station = $self->stash('station');
	my $via     = $self->stash('via');

	my @platforms = split( /,/, $self->param('platforms') // q{} );
	my @lines     = split( /,/, $self->param('lines')     // q{} );
	my $template       = $self->param('mode')         // 'multi';
	my $hide_low_delay = $self->param('hidelowdelay') // 0;
	my $hide_opts      = $self->param('hide_opts')    // 0;
	my $backend        = $self->param('backend')      // 'ris';
	my $callback       = $self->param('callback');

	my $api_version
	  = $backend eq 'iris'
	  ? $Travel::Status::DE::IRIS::VERSION
	  : $Travel::Status::DE::DeutscheBahn::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'db-fakedisplay' );
	$self->stash( version    => $VERSION );

	if ( not( $template ~~ [qw[clean json multi single]] ) ) {
		$template = 'multi';
	}

	if ( not $station ) {
		$self->render( $template, hide_opts => 0 );
		return;
	}

	my @departures;
	my @results = get_results_for( $backend, $station );

	if ( not @results and $template eq 'json' ) {
		my $json;
		if ( $backend eq 'iris' ) {
			my @candidates = map { { code => $_->[0], name => $_->[1] } }
			  Travel::Status::DE::IRIS::Stations::get_station($station);
			$json = $self->render_to_string(
				json => {
					api_version => $api_version,
					version     => $VERSION,
					error       => 'ambiguous station code/name',
					candidates  => \@candidates,
				}
			);
		}
		else {
			$json = $self->render_to_string(
				json => {
					api_version => $api_version,
					version     => $VERSION,
					error       => 'unknown station code/name',
				}
			);
		}
		if ($callback) {
			$self->render(
				data   => "$callback($json);",
				format => 'json'
			);
		}
		else {
			$self->render(
				data   => $json,
				format => 'json'
			);
		}
		return;
	}

	if ( not @results ) {
		if ( $backend eq 'iris' ) {
			my @candidates = map { [ "$_->[1] ($_->[0])", $_->[0] ] }
			  Travel::Status::DE::IRIS::Stations::get_station($station);
			if (@candidates) {
				$self->render(
					'multi',
					stationlist => \@candidates,
					hide_opts   => 0
				);
				return;
			}
		}
		$self->render(
			'multi',
			error     => "Got no results for '$station'",
			hide_opts => 0
		);
		return;
	}

	if ( $template eq 'single' ) {
		if ( not @platforms ) {
			for my $result (@results) {
				if ( not( $result->platform ~~ \@platforms ) ) {
					push( @platforms, $result->platform );
				}
			}
			@platforms = sort { $a <=> $b } @platforms;
		}
		my %pcnt;
		@results = grep { $pcnt{ $_->platform }++ < 1 } @results;
		@results = sort { $a->platform <=> $b->platform } @results;
	}

	for my $result (@results) {
		my $platform = ( split( / /, $result->platform ) )[0];
		my $line     = $result->line;
		my $delay    = $result->delay;
		if ($via) {
			my @route = $result->route;
			if ( $result->isa('Travel::Status::DE::IRIS::Result') ) {
				@route = $result->route_post;
			}
			if ( not( any { $_ =~ m{$via}io } @route ) ) {
				next;
			}
		}
		if ( @platforms and not( any { $_ eq $platform } @platforms ) ) {
			next;
		}
		if ( @lines and not( any { $line =~ m{^$_} } @lines ) ) {
			next;
		}
		my ( $info, $moreinfo );
		if ( $backend eq 'iris' ) {
			my $delaymsg
			  = join( ', ', map { $_->[1] } $result->delay_messages );
			my $qosmsg = join( ' +++ ', map { $_->[1] } $result->qos_messages );
			if ( $result->is_cancelled ) {
				$info = "Fahrt fällt aus: ${delaymsg}";
			}
			elsif ( $result->delay and $result->delay > 0 ) {
				if ( $template eq 'clean' ) {
					$info  = $delaymsg;
					$delay = $result->delay;
				}
				else {
					$info = sprintf( 'Verspätung ca. %d Min.%s%s',
						$result->delay, $delaymsg ? q{: } : q{}, $delaymsg );
				}
			}
			if ( $info and $qosmsg ) {
				$info .= ' +++ ';
			}
			$info .= $qosmsg;

			$moreinfo = [ $result->messages ];
		}
		else {
			$info = $result->info;
			if ($info) {
				$moreinfo = [ [ 'RIS', $info ] ];
			}
		}

		if ( $info eq '+0' ) {
			$info = undef;
		}
		if (    $template eq 'clean'
			and $info
			and $info =~ s{ (?: ca \. \s* )? \+ (\d+) :? \s* }{}x )
		{
			$delay = $1;
		}
		if ( $hide_low_delay and $info ) {
			$info =~ s{ (?: ca\. \s* )? \+ [ 1 2 3 4 ] $ }{}x;
		}
		if ($info) {
			$info =~ s{ (?: ca\. \s* )? \+ (\d+) }{Verspätung ca $1 Min.}x;
		}
		push(
			@departures,
			{
				time        => $result->time,
				train       => $result->train,
				via         => [ $result->route_interesting(3) ],
				destination => $result->destination,
				platform    => $platform,
				info        => $info,
				moreinfo    => $moreinfo,
				delay       => $delay,
			}
		);
	}

	if ( $template eq 'json' ) {
		my $json = $self->render_to_string(
			json => {
				api_version  => $api_version,
				preformatted => \@departures,
				version      => $VERSION,
				raw          => \@results,
			}
		);
		if ($callback) {
			$self->render(
				data   => "$callback($json);",
				format => 'json'
			);
		}
		else {
			$self->render(
				data   => $json,
				format => 'json'
			);
		}
	}
	else {
		$self->render(
			$template,
			departures       => \@departures,
			version          => $VERSION,
			title            => "departures for ${station}",
			refresh_interval => $refresh_interval + 3,
			hide_opts        => $hide_opts,
		);
	}
}

get '/_redirect' => sub {
	my $self    = shift;
	my $station = $self->param('station');
	my $via     = $self->param('via');
	my $params  = $self->req->params;

	$params->remove('station');
	$params->remove('via');

	if ( $params->param('mode') and $params->param('mode') eq 'multi' ) {
		$params->remove('mode');
	}

	for my $param (qw(platforms)) {
		if ( not $params->param($param) ) {
			$params->remove($param);
		}
	}

	$params = $params->to_string;

	if ($via) {
		$self->redirect_to("/${station}/${via}?${params}");
	}
	else {
		$self->redirect_to("/${station}?${params}");
	}
};

app->defaults( layout => 'default' );

get '/'               => \&handle_request;
get '/:station'       => \&handle_request;
get '/:station/:via'  => \&handle_request;
get '/multi/:station' => \&handle_request;

app->config(
	hypnotoad => {
		accepts  => 10,
		listen   => ['http://*:8092'],
		pid_file => '/tmp/db-fake.pid',
		workers  => $ENV{VRRFAKEDISPLAY_WORKERS} // 2,
	},
);

app->types->type( json => 'application/json; charset=utf-8' );
app->start();
