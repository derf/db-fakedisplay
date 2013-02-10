#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use Travel::Status::DE::DeutscheBahn;
use 5.014;
use utf8;

our $VERSION = '0.03';

sub get_results_for {
	my ($station) = @_;

	my $cache = Cache::File->new(
		cache_root      => '/tmp/db-fake',
		default_expires => '900 sec'
	);

	my $results = $cache->thaw($station);

	if ( not $results ) {
		my $status
		  = Travel::Status::DE::DeutscheBahn->new( station => $station );
		$results = [ $status->results ];
		$cache->freeze( $station, $results );
	}

	return @{$results};
}

sub handle_request {
	my $self    = shift;
	my $station = $self->stash('station');
	my $via     = $self->stash('via');

	my @platforms = split( /,/, $self->param('platforms') // q{} );
	my $template = $self->param('mode') // 'multi';

	$self->stash( departures => [] );
	$self->stash( title      => 'db-fakedisplay' );
	$self->stash( version    => $VERSION );

	if ( not( $template ~~ [qw[multi single]] ) ) {
		$template = 'multi';
	}

	if ( not $station ) {
		$self->render($template);
		return;
	}

	my @departures;
	my @results = get_results_for($station);

	if ( not @results ) {
		$self->render( 'multi', error => "Got no results for '$station'" );
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
		if ($via) {
			my @route = $result->route;
			if ( not( grep { $_ =~ m{$via}io } @route ) ) {
				next;
			}
		}
		if ( @platforms and not grep { $_ eq $platform } @platforms ) {
			next;
		}
		my $info = $result->info;

		if ( $info eq '+0' ) {
			$info = undef;
		}
		if ($info) {
			$info =~ s{ ^ (?: ca\. \s* )? \+ (\d+) }{Verspätung ca. $1 Minuten}x;
			$info =~ s{ 1 \s Minute\Kn }{}x;
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
			}
		);
	}

	$self->render(
		$template,
		departures => \@departures,
		version    => $VERSION,
		title      => "departures for ${station}"
	);
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
		workers  => 2,
	},
);

app->start();
