package DBInfoscreen::Helper::Wagonorder;

# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
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

sub get_p {
	my ( $self, %opt ) = @_;

	my %param;

	if ( $opt{param} ) {
		%param = %{ $opt{param} };
		delete $param{e};
	}
	else {
		my $datetime = $opt{datetime}->clone->set_time_zone('UTC');
		%param = (
			administrationId => 80,
			category         => $opt{train_type},
			date             => $datetime->strftime('%Y-%m-%d'),
			evaNumber        => $opt{eva},
			number           => $opt{train_number},
			time             => $datetime->rfc3339 =~ s{(?=Z)}{.000}r
		);
	}

	my $url = sprintf( '%s?%s',
'https://www.bahn.de/web/api/reisebegleitung/wagenreihung/vehicle-sequence',
		join( '&', map { $_ . '=' . $param{$_} } keys %param ) );

	my $promise = Mojo::Promise->new;

	if ( my $content = $self->{main_cache}->thaw($url) ) {
		$self->{log}->debug("wagonorder->get_p($url): cached");
		if ( $content->{error} ) {
			return $promise->reject(
"GET $url: HTTP $content->{error}{code} $content->{error}{message} (cachd)"
			);
		}
		return $promise->resolve( $content, \%param );
	}

	if ( my $content = $self->{realtime_cache}->thaw($url) ) {
		$self->{log}->debug("wagonorder->get_p($url): cached");
		if ( $content->{error} ) {
			return $promise->reject(
"GET $url: HTTP $content->{error}{code} $content->{error}{message} (cachd)"
			);
		}
		return $promise->resolve( $content, \%param );
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
				$self->{realtime_cache}->freeze( $url, $json );
				$promise->reject("GET $url: HTTP $err->{code} $err->{message}");
				return;
			}

			$self->{log}->debug("wagonorder->get_p($url): OK");
			my $json = $tx->res->json;
			$json->{ts} = DateTime->now( time_zone => 'Europe/Berlin' )
			  ->strftime('%d.%m.%Y %H:%M');

			$self->{main_cache}->freeze( $url, $json );
			$promise->resolve( $json, \%param );
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
