package DBInfoscreen::Controller::Map;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::Promise;

use DateTime::Format::Strptime;

my $dbf_version = qx{git describe --dirty} || 'experimental';

chomp $dbf_version;

sub get_hafas_polyline_p {
	my ( $self, $trip_id, $line ) = @_;

	my $url
	  = "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->app->cache_iris_main;
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

	$self->render_later;

	$self->get_hafas_polyline_p( $trip_id, $line_no )->then(
		sub {
			my ($pl) = @_;

			my @polyline = @{ $pl->{polyline} };
			my @line_pairs;
			my @station_coordinates;

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
				my $platform;

				if ( $stop->{arrival}
					and my $arrival
					= $strp->parse_datetime( $stop->{arrival} ) )
				{
					my $delay = $stop->{arrivalDelay} // 0;
					$platform //= $stop->{arrivalPlatform};
					my $arr_line = $arrival->strftime('Ankunft: %H:%M');
					if ($delay) {
						$arr_line .= sprintf( ' (%+d)', $delay / 60 );
					}
					push( @stop_lines, $arr_line );
				}

				if ( $stop->{departure}
					and my $departure
					= $strp->parse_datetime( $stop->{departure} ) )
				{
					my $delay = $stop->{departureDelay} // 0;
					$platform //= $stop->{departurePlatform};
					my $dep_line = $departure->strftime('Abfahrt: %H:%M');
					if ($delay) {
						$dep_line .= sprintf( ' (%+d)', $delay / 60 );
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
				polyline_groups => [
					{
						polylines  => [@line_pairs],
						color      => '#00838f',
						opacity    => 0.6,
						fit_bounds => 1,
					}
				],
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

1;
