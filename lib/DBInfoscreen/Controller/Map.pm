package DBInfoscreen::Controller::Map;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::Promise;

use DateTime;
use DateTime::Format::Strptime;
use Geo::Distance;

my $dbf_version = qx{git describe --dirty} || 'experimental';

my $strp = DateTime::Format::Strptime->new(
	pattern   => '%Y-%m-%dT%H:%M:%S.000%z',
	time_zone => 'Europe/Berlin',
);

chomp $dbf_version;

# Input: (HAFAS TripID, line number)
# Output: Promise returning a
# https://github.com/public-transport/hafas-client/blob/4/docs/trip.md instance
# on success
sub get_hafas_polyline_p {
	my ( $self, $trip_id, $line ) = @_;

	my $url
	  = "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->app->cache_iris_rt;
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->ua->request_timeout(5)
	  ->get_p(
		$url => { 'User-Agent' => "dbf.finalrewind.org/${dbf_version}" } )
	  ->then(
		sub {
			my ($tx) = @_;
			my $json = decode_json( $tx->res->body );
			my @coordinate_list;

			for my $feature ( @{ $json->{polyline}{features} } ) {
				if ( exists $feature->{geometry}{coordinates} ) {
					push( @coordinate_list, $feature->{geometry}{coordinates} );
				}

				#if ($feature->{type} eq 'Feature') {
				#	say "Feature " . $feature->{properties}{name};
				#}
			}

			my $ret = {
				name     => $json->{line}{name} // '?',
				polyline => [@coordinate_list],
				raw      => $json,
			};

			$cache->freeze( $url, $ret );
			$promise->resolve($ret);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
		}
	)->wait;

	return $promise;
}

# Input:
#   now: DateTime
#   from: current/previous stop
#         {dep => DateTime, name => str, lat => float, lon => float}
#   to: next stop
#       {arr => DateTime, name => str, lat => float, lon => float}
#   features: https://github.com/public-transport/hafas-client/blob/4/docs/trip.md features array
# Output: list of estimated train positions in [lat, lon] format.
# - current position
# - position 2 seconds from now
# - position 4 seconds from now
# - ...
sub estimate_train_positions {
	my (%opt) = @_;

	my $now = $opt{now};

	my $from_dt   = $opt{from}{dep};
	my $to_dt     = $opt{to}{arr};
	my $from_name = $opt{from}{name};
	my $to_name   = $opt{to}{name};
	my $features  = $opt{features};

	my @train_positions;

	my $time_complete = $now->epoch - $from_dt->epoch;
	my $time_total    = $to_dt->epoch - $from_dt->epoch;

	my @completion_ratios
	  = map { ( $time_complete + ( $_ * 2 ) ) / $time_total } ( 0 .. 45 );

	my $geo = Geo::Distance->new;
	my ( $from_index, $to_index );

	for my $j ( 0 .. $#{$features} ) {
		my $this_point = $features->[$j];
		if (    not defined $from_index
			and $this_point->{properties}{type}
			and $this_point->{properties}{type} eq 'stop'
			and $this_point->{properties}{name} eq $from_name )
		{
			$from_index = $j;
		}
		elsif ( $this_point->{properties}{type}
			and $this_point->{properties}{type} eq 'stop'
			and $this_point->{properties}{name} eq $to_name )
		{
			$to_index = $j;
			last;
		}
	}
	if ( defined $from_index and defined $to_index ) {
		my $total_distance = 0;
		for my $j ( $from_index + 1 .. $to_index ) {
			my $prev = $features->[ $j - 1 ]{geometry}{coordinates};
			my $this = $features->[$j]{geometry}{coordinates};
			if ( $prev and $this ) {
				$total_distance += $geo->distance(
					'kilometer', $prev->[0], $prev->[1],
					$this->[0],  $this->[1]
				);
			}
		}
		my @marker_distances = map { $total_distance * $_ } @completion_ratios;
		$total_distance = 0;
		for my $j ( $from_index + 1 .. $to_index ) {
			my $prev = $features->[ $j - 1 ]{geometry}{coordinates};
			my $this = $features->[$j]{geometry}{coordinates};
			if ( $prev and $this ) {
				my $prev_distance = $total_distance;
				$total_distance += $geo->distance(
					'kilometer', $prev->[0], $prev->[1],
					$this->[0],  $this->[1]
				);
				for my $i ( @train_positions .. $#marker_distances ) {
					my $marker_distance = $marker_distances[$i];
					if ( $total_distance > $marker_distance ) {

						# completion ratio for the line between (prev, this)
						my $sub_ratio = 1;
						if ( $total_distance != $prev_distance ) {
							$sub_ratio = ( $marker_distance - $prev_distance )
							  / ( $total_distance - $prev_distance );
						}

						my $lat = $prev->[1]
						  + ( $this->[1] - $prev->[1] ) * $sub_ratio;
						my $lon = $prev->[0]
						  + ( $this->[0] - $prev->[0] ) * $sub_ratio;

						push( @train_positions, [ $lat, $lon ] );
					}
				}
				if ( @train_positions == @completion_ratios ) {
					return @train_positions;
				}
			}
		}
		if (@train_positions) {
			return @train_positions;
		}
	}
	else {
		for my $ratio (@completion_ratios) {
			my $lat
			  = $opt{from}{lat} + ( $opt{to}{lat} - $opt{from}{lat} ) * $ratio;
			my $lon
			  = $opt{from}{lon} + ( $opt{to}{lon} - $opt{from}{lon} ) * $ratio;
			push( @train_positions, [ $lat, $lon ] );
		}
		return @train_positions;
	}
	return [ $opt{to}{lat}, $opt{to}{lon} ];
}

