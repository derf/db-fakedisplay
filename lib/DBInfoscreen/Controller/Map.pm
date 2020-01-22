package DBInfoscreen::Controller::Map;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::Promise;

use DateTime;
use DateTime::Format::Strptime;
use Geo::Distance;

my $dbf_version = qx{git describe --dirty} || 'experimental';

chomp $dbf_version;

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
			my @route;

			my @markers;
			my $next_stop;

			my $now  = DateTime->now( time_zone => 'Europe/Berlin' );
			my $strp = DateTime::Format::Strptime->new(
				pattern   => '%Y-%m-%dT%H:%M:%S.000%z',
				time_zone => 'Europe/Berlin',
			);

			for my $i ( 1 .. $#polyline ) {
				push(
					@line_pairs,
					[
						[ $polyline[ $i - 1 ][1], $polyline[ $i - 1 ][0] ],
						[ $polyline[$i][1],       $polyline[$i][0] ]
					]
				);
			}

			for my $stop ( @{ $pl->{raw}{stopovers} // [] } ) {
				my @stop_lines = ( $stop->{stop}{name} );
				my ( $platform, $arr, $dep, $arr_delay, $dep_delay );

				if ( $from_name and $stop->{stop}{name} eq $from_name ) {
					push(
						@markers,
						{
							lon   => $stop->{stop}{location}{longitude},
							lat   => $stop->{stop}{location}{latitude},
							title => $stop->{stop}{name},
							icon  => 'goldIcon',
						}
					);
				}
				if ( $to_name and $stop->{stop}{name} eq $to_name ) {
					push(
						@markers,
						{
							lon   => $stop->{stop}{location}{longitude},
							lat   => $stop->{stop}{location}{latitude},
							title => $stop->{stop}{name},
							icon  => 'greenIcon',
						}
					);
				}

				if (    $stop->{arrival}
					and $arr = $strp->parse_datetime( $stop->{arrival} ) )
				{
					$arr_delay = ( $stop->{arrivalDelay} // 0 ) / 60;
					$platform //= $stop->{arrivalPlatform};
					my $arr_line = $arr->strftime('Ankunft: %H:%M');
					if ($arr_delay) {
						$arr_line .= sprintf( ' (%+d)', $arr_delay );
					}
					push( @stop_lines, $arr_line );
				}

				if (    $stop->{departure}
					and $dep = $strp->parse_datetime( $stop->{departure} ) )
				{
					$dep_delay = ( $stop->{departureDelay} // 0 ) / 60;
					$platform //= $stop->{departurePlatform};
					my $dep_line = $dep->strftime('Abfahrt: %H:%M');
					if ($dep_delay) {
						$dep_line .= sprintf( ' (%+d)', $dep_delay );
					}
					push( @stop_lines, $dep_line );
				}

				if ($platform) {
					splice( @stop_lines, 1, 0, "Gleis $platform" );
				}

				push(
					@station_coordinates,
					[
						[
							$stop->{stop}{location}{latitude},
							$stop->{stop}{location}{longitude}
						],
						[@stop_lines],
					]
				);
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

			for my $i ( 1 .. $#route ) {
				if (    $route[$i]{arr}
					and $route[ $i - 1 ]{dep}
					and $now > $route[ $i - 1 ]{dep}
					and $now < $route[$i]{arr} )
				{
					my $from_dt   = $route[ $i - 1 ]{dep};
					my $to_dt     = $route[$i]{arr};
					my $from_name = $route[ $i - 1 ]{name};
					my $to_name   = $route[$i]{name};

					my $route_part_completion_ratio
					  = ( $now->epoch - $from_dt->epoch )
					  / ( $to_dt->epoch - $from_dt->epoch );

					my $title = $pl->{name};
					if ( $route[$i]{arr_delay} ) {
						$title .= sprintf( ' (%+d)', $route[$i]{arr_delay} );
					}

					my $geo = Geo::Distance->new;
					my ( $from_index, $to_index );

					for my $j ( 0 .. $#{ $pl->{raw}{polyline}{features} } ) {
						my $this_point = $pl->{raw}{polyline}{features}[$j];
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
					if ( $from_index and $to_index ) {
						my $total_distance = 0;
						for my $j ( $from_index + 1 .. $to_index ) {
							my $prev = $pl->{raw}{polyline}{features}[ $j - 1 ]
							  {geometry}{coordinates};
							my $this
							  = $pl->{raw}{polyline}{features}[$j]{geometry}
							  {coordinates};
							if ( $prev and $this ) {
								$total_distance += $geo->distance(
									'kilometer', $prev->[0], $prev->[1],
									$this->[0],  $this->[1]
								);
							}
						}
						my $marker_distance
						  = $total_distance * $route_part_completion_ratio;
						$total_distance = 0;
						for my $j ( $from_index + 1 .. $to_index ) {
							my $prev = $pl->{raw}{polyline}{features}[ $j - 1 ]
							  {geometry}{coordinates};
							my $this
							  = $pl->{raw}{polyline}{features}[$j]{geometry}
							  {coordinates};
							if ( $prev and $this ) {
								$total_distance += $geo->distance(
									'kilometer', $prev->[0], $prev->[1],
									$this->[0],  $this->[1]
								);
							}
							if ( $total_distance > $marker_distance ) {
								push(
									@markers,
									{
										lon   => $this->[0],
										lat   => $this->[1],
										title => $title
									}
								);
								$next_stop = {
									type    => 'next',
									station => $route[$i],
								};
								last;
							}
						}
					}
					else {
						push(
							@markers,
							{
								lat => $route[ $i - 1 ]{lat} + (
									( $route[$i]{lat} - $route[ $i - 1 ]{lat} )
									* $route_part_completion_ratio
								),
								lon => $route[ $i - 1 ]{lon} + (
									( $route[$i]{lon} - $route[ $i - 1 ]{lon} )
									* $route_part_completion_ratio
								),
								title => $title
							}
						);
						$next_stop = {
							type    => 'next',
							station => $route[$i],
						};
					}
					last;
				}
				if ( $route[ $i - 1 ]{dep} and $now <= $route[ $i - 1 ]{dep} ) {
					my $title = $pl->{name};
					if ( $route[$i]{arr_delay} ) {
						$title .= sprintf( ' (%+d)', $route[$i]{arr_delay} );
					}
					push(
						@markers,
						{
							lat   => $route[ $i - 1 ]{lat},
							lon   => $route[ $i - 1 ]{lon},
							title => $title
						}
					);
					$next_stop = {
						type    => 'present',
						station => $route[ $i - 1 ],
					};
					last;
				}
			}
			if ( not @markers ) {
				push(
					@markers,
					{
						lat   => $route[-1]{lat},
						lon   => $route[-1]{lon},
						title => $route[-1]{name} . ' - Endstation',
					}
				);
				$next_stop = {
					type    => 'present',
					station => $route[-1]
				};
			}

			$self->render(
				'route_map',
				title     => $pl->{name},
				hide_opts => 1,
				with_map  => 1,
				origin    => {
					name => $pl->{raw}{origin}{name},
					ts   => $pl->{raw}{dep_line}
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

1;
