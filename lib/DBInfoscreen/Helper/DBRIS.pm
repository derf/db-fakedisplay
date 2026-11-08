package DBInfoscreen::Helper::DBRIS;

# Copyright (C) 2025 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Travel::Status::DE::DBRIS;
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use Mojo::UserAgent;

my $is_enabled = $ENV{DBFAKEDISPLAY_ENABLE_DBRIS};

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"dbf/${version} on $opt{root_url} +https://finalrewind.org/projects/db-fakedisplay"
	  };

	return bless( \%opt, $class );

}

sub get_agent {
	my ($self) = @_;

	my $agent = $self->{user_agent};

	if ( my $proxy = $ENV{DBFAKEDISPLAY_DBRIS_PROXY} ) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	# Requird to workaround Akamai BMP UserAgent fingerprinting (which includes
	# supported TLS cipher suites and more) employed by bahn.de
	$agent->tls_options(
		{
			SSL_ciphersuites =>
			  'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256',
		}
	);

	return $agent;
}

sub get_journey_p {
	my ( $self, %opt ) = @_;

	if ( not $is_enabled ) {
		return Mojo::Promise->reject('DBRIS backend is disabled');
	}

	return Travel::Status::DE::DBRIS->new_p(
		journey    => $opt{id},
		cache      => $self->{realtime_cache},
		promise    => 'Mojo::Promise',
		user_agent => $self->get_agent->request_timeout(10)
	);
}

# Input: TripID
# Output: Promise returning a Travel::Status::DE::DBRIS::Journey instance on success
sub get_polyline_p {
	my ( $self, %opt ) = @_;

	my $trip_id = $opt{id};
	my $promise = Mojo::Promise->new;

	if ( not $is_enabled ) {
		return $promise->reject('DBRIS backend is disabled');
	}

	Travel::Status::DE::DBRIS->new_p(
		journey       => $trip_id,
		with_polyline => 1,
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $self->get_agent->request_timeout(10)
	)->then(
		sub {
			my ($dbris) = @_;
			my $journey = $dbris->result;

			$promise->resolve($journey);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("DBRIS->new_p($trip_id) error: $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub get_wagonorder_p {
	my ( $self, %opt ) = @_;

	if ( not $is_enabled ) {
		return Mojo::Promise->reject('DBRIS backend is disabled');
	}

	$self->{log}
	  ->debug("get_wagonorder_p($opt{train_type} $opt{train_no} @ $opt{eva})");

	return Travel::Status::DE::DBRIS->new_p(
		cache         => $self->{main_cache},
		failure_cache => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $self->get_agent->request_timeout(10),
		formation     => {
			departure    => $opt{datetime},
			eva          => $opt{eva},
			train_type   => $opt{train_type},
			train_number => $opt{train_no}
		},
		developer_mode => $self->{log}->is_level('debug') ? 1 : 0,
	);
}

1;
