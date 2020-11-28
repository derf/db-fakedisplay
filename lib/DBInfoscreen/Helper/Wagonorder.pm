package DBInfoscreen::Helper::Wagonorder;
# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: BSD-2-Clause

use strict;
use warnings;
use 5.020;

use Mojo::Promise;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"dbf/${version} on $opt{root_url} +https://finalrewind.org/projects/db-fakedisplay"
	  };

	return bless( \%opt, $class );

}

sub is_available_p {
	my ( $self, $train, $wr_link ) = @_;
	my $promise = Mojo::Promise->new;

	$self->check_wagonorder_p( $train->train_no, $wr_link )->then(
		sub {
			$promise->resolve;
			return;
		},
		sub {
			if ( $train->is_wing ) {
				my $wing = $train->wing_of;
				return $self->check_wagonorder_p( $wing->train_no, $wr_link );
			}
			else {
				$promise->reject;
				return;
			}
		}
	)->then(
		sub {
			$promise->resolve;
			return;
		},
		sub {
			$promise->reject;
			return;
		}
	)->wait;

	return $promise;
}

sub check_wagonorder_p {
	my ( $self, $train_no, $wr_link ) = @_;

	my $promise = Mojo::Promise->new;

	my $url
	  = "https://lib.finalrewind.org/dbdb/has_wagonorder/${train_no}/${wr_link}";
	my $cache = $self->{main_cache};

	if ( my $content = $cache->get($url) ) {
		if ( $content eq 'y' ) {
			return $promise->resolve;
		}
		else {
			return $promise->reject;
		}
	}

	$self->{user_agent}->request_timeout(5)->head_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			if ( $tx->result->is_success ) {
				$cache->set( $url, 'y' );
				$promise->resolve;
			}
			else {
				$cache->set( $url, 'n' );
				$promise->reject;
			}
			return;
		}
	)->catch(
		sub {
			$cache->set( $url, 'n' );
			$promise->reject;
			return;
		}
	)->wait;
	return $promise;
}

sub get_p {
	my ( $self, $train_no, $api_ts ) = @_;

	my $url
	  = "https://www.apps-bahn.de/wr/wagenreihung/1.0/${train_no}/${api_ts}";

	my $cache = $self->{realtime_cache};

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}->debug("GET $url (cached)");
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(10)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$self->{log}->warn(
					"wagonorder->get_p($url): HTTP $err->{code} $err->{message}"
				);
				$promise->reject(
					"GET $url returned HTTP $err->{code} $err->{message}");
				return;
			}

			$self->{log}->debug("GET $url (OK)");
			my $json = $tx->res->json;

			$cache->freeze( $url, $json );
			$promise->resolve($json);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("GET $url: $err");
			$promise->reject("GET $url: $err");
			return;
		}
	)->wait;
	return $promise;
}

sub get_stationinfo_p {
	my ( $self, $eva ) = @_;

	my $url = "https://lib.finalrewind.org/dbdb/s/${eva}.json";

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$cache->freeze( $url, {} );
				$promise->reject("HTTP $err->{code} $err->{message}");
				return;
			}

			my $json = $tx->result->json;
			$cache->freeze( $url, $json );
			$promise->resolve($json);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$cache->freeze( $url, {} );
			$promise->reject($err);
			return;
		}
	)->wait;
	return $promise;
}

1;
