#!/usr/bin/env perl
use strict;
use warnings;
use 5.014;
use Test::More;
use Test::Mojo;

use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new;

# Note: These tests depends on RIS live data. If it fails, it -might- also
# be because of RIS problems or unanticipated schedule changes.
# TODO: Support mock XML from hard disk.

$t->get_ok('/Dortmund Universitat?backend=ris')
  ->status_is(200)
  ->content_like(qr{S 1}, 'train name')
  ->content_like(qr{Dortmund Hbf}, 'dest')
  ->content_like(qr{Dortmund-Oespel}, 'via')
  ;

done_testing();
