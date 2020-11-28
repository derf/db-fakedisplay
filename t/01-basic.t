#!/usr/bin/env perl
# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: CC0-1.0

use Test::More;
use Test::Mojo;

use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('DBInfoscreen');
$t->get_ok('/')->status_is(200)->content_like(qr/db-infoscreen/);

done_testing();
