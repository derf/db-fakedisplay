package DBInfoscreen::Controller::Map;

# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::Promise;

use DateTime;
use DateTime::Format::Strptime;
use GIS::Distance;
use List::Util qw();

my $strp = DateTime::Format::Strptime->new(
	pattern   => '%Y-%m-%dT%H:%M:%S%z',
	time_zone => 'Europe/Berlin',
);

# Input:
#   - polyline: Travel::Status::DE::HAFAS::Journey->polyline
#   - from_name: station name
#   - to_name: station name
# Ouptut:
#   - from_index: polyline index that corresponds to from_name
#   - to_index: polyline index that corresponds to to_name
sub get_route_indexes {
	my ( $polyline, $from_name, $to_name ) = @_;
	my ( $from_index, $to_index );

	for my $i ( 0 .. $#{$polyline} ) {
		my $this_point = $polyline->[$i];
		if (    not defined $from_index
			and $this_point->{name}
			and $this_point->{name} eq $from_name )
		{
			$from_index = $i;
		}
		elsif ( $this_point->{name}
			and $this_point->{name} eq $to_name )
		{
			$to_index = $i;
			last;
		}
	}
	return ( $from_index, $to_index );
}

# Input:
#   now: DateTime
#   from: current/previous stop
#         {dep => DateTime, name => str, lat => float, lon => float}
#   to: next stop
#       {arr => DateTime, name => str, lat => float, lon => float}
#   route: Travel::Status::DE::HAFAS::Journey->route
#   polyline: Travel::Status::DE::HAFAS::Journey->polyline (list of lon/lat hashes)
# Output: list of estimated train positions in [lat, lon] format.
# - current position
# - position 2 seconds from now
# - position 4 seconds from now
# - ...
sub estimate_train_positions {
	my (%opt) = @_;

	my $now = $opt{now};

	my $from_dt   = $opt{from}{dep} // $opt{from}{arr};
	my $to_dt     = $opt{to}{arr}   // $opt{to}{dep};
	my $from_name = $opt{from}{name};
	my $to_name   = $opt{to}{name};
	my $route     = $opt{route};
	my $polyline  = $opt{polyline};

	my @train_positions;

	my $time_complete = $now->epoch - $from_dt->epoch;
	my $time_total    = $to_dt->epoch - $from_dt->epoch;

	my @completion_ratios
	  = map { ( $time_complete + ( $_ * 2 ) ) / $time_total } ( 0 .. 45 );

	my $distance = GIS::Distance->new;

	my ( $from_index, $to_index )
	  = get_route_indexes( $polyline, $from_name, $to_name );

	if ( defined $from_index and defined $to_index ) {
		my $total_distance = 0;
		for my $j ( $from_index + 1 .. $to_index ) {
			my $prev = $polyline->[ $j - 1 ];
			my $this = $polyline->[$j];
			if ( $prev and $this ) {
				$total_distance
				  += $distance->distance_metal( $prev->{lat}, $prev->{lon},
					$this->{lat}, $this->{lon} );
			}
		}
		my @marker_distances = map { $total_distance * $_ } @completion_ratios;
		$total_distance = 0;
		for my $j ( $from_index + 1 .. $to_index ) {
			my $prev = $polyline->[ $j - 1 ];
			my $this = $polyline->[$j];
			if ( $prev and $this ) {
				my $prev_distance = $total_distance;
				$total_distance
				  += $distance->distance_metal( $prev->{lat}, $prev->{lon},
					$this->{lat}, $this->{lon} );
				for my $i ( @train_positions .. $#marker_distances ) {
					my $marker_distance = $marker_distances[$i];
					if ( $total_distance > $marker_distance ) {

						# completion ratio for the line between (prev, this)
						my $sub_ratio = 1;
						if ( $total_distance != $prev_distance ) {
							$sub_ratio = ( $marker_distance - $prev_distance )
							  / ( $total_distance - $prev_distance );
						}

						my $lat = $prev->{lat}
						  + ( $this->{lat} - $prev->{lat} ) * $sub_ratio;
						my $lon = $prev->{lon}
						  + ( $this->{lon} - $prev->{lon} ) * $sub_ratio;

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
#   route: arrayref of hashrefs
#     lat: float
#     lon: float
#     name: str
#     arr: DateTime
#     dep: DateTime
#   polyline: ref to Travel::Status::DE::HAFAS::Journey polyline list
#  Output:
#    next_stop: {type, station}
#    positions: [current position [lat, lon], 2s from now, 4s from now, ...]
sub estimate_train_positions2 {
	my ( $self, %opt ) = @_;
	my $now   = $opt{now};
	my @route = @{ $opt{route} // [] };

	my @train_positions;
	my $next_stop;
	my $distance               = GIS::Distance->new;
	my $stop_distance_sum      = 0;
	my $avg_inter_stop_beeline = 0;

	for my $i ( 1 .. $#route ) {
		if (    not $next_stop
			and ( $route[$i]{arr} // $route[$i]{dep} )
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
				route    => $opt{route},
				polyline => $opt{polyline},
			);

			$next_stop = {
				type    => 'next',
				station => $route[$i],
			};
		}
		if (    not $next_stop
			and ( $route[ $i - 1 ]{dep} // $route[ $i - 1 ]{arr} )
			and $now <= ( $route[ $i - 1 ]{dep} // $route[ $i - 1 ]{arr} ) )
		{
			@train_positions
			  = ( [ $route[ $i - 1 ]{lat}, $route[ $i - 1 ]{lon} ] );
			$next_stop = {
				type    => 'present',
				station => $route[ $i - 1 ],
			};
		}
		$stop_distance_sum += $distance->distance_metal(
			$route[ $i - 1 ]{lat}, $route[ $i - 1 ]{lon},
			$route[$i]{lat},       $route[$i]{lon}
		) / 1000;
	}

	if ($#route) {
		$avg_inter_stop_beeline = $stop_distance_sum / $#route;
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
		next_stop              => $next_stop,
		avg_inter_stop_beeline => $avg_inter_stop_beeline,
		position_now           => $position_now,
		positions              => \@train_positions,
	};
}

sub route_to_ajax {
	my (@stopovers) = @_;

	my @route_entries;

	for my $stop (@stopovers) {
		my @stop_entries = ( $stop->{name} );
		my $platform;

		if ( my $arr = $stop->{arr} and not $stop->{arr_cancelled} ) {
			my $delay = $stop->{arr_delay} // 0;
			$platform = $stop->{arr_platform};

			push( @stop_entries, $arr->epoch, $delay );
		}
		else {
			push( @stop_entries, q{}, q{} );
		}

		if ( my $dep = $stop->{dep} and not $stop->{dep_cancelled} ) {
			my $delay = $stop->{dep_delay} // 0;
			$platform //= $stop->{dep_platform} // q{};

			push( @stop_entries, $dep->epoch, $delay, $platform );
		}
		else {
			push( @stop_entries, q{}, q{}, q{} );
		}

		push( @route_entries, join( ';', @stop_entries ) );
	}

	return join( '|', @route_entries );
}

sub polyline_to_line_pairs {
	my (@polyline) = @_;
	my @line_pairs;
	for my $i ( 1 .. $#polyline ) {
		push(
			@line_pairs,
			[
				[ $polyline[ $i - 1 ]{lat}, $polyline[ $i - 1 ]{lon} ],
				[ $polyline[$i]{lat},       $polyline[$i]{lon} ]
			]
		);
	}
	return @line_pairs;
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
			my ($journey) = @_;

			my @polyline = $journey->polyline;
			my @station_coordinates;

			my @markers;
			my $next_stop;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			# used to draw the train's journey on the map
			my @line_pairs = polyline_to_line_pairs(@polyline);

			my @route = $journey->route;

			my $train_pos = $self->estimate_train_positions2(
				now      => $now,
				route    => \@route,
				polyline => \@polyline,
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
					title => $journey->name
				}
			);
			$next_stop = $train_pos->{next_stop};

			$self->render(
				'route_map',
				description   => "Karte für " . $journey->name,
				title         => $journey->name,
				hide_opts     => 1,
				with_map      => 1,
				ajax_req      => "${trip_id}/${line_no}",
				ajax_route    => route_to_ajax( $journey->route ),
				ajax_polyline => join( '|',
					map { join( ';', @{$_} ) } @{ $train_pos->{positions} } ),
				origin => {
					name => ( $journey->route )[0]->{name},
					ts   => ( $journey->route )[0]->{dep},
				},
				destination => {
					name => $journey->route_end,
					ts   => ( $journey->route )[-1]->{arr},
				},
				train_no => $journey->number
				? ( $journey->type . ' ' . $journey->number )
				: undef,
				operator        => $journey->operator,
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
				station_radius      =>
				  ( $train_pos->{avg_inter_stop_beeline} > 500 ? 250 : 100 ),
				markers => [@markers],
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
			my ($journey) = @_;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			my @route    = $journey->route;
			my @polyline = $journey->polyline;

			my $train_pos = $self->estimate_train_positions2(
				now      => $now,
				route    => \@route,
				polyline => \@polyline,
			);

			$self->render(
				'_map_infobox',
				ajax_req      => "${trip_id}/${line_no}",
				ajax_route    => route_to_ajax(@route),
				ajax_polyline => join( '|',
					map { join( ';', @{$_} ) } @{ $train_pos->{positions} } ),
				origin => {
					name => ( $journey->route )[0]->{name},
					ts   => ( $journey->route )[0]->{dep},
				},
				destination => {
					name => $journey->route_end,
					ts   => ( $journey->route )[-1]->{arr},
				},
				train_no => $journey->number
				? ( $journey->type . ' ' . $journey->number )
				: undef,
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
