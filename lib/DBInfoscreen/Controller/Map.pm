package DBInfoscreen::Controller::Map;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);

my $dbf_version = qx{git describe --dirty} || 'experimental';

chomp $dbf_version;

sub get_hafas_polyline {
	my ( $ua, $cache, $trip_id, $line ) = @_;

	$ua->request_timeout(2);
	#say "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $res
	  = $ua->get(
"https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true"
		  => { 'User-Agent' => "dbf.finalrewind.org/${dbf_version}" } )->result;
	if ( $res->is_error ) {
		return;
	}

	my $json = decode_json( $res->body );
	my @coordinate_list;

	for my $feature ( @{ $json->{polyline}{features} } ) {
		if ( exists $feature->{geometry}{coordinates} ) {
			push( @coordinate_list, $feature->{geometry}{coordinates} );
		}

		#if ($feature->{type} eq 'Feature') {
		#	say "Feature " . $feature->{properties}{name};
		#}
	}

	return {
		name      => $json->{line}{name} // '?',
		polyline  => [@coordinate_list],
		stopovers => $json->{stopovers},
	};
}

sub route {
	my ($self)  = @_;
	my $trip_id = $self->stash('tripid');
	my $line_no = $self->stash('lineno');

	my $pl = get_hafas_polyline( $self->ua, $self->app->cache_iris_main,
		$trip_id, $line_no );
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

1;
