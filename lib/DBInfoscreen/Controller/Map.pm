package DBInfoscreen::Controller::Map;

# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::Promise;

use DateTime;
use DateTime::Format::Strptime;
use Geo::Distance;
use List::Util qw();

my $strp = DateTime::Format::Strptime->new(
	pattern   => '%Y-%m-%dT%H:%M:%S%z',
	time_zone => 'Europe/Berlin',
);

sub get_route_indexes {
	my ( $features, $from_name, $to_name ) = @_;
	my ( $from_index, $to_index );

	for my $i ( 0 .. $#{$features} ) {
		my $this_point = $features->[$i];
		if (    not defined $from_index
			and $this_point->{properties}{type}
			and $this_point->{properties}{type} eq 'stop'
			and $this_point->{properties}{name} eq $from_name )
		{
			$from_index = $i;
		}
		elsif ( $this_point->{properties}{type}
			and $this_point->{properties}{type} eq 'stop'
			and $this_point->{properties}{name} eq $to_name )
		{
			$to_index = $i;
			last;
		}
	}
	return ( $from_index, $to_index );
}

# Returns timestamped train positions between stop1 and stop2 (must not have
# intermittent stops) in 10-second steps.
sub estimate_timestamped_positions {
	my (%opt) = @_;

	my $from_dt   = $opt{from}{dep};
	my $to_dt     = $opt{to}{arr};
	my $from_name = $opt{from}{name};
	my $to_name   = $opt{to}{name};
	my $features  = $opt{features};

	my $duration = $to_dt->epoch - $from_dt->epoch;

	my @train_positions;

	my @completion_ratios
	  = map { ( $_ * 10 / $duration ) } ( 0 .. $duration / 10 );

	my ( $from_index, $to_index )
	  = get_route_indexes( $features, $from_name, $to_name );

	my $location_epoch = $from_dt->epoch;
	my $geo            = Geo::Distance->new;

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

						push( @train_positions,
							[ $location_epoch, $lat, $lon ] );
						$location_epoch += 10;
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
	return;
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

	my $from_dt = $opt{from}{dep} // $opt{from}{arr};
	my $to_dt   = $opt{to}{arr}   // $opt{to}{dep};
	my $from_name = $opt{from}{name};
	my $to_name   = $opt{to}{name};
	my $features  = $opt{features};

	my @train_positions;

	my $time_complete = $now->epoch - $from_dt->epoch;
	my $time_total    = $to_dt->epoch - $from_dt->epoch;

	my @completion_ratios
	  = map { ( $time_complete + ( $_ * 2 ) ) / $time_total } ( 0 .. 45 );

	my $geo = Geo::Distance->new;

	my ( $from_index, $to_index )
	  = get_route_indexes( $features, $from_name, $to_name );

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
	my ( $self, %opt ) = @_;
	my $now   = $opt{now};
	my @route = @{ $opt{route} // [] };

	my @train_positions;
	my $next_stop;

	for my $i ( 1 .. $#route ) {
		if (    ( $route[$i]{arr} // $route[$i]{dep} )
			and ( $route[ $i - 1 ]{dep} // $route[ $i - 1 ]{arr} )
			and $now > ( $route[ $i - 1 ]{dep} // $route[ $i - 1 ]{arr} )
			and $now < ( $route[$i]{arr} // $route[$i]{dep} ) )
		{

			# HAFAS does not provide delays for past stops
			$self->backpropagate_delay( $route[ $i - 1 ], $route[$i] );

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
		if ( ( $route[ $i - 1 ]{dep} // $route[ $i - 1 ]{arr} )
			and $now <= ( $route[ $i - 1 ]{dep} // $route[ $i - 1 ]{arr} ) )
		{
			@train_positions
			  = ( [ $route[ $i - 1 ]{lat}, $route[ $i - 1 ]{lon} ] );
			$next_stop = {
				type    => 'present',
				station => $route[ $i - 1 ],
			};
			last;
		}
	}

	if ( @route and not $next_stop ) {
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

sub estimate_train_intersection {
	my (%opt) = @_;
	my @route1 = @{ $opt{routes}[0] // [] };
	my @route2 = @{ $opt{routes}[1] // [] };

	my $ret;

	my $i1 = 0;
	my $i2 = 0;

	my @pairs;
	my @meeting_points;
	my $geo = Geo::Distance->new;

	# skip last route element as we compare route[i] with route[i+1]
	while ( $i1 < $#route1 and $i2 < $#route2 ) {
		my $dep1 = $route1[$i1]{dep};
		my $arr1 = $route1[ $i1 + 1 ]{arr};
		my $dep2 = $route2[$i2]{dep};
		my $arr2 = $route2[ $i2 + 1 ]{arr};

		if ( not( $dep1 and $arr1 ) ) {

			#say "skip 1 $route1[$i1]{name}";
			$i1++;
			next;
		}

		if ( not( $dep2 and $arr2 ) ) {

			#say "skip 2 $route2[$i2]{name}";
			$i2++;
			next;
		}

		if ( $arr1 <= $dep2 ) {
			$i1++;
		}
		elsif ( $arr2 <= $dep1 ) {
			$i2++;
		}
		elsif ( $arr2 <= $arr1 ) {
			push( @pairs, [ $i1, $i2 ] );
			if (    $route1[$i1]{name} eq $route2[ $i2 + 1 ]{name}
				and $route2[$i2]{name} eq $route1[ $i1 + 1 ]{name} )
			{
              # both i1 name == i2+1 name and i1 name == i2 name are valid cases
              # (trains don't just intersect when they travel in opposing
              # directions -- they may also travel in the same direction
              # with different speed and overtake each other).
              # We need both stop pairs later on, so we save both.
				$ret->{stop_pair} = [
					[ $route1[$i1]{name}, $route1[ $i1 + 1 ]{name} ],
					[ $route2[$i2]{name}, $route2[ $i2 + 1 ]{name} ]
				];
			}
			$i2++;
		}
		elsif ( $arr1 <= $arr2 ) {
			push( @pairs, [ $i1, $i2 ] );
			if (    $route1[$i1]{name} eq $route2[ $i2 + 1 ]{name}
				and $route2[$i2]{name} eq $route1[ $i1 + 1 ]{name} )
			{
				$ret->{stop_pair} = [
					[ $route1[$i1]{name}, $route1[ $i1 + 1 ]{name} ],
					[ $route2[$i2]{name}, $route2[ $i2 + 1 ]{name} ]
				];
			}
			$i1++;
		}
		else {
			$i1++;
		}
	}

	for my $pair (@pairs) {
		my ( $i1, $i2 ) = @{$pair};
		my @train1_positions = estimate_timestamped_positions(
			from     => $route1[$i1],
			to       => $route1[ $i1 + 1 ],
			features => $opt{features}[0],
		);
		my @train2_positions = estimate_timestamped_positions(
			from     => $route2[$i2],
			to       => $route2[ $i2 + 1 ],
			features => $opt{features}[1],
		);
		$i1 = 0;
		$i2 = 0;
		while ( $i1 <= $#train1_positions and $i2 <= $#train2_positions ) {
			if ( $train1_positions[$i1][0] < $train2_positions[$i2][0] ) {
				$i1++;
			}
			elsif ( $train1_positions[$i2][0] < $train2_positions[$i2][0] ) {
				$i2++;
			}
			else {
				if (
					(
						my $distance = $geo->distance(
							'kilometer',
							$train1_positions[$i1][2],
							$train1_positions[$i1][1],
							$train2_positions[$i2][2],
							$train2_positions[$i2][1]
						)
					) < 1
				  )
				{
					my $ts = DateTime->from_epoch(
						epoch     => $train1_positions[$i1][0],
						time_zone => 'Europe/Berlin'
					);
					$ret->{first_meeting_time} //= $ts;
					push(
						@meeting_points,
						{
							timestamp => $ts,
							lat       => (
								    $train1_positions[$i1][1]
								  + $train2_positions[$i2][1]
							) / 2,
							lon => (
								    $train1_positions[$i1][2]
								  + $train2_positions[$i2][2]
							) / 2,
							distance => $distance,
						}
					);
				}
				$i1++;
				$i2++;
			}
		}
	}

	$ret->{meeting_points} = \@meeting_points;

	return $ret;
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

sub polyline_to_line_pairs {
	my (@polyline) = @_;
	my @line_pairs;
	for my $i ( 1 .. $#polyline ) {
		push(
			@line_pairs,
			[
				[ $polyline[ $i - 1 ][1], $polyline[ $i - 1 ][0] ],
				[ $polyline[$i][1],       $polyline[$i][0] ]
			]
		);
	}
	return @line_pairs;
}

sub intersection {
	my ($self) = @_;

	my @trips    = split( qr{;}, $self->stash('trips') );
	my @trip_ids = map { [ split( qr{,}, $_ ) ] } @trips;

	$self->render_later;

	my @polyline_requests
	  = map { $self->hafas->get_polyline_p( @{$_} ) } @trip_ids;
	Mojo::Promise->all(@polyline_requests)->then(
		sub {
			my ( $pl1, $pl2 ) = map { $_->[0] } @_;
			my @polyline1 = @{ $pl1->{polyline} };
			my @polyline2 = @{ $pl2->{polyline} };
			my @station_coordinates;

			my @markers;
			my $next_stop;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			my @line1_pairs = polyline_to_line_pairs(@polyline1);
			my @line2_pairs = polyline_to_line_pairs(@polyline2);

			my @route1
			  = stopovers_to_route( @{ $pl1->{raw}{stopovers} // [] } );
			my @route2
			  = stopovers_to_route( @{ $pl2->{raw}{stopovers} // [] } );

			my $train1_pos = $self->estimate_train_positions2(
				now      => $now,
				route    => \@route1,
				features => $pl1->{raw}{polyline}{features},
			);

			my $train2_pos = $self->estimate_train_positions2(
				now      => $now,
				route    => \@route2,
				features => $pl2->{raw}{polyline}{features},
			);

			my $intersection = estimate_train_intersection(
				routes   => [ \@route1, \@route2 ],
				features => [
					$pl1->{raw}{polyline}{features},
					$pl2->{raw}{polyline}{features}
				],
			);

			for my $meeting_point ( @{ $intersection->{meeting_points} } ) {
				push(
					@station_coordinates,
					[
						[ $meeting_point->{lat}, $meeting_point->{lon} ],
						[ $meeting_point->{timestamp}->strftime('%H:%M') ]
					]
				);
			}

			push(
				@markers,
				{
					lat   => $train1_pos->{position_now}[0],
					lon   => $train1_pos->{position_now}[1],
					title => $pl1->{name}
				},
				{
					lat   => $train2_pos->{position_now}[0],
					lon   => $train2_pos->{position_now}[1],
					title => $pl2->{name}
				},
			);

			$self->render(
				'route_map',
				title        => "DBF",
				hide_opts    => 1,
				with_map     => 1,
				intersection => 1,
				train1_no =>
				  scalar( $pl1->{raw}{line}{additionalName} // $pl1->{name} ),
				train2_no =>
				  scalar( $pl2->{raw}{line}{additionalName} // $pl2->{name} ),
				likely_pair => $intersection->{stop_pair}
				? $intersection->{stop_pair}[0]
				: undef,
				time            => scalar $intersection->{first_meeting_time},
				polyline_groups => [
					{
						polylines  => [ @line1_pairs, @line2_pairs ],
						color      => '#ffffff',
						opacity    => 0,
						fit_bounds => 1,
					},
					{
						polylines => [@line1_pairs],
						color     => '#005080',
						opacity   => 0.6,
					},
					{
						polylines => [@line2_pairs],
						color     => '#800050',
						opacity   => 0.6,
					}
				],
				markers             => [@markers],
				station_coordinates => [@station_coordinates],
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				'route_map',
				title     => "DBF",
				hide_opts => 1,
				with_map  => 1,
				error     => $err,
			);
		}
	)->wait;
}

sub backpropagate_delay {
	my ( $self, $prev_stop, $next_stop ) = @_;

	if ( ( $next_stop->{arr_delay} || $next_stop->{dep_delay} )
		and not( $prev_stop->{dep_delay} || $prev_stop->{arr_delay} ) )
	{
		$self->log->debug("need to back-propagate delay");
		my $delay = $next_stop->{arr_delay} || $next_stop->{dep_delay};
		if ( $prev_stop->{arr} ) {
			$prev_stop->{arr}->add( minutes => $delay );
			$prev_stop->{arr_delay} = $delay;
		}
		if ( $prev_stop->{dep} ) {
			$prev_stop->{dep}->add( minutes => $delay );
			$prev_stop->{dep_delay} = $delay;
		}
	}
}

sub route {
	my ($self)  = @_;
	my $trip_id = $self->stash('tripid');
	my $line_no = $self->stash('lineno');

	my $from_name = $self->param('from');
	my $to_name   = $self->param('to');

	$self->render_later;

	$self->hafas->get_polyline_p( $trip_id, $line_no )->then(
		sub {
			my ($pl) = @_;

			my @polyline = @{ $pl->{polyline} };
			my @station_coordinates;

			my @markers;
			my $next_stop;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			# used to draw the train's journey on the map
			my @line_pairs = polyline_to_line_pairs(@polyline);

			my @route = stopovers_to_route( @{ $pl->{raw}{stopovers} // [] } );

			my $train_pos = $self->estimate_train_positions2(
				now      => $now,
				route    => \@route,
				features => $pl->{raw}{polyline}{features},
			);

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
				title     => "DBF",
				hide_opts => 1,
				with_map  => 1,
				error     => $err,
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

	$self->hafas->get_polyline_p( $trip_id, $line_no )->then(
		sub {
			my ($pl) = @_;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			my @route = stopovers_to_route( @{ $pl->{raw}{stopovers} // [] } );

			my $train_pos = $self->estimate_train_positions2(
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

sub search {
	my ($self) = @_;

	my $t1 = $self->param('train1');
	my $t2 = $self->param('train2');

	my $t1_data;
	my $t2_data;

	my @requests;

	if ( not( $t1 and $t1 =~ m{^\S+\s+\d+$} )
		or ( $t2 and not $t2 =~ m{^\S+\s+\d+$} ) )
	{
		$self->render(
			'trainsearch',
			title     => 'Fahrtverlauf',
			hide_opts => 1,
			error     => $t1
			? "Züge müssen im Format 'Zugtyp Nummer' angegeben werden, z.B. 'RE 1234'"
			: undef,
		);
		return;
	}

	$self->render_later;

	push( @requests, $self->hafas->trainsearch_p( train_no => $t1 ) );

	if ($t2) {
		push( @requests, $self->hafas->trainsearch_p( train_no => $t2 ) );
	}

	Mojo::Promise->all(@requests)->then(
		sub {
			my ( $t1_data, $t2_data ) = @_;

			if ($t2_data) {
				$self->redirect_to(
					sprintf(
						"/intersection/%s,0;%s,0",
						$t1_data->[0]{trip_id},
						$t2_data->[0]{trip_id},
					)
				);
			}
			else {
				$self->redirect_to(
					sprintf( "/map/%s/0", $t1_data->[0]{trip_id}, ) );
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				'trainsearch',
				title     => 'Fahrtverlauf',
				hide_opts => 1,
				error     => $err
			);
		}
	)->wait;
}

sub search_form {
	my ($self) = @_;

	$self->render(
		'trainsearch',
		title     => 'Fahrtverlauf',
		hide_opts => 1,
	);
}

1;
