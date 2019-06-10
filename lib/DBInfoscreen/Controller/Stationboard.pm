package DBInfoscreen::Controller::Stationboard;
use Mojo::Base 'Mojolicious::Controller';

# Copyright (C) 2011-2019 Daniel Friesel <derf+dbf@finalrewind.org>
# License: 2-Clause BSD

use DateTime;
use DateTime::Format::Strptime;
use Encode qw(decode encode);
use File::Slurp qw(read_file write_file);
use List::Util qw(max);
use List::MoreUtils qw();
use Mojo::JSON qw(decode_json);
use Travel::Status::DE::HAFAS;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use XML::LibXML;

use utf8;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

my $dbf_version = qx{git describe --dirty} || 'experimental';

my %default = (
	backend => 'iris',
	mode    => 'app',
	admode  => 'deparr',
);

sub result_is_train {
	my ( $result, $train ) = @_;

	if ( $result->can('train_id') ) {

		# IRIS
		if ( $train eq $result->type . ' ' . $result->train_no ) {
			return 1;
		}
		return 0;
	}
	else {
		# HAFAS
		if ( $train eq $result->type . ' ' . $result->train ) {
			return 1;
		}
		return 0;
	}
}

sub result_has_line {
	my ( $result, @lines ) = @_;
	my $line = $result->line;

	if ( List::MoreUtils::any { $line =~ m{^$_} } @lines ) {
		return 1;
	}
	return 0;
}

