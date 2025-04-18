package DBInfoscreen::Helper::MOTIS;

# Copyright (C) 2025 networkException <git@nwex.de>
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Travel::Status::MOTIS;
use Mojo::JSON qw(decode_json);
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

sub get_coverage {
	my ( $self, $service ) = @_;

	my $service_definition = Travel::Status::MOTIS::get_service($service);

	if ( not $service_definition ) {
		return {};
	}

	return $service_definition->{coverage}{area} // {};
}

# Input: TripID
# Output: Promise returning a Travel::Status::MOTIS::Trip instance on success
sub get_polyline_p {
	my ( $self, %opt ) = @_;

	my $trip_id = $opt{id};
	my $service = $opt{service} // 'transitous';

	my $promise = Mojo::Promise->new;

	my $agent = $self->{user_agent};

	Travel::Status::MOTIS->new_p(
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $agent->request_timeout(10),

		service       => $service,
		trip_id       => $trip_id,
	)->then(
		sub {
			my ($motis) = @_;
			my $trip = $motis->result;

			$promise->resolve($trip);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("MOTIS->new_p($trip_id) error: $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
