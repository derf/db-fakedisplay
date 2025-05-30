package DBInfoscreen;

# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious';

use Cache::File;
use DBInfoscreen::Helper::DBRIS;
use DBInfoscreen::Helper::EFA;
use DBInfoscreen::Helper::HAFAS;
use DBInfoscreen::Helper::MOTIS;
use DBInfoscreen::Helper::Wagonorder;
use File::Slurp qw(read_file);
use JSON;

use utf8;

sub startup {
	my ($self) = @_;

	$self->config(
		hypnotoad => {
			accepts  => $ENV{DBFAKEDISPLAY_ACCEPTS} // 100,
			clients  => $ENV{DBFAKEDISPLAY_CLIENTS} // 10,
			listen   => [ $ENV{DBFAKEDISPLAY_LISTEN} // 'http://*:8092' ],
			pid_file => $ENV{DBFAKEDISPLAY_PID_FILE}
			  // '/tmp/db-fakedisplay.pid',
			spare   => $ENV{DBFAKEDISPLAY_SPARE}   // 2,
			workers => $ENV{DBFAKEDISPLAY_WORKERS} // 2,
		},
		lookahead  => $ENV{DBFAKEDISPLAY_LOOKAHEAD} // 180,
		source_url => 'https://github.com/derf/db-fakedisplay',
		issue_url  => 'https://github.com/derf/db-fakedisplay/issues',
		version    => $ENV{DBFAKEDISPLAY_VERSION} // qx{git describe --dirty}
		  // '???',
	);

	chomp $self->config->{version};
	$self->defaults( version => $self->config->{version} // 'UNKNOWN' );

	# Generally, the reverse proxy handles compression.
	# Also, Mojolicious compression breaks legacy callback-based JSON endpoints
	# for some clients.
	$self->renderer->compress(0);

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
				}
			}
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
		dbdb_wagon => sub {
			return JSON->new->utf8->decode(
				scalar read_file('share/dbdb_wagen.json') );
		}
	);

	$self->helper(
		dbris => sub {
			my ($self) = @_;
			state $efa = DBInfoscreen::Helper::DBRIS->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->config->{version},
			);
		}
	);

	$self->helper(
		motis => sub {
			my ($self) = @_;
			state $motis = DBInfoscreen::Helper::MOTIS->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->config->{version},
			);
		}
	);

	$self->helper(
		efa => sub {
			my ($self) = @_;
			state $efa = DBInfoscreen::Helper::EFA->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->config->{version},
			);
		}
	);

	$self->helper(
		hafas => sub {
			my ($self) = @_;
			state $hafas = DBInfoscreen::Helper::HAFAS->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->config->{version},
			);
		}
	);

	$self->helper(
		wagonorder => sub {
			my ($self) = @_;
			state $hafas = DBInfoscreen::Helper::Wagonorder->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->config->{version},
			);
		}
	);

	$self->helper(
		wagon_image => sub {
			my ( $self, $train_type, $wagon_type, $uic ) = @_;
			my $ret;
			if (    $train_type =~ m{IC(?!E)}
				and $wagon_type
				=~ m{ ^ [AB] R? k? [ipv] m m? b? d? s? z f? $ }x )
			{
				$ret = $wagon_type;
			}
			elsif ( $train_type =~ m{IC2.TWIN} ) {
				$ret = $wagon_type;
			}
			elsif ( not $uic ) {
				return;
			}
			else {
				$ret = substr( $uic, 4, 5 );
			}

			if ( $train_type =~ m{[.]S(\d)$} ) {
				$ret .= ".$1";
			}
			elsif ( $train_type =~ m{[.]R$} ) {
				$ret .= '.r';
			}

			if ( $ret and $self->app->dbdb_wagon->{$ret} ) {
				return $ret;
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
			if ( ( $self->param('hafas') or $self->param('efa') )
				and $stop =~ m{ [Bb]ahnhof | Bf }x )
			{
				return 1;
			}
			return;
		}
	);

	$self->helper(
		'occupancy_icon' => sub {
			my ( $self, $occupancy ) = @_;

			my @symbols
			  = (
				qw(help_outline person_outline people priority_high not_interested)
			  );
			my $text = 'Auslastung unbekannt';

			if ( $occupancy eq 'MANY_SEATS' ) {
				$occupancy = 1;
			}
			elsif ( $occupancy eq 'FEW_SEATS' ) {
				$occupancy = 2;
			}
			elsif ( $occupancy eq 'STANDING_ONLY' ) {
				$occupancy = 3;
			}
			elsif ( $occupancy eq 'FULL' ) {
				$occupancy = 4;
			}

			if ( $occupancy > 3 ) {
				$text = 'Voraussichtlich überfüllt';
			}
			if ( $occupancy > 2 ) {
				$text = 'Sehr hohe Auslastung erwartet';
			}
			elsif ( $occupancy > 1 ) {
				$text = 'Hohe Auslastung erwartet';
			}
			elsif ( $occupancy > 0 ) {
				$text = 'Geringe Auslastung erwartet';
			}

			return ( $text, $symbols[$occupancy] );
		}
	);

	$self->helper(
		'utilization_icon' => sub {
			my ( $self,  $utilization ) = @_;
			my ( $first, $second )      = @{ $utilization // [] };
			$first  //= 0;
			$second //= 0;
			my $sum = ( $first + $second ) / 2;

			my @symbols
			  = (
				qw(help_outline person_outline people priority_high not_interested)
			  );
			my $text = 'Auslastung unbekannt';

			if ( $sum > 3.5 ) {
				$text = 'Zug ist ausgebucht';
			}
			elsif ( $sum >= 2.5 ) {
				$text = 'Sehr hohe Auslastung';
			}
			elsif ( $sum >= 1.5 ) {
				$text = 'Hohe Auslastung';
			}
			elsif ( $sum >= 1 ) {
				$text = 'Geringe Auslastung';
			}

			return ( $text, $symbols[$first], $symbols[$second] );
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

	$self->helper(
		'get_rt_time_class' => sub {
			my ( $self, $train ) = @_;
			if (    $train->{has_realtime}
				and not $train->{is_bit_delayed}
				and not $train->{is_delayed} )
			{
				return 'on-time';
			}
			if ( $train->{is_bit_delayed} ) {
				return 'a-bit-delayed';
			}
			if ( $train->{is_delayed} ) {
				return 'delayed';
			}
			return q{};
		}
	);

	my $r = $self->routes;

	$r->get('/_redirect')->to('stationboard#redirect_to_station');

	# legacy entry point
	$r->get('/_auto')->to('static#geostop');

	$r->get('/_autostop')->to('static#geostop');

	$r->get('/_backend')->to('stationboard#backend_list');

	$r->get('/_datenschutz')->to('static#privacy');

	$r->post('/_geolocation')->to('stationboard#stations_by_coordinates');

	$r->get('/_about')->to('static#about');

	$r->get('/_impressum')->to('static#imprint');

	$r->get('/dyn/:av/autocomplete.js')->to('stationboard#autocomplete');

	$r->get('/carriage-formation')->to('wagenreihung#wagenreihung');
	$r->get('/w/*wagon')->to('wagenreihung#wagen');

	$r->get('/_ajax_mapinfo/:tripid/:lineno')->to('map#ajax_route');
	$r->get('/map/:tripid/:lineno')->to('map#route');
	$r->get('/coverage/:backend/:service')->to('map#coverage');
	$r->get( '/z/:train/*station' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'stationboard#station_train_details', format => undef )
	  ->name('train_at_station');
	$r->get( '/z/:train' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'stationboard#train_details', format => undef )
	  ->name('train');

	$self->defaults( layout => 'app' );

	$r->get('/')->to('stationboard#handle_board_request');
	$r->get('/multi/*station')->to('stationboard#handle_board_request');
	$r->get( '/*station' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'stationboard#handle_board_request', format => undef );

	$self->types->type( json => 'application/json; charset=utf-8' );

}

1;
