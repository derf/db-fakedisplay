#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use List::MoreUtils qw();
use Travel::Status::DE::DeutscheBahn;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => "experimental::smartmatch";

our $VERSION = qx{git describe --dirty} || '0.05';

my $refresh_interval = 180;

sub get_results_for {
	my ( $backend, $station, %opt ) = @_;

	my $cache = Cache::File->new(
		cache_root      => '/tmp/db-fake',
		default_expires => $refresh_interval . ' sec',
		lock_level      => Cache::File::LOCK_LOCAL(),
	);

	# Cache::File has UTF-8 problems, so strip it (and any other potentially
	# problematic chars).
	my $cstation = $station;
	$cstation =~ tr{[0-9a-zA-Z -]}{}cd;

	my $cache_str = "${backend}_${cstation}";

	my $results = $cache->thaw($cache_str);

	if ( not $results ) {
		if ( $backend eq 'iris' ) {

			# requests with DS100 codes should be preferred (they avoid
			# encoding problems on the IRIS server). However, only use them
			# if we have an exact match. Ask the backend otherwise.
			my @station_matches
			  = Travel::Status::DE::IRIS::Stations::get_station($station);
			if ( @station_matches == 1 ) {
				$station = $station_matches[0][0];
			}

			my $status = Travel::Status::DE::IRIS->new(
				station      => $station,
				serializable => 1,
				%opt
			);
			$results = [ $status->results ];
			$cache->freeze( $cache_str, $results );
		}
		else {
			my $status = Travel::Status::DE::DeutscheBahn->new(
				station => $station,
				%opt
			);
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
	my $template       = $self->param('mode')          // 'multi';
	my $hide_low_delay = $self->param('hidelowdelay')  // 0;
	my $hide_opts      = $self->param('hide_opts')     // 0;
	my $show_realtime  = $self->param('show_realtime') // 0;
	my $backend        = $self->param('backend')       // 'ris';
	my $admode         = $self->param('admode')        // 'deparr';
	my $callback       = $self->param('callback');
	my $apiver         = $self->param('version')       // 0;
	my %opt;

	my $api_version
	  = $backend eq 'iris'
	  ? $Travel::Status::DE::IRIS::VERSION
	  : $Travel::Status::DE::DeutscheBahn::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'db-fakedisplay' );
	$self->stash( version    => $VERSION );

	if ( not( $template ~~ [qw[clean json marudor_v1 marudor multi single]] ) )
	{
		$template = 'multi';
	}

	if ( not $station ) {
		$self->render(
			$template,
			hide_opts  => 0,
			show_intro => 1
		);
		return;
	}

	if ( $template eq 'marudor' and $backend eq 'iris' ) {
		$opt{lookahead} = 120;
	}

	my @departures;
	my @results = get_results_for( $backend, $station, %opt );

	if ( not @results and $template ~~ [qw[json marudor_v1 marudor]] ) {
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

	if ( $backend eq 'iris' and $show_realtime ) {
		if ( $admode eq 'arr' ) {
			@results = sort {
				( $a->arrival // $a->departure )
				  <=> ( $b->arrival // $b->depearture )
			} @results;
		}
		else {
			@results = sort {
				( $a->departure // $a->arrival )
				  <=> ( $b->departure // $b->arrival )
			} @results;
		}
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
			if ( not( List::MoreUtils::any { $_ =~ m{$via}io } @route ) ) {
				next;
			}
		}
		if ( @platforms
			and not( List::MoreUtils::any { $_ eq $platform } @platforms ) )
		{
			next;
		}
		if ( @lines and not( List::MoreUtils::any { $line =~ m{^$_} } @lines ) )
		{
			next;
		}
		if ( $backend eq 'iris' and $admode eq 'arr' and not $result->arrival )
		{
			next;
		}
		if (    $backend eq 'iris'
			and $admode eq 'dep'
			and not $result->departure )
		{
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
			if ( $result->replacement_for and $template ne 'clean') {
				for my $rep ($result->replacement_for) {
					$info = sprintf('Ersatzzug für %s %s %s%s',
						$rep->type,
						$rep->train_no,
						$info ? '+++ ' : q{},
						$info // q{}
					);
				}
			}
			if ( $info and $qosmsg ) {
				$info .= ' +++ ';
			}
			$info .= $qosmsg;

			if ( $result->additional_stops and not $result->is_cancelled ) {
				my $additional_line = join( q{, }, $result->additional_stops );
				$info
				  = 'Zusätzliche Halte: '
				  . $additional_line
				  . ( $info ? ' +++ ' : q{} )
				  . $info;
				if ( $template ne 'marudor_v1' and $template ne 'marudor' ) {
					push(
						@{$moreinfo},
						[ 'Zusätzliche Halte', $additional_line ]
					);
				}
			}

			if ( $result->canceled_stops and not $result->is_cancelled ) {
				my $cancel_line = join( q{, }, $result->canceled_stops );
				$info
				  = 'Ohne Halt in: '
				  . $cancel_line
				  . ( $info ? ' +++ ' : q{} )
				  . $info;
				if ( $template ne 'marudor_v1' and $template ne 'marudor' ) {
					push( @{$moreinfo}, [ 'Ohne Halt in', $cancel_line ] );
				}
			}

			push( @{$moreinfo}, $result->messages );
		}
		else {
			$info = $result->info;
			if ($info) {
				$moreinfo = [ [ 'RIS', $info ] ];
			}
		}

		my $time = $result->time;

		if ( $backend eq 'iris' ) {

			# ->time defaults to dep, so we only need to overwrite $time
			# if we want arrival times
			if ( $admode eq 'arr' ) {
				$time = $result->sched_arrival->strftime('%H:%M');
			}

			if ($show_realtime) {
				if ( ( $admode eq 'arr' and $result->arrival )
					or not $result->departure )
				{
					$time = $result->arrival->strftime('%H:%M');
				}
				else {
					$time = $result->departure->strftime('%H:%M');
				}
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

		if ( $template eq 'marudor' ) {
			my ( $route_idx, $sched_idx ) = ( 0, 0 );
			my @json_route;
			my @route       = $result->route;
			my @sched_route = $result->sched_route;

			while ( $route_idx <= $#route and $sched_idx <= $#sched_route ) {
				if ( $route[$route_idx] eq $sched_route[$sched_idx] ) {
					push( @json_route, { name => $route[$route_idx] } );
					$route_idx++;
					$sched_idx++;
				}

				# this branch is inefficient, but won't be taken frequently
				elsif ( not( $route[$route_idx] ~~ \@sched_route ) ) {
					push(
						@json_route,
						{
							name         => $route[$route_idx],
							isAdditional => 1
						}
					);
					$route_idx++;
				}
				else {
					push(
						@json_route,
						{
							name        => $sched_route[$sched_idx],
							isCancelled => 1
						}
					);
					$sched_idx++;
				}
			}
			while ( $route_idx++ < $#route ) {
				push(
					@json_route,
					{
						name         => $route[ $route_idx++ ],
						isAdditional => 1,
						isCancelled  => 0
					}
				);
			}
			while ( $sched_idx++ < $#sched_route ) {
				push(
					@json_route,
					{
						name         => $route[ $route_idx++ ],
						isAdditional => 0,
						isCancelled  => 1
					}
				);
			}

			push(
				@departures,
				{
					delay       => $delay,
					destination => $result->destination,
					isCancelled => $result->can('is_cancelled')
					? $result->is_cancelled
					: undef,
					messages => {
						delay => [
							map { { timestamp => $_->[0], text => $_->[1] } }
							  $result->delay_messages
						],
						qos => [
							map { { timestamp => $_->[0], text => $_->[1] } }
							  $result->qos_messages
						],
					},
					platform          => $result->platform,
					route             => \@json_route,
					scheduledPlatform => $result->sched_platform,
					time              => $time,
					train             => $result->train,
					via               => [ $result->route_interesting(3) ],
				}
			);
		}
		elsif ( $backend eq 'iris' ) {
			push(
				@departures,
				{
					time            => $time,
					train           => $result->train,
					via             => [ $result->route_interesting(3) ],
					scheduled_route => [ $result->sched_route ],
					destination     => $result->destination,
					platform        => $platform,
					info            => $info,
					is_cancelled    => $result->can('is_cancelled')
					? $result->is_cancelled
					: undef,
					messages => {
						delay => [
							map { { timestamp => $_->[0], text => $_->[1] } }
							  $result->delay_messages
						],
						qos => [
							map { { timestamp => $_->[0], text => $_->[1] } }
							  $result->qos_messages
						],
					},
					moreinfo         => $moreinfo,
					delay            => $delay,
					additional_stops => [ $result->additional_stops ],
					canceled_stops   => [ $result->canceled_stops ],
					replaced_by      => $result->can('replaced_by')
					? [ map { $_->type . q{ } . $_->train_no } $result->replaced_by ] : [],
					replacement_for  => $result->can('replacement_for')
					? [ map { $_->type . q{ } . $_->train_no } $result->replacement_for ] : [],
				}
			);
		}
		else {
			push(
				@departures,
				{
					time         => $time,
					train        => $result->train,
					via          => [ $result->route_interesting(3) ],
					destination  => $result->destination,
					platform     => $platform,
					info         => $info,
					is_cancelled => $result->can('is_cancelled')
					? $result->is_cancelled
					: undef,
					messages => {
						delay => [],
						qos   => [],
					},
					moreinfo         => $moreinfo,
					delay            => $delay,
					additional_stops => [],
					canceled_stops   => [],
				}
			);
		}
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
	elsif ( $template eq 'marudor' ) {
		my $json = $self->render_to_string(
			json => {
				departures => \@departures,
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
	elsif ( $template eq 'marudor_v1' ) {
		my $json = $self->render_to_string(
			json => {
				api_version  => $api_version,
				preformatted => \@departures,
				version      => $VERSION,
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
			show_realtime    => $show_realtime,
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
