#!/usr/bin/env perl
# Copyright (C) 2011-2020 Daniel Friesel
#
# SPDX-License-Identifier: BSD-2-Clause

use strict;
use warnings;

use lib 'lib';
use Mojolicious::Commands;

Mojolicious::Commands->start_app('DBInfoscreen');
