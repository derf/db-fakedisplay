#!/usr/bin/env perl
# Copyright (C) 2011-2018 Daniel Friesel <derf+dbf@finalrewind.org>
# License: 2-Clause BSD

use strict;
use warnings;

use lib 'lib';
use Mojolicious::Commands;

Mojolicious::Commands->start_app('DBInfoscreen');
