package DBInfoscreen::Helper::EFA;

# Copyright (C) 2020-2022 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode     qw(decode encode);
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use Mojo::Util qw(url_escape);
use Travel::Status::DE::EFA;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"dbf/${version} on $opt{root_url} +https://finalrewind.org/projects/db-fakedisplay"
	  };

	return bless( \%opt, $class );

}

sub get_polyline_p {
	my ( $self, %opt ) = @_;

	my $stopseq = $opt{stopseq};
	my $service = $opt{service};
	my $promise = Mojo::Promise->new;

	Travel::Status::DE::EFA->new_p(
		service    => $service,
		stopseq    => $stopseq,
		cache      => $self->{realtime_cache},
		promise    => 'Mojo::Promise',
		user_agent => $self->{user_agent}->request_timeout(10)
	)->then(
		sub {
			my ($efa) = @_;
			my $journey = $efa->result;

			$promise->resolve($journey);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("EFA->new_p($stopseq) error: $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub get_coverage {
	my ( $self, $service ) = @_;

	my $service_definition = Travel::Status::DE::EFA::get_service($service);

	if ( not $service_definition ) {
		return {};
	}

	return $service_definition->{coverage}{area} // {};
}

sub get_json_p {
	my ( $self, $cache, $url ) = @_;

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}->debug("efa->get_json_p($url): cached");
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
					"efa->get_json_p($url): HTTP $err->{code} $err->{message}");
				$cache->freeze( $url, { error => $err->{message} } );
				$promise->reject(
					"GET $url returned HTTP $err->{code} $err->{message}");
				return;
			}

			my $res = $tx->res->json;

			if ( not $res ) {
				$self->{log}->debug("efa->get_json_p($url): empty response");
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
			$self->{log}->debug("efa->get_json_p($url): $err");
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

1;
