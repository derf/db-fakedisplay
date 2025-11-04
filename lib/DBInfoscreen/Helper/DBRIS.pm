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

	return $agent;
}

sub get_journey_p {
	my ( $self, %opt ) = @_;

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
