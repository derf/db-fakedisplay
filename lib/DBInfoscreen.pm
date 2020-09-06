package DBInfoscreen;
use Mojo::Base 'Mojolicious';

# Copyright (C) 2011-2019 Daniel Friesel <derf+dbf@finalrewind.org>
# License: 2-Clause BSD

use Cache::File;
use DBInfoscreen::Helper::HAFAS;
use DBInfoscreen::Helper::Wagonorder;
use File::Slurp qw(read_file);
use JSON;
use Travel::Status::DE::HAFAS;
use Travel::Status::DE::HAFAS::StopFinder;
use Travel::Status::DE::IRIS::Stations;

use utf8;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

our $VERSION = qx{git describe --dirty} || '0.05';

chomp $VERSION;

my %default = (
	backend => 'iris',
	mode    => 'app',
	admode  => 'deparr',
);

sub startup {
	my ($self) = @_;

	$self->hook(
		before_dispatch => sub {
			my ($self) = @_;

           # The "theme" cookie is set client-side if the theme we delivered was
           # changed by dark mode detection or by using the theme switcher. It's
           # not part of Mojolicious' session data (and can't be, due to
           # signing and HTTPOnly), so we need to add it here.

			for my $cookie ( @{ $self->req->cookies } ) {
				if ( $cookie->name eq 'theme' ) {
					$self->session( theme => $cookie->value );
					return;
				}
			}
		}
	);

	$self->attr(
		cache_hafas => sub {
			my ($self) = @_;
			return Cache::File->new(
				cache_root => $ENV{DBFAKEDISPLAY_HAFAS_CACHE}
				  // '/tmp/dbf-hafas',
				default_expires => '180 seconds',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
		}
	);

	$self->attr(
		cache_iris_main => sub {
			my ($self) = @_;
			return Cache::File->new(
				cache_root => $ENV{DBFAKEDISPLAY_IRIS_CACHE}
				  // '/tmp/dbf-iris-main',
				default_expires => '6 hours',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
		}
	);

	$self->attr(
		cache_iris_rt => sub {
			my ($self) = @_;
			return Cache::File->new(
				cache_root => $ENV{DBFAKEDISPLAY_IRISRT_CACHE}
				  // '/tmp/dbf-iris-realtime',
				default_expires => '70 seconds',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
		}
	);

	$self->attr(
		ice_type_map => sub {
			my $ice_type_map = JSON->new->utf8->decode(
				scalar read_file('share/ice_type.json') );
			my $ret;
			while ( my ( $k, $v ) = each %{$ice_type_map} ) {
				if ( $v->{type} ) {
					$ret->{$k} = [ $v->{type}, $v->{short} ];
				}
			}
			return $ret;
		}
	);

	$self->helper(
		hafas => sub {
			my ($self) = @_;
			state $hafas = DBInfoscreen::Helper::HAFAS->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				user_agent     => $self->ua,
				version        => $VERSION,
			);
		}
	);

	$self->helper(
		wagonorder => sub {
			my ($self) = @_;
			state $hafas = DBInfoscreen::Helper::Wagonorder->new(
				log        => $self->app->log,
				cache      => $self->app->cache_iris_main,
				user_agent => $self->ua,
				version    => $VERSION,
			);
		}
	);

	$self->helper(
		'handle_no_results' => sub {
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
						hide_opts   => 0
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
						hide_opts   => 0
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
	);

	$self->helper(
		'handle_no_results_json' => sub {
			my ( $self, $backend, $station, $errstr, $api_version ) = @_;

			my $callback = $self->param('callback');

			$self->res->headers->access_control_allow_origin(q{*});
			my $json;
			if ($errstr) {
				$json = $self->render_to_string(
					json => {
						api_version => $api_version,
						version     => $VERSION,
						error       => $errstr,
					}
				);
			}
			else {
				my @candidates = map { { code => $_->[0], name => $_->[1] } }
				  Travel::Status::DE::IRIS::Stations::get_station($station);
				if ( @candidates > 1
					or
					( @candidates == 1 and $candidates[0]{code} ne $station ) )
				{
					$json = $self->render_to_string(
						json => {
							api_version => $api_version,
							version     => $VERSION,
							error       => 'ambiguous station code/name',
							candidates  => \@candidates,
						}
					);
				}
				else {
					$json = $self->render_to_string(
						json => {
							api_version => $api_version,
							version     => $VERSION,
							error =>
							  ( $errstr // "Got no results for '$station'" )
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
	);

	$self->helper(
		'is_important' => sub {
			my ( $self, $stop ) = @_;

			# Centraal: dutch main station (Hbf in .nl)
			# HB:  swiss main station (Hbf in .ch)
			# hl.n.: czech main station (Hbf in .cz)
			if ( $stop =~ m{ HB $ | hl\.n\. $ | Hbf | Centraal | Flughafen }x )
			{
				return 1;
			}
			return;
		}
	);

	$self->helper(
		'json_route_diff' => sub {
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
				elsif ( not( $route[$route_idx] ~~ \@sched_route ) ) {
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
	);

	$self->helper(
		'numeric_platform_part' => sub {
			my ( $self, $platform ) = @_;

			if ( not defined $platform ) {
				return 0;
			}

			if ( $platform =~ m{ ^ \d+ $ }x ) {
				return $platform;
			}

			if ( $platform =~ m{ (\d+) }x ) {
				return $1;
			}

			return 0;
		}
	);

	my $r = $self->routes;

	$r->get('/_redirect')->to('static#redirect');

	$r->get('/_auto')->to('static#geolocation');

	$r->get('/_datenschutz')->to('static#privacy');

	$r->post('/_geolocation')->to('stationboard#stations_by_coordinates');

	$r->get('/_about')->to('static#about');

	$r->get('/_impressum')->to('static#imprint');

	$r->get('/_wr/:train/:departure')->to('wagenreihung#wagenreihung');

	$r->get('/_ajax_mapinfo/:tripid/:lineno')->to('map#ajax_route');
	$r->get('/map/:tripid/:lineno')->to('map#route');
	$r->get('/intersection/:trips')->to('map#intersection');

	$self->defaults( layout => 'app' );

	$r->get('/')->to('stationboard#handle_request');
	$r->get('/multi/*station')->to('stationboard#handle_request');
	$r->get('/*station')->to('stationboard#handle_request');

	$self->config(
		hypnotoad => {
			accepts => $ENV{DBFAKEDISPLAY_ACCEPTS} // 100,
			clients => $ENV{DBFAKEDISPLAY_CLIENTS} // 10,
			listen   => [ $ENV{DBFAKEDISPLAY_LISTEN} // 'http://*:8092' ],
			pid_file => $ENV{DBFAKEDISPLAY_PID_FILE}
			  // '/tmp/db-fakedisplay.pid',
			spare   => $ENV{DBFAKEDISPLAY_SPARE}   // 2,
			workers => $ENV{DBFAKEDISPLAY_WORKERS} // 2,
		},
	);

	$self->types->type( json => 'application/json; charset=utf-8' );

}

1;
