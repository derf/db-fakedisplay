#!/usr/bin/env perl
# Copyright (C) 2011-2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;

use lib 'lib';
use Mojolicious::Commands;

Mojolicious::Commands->start_app('DBInfoscreen');
