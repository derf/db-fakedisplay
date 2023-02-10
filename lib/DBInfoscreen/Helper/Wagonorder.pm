package DBInfoscreen::Helper::Wagonorder;

# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

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
			my ($body) = @_;
			$promise->resolve($body);
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
			my ($body) = @_;
			$promise->resolve($body);
			return;
		},
		sub {
			$promise->reject;
			return;
		}
	)->wait;

	return $promise;
}

sub get_dbdb_p {
	my ( $self, $url ) = @_;

	my $promise = Mojo::Promise->new;

	my $cache = $self->{main_cache};

	if ( my $content = $cache->get($url) ) {
		if ($content) {
			return $promise->resolve($content);
		}
		else {
			return $promise->reject;
		}
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			if ( $tx->result->is_success ) {
				my $body = $tx->result->body;
				$cache->set( $url, $body );
				$promise->resolve($body);
			}
			else {
				$cache->set( $url, q{} );
				$promise->reject;
			}
			return;
		}
	)->catch(
		sub {
			$cache->set( $url, q{} );
			$promise->reject;
			return;
		}
	)->wait;
	return $promise;
}

sub head_dbdb_p {
	my ( $self, $url ) = @_;

	my $promise = Mojo::Promise->new;

	my $cache = $self->{main_cache};

	if ( my $content = $cache->get($url) ) {
		$self->{log}->debug("wagonorder->head_dbdb_p($url): cached ($content)");
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
				$self->{log}->debug("wagonorder->head_dbdb_p($url): y");
				$cache->set( $url, 'y' );
				$promise->resolve;
			}
			else {
				$self->{log}->debug("wagonorder->head_dbdb_p($url): n");
				$cache->set( $url, 'n' );
				$promise->reject;
			}
			return;
		}
	)->catch(
		sub {
			$self->{log}->debug("wagonorder->head_dbdb_p($url): n");
			$cache->set( $url, 'n' );
			$promise->reject;
			return;
		}
	)->wait;
	return $promise;
}

sub has_cycle_p {
	my ( $self, $train_no ) = @_;

	return $self->head_dbdb_p(
		"https://lib.finalrewind.org/dbdb/db_umlauf/${train_no}.svg");
}

sub check_wagonorder_p {
	my ( $self, $train_no, $wr_link ) = @_;

	my $promise = Mojo::Promise->new;

	$self->head_dbdb_p(
		"https://lib.finalrewind.org/dbdb/has_wagonorder/${train_no}/${wr_link}"
	)->then(
		sub {
			$promise->resolve;
			return;
		}
	)->catch(
		sub {
			$self->get_p( $train_no, $wr_link )->then(
				sub {
					$promise->resolve;
					return;
				}
			)->catch(
				sub {
					$promise->reject;
					return;
				}
			)->wait;
			return;
		}
	)->wait;

	return $promise;
}

sub get_p {
	my ( $self, $train_no, $api_ts ) = @_;

	my $url
	  = "https://ist-wr.noncd.db.de/wagenreihung/1.0/${train_no}/${api_ts}";

	my $cache = $self->{realtime_cache};

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}->debug("wagonorder->get_p($url): cached");
		if ( $content->{error} ) {
			return $promise->reject($content);
		}
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(10)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				my $json = {
					error => {
						id  => $err->{code},
						msg => $err->{message}
					}
				};
				$self->{log}->debug(
					"wagonorder->get_p($url): HTTP $err->{code} $err->{message}"
				);
				$cache->freeze( $url, $json );
				$promise->reject($json);
				return;
			}

			$self->{log}->debug("wagonorder->get_p($url): OK");
			my $json = $tx->res->json;

			$cache->freeze( $url, $json );
			$promise->resolve($json);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("wagonorder->get_p($url): $err");
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