# Input:
#   now: DateTime
#   route: hash
#     lat: float
#     lon: float
#     name: str
#     arr: DateTime
#     dep: DateTime
#   features: ref to transport.rest features list
#  Output:
#    next_stop: {type, station}
#    positions: [current position [lat, lon], 2s from now, 4s from now, ...]
sub estimate_train_positions2 {
	my (%opt) = @_;
	my $now   = $opt{now};
	my @route = @{ $opt{route} // [] };

	my @train_positions;
	my $next_stop;

	for my $i ( 1 .. $#route ) {
		if (    $route[$i]{arr}
			and $route[ $i - 1 ]{dep}
			and $now > $route[ $i - 1 ]{dep}
			and $now < $route[$i]{arr} )
		{

			# (current position, future positons...) in 2 second steps
			@train_positions = estimate_train_positions(
				from     => $route[ $i - 1 ],
				to       => $route[$i],
				now      => $now,
				features => $opt{features},
			);

			$next_stop = {
				type    => 'next',
				station => $route[$i],
			};
			last;
		}
		if ( $route[ $i - 1 ]{dep} and $now <= $route[ $i - 1 ]{dep} ) {
			@train_positions
			  = ( [ $route[ $i - 1 ]{lat}, $route[ $i - 1 ]{lon} ] );
			$next_stop = {
				type    => 'present',
				station => $route[ $i - 1 ],
			};
			last;
		}
	}

	if ( not $next_stop ) {
		@train_positions = ( [ $route[-1]{lat}, $route[-1]{lon} ] );
		$next_stop       = {
			type    => 'present',
			station => $route[-1]
		};
	}

	my $position_now = shift @train_positions;

	return {
		next_stop    => $next_stop,
		position_now => $position_now,
		positions    => \@train_positions,
	};
}

sub route_to_ajax {
	my (@stopovers) = @_;

	my @route_entries;

	for my $stop (@stopovers) {
		my @stop_entries = ( $stop->{stop}{name} );
		my $platform;

		if ( $stop->{arrival}
			and my $arr = $strp->parse_datetime( $stop->{arrival} ) )
		{
			my $delay = ( $stop->{arrivalDelay} // 0 ) / 60;
			$platform = $stop->{arrivalPlatform};

			push( @stop_entries, $arr->epoch, $delay );
		}
		else {
			push( @stop_entries, q{}, q{} );
		}

		if ( $stop->{departure}
			and my $dep = $strp->parse_datetime( $stop->{departure} ) )
		{
			my $delay = ( $stop->{departureDelay} // 0 ) / 60;
			$platform //= $stop->{departurePlatform} // q{};

			push( @stop_entries, $dep->epoch, $delay, $platform );
		}
		else {
			push( @stop_entries, q{}, q{}, q{} );
		}

		push( @route_entries, join( ';', @stop_entries ) );
	}

	return join( '|', @route_entries );
}

# Input: List of transport.rest stopovers
# Output: List of preprocessed stops. Each is a hash with the following keys:
#   lat: float
#   lon: float
#   name: str
#   arr: DateTime
#   dep: DateTime
#   arr_delay: int
#   dep_delay: int
#   platform: str
sub stopovers_to_route {
	my (@stopovers) = @_;
	my @route;

	for my $stop (@stopovers) {
		my @stop_lines = ( $stop->{stop}{name} );
		my ( $platform, $arr, $dep, $arr_delay, $dep_delay );

		if (    $stop->{arrival}
			and $arr = $strp->parse_datetime( $stop->{arrival} ) )
		{
			$arr_delay = ( $stop->{arrivalDelay} // 0 ) / 60;
			$platform //= $stop->{arrivalPlatform};
		}

		if (    $stop->{departure}
			and $dep = $strp->parse_datetime( $stop->{departure} ) )
		{
			$dep_delay = ( $stop->{departureDelay} // 0 ) / 60;
			$platform //= $stop->{departurePlatform};
		}

		push(
			@route,
			{
				lat       => $stop->{stop}{location}{latitude},
				lon       => $stop->{stop}{location}{longitude},
				name      => $stop->{stop}{name},
				arr       => $arr,
				dep       => $dep,
				arr_delay => $arr_delay,
				dep_delay => $dep_delay,
				platform  => $platform,
			}
		);

	}
	return @route;
}

sub route {
	my ($self)  = @_;
	my $trip_id = $self->stash('tripid');
	my $line_no = $self->stash('lineno');

	my $from_name = $self->param('from');
	my $to_name   = $self->param('to');

	$self->render_later;

	$self->get_hafas_polyline_p( $trip_id, $line_no )->then(
		sub {
			my ($pl) = @_;

			my @polyline = @{ $pl->{polyline} };
			my @line_pairs;
			my @station_coordinates;

			my @markers;
			my $next_stop;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			# @line_pairs are used to draw the train's journey on the map
			for my $i ( 1 .. $#polyline ) {
				push(
					@line_pairs,
					[
						[ $polyline[ $i - 1 ][1], $polyline[ $i - 1 ][0] ],
						[ $polyline[$i][1],       $polyline[$i][0] ]
					]
				);
			}

			my @route = stopovers_to_route( @{ $pl->{raw}{stopovers} // [] } );

			# Prepare from/to markers and name/time/delay overlays for stations
			for my $stop (@route) {
				my @stop_lines = ( $stop->{name} );

				if ( $from_name and $stop->{name} eq $from_name ) {
					push(
						@markers,
						{
							lon   => $stop->{lon},
							lat   => $stop->{lat},
							title => $stop->{name},
							icon  => 'goldIcon',
						}
					);
				}
				if ( $to_name and $stop->{name} eq $to_name ) {
					push(
						@markers,
						{
							lon   => $stop->{lon},
							lat   => $stop->{lat},
							title => $stop->{name},
							icon  => 'greenIcon',
						}
					);
				}

				if ( $stop->{platform} ) {
					push( @stop_lines, 'Gleis ' . $stop->{platform} );
				}
				if ( $stop->{arr} ) {
					my $arr_line = $stop->{arr}->strftime('Ankunft: %H:%M');
					if ( $stop->{arr_delay} ) {
						$arr_line .= sprintf( ' (%+d)', $stop->{arr_delay} );
					}
					push( @stop_lines, $arr_line );
				}
				if ( $stop->{dep} ) {
					my $dep_line = $stop->{dep}->strftime('Abfahrt: %H:%M');
					if ( $stop->{dep_delay} ) {
						$dep_line .= sprintf( ' (%+d)', $stop->{dep_delay} );
					}
					push( @stop_lines, $dep_line );
				}

				push( @station_coordinates,
					[ [ $stop->{lat}, $stop->{lon} ], [@stop_lines], ] );
			}

			my $train_pos = estimate_train_positions2(
				now      => $now,
				route    => \@route,
				features => $pl->{raw}{polyline}{features},
			);

			push(
				@markers,
				{
					lat   => $train_pos->{position_now}[0],
					lon   => $train_pos->{position_now}[1],
					title => $pl->{name}
				}
			);
			$next_stop = $train_pos->{next_stop};

			$self->render(
				'route_map',
				title      => $pl->{name},
				hide_opts  => 1,
				with_map   => 1,
				ajax_req   => "${trip_id}/${line_no}",
				ajax_route => route_to_ajax( @{ $pl->{raw}{stopovers} // [] } ),
				ajax_polyline => join( '|',
					map { join( ';', @{$_} ) } @{ $train_pos->{positions} } ),
				origin => {
					name => $pl->{raw}{origin}{name},
					ts   => $pl->{raw}{departure}
					? scalar $strp->parse_datetime( $pl->{raw}{departure} )
					: undef,
				},
				destination => {
					name => $pl->{raw}{destination}{name},
					ts   => $pl->{raw}{arrival}
					? scalar $strp->parse_datetime( $pl->{raw}{arrival} )
					: undef,
				},
				train_no        => scalar $pl->{raw}{line}{additionalName},
				operator        => scalar $pl->{raw}{line}{operator}{name},
				next_stop       => $next_stop,
				polyline_groups => [
					{
						polylines  => [@line_pairs],
						color      => '#00838f',
						opacity    => 0.6,
						fit_bounds => 1,
					}
				],
				station_coordinates => [@station_coordinates],
				markers             => [@markers],
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				'route_map',
				title       => "DBF",
				hide_opts   => 1,
				with_map    => 1,
				error       => $err,
				origin      => undef,
				destination => undef,
			);

		}
	)->wait;
}

sub ajax_route {
	my ($self)  = @_;
	my $trip_id = $self->stash('tripid');
	my $line_no = $self->stash('lineno');

	delete $self->stash->{layout};

	$self->render_later;

	$self->get_hafas_polyline_p( $trip_id, $line_no )->then(
		sub {
			my ($pl) = @_;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			my @route = stopovers_to_route( @{ $pl->{raw}{stopovers} // [] } );

			my $train_pos = estimate_train_positions2(
				now      => $now,
				route    => \@route,
				features => $pl->{raw}{polyline}{features},
			);

			my @polyline = @{ $pl->{polyline} };
			$self->render(
				'_map_infobox',
				ajax_req   => "${trip_id}/${line_no}",
				ajax_route => route_to_ajax( @{ $pl->{raw}{stopovers} // [] } ),
				ajax_polyline => join( '|',
					map { join( ';', @{$_} ) } @{ $train_pos->{positions} } ),
				origin => {
					name => $pl->{raw}{origin}{name},
					ts   => $pl->{raw}{departure}
					? scalar $strp->parse_datetime( $pl->{raw}{departure} )
					: undef,
				},
				destination => {
					name => $pl->{raw}{destination}{name},
					ts   => $pl->{raw}{arrival}
					? scalar $strp->parse_datetime( $pl->{raw}{arrival} )
					: undef,
				},
				next_stop => $train_pos->{next_stop},
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				'_error',
				error => $err,
			);
		}
	)->wait;
}

1;
