package DBInfoscreen::Helper::HAFAS;

# Copyright (C) 2011-2022 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Travel::Status::DE::HAFAS;
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
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

sub get_route_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $now     = DateTime->now( time_zone => 'Europe/Berlin' );

	my $hafas_promise;

	if ( $opt{trip_id} ) {
		$hafas_promise = Travel::Status::DE::HAFAS->new_p(
			journey => {
				id => $opt{trip_id},
			},
			language   => $opt{language},
			cache      => $self->{realtime_cache},
			promise    => 'Mojo::Promise',
			user_agent => $self->{user_agent}->request_timeout(10)
		);
	}
	elsif ( $opt{train} ) {
		$opt{train_req}    = $opt{train}->type . ' ' . $opt{train}->train_no;
		$opt{train_origin} = $opt{train}->origin;
	}
	else {
		$opt{train_req} = $opt{train_type} . ' ' . $opt{train_no};
	}

	$hafas_promise //= Travel::Status::DE::HAFAS->new_p(
		journeyMatch => $opt{train_req} =~ s{^- }{}r,
		datetime     => ( $opt{train} ? $opt{train}->start : $opt{datetime} ),
		language     => $opt{language},
		cache        => $self->{realtime_cache},
		promise      => 'Mojo::Promise',
		user_agent   => $self->{user_agent}->request_timeout(10)
	)->then(
		sub {
			my ($hafas) = @_;
			my @results = $hafas->results;

			if ( not @results ) {
				return Mojo::Promise->reject(
					"journeyMatch($opt{train_req}) found no results");
			}

			my $result = $results[0];
			if ( @results > 1 ) {
				for my $journey (@results) {
					if ( $opt{train_origin}
						and ( $journey->route )[0]->loc->name eq
						$opt{train_origin} )
					{
						$result = $journey;
						last;
					}
				}
			}

			return Travel::Status::DE::HAFAS->new_p(
				journey => {
					id => $result->id,
				},
				language   => $opt{language},
				cache      => $self->{realtime_cache},
				promise    => 'Mojo::Promise',
				user_agent => $self->{user_agent}->request_timeout(10)
			);
		}
	);

	$hafas_promise->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;
			my @ret;
			my $station_is_past = 1;
			for my $stop ( $journey->route ) {
				push(
					@ret,
					{
						name           => $stop->loc->name,
						eva            => $stop->loc->eva,
						sched_arr      => $stop->sched_arr,
						sched_dep      => $stop->sched_dep,
						rt_arr         => $stop->rt_arr,
						rt_dep         => $stop->rt_dep,
						arr_delay      => $stop->arr_delay,
						dep_delay      => $stop->dep_delay,
						arr_cancelled  => $stop->arr_cancelled,
						dep_cancelled  => $stop->dep_cancelled,
						platform       => $stop->platform,
						sched_platform => $stop->sched_platform,
						load           => $stop->load,
						isAdditional   => $stop->is_additional,
						isCancelled    => (
							( $stop->arr_cancelled or not $stop->sched_arr )
							  and
							  ( $stop->dep_cancelled or not $stop->sched_dep )
						),
					}
				);
				if (
					    $station_is_past
					and not $ret[-1]{isCancelled}
					and $now->epoch < (
						$ret[-1]{rt_arr} // $ret[-1]{rt_dep}
						  // $ret[-1]{sched_arr} // $ret[-1]{sched_dep} // $now
					)->epoch
				  )
				{
					$station_is_past = 0;
				}
				$ret[-1]{isPast} = $station_is_past;
			}

			$promise->resolve( \@ret, $journey );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

# Input: (HAFAS TripID, line number)
# Output: Promise returning a Travel::Status::DE::HAFAS::Journey instance on success
sub get_polyline_p {
	my ( $self, $trip_id, $line ) = @_;

	my $promise = Mojo::Promise->new;

	Travel::Status::DE::HAFAS->new_p(
		journey => {
			id   => $trip_id,
			name => $line,
		},
		with_polyline => 1,
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $self->{user_agent}->request_timeout(10)
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;

			$promise->resolve($journey);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("HAFAS->new_p($trip_id, $line) error: $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
