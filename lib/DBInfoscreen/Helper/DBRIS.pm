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

# Input: TripID
# Output: Promise returning a Travel::Status::DE::DBRIS::Journey instance on success
sub get_polyline_p {
	my ( $self, %opt ) = @_;

	my $trip_id = $opt{id};
	my $promise = Mojo::Promise->new;

	my $agent = $self->{user_agent};

	if ( my $proxy = $ENV{DBFAKEDISPLAY_DBRIS_PROXY} ) {
		say "set up proxy $proxy";
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	Travel::Status::DE::DBRIS->new_p(
		journey       => $trip_id,
		with_polyline => 1,
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $agent->request_timeout(10)
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

1;