sub result_has_platform {
	my ( $result, @platforms ) = @_;
	my $platform = ( split( qr{ }, $result->platform // '' ) )[0] // '';

	if ( List::MoreUtils::any { $_ eq $platform } @platforms ) {
		return 1;
	}
	return 0;
}

sub result_has_train_type {
	my ( $result, @train_types ) = @_;
	my $train_type = $result->type;

	if ( List::MoreUtils::any { $train_type =~ m{^$_} } @train_types ) {
		return 1;
	}
	return 0;
}

sub result_has_via {
	my ( $result, $via ) = @_;

	if ( not $result->can('route_post') ) {
		return 1;
	}

	my @route = $result->route_post;

	if ( List::MoreUtils::any { m{$via}i } @route ) {
		return 1;
	}
	return 0;
}

sub log_api_access {
	my $counter = 1;
	if ( -r $ENV{DBFAKEDISPLAY_STATS} ) {
		$counter = read_file( $ENV{DBFAKEDISPLAY_STATS} ) + 1;
	}
	write_file( $ENV{DBFAKEDISPLAY_STATS}, $counter );
	return;
}

sub hafas_json_req {
	my ( $ua, $cache, $url ) = @_;

	if ( my $content = $cache->thaw($url) ) {
		return $content;
	}

	my $res = $ua->get($url)->result;

	if ( $res->is_error ) {
		return;
	}

	my $body = encode( 'utf-8', decode( 'ISO-8859-15', $res->body ) );

	$body =~ s{^TSLs[.]sls = }{};
	$body =~ s{;$}{};
	$body =~ s{&#x0028;}{(}g;
	$body =~ s{&#x0029;}{)}g;

	my $json = decode_json($body);

	$cache->freeze( $url, $json );

	return $json;
}

sub hafas_xml_req {
	my ( $ua, $cache, $url ) = @_;

	if ( my $content = $cache->thaw($url) ) {
		return $content;
	}

	my $res = $ua->get($url)->result;

	if ( $res->is_error ) {
		$cache->freeze( $url, {} );
		return;
	}

	my $body = decode( 'ISO-8859-15', $res->body );

	# <SDay text="... &gt; ..."> is invalid HTML, but present
	# regardless. As it is the last tag, we just throw it away.
	$body =~ s{<SDay [^>]*/>}{}s;

	my $tree;

	eval { $tree = XML::LibXML->load_xml( string => $body ) };

	if ($@) {
		$cache->freeze( $url, {} );
		return;
	}

	my $ret = {
		station  => {},
		stations => [],
		messages => [],
	};

	for my $station ( $tree->findnodes('/Journey/St') ) {
		my $name   = $station->getAttribute('name');
		my $adelay = $station->getAttribute('adelay');
		my $ddelay = $station->getAttribute('ddelay');
		push( @{ $ret->{stations} }, $name );
		$ret->{station}{$name} = {
			adelay => $adelay,
			ddelay => $ddelay,
		};
	}

	for my $message ( $tree->findnodes('/Journey/HIMMessage') ) {
		my $header  = $message->getAttribute('header');
		my $lead    = $message->getAttribute('lead');
		my $display = $message->getAttribute('display');
		push(
			@{ $ret->{messages} },
			{
				header  => $header,
				lead    => $lead,
				display => $display
			}
		);
	}

	$cache->freeze( $url, $ret );

	return $ret;
}

# quick&dirty, will be cleaned up later
sub get_route_timestamps {
	my ( $ua, $cache_main, $cache_rt, $train ) = @_;

	$ua->request_timeout(3);

	my $base
	  = 'https://reiseauskunft.bahn.de/bin/trainsearch.exe/dn?L=vs_json&start=yes&rt=1';
	my $date_yy   = $train->start->strftime('%d.%m.%y');
	my $date_yyyy = $train->start->strftime('%d.%m.%Y');
	my $train_no  = $train->type . ' ' . $train->train_no;

	my $trainsearch = hafas_json_req( $ua, $cache_main,
		"${base}&date=${date_yy}&trainname=${train_no}" );

	if ( not $trainsearch ) {
		return;
	}

	# Fallback: Take first result
	my $trainlink = $trainsearch->{suggestions}[0]{trainLink};

	# Try finding a result for the current date
	for my $suggestion ( @{ $trainsearch->{suggestions} // [] } ) {

       # Drunken API, sail with care. Both date formats are used interchangeably
		if (   $suggestion->{depDate} eq $date_yy
			or $suggestion->{depDate} eq $date_yyyy )
		{
			$trainlink = $suggestion->{trainLink};
			last;
		}
	}

	if ( not $trainlink ) {
		return;
	}

	$base = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';

	my $traininfo = hafas_json_req( $ua, $cache_main,
		"${base}/${trainlink}?rt=1&date=${date_yy}&L=vs_json" );

	if ( not $traininfo or $traininfo->{error} ) {
		return;
	}

	my $traindelay = hafas_xml_req( $ua, $cache_rt,
		"${base}/${trainlink}?rt=1&date=${date_yy}&L=vs_java3" );

	my $ret = {};

	my $strp = DateTime::Format::Strptime->new(
		pattern   => '%d.%m.%y %H:%M',
		time_zone => 'Europe/Berlin',
	);

	for my $station ( @{ $traininfo->{suggestions}[0]{locations} // [] } ) {
		my $name = $station->{name};
		my $arr  = $station->{arrDate} . ' ' . $station->{arrTime};
		my $dep  = $station->{depDate} . ' ' . $station->{depTime};
		$ret->{$name} = {
			sched_arr => scalar $strp->parse_datetime($arr),
			sched_dep => scalar $strp->parse_datetime($dep),
		};
		if ( exists $traindelay->{station}{$name} ) {
			my $delay = $traindelay->{station}{$name};
			if (    $ret->{$name}{sched_arr}
				and $delay->{adelay}
				and $delay->{adelay} =~ m{^\d+$} )
			{
				$ret->{$name}{rt_arr} = $ret->{$name}{sched_arr}
				  ->clone->add( minutes => $delay->{adelay} );
			}
			if (    $ret->{$name}{sched_dep}
				and $delay->{ddelay}
				and $delay->{ddelay} =~ m{^\d+$} )
			{
				$ret->{$name}{rt_dep} = $ret->{$name}{sched_dep}
				  ->clone->add( minutes => $delay->{ddelay} );
			}
		}
	}

	return ( $ret, $traindelay // {} );
}

sub get_results_for {
	my ( $backend, $station, %opt ) = @_;
	my $data;

	# Cache::File has UTF-8 problems, so strip it (and any other potentially
	# problematic chars).
	my $cache_str = $station;
	$cache_str =~ tr{[0-9a-zA-Z -]}{}cd;

	if ( $backend eq 'iris' ) {

		if ( $ENV{DBFAKEDISPLAY_STATS} ) {
			log_api_access();
		}

		# requests with DS100 codes should be preferred (they avoid
		# encoding problems on the IRIS server). However, only use them
		# if we have an exact match. Ask the backend otherwise.
		my @station_matches
		  = Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @station_matches == 1 ) {
			$station = $station_matches[0][0];
			my $status = Travel::Status::DE::IRIS->new(
				station        => $station,
				main_cache     => $opt{cache_iris_main},
				realtime_cache => $opt{cache_iris_rt},
				log_dir        => $ENV{DBFAKEDISPLAY_XMLDUMP_DIR},
				lookbehind     => 20,
				lwp_options    => {
					timeout => 10,
					agent   => 'dbf.finalrewind.org/2'
				},
				%opt
			);
			$data = {
				results => [ $status->results ],
				errstr  => $status->errstr,
				station_name =>
				  ( $status->station ? $status->station->{name} : $station ),
			};
		}
		elsif ( @station_matches > 1 ) {
			$data = {
				results => [],
				errstr  => 'Ambiguous station name',
			};
		}
		else {
			$data = {
				results => [],
				errstr  => 'Unknown station name',
			};
		}
	}
	elsif ( $backend eq 'ris' ) {
		$data = $opt{cache_hafas}->thaw($cache_str);
		if ( not $data ) {
			if ( $ENV{DBFAKEDISPLAY_STATS} ) {
				log_api_access();
			}
			my $status = Travel::Status::DE::HAFAS->new(
				station       => $station,
				excluded_mots => [qw[bus ferry ondemand tram u]],
				lwp_options   => {
					timeout => 10,
					agent   => 'dbf.finalrewind.org/2'
				},
				%opt
			);
			$data = {
				results => [ $status->results ],
				errstr  => $status->errstr,
			};
			$opt{cache_hafas}->freeze( $cache_str, $data );
		}
	}
	else {
		$data = {
			results => [],
			errstr  => "Backend '$backend' not supported",
		};
	}

	return $data;
}

sub handle_request {
	my ($self)  = @_;
	my $station = $self->stash('station');
	my $via     = $self->param('via');

	my @platforms = split( /,/, $self->param('platforms') // q{} );
	my @lines     = split( /,/, $self->param('lines')     // q{} );
	my $template       = $self->param('mode')          // 'app';
	my $hide_low_delay = $self->param('hidelowdelay')  // 0;
	my $hide_opts      = $self->param('hide_opts')     // 0;
	my $show_realtime  = $self->param('show_realtime') // 0;
	my $show_details   = $self->param('detailed')      // 0;
	my $backend        = $self->param('backend')       // 'iris';
	my $admode         = $self->param('admode')        // 'deparr';
	my $dark_layout    = $self->param('dark')          // 0;
	my $apiver         = $self->param('version')       // 0;
	my $callback       = $self->param('callback');
	my $with_related   = !$self->param('no_related');
	my $save_defaults  = $self->param('save_defaults') // 0;
	my $limit          = $self->param('limit')         // 0;
	my @train_types = split( /,/, $self->param('train_types') // q{} );
	my %opt         = (
		cache_hafas     => $self->app->cache_hafas,
		cache_iris_main => $self->app->cache_iris_main,
		cache_iris_rt   => $self->app->cache_iris_rt,
	);

	my $api_version
	  = $backend eq 'iris'
	  ? $Travel::Status::DE::IRIS::VERSION
	  : $Travel::Status::DE::HAFAS::VERSION;

	if ($save_defaults) {
		$self->session( has_data      => 1 );
		$self->session( mode          => $template );
		$self->session( hidelowdelay  => $hide_low_delay );
		$self->session( hide_opts     => $hide_opts );
		$self->session( show_realtime => $show_realtime );
		$self->session( admode        => $admode );
		$self->session( dark          => $dark_layout );
		$self->session( detailed      => $show_details );
		$self->session( no_related    => !$with_related );
	}

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );
	$self->stash( version    => $dbf_version );

	if ( defined $station and $station =~ s{ [.] txt $ }{}x ) {
		$template = 'text';
		$self->param( station => $station );
		$self->stash( layout => 'text' );
	}
	elsif ( defined $station and $station =~ s{ [.] json $ }{}x ) {
		$template = 'json';
	}
	elsif ( $template ne 'app' ) {
		$self->stash( layout => 'legacy' );
	}

	# Historically, there were two JSON APIs: 'json' (undocumented, raw
	# passthrough of serialized Travel::Status::DE::IRIS::Result /
	# Travel::Status::DE::DE::HAFAS::Result objects) and 'marudor'
	# (documented, IRIS only, stable versioned API). The latter was initially
	# created for marudor.de, but quickly used by other clients as well.
	#
	# marudor.de switched to a nodejs IRIS parser in December 2018. As the
	# 'json' API was not used and the 'marudor' variant is no longer related to
	# (or used by) marudor.de, it was renamed to 'json'. Many clients won't
	# notice this for year to come, so we make sure mode=marudor still works as
	# intended.
	if ( $template eq 'marudor' ) {
		$template = 'json';
	}

	if ( not( $template ~~ [qw[app infoscreen json multi single text]] ) ) {
		$template = 'app';
	}

	if ( not $station ) {
		if ( $self->session('has_data') ) {
			for my $param (
				qw(mode hidelowdelay hide_opts show_realtime admode no_related dark detailed)
			  )
			{
				$self->param( $param => $self->session($param) );
			}
		}
		$self->render( 'landingpage', show_intro => 1 );
		return;
	}

	if ( $template eq 'json' ) {
		$backend = 'iris';
		$opt{lookahead} = 120;
	}

	if ($with_related) {
		$opt{with_related} = 1;
	}

	my @departures;
	my $data        = get_results_for( $backend, $station, %opt );
	my $results_ref = $data->{results};
	my $errstr      = $data->{errstr};
	my @results     = @{$results_ref};

	if ( not @results and $template eq 'json' ) {
		$self->handle_no_results_json( $backend, $station, $errstr,
			$api_version, $callback );
		return;
	}

	# foo/bar used to mean "departures for foo via bar". This is now
	# deprecated, but most of these cases are handled here.
	if ( not @results and $station =~ m{/} ) {
		( $station, $via ) = split( qr{/}, $station );
		$self->param( station => $station );
		$self->param( via     => $via );
		$data        = get_results_for( $backend, $station, %opt );
		$results_ref = $data->{results};
		$errstr      = $data->{errstr};
		@results     = @{$results_ref};
	}

	if ( not @results ) {
		$self->handle_no_results( $backend, $station, $errstr );
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
				  <=> ( $b->arrival // $b->departure )
			} @results;
		}
		else {
			@results = sort {
				( $a->departure // $a->arrival )
				  <=> ( $b->departure // $b->arrival )
			} @results;
		}
	}

	if ( my $train = $self->param('train') ) {
		@results = grep { result_is_train( $_, $train ) } @results;
	}

	if (@lines) {
		@results = grep { result_has_line( $_, @lines ) } @results;
	}

	if (@platforms) {
		@results = grep { result_has_platform( $_, @platforms ) } @results;
	}

	if ($via) {
		$via =~ s{ , \s* }{|}gx;
		@results = grep { result_has_via( $_, $via ) } @results;
	}

	if (@train_types) {
		@results = grep { result_has_train_type( $_, @train_types ) } @results;
	}

	if ( $limit and $limit =~ m{ ^ \d+ $ }x ) {
		splice( @results, $limit );
	}

	for my $result (@results) {
		my $platform = ( split( qr{ }, $result->platform // '' ) )[0];
		my $delay    = $result->delay;
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
			elsif ( $result->departure_is_cancelled ) {
				$info = "Zug endet hier: ${delaymsg}";
			}
			elsif ( $result->delay and $result->delay > 0 ) {
				if ( $template eq 'app' or $template eq 'infoscreen' ) {
					$info = $delaymsg;
				}
				else {
					$info = sprintf( 'ca. +%d%s%s',
						$result->delay, $delaymsg ? q{: } : q{}, $delaymsg );
				}
			}
			if (    $result->replacement_for
				and $template ne 'app'
				and $template ne 'infoscreen' )
			{
				for my $rep ( $result->replacement_for ) {
					$info = sprintf(
						'Ersatzzug für %s %s %s%s',
						$rep->type, $rep->train_no,
						$info ? '+++ ' : q{}, $info // q{}
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
				if ( $template ne 'json' ) {
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
				if ( $template ne 'json' ) {
					push( @{$moreinfo}, [ 'Ohne Halt in', $cancel_line ] );
				}
			}

			push( @{$moreinfo}, $result->messages );
		}
		else {
			$info = $result->info;
			if ($info) {
				$moreinfo = [ [ 'HAFAS', $info ] ];
			}
			if ( $result->delay and $result->delay > 0 ) {
				if ($info) {
					$info = 'ca. +' . $result->delay . ': ' . $info;
				}
				else {
					$info = 'ca. +' . $result->delay;
				}
			}
			push( @{$moreinfo}, map { [ 'HAFAS', $_ ] } $result->messages );
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

		if ($hide_low_delay) {
			if ($info) {
				$info =~ s{ (?: ca [.] \s* )? [+] [ 1 2 3 4 ] $ }{}x;
			}
			if ( $delay and $delay < 5 ) {
				$delay = undef;
			}
		}
		if ($info) {
			$info =~ s{ (?: ca [.] \s* )? [+] (\d+) }{Verspätung ca $1 Min.}x;
		}

		if ( $template eq 'json' ) {
			my @json_route = $self->json_route_diff( [ $result->route ],
				[ $result->sched_route ] );

			if ( $apiver == 1 ) {
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
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->delay_messages
							],
							qos => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->qos_messages
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
			elsif ( $apiver == 2 ) {
				my ( $delay_arr, $delay_dep, $sched_arr, $sched_dep );
				if ( $result->arrival ) {
					$delay_arr = $result->arrival->subtract_datetime(
						$result->sched_arrival )->in_units('minutes');
				}
				if ( $result->departure ) {
					$delay_dep = $result->departure->subtract_datetime(
						$result->sched_departure )->in_units('minutes');
				}
				if ( $result->sched_arrival ) {
					$sched_arr = $result->sched_arrival->strftime('%H:%M');
				}
				if ( $result->sched_departure ) {
					$sched_dep = $result->sched_departure->strftime('%H:%M');
				}
				push(
					@departures,
					{
						delayArrival   => $delay_arr,
						delayDeparture => $delay_dep,
						destination    => $result->destination,
						isCancelled    => $result->can('is_cancelled')
						? $result->is_cancelled
						: undef,
						messages => {
							delay => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->delay_messages
							],
							qos => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->qos_messages
							],
						},
						platform           => $result->platform,
						route              => \@json_route,
						scheduledPlatform  => $result->sched_platform,
						scheduledArrival   => $sched_arr,
						scheduledDeparture => $sched_dep,
						train              => $result->train,
						via                => [ $result->route_interesting(3) ],
					}
				);
			}
			else {    # apiver == 3
				my ( $delay_arr, $delay_dep, $sched_arr, $sched_dep );
				if ( $result->arrival ) {
					$delay_arr = $result->arrival->subtract_datetime(
						$result->sched_arrival )->in_units('minutes');
				}
				if ( $result->departure ) {
					$delay_dep = $result->departure->subtract_datetime(
						$result->sched_departure )->in_units('minutes');
				}
				if ( $result->sched_arrival ) {
					$sched_arr = $result->sched_arrival->strftime('%H:%M');
				}
				if ( $result->sched_departure ) {
					$sched_dep = $result->sched_departure->strftime('%H:%M');
				}
				push(
					@departures,
					{
						delayArrival   => $delay_arr,
						delayDeparture => $delay_dep,
						destination    => $result->destination,
						isCancelled    => $result->can('is_cancelled')
						? $result->is_cancelled
						: undef,
						messages => {
							delay => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->delay_messages
							],
							qos => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->qos_messages
							],
						},
						platform           => $result->platform,
						route              => \@json_route,
						scheduledPlatform  => $result->sched_platform,
						scheduledArrival   => $sched_arr,
						scheduledDeparture => $sched_dep,
						train              => $result->train,
						trainClasses       => [ $result->classes ],
						trainNumber        => $result->train_no,
						via                => [ $result->route_interesting(3) ],
					}
				);
			}
		}
		elsif ( $template eq 'text' ) {
			push(
				@departures,
				[
					sprintf( '%5s %s%s',
						$result->is_cancelled ? '--:--' : $time,
						( $delay and $delay > 0 ) ? q{+} : q{},
						$delay || q{} ),
					$result->train,
					$result->destination,
					$platform // q{ }
				]
			);
		}
		elsif ( $backend eq 'iris' ) {
			push(
				@departures,
				{
					time          => $time,
					sched_arrival => $result->sched_arrival
					? $result->sched_arrival->strftime('%H:%M')
					: undef,
					sched_departure => $result->sched_departure
					? $result->sched_departure->strftime('%H:%M')
					: undef,
					arrival => $result->arrival
					? $result->arrival->strftime('%H:%M')
					: undef,
					departure => $result->departure
					? $result->departure->strftime('%H:%M')
					: undef,
					train                  => $result->train,
					train_type             => $result->type,
					train_line             => $result->line_no,
					train_no               => $result->train_no,
					via                    => [ $result->route_interesting(3) ],
					destination            => $result->destination,
					origin                 => $result->origin,
					platform               => $result->platform,
					scheduled_platform     => $result->sched_platform,
					info                   => $info,
					is_cancelled           => $result->is_cancelled,
					departure_is_cancelled => $result->departure_is_cancelled,
					arrival_is_cancelled   => $result->arrival_is_cancelled,
					messages               => {
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
					replaced_by      => [
						map { $_->type . q{ } . $_->train_no }
						  $result->replaced_by
					],
					replacement_for => [
						map { $_->type . q{ } . $_->train_no }
						  $result->replacement_for
					],
					wr_link => $result->sched_departure
					? $result->sched_departure->strftime('%Y%m%d%H%M')
					: undef,
				}
			);
			if ( $self->param('train') ) {
				$departures[-1]{route_pre}      = [ $result->route_pre ];
				$departures[-1]{route_pre_diff} = [
					$self->json_route_diff(
						[ $result->route_pre ],
						[ $result->sched_route_pre ]
					)
				];
				$departures[-1]{route_post}      = [ $result->route_post ];
				$departures[-1]{route_post_diff} = [
					$self->json_route_diff(
						[ $result->route_post ],
						[ $result->sched_route_post ]
					)
				];
				my ( $route_ts, $route_info ) = get_route_timestamps(
					$self->ua,
					$self->app->cache_iris_main,
					$self->app->cache_iris_rt, $result
				);

             # If a train number changes on the way, IRIS routes are incomplete,
             # whereas HAFAS data has all stops -> merge HAFAS stops into IRIS
             # stops. This is a rare case, one point where it can be observed is
             # the TGV service at Frankfurt/Karlsruhe/Mannheim.
				if ( my @hafas_stations = @{ $route_info->{stations} } ) {
					if ( my @iris_stations
						= @{ $departures[-1]{route_pre_diff} } )
					{
						my @missing_pre;
						for my $station (@hafas_stations) {
							if (
								List::MoreUtils::any { $_->{name} eq $station }
								@iris_stations
							  )
							{
								last;
							}
							push(
								@missing_pre,
								{
									name  => $station,
									hafas => 1
								}
							);
						}
						unshift(
							@{ $departures[-1]{route_pre_diff} },
							@missing_pre
						);
					}
					if ( my @iris_stations
						= @{ $departures[-1]{route_post_diff} } )
					{
						my @missing_post;
						for my $station ( reverse @hafas_stations ) {
							if (
								List::MoreUtils::any { $_->{name} eq $station }
								@iris_stations
							  )
							{
								last;
							}
							unshift(
								@missing_post,
								{
									name  => $station,
									hafas => 1
								}
							);
						}
						push(
							@{ $departures[-1]{route_post_diff} },
							@missing_post
						);
					}
				}
				if ($route_ts) {
					for my $elem (
						@{ $departures[-1]{route_pre_diff} },
						@{ $departures[-1]{route_post_diff} }
					  )
					{
						for my $key (
							keys %{ $route_ts->{ $elem->{name} } // {} } )
						{
							$elem->{$key} = $route_ts->{ $elem->{name} }{$key};
						}
					}
				}
				if ( @{ $route_info->{messages} } ) {
					my $him = $route_info->{messages};
					my @him_messages;
					$departures[-1]{messages}{him} = $him;
					for my $message ( @{$him} ) {
						if ( $message->{display} ) {
							push( @him_messages,
								[ $message->{header}, $message->{lead} ] );
						}
					}
					unshift( @{ $departures[-1]{moreinfo} }, @him_messages );
				}
			}
		}
		else {
			push(
				@departures,
				{
					time             => $time,
					train            => $result->train,
					train_type       => $result->type,
					destination      => $result->destination,
					platform         => $platform,
					changed_platform => $result->is_changed_platform,
					info             => $info,
					is_cancelled     => $result->can('is_cancelled')
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
					replaced_by      => [],
					replacement_for  => [],
				}
			);
		}
	}

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	if ( $template eq 'json' ) {
		$self->res->headers->access_control_allow_origin(q{*});
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
	elsif ( $template eq 'text' ) {
		my @line_length;
		for my $i ( 0 .. $#{ $departures[0] } ) {
			$line_length[$i] = max map { length( $_->[$i] ) } @departures;
		}
		my $output = q{};
		for my $departure (@departures) {
			$output .= sprintf(
				join( q{  }, ( map { "%-${_}s" } @line_length ) ) . "\n",
				@{$departure}[ 0 .. $#{$departure} ]
			);
		}
		$self->render(
			text   => $output,
			format => 'text',
		);
	}
	elsif ( my $train = $self->param('train') ) {

		my ($departure) = @departures;

		if ($departure) {

			my $linetype = 'bahn';
			if ( $departure->{train_type} eq 'S' ) {
				$linetype = 'sbahn';
			}
			elsif ($departure->{train_type} eq 'IC'
				or $departure->{train_type} eq 'ICE'
				or $departure->{train_type} eq 'EC'
				or $departure->{train_type} eq 'ECE'
				or $departure->{train_type} eq 'EN' )
			{
				$linetype = 'fern';
			}
			elsif ($departure->{train_type} eq 'THA'
				or $departure->{train_type} eq 'TGV'
				or $departure->{train_type} eq 'FLX'
				or $departure->{train_type} eq 'NJ' )
			{
				$linetype = 'ext';
			}

			$self->render(
				'_train_details',
				departure => $departure,
				linetype  => $linetype,
				dt_now    => DateTime->now( time_zone => 'Europe/Berlin' ),
			);
		}
		else {
			$self->render('not_found');
		}
	}
	else {
		my $station_name = $data->{station_name} // $station;
		$self->render(
			$template,
			departures       => \@departures,
			version          => $dbf_version,
			title            => $via ? "$station_name → $via" : $station_name,
			refresh_interval => $template eq 'app' ? 0 : 120,
			hide_opts        => $hide_opts,
			hide_low_delay   => $hide_low_delay,
			show_realtime    => $show_realtime,
			load_marquee     => (
				     $template eq 'single'
				  or $template eq 'multi'
			),
			force_mobile => ( $template eq 'app' ),
		);
	}
	return;
}

sub stations_by_coordinates {
	my $self = shift;

	my $lon = $self->param('lon');
	my $lat = $self->param('lat');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
	}
	else {
		my @candidates = map {
			{
				ds100    => $_->[0][0],
				name     => $_->[0][1],
				eva      => $_->[0][2],
				lon      => $_->[0][3],
				lat      => $_->[0][4],
				distance => $_->[1],
			}
		} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
			$lat, 10 );
		$self->render(
			json => {
				candidates => [@candidates],
			}
		);
	}
}

1;
