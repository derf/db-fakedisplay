#!/usr/bin/env perl
# Copyright (C) 2026
#
# SPDX-License-Identifier: CC0-1.0

use strict;
use warnings;
use 5.020;

use Test::More;
use Mojo::Promise;
use Mojo::UserAgent;

use lib 'lib';
use DBInfoscreen::Controller::Stationboard;

{
	package t::MockController;

	sub new { bless {}, shift }
	sub ua  { return Mojo::UserAgent->new }
}

my $controller = t::MockController->new;
my $lookahead  = 123;

{
	my %seen;
	local *Travel::Status::DE::HAFAS::new_p = sub {
		my ( $class, %opt ) = @_;
		%seen = %opt;
		return Mojo::Promise->resolve;
	};

	DBInfoscreen::Controller::Stationboard::get_results_p(
		$controller,
		'Berlin Hbf',
		hafas         => 1,
		lookahead     => $lookahead,
		cache_iris_rt => '/tmp/rt',
	);

	ok( exists $seen{lookahead}, 'lookahead passed to HAFAS' );
	is( $seen{lookahead}, $lookahead, 'HAFAS lookahead value' );
}

{
	my %seen;
	local *Travel::Status::DE::EFA::new_p = sub {
		my ( $class, %opt ) = @_;
		%seen = %opt;
		return Mojo::Promise->resolve;
	};

	DBInfoscreen::Controller::Stationboard::get_results_p(
		$controller,
		'Bochum Hbf',
		efa           => 1,
		lookahead     => $lookahead,
		cache_iris_rt => '/tmp/rt',
	);

	ok( !exists $seen{lookahead}, 'lookahead not passed to EFA. It does not support it' );
}

{
	my %seen;
	local *Travel::Status::DE::DBRIS::new_p = sub {
		my ( $class, %opt ) = @_;
		%seen = %opt;
		return Mojo::Promise->resolve;
	};

	DBInfoscreen::Controller::Stationboard::get_results_p(
		$controller,
		'@L=8000105@',
		dbris         => 1,
		lookahead     => $lookahead,
		cache_iris_rt => '/tmp/rt',
	);

	ok( !exists $seen{lookahead}, 'lookahead not passed to DBRIS. It does not support it' );
}

{
	my %seen;
	local *Travel::Status::DE::IRIS::Stations::get_station =
	  sub { return ( [ undef, undef, '8000105' ] ); };
	local *Travel::Status::DE::IRIS::Stations::get_meta = sub { return {}; };
	local *Travel::Status::DE::IRIS::new_p = sub {
		my ( $class, %opt ) = @_;
		%seen = %opt;
		return Mojo::Promise->resolve;
	};

	DBInfoscreen::Controller::Stationboard::get_results_p(
		$controller,
		'Berlin Hbf',
		lookahead       => $lookahead,
		cache_iris_main => '/tmp/main',
		cache_iris_rt   => '/tmp/rt',
	);

	ok( exists $seen{lookahead}, 'lookahead passed to IRIS' );
	is( $seen{lookahead}, $lookahead, 'IRIS lookahead value' );
}

done_testing();
