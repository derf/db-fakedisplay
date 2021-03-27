package DBInfoscreen::Controller::Stationboard;

# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use Encode qw(decode encode);
use File::Slurp qw(read_file write_file);
use List::Util qw(max uniq);
use List::MoreUtils qw();
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use Travel::Status::DE::HAFAS;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use XML::LibXML;

use utf8;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

my %default = (
	backend => 'iris',
	mode    => 'app',
	admode  => 'deparr',
);

sub handle_no_results {
	my ( $self, $backend, $station, $errstr ) = @_;

	if ( $backend eq 'ris' ) {
		my $db_service = Travel::Status::DE::HAFAS::get_service('DB');
		my $sf         = Travel::Status::DE::HAFAS::StopFinder->new(
			url   => $db_service->{stopfinder},
			input => $station,
		);
		my @candidates
		  = map { [ $_->{name}, $_->{id} ] } $sf->results;
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0][1] ne $station ) )
		{
			$self->render(
				'landingpage',
				stationlist => \@candidates,
				hide_opts   => 0,
				status      => 300,
			);
			return;
		}
	}
	if ( $backend eq 'iris' ) {
		my @candidates = map { [ $_->[1], $_->[0] ] }
		  Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0][1] ne $station ) )
		{
			$self->render(
				'landingpage',
				stationlist => \@candidates,
				hide_opts   => 0,
				status      => 300,
			);
			return;
		}
	}
	$self->render(
		'landingpage',
		error     => ( $errstr // "Got no results for '$station'" ),
		hide_opts => 0
	);
	return;
}

sub handle_no_results_json {
	my ( $self, $backend, $station, $errstr, $api_version ) = @_;

	my $callback = $self->param('callback');

	$self->res->headers->access_control_allow_origin(q{*});
	my $json;
	if ($errstr) {
		$json = $self->render_to_string(
			json => {
				api_version => $api_version,
				version     => $self->config->{version},
				error       => $errstr,
			}
		);
	}
	else {
		my @candidates = map { { code => $_->[0], name => $_->[1] } }
		  Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0]{code} ne $station ) )
		{
			$json = $self->render_to_string(
				json => {
					api_version => $api_version,
					version     => $self->config->{version},
					error       => 'ambiguous station code/name',
					candidates  => \@candidates,
				}
			);
		}
		else {
			$json = $self->render_to_string(
				json => {
					api_version => $api_version,
					version     => $self->config->{version},
					error => ( $errstr // "Got no results for '$station'" )
				}
			);
		}
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

	my $eq_result = List::MoreUtils::any { lc eq lc($via) } @route;

	if ($eq_result) {
		return 1;
	}

	my ( $re1_result, $re2_result );

	eval {
		$re2_result = List::MoreUtils::any { m{\Q$via\E}i } @route;
	};
	eval {
		$re1_result = List::MoreUtils::any { m{$via}i } @route;
	};

	if ($@) {
		return $re2_result || $eq_result;
	}

	return $re1_result || $re2_result || $eq_result;
}

sub log_api_access {
	my $counter = 1;
	if ( -r $ENV{DBFAKEDISPLAY_STATS} ) {
		$counter = read_file( $ENV{DBFAKEDISPLAY_STATS} ) + 1;
	}
	write_file( $ENV{DBFAKEDISPLAY_STATS}, $counter );
	return;
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
	my ($self) = @_;
	my $station = $self->stash('station');

	my $template = $self->param('mode')    // 'app';
	my $backend  = $self->param('backend') // 'iris';
	my $with_related = !$self->param('no_related');
	my %opt          = (
		cache_hafas     => $self->app->cache_hafas,
		cache_iris_main => $self->app->cache_iris_main,
		cache_iris_rt   => $self->app->cache_iris_rt,
	);

	my $api_version
	  = $backend eq 'iris'
	  ? $Travel::Status::DE::IRIS::VERSION
	  : $Travel::Status::DE::HAFAS::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );
	$self->stash( version    => $self->config->{version} );

	if ( not( $template ~~ [qw[app infoscreen json multi single text]] ) ) {
		$template = 'app';
	}

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

	$self->param( mode => $template );

	if ( not $station ) {
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

	if ( $self->param('train') ) {

		# request results from five minutes ago to avoid train details suddenly
		# becoming unavailable when its scheduled departure is reached.
		$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' )
		  ->subtract( minutes => 20 );
		$opt{lookahead} = 200;
	}

	my $data   = get_results_for( $backend, $station, %opt );
	my $errstr = $data->{errstr};

	if ( not @{ $data->{results} } and $template eq 'json' ) {
		$self->handle_no_results_json( $backend, $station, $errstr,
			$api_version );
		return;
	}

	if ( not @{ $data->{results} } ) {
		$self->handle_no_results( $backend, $station, $errstr );
		return;
	}

	$self->handle_result($data);
}

