package DBInfoscreen::Controller::Map;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::Promise;

use Encode qw(decode);

my $dbf_version = qx{git describe --dirty} || 'experimental';

chomp $dbf_version;

sub get_hafas_polyline_p {
	my ( $self, $trip_id, $line ) = @_;

	my $url
	  = "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->app->cache_iris_main;
	my $promise = Mojo::Promise->new;

	say $url;

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
			my $body = decode( 'utf-8', $tx->res->body );
			my $json = decode_json($body);
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
				name      => $json->{line}{name} // '?',
				polyline  => [@coordinate_list],
				stopovers => $json->{stopovers},
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

			for my $i ( 1 .. $#polyline ) {
				push(
					@line_pairs,
					[
						[ $polyline[ $i - 1 ][1], $polyline[ $i - 1 ][0] ],
						[ $polyline[$i][1],       $polyline[$i][0] ]
					]
				);
			}

			for my $stop ( @{ $pl->{stopovers} // [] } ) {
				push(
					@station_coordinates,
					[
						[
							$stop->{stop}{location}{latitude},
							$stop->{stop}{location}{longitude}
						],
						$stop->{stop}{name}
					]
				);
			}

			$self->render(
				'route_map',
				title           => $pl->{name},
				hide_opts       => 1,
				with_map        => 1,
				polyline_groups => [
					{
						polylines  => \@line_pairs,
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
				title     => "Fehler",
				hide_opts => 1,
			);

		}
	)->wait;
}

1;
