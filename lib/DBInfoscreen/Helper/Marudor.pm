package DBInfoscreen::Helper::Marudor;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use Mojo::Util qw(url_escape);
use XML::LibXML;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"dbf/${version} on $opt{root_url} +https://finalrewind.org/projects/db-fakedisplay"
	  };

	return bless( \%opt, $class );

}

sub get_json_p {
	my ( $self, $cache, $url ) = @_;

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}->debug("marudor->get_json_p($url): cached");
		if ( $content->{error} ) {
			return $promise->reject( $content->{error} );
		}
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$self->{log}->debug(
"marudor->get_json_p($url): HTTP $err->{code} $err->{message}"
				);
				$cache->freeze( $url, { error => $err->{message} } );
				$promise->reject(
					"GET $url returned HTTP $err->{code} $err->{message}");
				return;
			}

			my $res = $tx->res->json;

			if ( not $res ) {
				$self->{log}
				  ->debug("marudor->get_json_p($url): empty response");
				$promise->reject("GET $url returned empty response");
				return;
			}

			$cache->freeze( $url, $res );

			$promise->resolve($res);

			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("marudor->get_json_p($url): $err");
			$cache->freeze( $url, { error => $err } );
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub get_efa_occupancy {
	my ( $self, %opt ) = @_;

	my $eva      = $opt{eva};
	my $train_no = $opt{train_no};
	my $promise  = Mojo::Promise->new;

	$self->get_json_p( $self->{realtime_cache},
		"https://vrrf.finalrewind.org/_eva/occupancy-by-eva/${eva}.json" )
	  ->then(
		sub {
			my ($utilization_json) = @_;

			if ( $utilization_json->{train}{$train_no}{occupancy} ) {
				$promise->resolve(
					$utilization_json->{train}{$train_no}{occupancy} );
				return;
			}
			$promise->reject;
			return;
		}
	)->catch(
		sub {
			$promise->reject;
			return;
		}
	)->wait;

	return $promise;
}

sub get_train_utilization {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $train   = $opt{train};

	if ( not $train->sched_departure ) {
		$promise->reject("train has no departure");
		return $promise;
	}

	my $train_no     = $train->train_no;
	my $this_station = $train->station;
	my @route        = $train->route_post;
	my $next_station;
	my $dep = $train->sched_departure->iso8601;

	if ( @route > 1 ) {
		$next_station = $route[1];
	}
	else {
		$next_station = $route[0];
	}

	if ( not $next_station ) {
		$promise->reject("train has no next_station");
		return $promise;
	}

	$this_station
	  = url_escape( encode( 'utf-8', decode( 'iso-8859-15', $this_station ) ) );
	$next_station
	  = url_escape( encode( 'utf-8', decode( 'iso-8859-15', $next_station ) ) );

	$self->get_json_p( $self->{realtime_cache},
"https://marudor.de/api/hafas/v2/auslastung/${this_station}/${next_station}/${train_no}/${dep}"
	)->then(
		sub {
			my ($utilization_json) = @_;

			$promise->resolve( $utilization_json->{first},
				$utilization_json->{second} );
			return;
		}
	)->catch(
		sub {
			$promise->reject;
			return;
		}
	)->wait;

	return $promise;
}

1;