sub filter_results {
	my ( $self, @results ) = @_;

	if ( my $train = $self->param('train') ) {
		@results = grep { result_is_train( $_, $train ) } @results;
	}

	if ( my @lines = split( /,/, $self->param('lines') // q{} ) ) {
		@results = grep { result_has_line( $_, @lines ) } @results;
	}

	if ( my @platforms = split( /,/, $self->param('platforms') // q{} ) ) {
		@results = grep { result_has_platform( $_, @platforms ) } @results;
	}

	if ( my $via = $self->param('via') ) {
		$via =~ s{ , \s* }{|}gx;
		@results = grep { result_has_via( $_, $via ) } @results;
	}

	if ( my @train_types = split( /,/, $self->param('train_types') // q{} ) ) {
		@results = grep { result_has_train_type( $_, @train_types ) } @results;
	}

	if ( my $limit = $self->param('limit') ) {
		if ( $limit =~ m{ ^ \d+ $ }x ) {
			splice( @results, $limit );
		}
	}

	return @results;
}

sub format_iris_result_info {
	my ( $self, $template, $result ) = @_;
	my ( $info, $moreinfo );

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
				[ 'Außerplanmäßiger Halt in', $additional_line ]
			);
		}
	}

	if ( $result->canceled_stops and not $result->is_cancelled ) {
		my $cancel_line = join( q{, }, $result->canceled_stops );
		$info
		  = 'Ohne Halt in: ' . $cancel_line . ( $info ? ' +++ ' : q{} ) . $info;
		if ( $template ne 'json' ) {
			push( @{$moreinfo}, [ 'Ohne Halt in', $cancel_line ] );
		}
	}

	push( @{$moreinfo}, $result->messages );

	return ( $info, $moreinfo );
}

sub format_hafas_result_info {
	my ( $self, $result ) = @_;
	my ( $info, $moreinfo );

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

	return ( $info, $moreinfo );
}

