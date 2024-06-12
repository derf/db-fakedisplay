package DBInfoscreen::Controller::Stationboard;

# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use Encode          qw(decode encode);
use File::Slurp     qw(read_file write_file);
use List::Util      qw(max uniq);
use List::UtilsBy   qw(uniq_by);
use List::MoreUtils qw();
use Mojo::JSON      qw(decode_json encode_json);
use Mojo::Promise;
use Mojo::UserAgent;
use Travel::Status::DE::DBWagenreihung;
use Travel::Status::DE::EFA;
use Travel::Status::DE::HAFAS;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use XML::LibXML;

use utf8;

my %default = (
	mode   => 'app',
	admode => 'deparr',
);

sub class_to_product {
	my ( $self, $hafas ) = @_;

	my $bits = $hafas->get_active_service->{productbits};
	my $ret;

	for my $i ( 0 .. $#{$bits} ) {
		$ret->{ 2**$i }
		  = ref( $bits->[$i] ) eq 'ARRAY' ? $bits->[$i][0] : $bits->[$i];
	}

	return $ret;
}

sub handle_no_results {
	my ( $self, $station, $data, $hafas, $efa ) = @_;

	my $errstr = $data->{errstr};

	if ($efa) {
		$self->render(
			'landingpage',
			error     => ( $errstr // "Keine Abfahrten an '$station'" ),
			hide_opts => 0,
			status    => $data->{status} // 404,
		);
		return;
	}
	elsif ($hafas) {
		$self->render_later;
		my $service = 'DB';
		if ( $hafas ne '1' and Travel::Status::DE::HAFAS::get_service($hafas) )
		{
			$service = $hafas;
		}
		Travel::Status::DE::HAFAS->new_p(
			locationSearch => $station,
			service        => $service,
			promise        => 'Mojo::Promise',
			user_agent     => $self->ua,
		)->then(
			sub {
				my ($status) = @_;
				my @candidates = $status->results;
				@candidates = map { [ $_->name, $_->eva ] } @candidates;
				if ( @candidates == 1 and $candidates[0][0] ne $station ) {
					my $s      = $candidates[0][0];
					my $params = $self->req->params->to_string;
					$self->redirect_to("/${s}?${params}");
					return;
				}
				for my $candidate (@candidates) {
					$candidate->[0] =~ s{[&]#x0028;}{(}g;
					$candidate->[0] =~ s{[&]#x0029;}{)}g;
				}
				my $err;
				if ( not $errstr =~ m{LOCATION} ) {
					$err = $errstr;
				}
				$self->render(
					'landingpage',
					error       => $err,
					stationlist => \@candidates,
					hide_opts   => 0,
					status      => $data->{status} // 300,
				);
				return;
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					'landingpage',
					error     => ( $err // "Keine Abfahrten an '$station'" ),
					hide_opts => 0,
					status    => $data->{status} // 500,
				);
				return;
			}
		)->wait;
		return;
	}

	my @candidates = map { [ $_->[1], $_->[0] ] }
	  Travel::Status::DE::IRIS::Stations::get_station($station);
	if (
		@candidates > 1
		or (    @candidates == 1
			and $candidates[0][0] ne $station
			and $candidates[0][1] ne $station )
	  )
	{
		$self->render(
			'landingpage',
			stationlist => \@candidates,
			hide_opts   => 0,
			status      => $data->{status} // 300,
		);
		return;
	}
	if ( $data->{station_ds100} and $data->{station_ds100} =~ m{ ^ [OPQXYZ] }x )
	{
		$self->render(
			'landingpage',
			error => ( $errstr // "Keine Abfahrten an '$station'" )
			  . '. Das von DBF genutzte IRIS-Backend unterstützt im Regelfall nur innerdeutsche Zugfahrten.',
			hide_opts => 0,
			status    => $data->{status} // 200,
		);
		return;
	}
	$self->render(
		'landingpage',
		error     => ( $errstr // "Keine Abfahrten an '$station'" ),
		hide_opts => 0,
		status    => $data->{status} // 404,
	);
	return;
}

sub handle_no_results_json {
	my ( $self, $station, $data, $api_version ) = @_;

	my $errstr   = $data->{errstr};
	my $callback = $self->param('callback');

	$self->res->headers->access_control_allow_origin(q{*});
	my $json;
	if ($errstr) {
		$json = {
			api_version => $api_version,
			error       => $errstr,
		};
	}
	else {
		my @candidates = map { { code => $_->[0], name => $_->[1] } }
		  Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0]{code} ne $station ) )
		{
			$json = {
				api_version => $api_version,
				error       => 'ambiguous station code/name',
				candidates  => \@candidates,
			};
		}
		else {
			$json = {
				api_version => $api_version,
				error       => ( $errstr // "Got no results for '$station'" )
			};
		}
	}
	if ($callback) {
		$json = $self->render_to_string( json => $json );
		$self->render(
			data   => "$callback($json);",
			format => 'json',
		);
	}
	else {
		$self->render(
			json   => $json,
			status => $data->{status} // 300,
		);
	}
	return;
}

sub result_is_train {
	my ( $result, $train ) = @_;

	if ( $train eq $result->type . ' ' . $result->train_no ) {
		return 1;
	}
	return 0;
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

	my @route
	  = $result->can('route_post') ? $result->route_post : map { $_->loc->name }
	  $result->route;

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
	my ($suffix) = @_;
	$suffix //= q{};

	my $file    = "$ENV{DBFAKEDISPLAY_STATS}${suffix}";
	my $counter = 1;
	if ( -r $file ) {
		$counter = read_file($file) + 1;
	}
	write_file( $file, $counter );
	return;
}

sub json_route_diff {
	my ( $self, $route, $sched_route ) = @_;
	my @json_route;
	my @route       = @{$route};
	my @sched_route = @{$sched_route};

	my $route_idx = 0;
	my $sched_idx = 0;

	while ( $route_idx <= $#route and $sched_idx <= $#sched_route ) {
		if ( $route[$route_idx] eq $sched_route[$sched_idx] ) {
			push( @json_route, { name => $route[$route_idx] } );
			$route_idx++;
			$sched_idx++;
		}

		# this branch is inefficient, but won't be taken frequently
		elsif (
			not(
				List::MoreUtils::any { $route[$route_idx] eq $_ }
				@sched_route
			)
		  )
		{
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
	while ( $route_idx <= $#route ) {
		push(
			@json_route,
			{
				name         => $route[$route_idx],
				isAdditional => 1,
				isCancelled  => 0
			}
		);
		$route_idx++;
	}
	while ( $sched_idx <= $#sched_route ) {
		push(
			@json_route,
			{
				name         => $sched_route[$sched_idx],
				isAdditional => 0,
				isCancelled  => 1
			}
		);
		$sched_idx++;
	}
	return @json_route;
}

sub get_results_p {
	my ( $self, $station, %opt ) = @_;
	my $data;

	if ( $opt{efa} ) {
		my $service = 'VRR';
		if ( $opt{efa} ne '1'
			and Travel::Status::DE::EFA::get_service( $opt{efa} ) )
		{
			$service = $opt{efa};
		}
		return Travel::Status::DE::EFA->new_p(
			service     => $service,
			name        => $station,
			lwp_options => {
				timeout => 10,
				agent   => 'dbf.finalrewind.org/2'
			},
			promise    => 'Mojo::Promise',
			user_agent => Mojo::UserAgent->new,
		);
	}
	if ( $opt{hafas} ) {
		my $service = 'DB';
		if ( $opt{hafas} ne '1'
			and Travel::Status::DE::HAFAS::get_service( $opt{hafas} ) )
		{
			$service = $opt{hafas};
		}
		return Travel::Status::DE::HAFAS->new_p(
			service     => $service,
			station     => $station,
			arrivals    => $opt{arrivals},
			cache       => $opt{cache_iris_rt},
			lwp_options => {
				timeout => 10,
				agent   => 'dbf.finalrewind.org/2'
			},
			promise    => 'Mojo::Promise',
			user_agent => $self->ua,
		);
	}

	if ( $ENV{DBFAKEDISPLAY_STATS} ) {
		log_api_access();
	}

	# requests with DS100 codes should be preferred (they avoid
	# encoding problems on the IRIS server). However, only use them
	# if we have an exact match. Ask the backend otherwise.
	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	# Requests with EVA codes can be handled even if we do not know about them.
	if ( @station_matches != 1 and $station =~ m{^\d+$} ) {
		@station_matches = ( [ undef, undef, $station ] );
	}

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][2];
		return Travel::Status::DE::IRIS->new_p(
			iris_base      => $ENV{DBFAKEDISPLAY_IRIS_BASE},
			station        => $station,
			main_cache     => $opt{cache_iris_main},
			realtime_cache => $opt{cache_iris_rt},
			log_dir        => $ENV{DBFAKEDISPLAY_XMLDUMP_DIR},
			lookbehind     => 20,
			lwp_options    => {
				timeout => 10,
				agent   => 'dbf.finalrewind.org/2'
			},
			promise     => 'Mojo::Promise',
			user_agent  => Mojo::UserAgent->new,
			get_station => \&Travel::Status::DE::IRIS::Stations::get_station,
			meta        => Travel::Status::DE::IRIS::Stations::get_meta(),
			%opt
		);
	}
	elsif ( @station_matches > 1 ) {
		return Mojo::Promise->reject('Ambiguous station name');
	}
	else {
		return Mojo::Promise->reject('Unknown station name');
	}
}

sub handle_request {
	my ($self) = @_;
	my $station = $self->stash('station');

	my $template     = $self->param('mode') // 'app';
	my $efa          = $self->param('efa');
	my $hafas        = $self->param('hafas');
	my $with_related = !$self->param('no_related');
	my %opt          = (
		cache_iris_main => $self->app->cache_iris_main,
		cache_iris_rt   => $self->app->cache_iris_rt,
		lookahead       => $self->config->{lookahead},
		efa             => $efa,
		hafas           => $hafas,
	);

	if ( $self->param('past') ) {
		$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' )
		  ->subtract( minutes => 60 );
		$opt{lookahead} += 60;
	}

	if ( $self->param('admode') and $self->param('admode') eq 'arr' ) {
		$opt{arrivals} = 1;
	}

	my $api_version = $Travel::Status::DE::IRIS::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );

	if (
		not(
			List::MoreUtils::any { $template eq $_ }
			(qw(app infoscreen json multi single text))
		)
	  )
	{
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
	if (
		$template eq 'marudor'
		or (    $self->req->headers->accept
			and $self->req->headers->accept eq 'application/json' )
	  )
	{
		$template = 'json';
	}

	$self->param( mode => $template );

	if ( not $station ) {
		$self->render( 'landingpage', show_intro => 1 );
		return;
	}

	# pre-fill station / train input form
	$self->stash( input => $station );
	$self->param( input => $station );

	if ($with_related) {
		$opt{with_related} = 1;
	}

	if ( $self->param('train') and not $opt{datetime} ) {

		# request results from twenty minutes ago to avoid train details suddenly
		# becoming unavailable when its scheduled departure is reached.
		$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' )
		  ->subtract( minutes => 20 );
		$opt{lookahead} = $self->config->{lookahead} + 20;
	}

	$self->render_later;

	$self->get_results_p( $station, %opt )->then(
		sub {
			my ($status) = @_;
			if ($efa) {
				$self->handle_efa( $station, $status );
				return;
			}
			my $data = {
				results       => [ $status->results ],
				hafas         => $hafas ? $status : undef,
				station_ds100 =>
				  ( $status->station ? $status->station->{ds100} : undef ),
				station_eva => (
					$status->station
					? ( $status->station->{uic} // $status->station->{eva} )
					: undef
				),
				station_evas =>
				  ( $status->station ? $status->station->{evas} : [] ),
				station_name =>
				  ( $status->station ? $status->station->{name} : $station ),
			};

			if ( not @{ $data->{results} } and $template eq 'json' ) {
				$self->handle_no_results_json( $station, $data, $api_version );
				return;
			}
			if ( not @{ $data->{results} } ) {
				$self->handle_no_results( $station, $data, $hafas );
				return;
			}
			$self->handle_result($data);
		}
	)->catch(
		sub {
			my ($err) = @_;
			if ( $template eq 'json' ) {
				$self->handle_no_results_json(
					$station,
					{
						errstr => $err,
						status => ( $err =~ m{Ambiguous|LOCATION} ? 300 : 500 ),
					},
					$api_version
				);
				return;
			}
			$self->handle_no_results(
				$station,
				{
					errstr => $err,
					status => ( $err =~ m{Ambiguous|LOCATION} ? 300 : 500 ),
				},
				$hafas, $efa
			);
			return;
		}
	)->wait;
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
		$info = "Fahrt fällt aus";
		if ($delaymsg) {
			$info .= ": ${delaymsg}";
		}
	}
	elsif ( $result->departure_is_cancelled ) {
		$info = "Zug endet hier";
		if ($delaymsg) {
			$info .= ": ${delaymsg}";
		}
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
				$rep->type,           $rep->train_no,
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
				[ 'Außerplanmäßiger Halt in', { text => $additional_line } ]
			);
		}
	}

	if ( $result->canceled_stops and not $result->is_cancelled ) {
		my $cancel_line = join( q{, }, $result->canceled_stops );
		$info
		  = 'Ohne Halt in: ' . $cancel_line . ( $info ? ' +++ ' : q{} ) . $info;
		if ( $template ne 'json' ) {
			push( @{$moreinfo}, [ 'Ohne Halt in', { text => $cancel_line } ] );
		}
	}

	push( @{$moreinfo}, $result->messages );

	return ( $info, $moreinfo );
}

sub render_train {
	my ( $self, $result, $departure, $station_name, $template ) = @_;

	$departure->{links} = [];
	if ( $result->can('route_pre') ) {
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
	}

	if ( not $result->has_realtime ) {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		if ( $result->start < $now ) {
			$departure->{missing_realtime} = 1;
		}
		else {
			$departure->{no_realtime_yet} = 1;
		}
	}

	my $linetype = 'bahn';

	if ( $result->can('classes') ) {
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
	}
	elsif ( $result->can('class') ) {
		if ( $result->class <= 2 ) {
			$linetype = 'fern';
		}
		elsif ( $result->class == 16 ) {
			$linetype = 'sbahn';
		}
		elsif ( $result->class == 32 ) {
			$linetype = 'bus';
		}
		elsif ( $result->class == 128 ) {
			$linetype = 'ubahn';
		}
		elsif ( $result->class == 256 ) {
			$linetype = 'tram';
		}
	}

	$self->render_later;

	my $wagonorder_req  = Mojo::Promise->new;
	my $occupancy_req   = Mojo::Promise->new;
	my $stationinfo_req = Mojo::Promise->new;
	my $route_req       = Mojo::Promise->new;

	my @requests
	  = ( $wagonorder_req, $occupancy_req, $stationinfo_req, $route_req );

	if ( $departure->{wr_link} ) {
		$self->wagonorder->get_p( $result->train_no, $departure->{wr_link} )
		  ->then(
			sub {
				my ($wr_json) = @_;
				eval {
					my $wr
					  = Travel::Status::DE::DBWagenreihung->new(
						from_json => $wr_json );
					$departure->{wr}      = $wr;
					$departure->{wr_text} = join( q{ • },
						map { $_->desc_short }
						grep { $_->desc_short } $wr->groups );
					my $first = 0;
					for my $group ( $wr->groups ) {
						my $had_entry = 0;
						for my $wagon ( $group->wagons ) {
							if (
								not(   $wagon->is_locomotive
									or $wagon->is_powercar )
							  )
							{
								my $class;
								if ($first) {
									push(
										@{ $departure->{wr_preview} },
										[ '•', 'meta' ]
									);
									$first = 0;
								}
								my $entry;
								if ( $wagon->is_closed ) {
									$entry = 'X';
									$class = 'closed';
								}
								else {
									$entry = $wagon->number
									  || (
										  $wagon->type =~ m{AB} ? '½'
										: $wagon->type =~ m{A}  ? '1.'
										: $wagon->type =~ m{B}  ? '2.'
										:                         $wagon->type
									  );
								}
								if (
									$group->train_no ne $departure->{train_no} )
								{
									$class = 'otherno';
								}
								push(
									@{ $departure->{wr_preview} },
									[ $entry, $class ]
								);
								$had_entry = 1;
							}
						}
						if ($had_entry) {
							$first = 1;
						}
					}
				};
				$departure->{wr_text} ||= 'Wagen';
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
	}
	else {
		$wagonorder_req->resolve;
	}

	$self->efa->get_efa_occupancy(
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
				$departure->{wr_direction}     = $direction;
				$departure->{wr_direction_num} = $direction eq 'l' ? 0 : 100;
			}
			elsif ( $platform_info->{direction} ) {
				$departure->{wr_direction} = 'a' . $platform_info->{direction};
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

	my %opt = ( train => $result );

	#if ( $self->languages =~ m{^en} ) {
	#	$opt{language} = 'en';
	#}

	$self->hafas->get_route_p(%opt)->then(
		sub {
			my ( $route, $journey ) = @_;

			$departure->{trip_id}   = $journey->id;
			$departure->{operators} = [ $journey->operators ];
			$departure->{date} = $route->[0]{sched_dep} // $route->[0]{dep};

			# Use HAFAS route as source of truth; ignore IRIS data
			$departure->{route_pre_diff}  = [];
			$departure->{route_post_diff} = $route;
			my $split;
			for my $i ( 0 .. $#{ $departure->{route_post_diff} } ) {
				if ( $departure->{route_post_diff}[$i]{name} eq $station_name )
				{
					$split = $i;
					if ( my $load = $route->[$i]{load} ) {
						if ( %{$load} ) {
							$departure->{utilization}
							  = [ $load->{FIRST}, $load->{SECOND} ];
						}
					}
					$departure->{tz_offset}   = $route->[$i]{tz_offset};
					$departure->{local_dt_da} = $route->[$i]{local_dt_da};
					$departure->{local_sched_arr}
					  = $route->[$i]{local_sched_arr};
					$departure->{local_sched_dep}
					  = $route->[$i]{local_sched_dep};
					$departure->{is_annotated} = $route->[$i]{is_annotated};
					$departure->{prod_name}    = $route->[$i]{prod_name};
					$departure->{direction}    = $route->[$i]{direction};
					$departure->{operator}     = $route->[$i]{operator};
					last;
				}
			}

			if ( defined $split ) {
				for my $i ( 0 .. $split - 1 ) {
					push(
						@{ $departure->{route_pre_diff} },
						shift( @{ $departure->{route_post_diff} } )
					);
				}

				# remove entry for $station_name
				shift( @{ $departure->{route_post_diff} } );
			}

			my @him_messages;
			my @him_details;
			for my $message ( $journey->messages ) {
				if ( $message->code ) {
					push( @him_details,
						[ $message->short // q{}, { text => $message->text } ]
					);
				}
				else {
					push( @him_messages,
						[ $message->short // q{}, { text => $message->text } ]
					);
				}
			}
			for my $m (@him_messages) {
				if ( $m->[0] =~ s{: Information.}{:} ) {
					$m->[1]{icon} = 'info_outline';
				}
				elsif ( $m->[0] =~ s{: Störung.}{: } ) {
					$m->[1]{icon} = 'warning';
				}
				elsif ( $m->[0] =~ s{: Bauarbeiten.}{: } ) {
					$m->[1]{icon} = 'build';
				}
				$m->[0] =~ s{(?!<)->}{ → };
			}
			unshift( @{ $departure->{moreinfo} }, @him_messages );
			unshift( @{ $departure->{details} },  @him_details );
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

	# Defer rendering until all requests have completed
	Mojo::Promise->all(@requests)->then(
		sub {
			$self->respond_to(
				json => {
					json => {
						departure    => $departure,
						station_name => $station_name,
					},
				},
				any => {
					template    => $template // '_train_details',
					description => sprintf(
						'%s %s%s%s nach %s',
						$departure->{train_type},
						$departure->{train_line} // $departure->{train_no},
						$departure->{origin} ? ' von ' : q{},
						$departure->{origin}      // q{},
						$departure->{destination} // 'unbekannt'
					),
					departure => $departure,
					linetype  => $linetype,
					dt_now    => DateTime->now( time_zone => 'Europe/Berlin' ),
					station_name => $station_name,
					nav_link     =>
					  $self->url_for( 'station', station => $station_name )
					  ->query(
						{
							detailed => $self->param('detailed'),
							hafas    => $self->param('hafas')
						}
					  ),
				},
			);
		}
	)->wait;
}

# /z/:train/*station
sub station_train_details {
	my ($self)   = @_;
	my $train_no = $self->stash('train');
	my $station  = $self->stash('station');

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	if ( $station =~ s{ [.] json $ }{}x ) {
		$self->stash( format => 'json' );
	}

	my %opt = (
		cache_iris_main => $self->app->cache_iris_main,
		cache_iris_rt   => $self->app->cache_iris_rt,
	);

	my $api_version = $Travel::Status::DE::IRIS::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );
	$self->stash( version    => $self->config->{version} );

	if ( $self->param('past') ) {
		$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' )
		  ->subtract( minutes => 80 );
		$opt{lookahead} = $self->config->{lookahead} + 80;
	}
	else {
		$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' )
		  ->subtract( minutes => 20 );
		$opt{lookahead} = $self->config->{lookahead} + 20;
	}

	# Berlin Hbf exists twice:
	# - BLS / 8011160
	# - BL / 8098160 (formerly "Berlin Hbf (tief)")
	# Right now DBF assumes that station name -> EVA / DS100 is a unique map.
	# This is not the case. Work around it here until dbf has been adjusted
	# properly.
	if ( $station eq 'Berlin Hbf' ) {
		$opt{with_related} = 1;
	}

	$self->render_later;

	# Always performs an IRIS request
	$self->get_results_p( $station, %opt )->then(
		sub {
			my ($status) = @_;
			my ($result)
			  = grep { result_is_train( $_, $train_no ) } $status->results;

			if ( not $result ) {
				die("Train not found\n");
			}

			my ( $info, $moreinfo )
			  = $self->format_iris_result_info( 'app', $result );

			my $result_info = {
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
				arrival_hidden         => $result->arrival_hidden,
				departure_hidden       => $result->departure_hidden,
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
				arrival_delay          => $result->arrival_delay,
				departure_delay        => $result->departure_delay,
				route_pre              => [ $result->route_pre ],
				route_post             => [ $result->route_post ],
				replaced_by            => [
					map { $_->type . q{ } . $_->train_no } $result->replaced_by
				],
				replacement_for => [
					map { $_->type . q{ } . $_->train_no }
					  $result->replacement_for
				],
				wr_link => $result->sched_departure
				? $result->sched_departure->strftime('%Y%m%d%H%M')
				: undef,
				eva   => $result->station_uic,
				start => $result->start,
			};

			$self->stash( title => $status->station->{name}
				  // $self->stash('station') );
			$self->stash( hide_opts => 1 );

			$self->render_train(
				$result,
				$result_info,
				$status->station->{name} // $self->stash('station'),
				$self->param('ajax') ? '_train_details' : 'train_details'
			);
		}
	)->catch(
		sub {
			my ($errstr) = @_;
			$self->respond_to(
				json => {
					json => {
						error =>
"Keine Abfahrt von $train_no in $station gefunden: $errstr",
					},
					status => 404,
				},
				any => {
					template => 'landingpage',
					error    =>
"Keine Abfahrt von $train_no in $station gefunden: $errstr",
					status => 404,
				},
			);
			return;
		}
	)->wait;
}

# /z/:train
sub train_details {
	my ($self) = @_;
	my $train  = $self->stash('train');
	my $hafas  = $self->param('hafas');

	# TODO error handling

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	$self->stash( departures => [] );
	$self->stash( title      => 'DBF' );

	my $res = {
		train_type      => undef,
		train_line      => undef,
		train_no        => undef,
		route_pre_diff  => [],
		route_post_diff => [],
		moreinfo        => [],
		replaced_by     => [],
		replacement_for => [],
	};

	my %opt;

	if ( $train =~ m{[|]} ) {
		$opt{trip_id} = $train;
	}
	else {
		my ( $train_type, $train_no ) = ( $train =~ m{ ^ (\S+) \s+ (.*) $ }x );
		$res->{train_type} = $train_type;
		$res->{train_no}   = $train_no;
		$self->stash( title => "${train_type} ${train_no}" );
		$opt{train_type} = $train_type;
		$opt{train_no}   = $train_no;
	}

	my $service = 'DB';
	if (    $hafas
		and $hafas ne '1'
		and Travel::Status::DE::HAFAS::get_service($hafas) )
	{
		$opt{service} = $hafas;
	}

	#if ( $self->languages =~ m{^en} ) {
	#	$opt{language} = 'en';
	#}

	if ( my $date = $self->param('date') ) {
		if ( $date
			=~ m{ ^ (?<day> \d{1,2} ) [.] (?<month> \d{1,2} ) [.] (?<year> \d{4})? $ }x
		  )
		{
			$opt{datetime} = DateTime->now( time_zone => 'Europe/Berlin' );
			$opt{datetime}->set(
				day   => $+{day},
				month => $+{month}
			);
			if ( $+{year} ) {
				$opt{datetime}->set( year => $+{year} );
			}
		}
	}

	$self->stash( hide_opts => 1 );
	$self->render_later;

	my $linetype = 'bahn';

	$self->hafas->get_route_p(%opt)->then(
		sub {
			my ( $route, $journey, $hafas_obj ) = @_;

			$res->{trip_id} = $journey->id;
			$res->{date}    = $route->[0]{sched_dep} // $route->[0]{dep};

			my $product = $journey->product;

			if ( my $req_name = $self->param('highlight') ) {
				if ( my $p = $journey->product_at($req_name) ) {
					$product = $p;
				}
			}

			my $train_type = $res->{train_type} = $product->type   // q{};
			my $train_no   = $res->{train_no}   = $product->number // q{};
			$res->{train_line} = $product->line_no // q{};
			$self->stash( title => $train_type . ' '
				  . ( $train_no || $res->{train_line} ) );

			if ( not defined $product->class ) {
				$linetype = 'ext';
			}
			else {
				my $prod
				  = $self->class_to_product($hafas_obj)->{ $product->class }
				  // q{};
				if ( $prod eq 'ice' or $prod eq 'ic_ec' ) {
					$linetype = 'fern';
				}
				elsif ( $prod eq 's' ) {
					$linetype = 'sbahn';
				}
				elsif ( $prod eq 'bus' ) {
					$linetype = 'bus';
				}
				elsif ( $prod eq 'u' ) {
					$linetype = 'ubahn';
				}
				elsif ( $prod eq 'tram' ) {
					$linetype = 'tram';
				}
			}

			$res->{origin}      = $journey->route_start;
			$res->{destination} = $journey->route_end;
			$res->{operators}   = [ $journey->operators ];

			$res->{route_post_diff} = $route;

			if ( my $req_name = $self->param('highlight') ) {
				my $split;
				for my $i ( 0 .. $#{ $res->{route_post_diff} } ) {
					if ( $res->{route_post_diff}[$i]{name} eq $req_name ) {
						$split = $i;
						last;
					}
				}
				if ( defined $split ) {
					$self->stash( station_name => $req_name );
					for my $i ( 0 .. $split - 1 ) {
						push(
							@{ $res->{route_pre_diff} },
							shift( @{ $res->{route_post_diff} } )
						);
					}
					my $station_info = shift( @{ $res->{route_post_diff} } );
					$res->{eva} = $station_info->{eva};
					if ( $station_info->{sched_arr} ) {
						$res->{sched_arrival}
						  = $station_info->{sched_arr}->strftime('%H:%M');
					}
					if ( $station_info->{rt_arr} ) {
						$res->{arrival}
						  = $station_info->{rt_arr}->strftime('%H:%M');
					}
					if ( $station_info->{sched_dep} ) {
						$res->{sched_departure}
						  = $station_info->{sched_dep}->strftime('%H:%M');
					}
					if ( $station_info->{rt_dep} ) {
						$res->{departure}
						  = $station_info->{rt_dep}->strftime('%H:%M');
					}
					$res->{arrival_is_cancelled}
					  = $station_info->{arr_cancelled};
					$res->{departure_is_cancelled}
					  = $station_info->{dep_cancelled};
					$res->{is_cancelled} = $res->{arrival_is_cancelled}
					  || $res->{arrival_is_cancelled};
					$res->{tz_offset}       = $station_info->{tz_offset};
					$res->{local_dt_da}     = $station_info->{local_dt_da};
					$res->{local_sched_arr} = $station_info->{local_sched_arr};
					$res->{local_sched_dep} = $station_info->{local_sched_dep};
					$res->{is_annotated}    = $station_info->{is_annotated};
					$res->{prod_name}       = $station_info->{prod_name};
					$res->{direction}       = $station_info->{direction};
					$res->{operator}        = $station_info->{operator};
					$res->{platform}        = $station_info->{platform};
					$res->{scheduled_platform}
					  = $station_info->{sched_platform};
				}
			}

			my @him_messages;
			my @him_details;
			for my $message ( $journey->messages ) {
				if ( $message->code ) {
					push( @him_details,
						[ $message->short // q{}, { text => $message->text } ]
					);
				}
				else {
					push( @him_messages,
						[ $message->short // q{}, { text => $message->text } ]
					);
				}
			}
			for my $m (@him_messages) {
				if ( $m->[0] =~ s{: Information.}{:} ) {
					$m->[1]{icon} = 'info_outline';
				}
				elsif ( $m->[0] =~ s{: Störung.}{: } ) {
					$m->[1]{icon} = 'warning';
				}
				elsif ( $m->[0] =~ s{: Bauarbeiten.}{: } ) {
					$m->[1]{icon} = 'build';
				}
			}
			if (@him_messages) {
				$res->{moreinfo} = [@him_messages];
			}
			if (@him_details) {
				$res->{details} = [@him_details];
			}

			$self->respond_to(
				json => {
					json => {
						journey => $journey,
					},
				},
				any => {
					template => $self->param('ajax')
					? '_train_details'
					: 'train_details',
					description => sprintf(
						'%s %s%s%s nach %s',
						$res->{train_type},
						$res->{train_line} // $res->{train_no},
						$res->{origin} ? ' von ' : q{},
						$res->{origin}      // q{},
						$res->{destination} // 'unbekannt'
					),
					departure => $res,
					linetype  => $linetype,
					dt_now    => DateTime->now( time_zone => 'Europe/Berlin' ),
				},
			);
		}
	)->catch(
		sub {
			my ($e) = @_;
			if ($e) {
				$self->respond_to(
					json => {
						json => {
							error => $e,
						},
						status => 500,
					},
					any => {
						template  => 'exception',
						message   => $e,
						exception => undef,
						snapshot  => {},
						status    => 500,
					},
				);
			}
			else {
				$self->render( 'not_found', status => 404 );
			}
		}
	)->wait;
}

sub handle_efa {
	my ( $self, $station_name, $efa ) = @_;
	my $template       = $self->param('mode')         // 'app';
	my $hide_low_delay = $self->param('hidelowdelay') // 0;
	my $hide_opts      = $self->param('hide_opts')    // 0;
	my $show_realtime  = $self->param('rt') // $self->param('show_realtime')
	  // 0;

	my @departures;

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	for my $result ( $efa->results ) {
		my $time;

		if ( $show_realtime and $result->rt_datetime ) {
			$time = $result->rt_datetime->strftime('%H:%M');
		}
		else {
			$time = $result->sched_datetime->strftime('%H:%M');
		}

		my $linetype = $result->mot_name // 'bahn';
		if ( $linetype eq 's-bahn' ) {
			$linetype = 'sbahn';
		}
		elsif ( $linetype eq 'u-bahn' ) {
			$linetype = 'ubahn';
		}
		elsif ( $linetype =~ m{bus} ) {
			$linetype = 'bus';
		}
		elsif ( $linetype eq 'zug' ) {
			$linetype = 'bahn';
		}
		elsif ( $linetype eq 'sonstige' ) {
			$linetype = 'ext';
		}
		push(
			@departures,
			{
				time            => $time,
				sched_departure => $result->sched_datetime->strftime('%H:%M'),
				departure       => $result->rt_datetime
				? $result->rt_datetime->strftime('%H:%M')
				: undef,
				train           => $result->line,
				train_type      => q{},
				train_line      => $result->line,
				train_no        => $result->train_no,
				via             => [],
				origin          => $result->origin,
				destination     => $result->destination,
				platform        => $result->platform,
				is_cancelled    => $result->is_cancelled,
				linetype        => $linetype,
				delay           => $result->delay,
				occupancy       => $result->occupancy,
				replaced_by     => [],
				replacement_for => [],
				route_pre       => [],
				route_post      => [],
				wr_link         => undef,
			}
		);
	}

	$self->render(
		$template,
		description      => "Abfahrtstafel $station_name",
		departures       => \@departures,
		station          => $station_name,
		version          => $self->config->{version},
		title            => $station_name,
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

sub handle_result {
	my ( $self, $data ) = @_;

	my @results = @{ $data->{results} };
	my @departures;

	my @platforms      = split( /,/, $self->param('platforms') // q{} );
	my $template       = $self->param('mode')         // 'app';
	my $hide_low_delay = $self->param('hidelowdelay') // 0;
	my $hide_opts      = $self->param('hide_opts')    // 0;
	my $show_realtime  = $self->param('rt') // $self->param('show_realtime')
	  // 0;
	my $show_details = $self->param('detailed') // 0;
	my $admode       = $self->param('admode')   // 'deparr';
	my $apiver       = $self->param('version')  // 0;
	my $callback     = $self->param('callback');
	my $via          = $self->param('via');
	my $hafas        = $self->param('hafas');
	my $hafas_obj    = $data->{hafas};

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );

	if ( $self->param('ajax') ) {
		delete $self->stash->{layout};
	}

	if ( $template eq 'single' ) {
		if ( not @platforms ) {
			for my $result (@results) {
				my $num_part
				  = $self->numeric_platform_part( $result->platform );
				if (
					not( List::MoreUtils::any { $num_part eq $_ } @platforms ) )
				{
					push( @platforms, $num_part );
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

	if ($show_realtime) {
		if ($hafas) {
			@results = sort { $a->datetime <=> $b->datetime } @results;
		}
		elsif ( $admode eq 'arr' ) {
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

	my $class_to_product
	  = $hafas_obj ? $self->class_to_product($hafas_obj) : {};

	@results = $self->filter_results(@results);

	for my $result (@results) {
		my $platform = ( split( qr{ }, $result->platform // '' ) )[0];
		my $delay    = $result->delay;
		if ( $admode eq 'arr' and not $hafas and not $result->arrival ) {
			next;
		}
		if (    $admode eq 'dep'
			and not $hafas
			and not $result->departure )
		{
			next;
		}
		my ( $info, $moreinfo );
		if ( $result->can('replacement_for') ) {
			( $info, $moreinfo )
			  = $self->format_iris_result_info( $template, $result );
		}

		my $time
		  = $result->can('time')
		  ? $result->time
		  : $result->sched_datetime->strftime('%H:%M');
		my $linetype = 'bahn';

		if ( $result->can('classes') ) {
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
		}
		elsif ( $result->can('class') ) {
			my $prod = $class_to_product->{ $result->class } // q{};
			if ( $prod eq 'ice' or $prod eq 'ic_ec' ) {
				$linetype = 'fern';
			}
			elsif ( $prod eq 's' ) {
				$linetype = 'sbahn';
			}
			elsif ( $prod eq 'bus' ) {
				$linetype = 'bus';
			}
			elsif ( $prod eq 'u' ) {
				$linetype = 'ubahn';
			}
			elsif ( $prod eq 'tram' ) {
				$linetype = 'tram';
			}
		}

		# ->time defaults to dep, so we only need to overwrite $time
		# if we want arrival times
		if ( $admode eq 'arr' and not $hafas ) {
			$time = $result->sched_arrival->strftime('%H:%M');
		}

		if ($show_realtime) {
			if ($hafas) {
				$time = $result->datetime->strftime('%H:%M');
			}
			elsif ( ( $admode eq 'arr' and $result->arrival )
				or not $result->departure )
			{
				$time = $result->arrival->strftime('%H:%M');
			}
			else {
				$time = $result->departure->strftime('%H:%M');
			}
		}

		if ($hide_low_delay) {
			if ($info) {
				$info =~ s{ (?: ca [.] \s* )? [+] [ 1 2 3 4 ] $ }{}x;
			}
		}
		if ($info) {
			$info =~ s{ (?: ca [.] \s* )? [+] (\d+) }{Verspätung ca $1 Min.}x;
		}

		if ( $template eq 'json' ) {
			my @json_route;
			if ( $result->can('sched_route') ) {
				@json_route = $self->json_route_diff( [ $result->route ],
					[ $result->sched_route ] );
			}
			else {
				@json_route = map { $_->TO_JSON } $result->route;
			}

			if ( $apiver eq '1' or $apiver eq '2' ) {

				# no longer supported
				$self->handle_no_results_json(
					undef,
					{
						errstr =>
						  "JSON API version=${apiver} is no longer supported"
					},
					$Travel::Status::DE::IRIS::VERSION
				);
				return;
			}
			else {    # apiver == 3
				if ( $result->isa('Travel::Status::DE::IRIS::Result') ) {
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
						$sched_dep
						  = $result->sched_departure->strftime('%H:%M');
					}
					push(
						@departures,
						{
							delayArrival   => $delay_arr,
							delayDeparture => $delay_dep,
							destination    => $result->destination,
							isCancelled    => $result->is_cancelled,
							messages       => {
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
							missingRealtime => (
								(
									not $result->has_realtime
									  and $result->start < $now
								) ? \1 : \0
							),
							platform           => $result->platform,
							route              => \@json_route,
							scheduledPlatform  => $result->sched_platform,
							scheduledArrival   => $sched_arr,
							scheduledDeparture => $sched_dep,
							train              => $result->train,
							trainClasses       => [ $result->classes ],
							trainNumber        => $result->train_no,
							via => [ $result->route_interesting(3) ],
						}
					);
				}
				else {
					push(
						@departures,
						{
							delay             => $result->delay,
							direction         => $result->direction,
							destination       => $result->destination,
							isCancelled       => $result->is_cancelled,
							messages          => [ $result->messages ],
							platform          => $result->platform,
							route             => \@json_route,
							scheduledPlatform => $result->sched_platform,
							scheduledTime     => $result->sched_datetime->epoch,
							time              => $result->datetime->epoch,
							train             => $result->line,
							trainNumber       => $result->number,
							via => [ $result->route_interesting(3) ],
						}
					);
				}
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
		else {
			if ( $result->can('replacement_for') ) {
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
						train              => $result->train,
						train_type         => $result->type // '',
						train_line         => $result->line_no,
						train_no           => $result->train_no,
						via                => [ $result->route_interesting(3) ],
						destination        => $result->destination,
						origin             => $result->origin,
						platform           => $result->platform,
						scheduled_platform => $result->sched_platform,
						info               => $info,
						is_cancelled       => $result->is_cancelled,
						departure_is_cancelled =>
						  $result->departure_is_cancelled,
						arrival_is_cancelled => $result->arrival_is_cancelled,
						linetype             => $linetype,
						messages             => {
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
						station          => $result->station,
						moreinfo         => $moreinfo,
						delay            => $delay,
						arrival_delay    => $result->arrival_delay,
						departure_delay  => $result->departure_delay,
						missing_realtime => (
							not $result->has_realtime
							  and $result->start < $now ? 1 : 0
						),
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
			}
			else {
				my $city = q{};
				if ( $result->station =~ m{ , ([^,]+) $ }x ) {
					$city = $1;
				}
				push(
					@departures,
					{
						time            => $time,
						sched_departure =>
						  ( $result->sched_datetime and $admode ne 'arr' )
						? $result->sched_datetime->strftime('%H:%M')
						: undef,
						departure =>
						  ( $result->rt_datetime and $admode ne 'arr' )
						? $result->rt_datetime->strftime('%H:%M')
						: undef,
						train      => $result->name,
						train_type => q{},
						train_line => $result->line,
						train_no   => $result->number,
						journey_id => $result->id,
						via        => [
							map { $_->loc->name =~ s{,\Q$city\E}{}r }
							  $result->route_interesting(3)
						],
						destination => $result->route_end =~ s{,\Q$city\E}{}r,
						origin      => $result->route_end =~ s{,\Q$city\E}{}r,
						platform           => $result->platform,
						scheduled_platform => $result->sched_platform,
						load               => $result->load // {},
						info               => $info,
						is_cancelled       => $result->is_cancelled,
						linetype           => $linetype,
						station            => $result->station,
						moreinfo           => $moreinfo,
						delay              => $delay,
						replaced_by        => [],
						replacement_for    => [],
						route_pre          => $admode eq 'arr'
						? [ map { $_->loc->name } $result->route ]
						: [],
						route_post => $admode eq 'arr' ? []
						: [ map { $_->loc->name } $result->route ],
						wr_link => $result->sched_datetime
						? $result->sched_datetime->strftime('%Y%m%d%H%M')
						: undef,
					}
				);
			}
			if ( $self->param('train') ) {
				$self->render_train( $result, $departures[-1],
					$data->{station_name} // $self->stash('station') );
				return;
			}
		}
	}

	if ( $template eq 'json' ) {
		$self->res->headers->access_control_allow_origin(q{*});
		my $json = {
			departures => \@departures,
		};
		if ($callback) {
			$json = $self->render_to_string( json => $json );
			$self->render(
				data   => "$callback($json);",
				format => 'json'
			);
		}
		else {
			$self->render(
				json => $json,
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
		my ( $api_link, $api_text, $api_icon );
		my $params = $self->req->params->clone;
		$params->param( hafas => not $params->param('hafas') );
		if ( $params->param('hafas') ) {
			if (    $data->{station_eva} >= 8100000
				and $data->{station_eva} < 8200000 )
			{
				$params->param( hafas => 'ÖBB' );
			}
			$api_link = '/' . $data->{station_eva} . '?' . $params->to_string;
			$api_text = 'Auf Nahverkehr wechseln';
			$api_icon = 'train';
		}
		else {
			my $iris_eva = List::Util::min grep { $_ >= 1000000 }
			  @{ $data->{station_evas} // [] };
			if ($iris_eva) {
				$api_link = '/' . $iris_eva . '?' . $params->to_string;
				$api_text = 'Auf Bahnverkehr wechseln';
				$api_icon = 'directions';
			}
		}
		$self->render(
			$template,
			description => 'Abfahrtstafel '
			  . ( $via ? "$station_name via $via" : $station_name ),
			api_link         => $api_link,
			api_text         => $api_text,
			api_icon         => $api_icon,
			departures       => \@departures,
			station          => $station_name,
			version          => $self->config->{version},
			title            => $via ? "$station_name → $via" : $station_name,
			refresh_interval => $template eq 'app' ? 0        : 120,
			hide_opts        => $hide_opts,
			hide_low_delay   => $hide_low_delay,
			show_realtime    => $show_realtime,
			load_marquee     => (
				     $template eq 'single'
				  or $template eq 'multi'
			),
			force_mobile => ( $template eq 'app' ),
			nav_link     =>
			  $self->url_for( 'station', station => $station_name )->query(
				{
					detailed => $self->param('detailed'),
					hafas    => $self->param('hafas')
				}
			  ),
		);
	}
	return;
}

sub stations_by_coordinates {
	my $self = shift;

	my $lon   = $self->param('lon');
	my $lat   = $self->param('lat');
	my $hafas = $self->param('hafas');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
		return;
	}

	my $service = 'DB';
	if (    $hafas
		and $hafas ne '1'
		and Travel::Status::DE::HAFAS::get_service($hafas) )
	{
		$service = $hafas;
	}

	$self->render_later;

	my @iris = map {
		{
			ds100    => $_->[0][0],
			name     => $_->[0][1],
			eva      => $_->[0][2],
			lon      => $_->[0][3],
			lat      => $_->[0][4],
			distance => $_->[1],
			hafas    => 0,
		}
	} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
		$lat, 10 );

	@iris = uniq_by { $_->{name} } @iris;

	Travel::Status::DE::HAFAS->new_p(
		promise    => 'Mojo::Promise',
		user_agent => $self->ua,
		service    => $service,
		geoSearch  => {
			lat => $lat,
			lon => $lon
		}
	)->then(
		sub {
			my ($hafas) = @_;
			my @hafas = map {
				{
					name     => $_->name,
					eva      => $_->eva,
					distance => $_->distance_m / 1000,
					hafas    => $service,
				}
			} $hafas->results;
			if ( @hafas > 10 ) {
				@hafas = @hafas[ 0 .. 9 ];
			}
			my @results = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map { [ $_, $_->{distance} ] } ( @iris, @hafas );
			$self->render(
				json => {
					candidates => [@results],
				}
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				json => {
					candidates => [@iris],
					warning    => $err,
				}
			);
		}
	)->wait;
}

sub autocomplete {
	my ($self) = @_;

	$self->res->headers->cache_control('max-age=31536000, immutable');

	my $output = '$(function(){const stations=';
	$output
	  .= encode_json(
		[ map { $_->[1] } Travel::Status::DE::IRIS::Stations::get_stations() ]
	  );
	$output .= ";\n";
	$output
	  .= "\$('input.station').autocomplete({delay:0,minLength:3,source:stations});});\n";

	$self->render(
		format => 'js',
		data   => $output
	);
}

sub redirect_to_station {
	my ($self) = @_;
	my $input  = $self->param('input');
	my $params = $self->req->params;

	$params->remove('input');

	for my $param (qw(platforms mode admode via)) {
		if (
			not $params->param($param)
			or ( exists $default{$param}
				and $params->param($param) eq $default{$param} )
		  )
		{
			$params->remove($param);
		}
	}

	if ( $input =~ m{ ^ [a-zA-Z]{1,5} \s+ \d+ }x ) {
		if ( $input =~ s{ \s* @ \s* (?<date> [0-9.]+) $ }{}x ) {
			$params->param( date => $+{date} );
		}
		elsif ( $input =~ s{ \s* [(] \s* (?<date> [0-9.]+) \s* [)] $ }{}x ) {
			$params->param( date => $+{date} );
		}
		$params = $params->to_string;
		$self->redirect_to("/z/${input}?${params}");
	}
	elsif ( $params->param('hafas') and $params->param('hafas') ne '1' ) {
		$params = $params->to_string;
		$self->redirect_to("/${input}?${params}");
	}
	else {
		my @candidates
		  = Travel::Status::DE::IRIS::Stations::get_station($input);
		if (
			@candidates == 1
			and (  $input eq $candidates[0][0]
				or lc($input) eq lc( $candidates[0][1] )
				or $input eq $candidates[0][2] )
		  )
		{
			$params->remove('hafas');
		}
		else {
			$params->param( hafas => 1 );
		}
		$params = $params->to_string;
		$self->redirect_to("/${input}?${params}");
	}
}

1;