sub render_train {
	my ( $self, $result, $departure, $station_name, $template ) = @_;

	$departure->{links}          = [];
	$departure->{route_pre_diff} = [
		$self->json_route_diff(
			[ $result->route_pre ],
			[ $result->sched_route_pre ]
		)
	];
	$departure->{route_post_diff} = [
		$self->json_route_diff(
			[ $result->route_post ],
			[ $result->sched_route_post ]
		)
	];

	my $linetype = 'bahn';
	my @classes  = $result->classes;
	if ( @classes == 0 ) {
		$linetype = 'ext';
	}
	elsif ( grep { $_ eq 'S' } @classes ) {
		$linetype = 'sbahn';
	}
	elsif ( grep { $_ eq 'F' } @classes ) {
		$linetype = 'fern';
	}

	$self->render_later;

	my $wagonorder_req  = Mojo::Promise->new;
	my $utilization_req = Mojo::Promise->new;
	my $occupancy_req   = Mojo::Promise->new;
	my $stationinfo_req = Mojo::Promise->new;
	my $route_req       = Mojo::Promise->new;

	my @requests = (
		$wagonorder_req,  $utilization_req, $occupancy_req,
		$stationinfo_req, $route_req
	);

	if ( $departure->{wr_link} ) {
		$self->wagonorder->is_available_p( $result, $departure->{wr_link} )
		  ->then(
			sub {
				# great!
				return;
			},
			sub {
				$departure->{wr_link} = undef;
				return;
			}
		)->finally(
			sub {
				$wagonorder_req->resolve;
				return;
			}
		)->wait;

		# Looks like utilization data is only available for long-distance trains
		# – and the few regional trains which also have wagon order data (e.g.
		# around Stuttgart). Funky.
		$self->marudor->get_train_utilization( train => $result )->then(
			sub {
				my ( $first, $second ) = @_;
				$departure->{utilization} = [ $first, $second ];
				return;
			},
			sub {
				$departure->{utilization} = undef;
				return;
			}
		)->finally(
			sub {
				$utilization_req->resolve;
				return;
			}
		)->wait;
	}
	else {
		$wagonorder_req->resolve;
		$utilization_req->resolve;
	}

	$self->marudor->get_efa_occupancy(
		eva      => $result->station_uic,
		train_no => $result->train_no
	)->then(
		sub {
			my ($occupancy) = @_;
			$departure->{occupancy} = $occupancy;
			return;
		},
		sub {
			$departure->{occupancy} = undef;
			return;
		}
	)->finally(
		sub {
			$occupancy_req->resolve;
			return;
		}
	)->wait;

	$self->wagonorder->get_stationinfo_p( $result->station_uic )->then(
		sub {
			my ($station_info)    = @_;
			my ($platform_number) = ( $result->platform =~ m{(\d+)} );
			if ( not defined $platform_number ) {
				return;
			}
			my $platform_info = $station_info->{$platform_number};
			if ( not $platform_info ) {
				return;
			}
			my $prev_stop = ( $result->route_pre )[-1];
			my $next_stop = ( $result->route_post )[0];
			my $direction;

			if ( $platform_info->{kopfgleis} and $next_stop ) {
				$direction = $platform_info->{direction} eq 'r' ? 'l' : 'r';
			}
			elsif ( $platform_info->{kopfgleis} ) {
				$direction = $platform_info->{direction};
			}
			elsif ( $prev_stop
				and exists $platform_info->{direction_from}{$prev_stop} )
			{
				$direction = $platform_info->{direction_from}{$prev_stop};
			}
			elsif ( $next_stop
				and exists $platform_info->{direction_from}{$next_stop} )
			{
				$direction
				  = $platform_info->{direction_from}{$next_stop} eq 'r'
				  ? 'l'
				  : 'r';
			}

			if ($direction) {
				$departure->{direction} = $direction;
			}
			elsif ( $platform_info->{direction} ) {
				$departure->{direction} = 'a' . $platform_info->{direction};
			}

			return;
		},
		sub {
			# errors don't matter here
			return;
		}
	)->finally(
		sub {
			$stationinfo_req->resolve;
			return;
		}
	)->wait;

	$self->hafas->get_route_timestamps_p( train => $result )->then(
		sub {
			my ( $route_ts, $route_info, $trainsearch ) = @_;

			$departure->{trip_id} = $trainsearch->{trip_id};

			# If a train number changes on the way, IRIS routes are incomplete,
			# whereas HAFAS data has all stops -> merge HAFAS stops into IRIS
			# stops. This is a rare case, one point where it can be observed is
			# the TGV service at Frankfurt/Karlsruhe/Mannheim.
			if ( $route_info
				and my @hafas_stations = @{ $route_info->{stations} // [] } )
			{
				if ( my @iris_stations = @{ $departure->{route_pre_diff} } ) {
					my @missing_pre;
					for my $station (@hafas_stations) {
						if (
							List::MoreUtils::any { $_->{name} eq $station }
							@iris_stations
						  )
						{
							unshift(
								@{ $departure->{route_pre_diff} },
								@missing_pre
							);
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
				}
				if ( my @iris_stations = @{ $departure->{route_post_diff} } ) {
					my @missing_post;
					for my $station ( reverse @hafas_stations ) {
						if (
							List::MoreUtils::any { $_->{name} eq $station }
							@iris_stations
						  )
						{
							push(
								@{ $departure->{route_post_diff} },
								@missing_post
							);
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
				}
			}
			if ($route_ts) {
				for my $elem (
					@{ $departure->{route_pre_diff} },
					@{ $departure->{route_post_diff} }
				  )
				{
					for my $key ( keys %{ $route_ts->{ $elem->{name} } // {} } )
					{
						$elem->{$key} = $route_ts->{ $elem->{name} }{$key};
					}
				}
			}
			if ( $route_info and @{ $route_info->{messages} // [] } ) {
				my $him = $route_info->{messages};
				my @him_messages;
				$departure->{messages}{him} = $him;
				for my $message ( @{$him} ) {
					if ( $message->{display} ) {
						push( @him_messages,
							[ $message->{header}, $message->{lead} ] );
						if ( $message->{lead} =~ m{zuginfo.nrw/?\?msg=(\d+)} ) {
							push(
								@{ $departure->{links} },
								[
									"Großstörung",
									"https://zuginfo.nrw/?msg=$1"
								]
							);
						}
					}
				}
				for my $message ( @{ $departure->{moreinfo} // [] } ) {
					my $m = $message->[1];
					@him_messages
					  = grep { $_->[0] !~ m{Information\. $m\.$} }
					  @him_messages;
				}
				unshift( @{ $departure->{moreinfo} }, @him_messages );
			}
		}
	)->catch(
		sub {
			# nop
		}
	)->finally(
		sub {
			$route_req->resolve;
			return;
		}
	)->wait;

	if ( $self->param('detailed') ) {
		my $cycle_req = Mojo::Promise->new;
		push( @requests, $cycle_req );
		$self->wagonorder->has_cycle_p( $result->train_no )->then(
			sub {
				$departure->{has_cycle} = 1;
			}
		)->catch(
			sub {
				# nop
			}
		)->finally(
			sub {
				$cycle_req->resolve;
				return;
			}
		)->wait;
		$departure->{composition}
		  = $self->app->train_details_db->{ $departure->{train_no} };
		my @cycle_from;
		my @cycle_to;
		for my $cycle ( values %{ $departure->{composition}->{cycle} // {} } ) {
			push( @cycle_from, @{ $cycle->{from} // [] } );
			push( @cycle_to,   @{ $cycle->{to}   // [] } );
		}
		@cycle_from = sort { $a <=> $b } uniq @cycle_from;
		@cycle_to   = sort { $a <=> $b } uniq @cycle_to;
		$departure->{cycle_from}
		  = [ map { [ $_, $self->app->train_details_db->{$_} ] } @cycle_from ];
		$departure->{cycle_to}
		  = [ map { [ $_, $self->app->train_details_db->{$_} ] } @cycle_to ];
	}

	# Defer rendering until all requests have completed
	Mojo::Promise->all(@requests)->then(
		sub {
			$self->render(
				$template // '_train_details',
				departure => $departure,
				linetype  => $linetype,
				icetype => $self->app->ice_type_map->{ $departure->{train_no} },
				details => $departure->{composition} // {},
				dt_now  => DateTime->now( time_zone => 'Europe/Berlin' ),
				station_name => $station_name,
				nav_link =>
				  $self->url_for( 'station', station => $station_name )
				  ->query( { detailed => $self->param('detailed') } ),
			);
		}
	)->wait;
}

sub station_train_details {
	my ($self)   = @_;
	my $train_no = $self->stash('train');
	my $station  = $self->stash('station');

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	my %opt = (
		cache_hafas     => $self->app->cache_hafas,
		cache_iris_main => $self->app->cache_iris_main,
		cache_iris_rt   => $self->app->cache_iris_rt,
	);

	my $api_version = $Travel::Status::DE::IRIS::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );
	$self->stash( version    => $self->config->{version} );

	$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->subtract( minutes => 20 );
	$opt{lookahead} = 200;

	my $data   = get_results_for( 'iris', $station, %opt );
	my $errstr = $data->{errstr};

	if ( not @{ $data->{results} } ) {
		$self->render(
			'landingpage',
			error  => "Keine Abfahrt von $train_no in $station gefunden",
			status => 404,
		);
		return;
	}

	my ($result)
	  = grep { result_is_train( $_, $train_no ) } @{ $data->{results} };

	if ( not $result ) {
		$self->render(
			'landingpage',
			error  => "Keine Abfahrt von $train_no in $station gefunden",
			status => 404,
		);
		return;
	}

	my ( $info, $moreinfo ) = $self->format_iris_result_info( 'app', $result );

	my $result_info = {
		sched_arrival => $result->sched_arrival
		? $result->sched_arrival->strftime('%H:%M')
		: undef,
		sched_departure => $result->sched_departure
		? $result->sched_departure->strftime('%H:%M')
		: undef,
		arrival => $result->arrival ? $result->arrival->strftime('%H:%M')
		: undef,
		departure => $result->departure ? $result->departure->strftime('%H:%M')
		: undef,
		train_type             => $result->type // '',
		train_line             => $result->line_no,
		train_no               => $result->train_no,
		destination            => $result->destination,
		origin                 => $result->origin,
		platform               => $result->platform,
		scheduled_platform     => $result->sched_platform,
		is_cancelled           => $result->is_cancelled,
		departure_is_cancelled => $result->departure_is_cancelled,
		arrival_is_cancelled   => $result->arrival_is_cancelled,
		moreinfo               => $moreinfo,
		delay                  => $result->delay,
		route_pre              => [ $result->route_pre ],
		route_post             => [ $result->route_post ],
		replaced_by =>
		  [ map { $_->type . q{ } . $_->train_no } $result->replaced_by ],
		replacement_for =>
		  [ map { $_->type . q{ } . $_->train_no } $result->replacement_for ],
		wr_link => $result->sched_departure
		? $result->sched_departure->strftime('%Y%m%d%H%M')
		: undef,
	};

	$self->stash( title => $data->{station_name} // $self->stash('station') );
	$self->stash( hide_opts => 1 );

	$self->render_train(
		$result, $result_info,
		$data->{station_name} // $self->stash('station'),
		$self->param('ajax') ? '_train_details' : 'train_details'
	);
}

sub train_details {
	my ($self) = @_;
	my $train = $self->stash('train');

	my ( $train_type, $train_no ) = ( $train =~ m{ ^ (\S+) \s+ (.*) $ }x );

	# TODO error handling

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	my $api_version = $Travel::Status::DE::IRIS::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );
	$self->stash( version    => $self->config->{version} );

	my $res = {
		train_type      => $train_type,
		train_line      => undef,
		train_no        => $train_no,
		route_pre_diff  => [],
		route_post_diff => [],
		moreinfo        => [],
		replaced_by     => [],
		replacement_for => [],
	};

	$self->stash( title     => "${train_type} ${train_no}" );
	$self->stash( hide_opts => 1 );

	$self->render_later;

	my $linetype = 'bahn';

	$self->hafas->get_route_timestamps_p(
		train_req => "${train_type} $train_no" )->then(
		sub {
			my ( $route_ts, $route_info, $trainsearch ) = @_;

			$res->{trip_id} = $trainsearch->{trip_id};

			if ( not defined $trainsearch->{trainClass} ) {
				$linetype = 'ext';
			}
			elsif ( $trainsearch->{trainClass} <= 2 ) {
				$linetype = 'fern';
			}
			elsif ( $trainsearch->{trainClass} <= 8 ) {
				$linetype = 'bahn';
			}
			elsif ( $trainsearch->{trainClass} <= 16 ) {
				$linetype = 'sbahn';
			}

			$res->{origin}      = $route_info->{stations}[0];
			$res->{destination} = $route_info->{stations}[-1];

			$res->{route_post_diff}
			  = [ map { { name => $_ } } @{ $route_info->{stations} } ];

			if ($route_ts) {
				for my $elem ( @{ $res->{route_post_diff} } ) {
					for my $key ( keys %{ $route_ts->{ $elem->{name} } // {} } )
					{
						$elem->{$key} = $route_ts->{ $elem->{name} }{$key};
					}
				}
			}

			if ( $route_info and @{ $route_info->{messages} // [] } ) {
				my $him = $route_info->{messages};
				my @him_messages;
				for my $message ( @{$him} ) {
					if ( $message->{display} ) {
						push( @him_messages,
							[ $message->{header}, $message->{lead} ] );
						if ( $message->{lead} =~ m{zuginfo.nrw/?\?msg=(\d+)} ) {
							push(
								@{ $res->{links} },
								[
									"Großstörung",
									"https://zuginfo.nrw/?msg=$1"
								]
							);
						}
					}
				}
				$res->{moreinfo} = [@him_messages];
			}

			$self->render(
				$self->param('ajax') ? '_train_details' : 'train_details',
				departure => $res,
				linetype  => $linetype,
				icetype   => $self->app->ice_type_map->{ $res->{train_no} },
				details => {},    #$departure->{composition} // {},
				dt_now => DateTime->now( time_zone => 'Europe/Berlin' ),

				#station_name => "FIXME",#$station_name,
			);
		}
	)->catch(
		sub {
			my ($e) = @_;
			if ($e) {
				$self->render(
					'exception',
					exception => $e,
					snapshot  => {}
				);
			}
			else {
				$self->render('not_found');
			}
		}
	)->wait;
}

sub handle_result {
	my ( $self, $data ) = @_;

	my @results = @{ $data->{results} };
	my @departures;

	my @platforms      = split( /,/, $self->param('platforms') // q{} );
	my $template       = $self->param('mode') // 'app';
	my $hide_low_delay = $self->param('hidelowdelay') // 0;
	my $hide_opts      = $self->param('hide_opts') // 0;
	my $show_realtime  = $self->param('show_realtime') // 0;
	my $show_details   = $self->param('detailed') // 0;
	my $backend        = $self->param('backend') // 'iris';
	my $admode         = $self->param('admode') // 'deparr';
	my $apiver         = $self->param('version') // 0;
	my $callback       = $self->param('callback');
	my $via            = $self->param('via');

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	if ( $template eq 'single' ) {
		if ( not @platforms ) {
			for my $result (@results) {
				if (
					not( $self->numeric_platform_part( $result->platform ) ~~
						\@platforms )
				  )
				{
					push( @platforms,
						$self->numeric_platform_part( $result->platform ) );
				}
			}
			@platforms = sort { $a <=> $b } @platforms;
		}
		my %pcnt;
		@results
		  = grep { $pcnt{ $self->numeric_platform_part( $_->platform ) }++ < 1 }
		  @results;
		@results = map { $_->[1] }
		  sort { $a->[0] <=> $b->[0] }
		  map { [ $self->numeric_platform_part( $_->platform ), $_ ] } @results;
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

	@results = $self->filter_results(@results);

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
			( $info, $moreinfo )
			  = $self->format_iris_result_info( $template, $result );
		}
		else {
			( $info, $moreinfo ) = $self->format_hafas_result_info($result);
		}

		my $time     = $result->time;
		my $linetype = 'bahn';

		if ( $backend eq 'iris' ) {

			my @classes = $result->classes;
			if ( @classes == 0 ) {
				$linetype = 'ext';
			}
			elsif ( grep { $_ eq 'S' } @classes ) {
				$linetype = 'sbahn';
			}
			elsif ( grep { $_ eq 'F' } @classes ) {
				$linetype = 'fern';
			}

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

			if ( $apiver eq '1' or $apiver eq '2' ) {

				# no longer supported
				$self->handle_no_results_json(
					$backend, undef,
					"JSON API version=${apiver} is no longer supported",
					$Travel::Status::DE::IRIS::VERSION
				);
				return;
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
						$result->is_cancelled     ? '--:--' : $time,
						( $delay and $delay > 0 ) ? q{+}    : q{},
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
					train_type             => $result->type // '',
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
					linetype               => $linetype,
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
					station          => $result->station,
					moreinfo         => $moreinfo,
					delay            => $delay,
					route_pre        => [ $result->route_pre ],
					route_post       => [ $result->route_post ],
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
				$self->render_train( $result, $departures[-1],
					$data->{station_name} // $self->stash('station') );
				return;
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
	else {
		my $station_name = $data->{station_name} // $self->stash('station');
		$self->render(
			$template,
			departures       => \@departures,
			ice_type         => $self->app->ice_type_map,
			station          => $station_name,
			version          => $self->config->{version},
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
			nav_link => $self->url_for( 'station', station => $station_name )
			  ->query( { detailed => $self->param('detailed') } ),
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
