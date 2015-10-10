#!/usr/bin/env perl
use strict;
use warnings;
use 5.014;
use Test::More;
use Test::Mojo;

use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new;

# Note: These tests depends on IRIS live data. If it fails, it -might- also
# be because of IRIS problems or unanticipated schedule changes.
# TODO: Support mock XML from hard disk.

$t->get_ok('/EDUV?mode=marudor&version=1')
  ->status_is(200)
  ->json_has('/departures', 'has departures')
  ->json_has('/departures/0', 'has a departure')
  ->json_has('/departures/0/route', '.route')
  ->json_has('/departures/0/delay', '.delay')
  ->json_like('/departures/0/destination',
              qr{ ^ (Dortmund|Bochum|Essen|D.sseldorf|Solingen) \s Hbf $}x,
              '.destination')
  ->json_like('/departures/0/isCancelled', qr{ ^ 0 | 1 $ }x, '.is_cancelled')
  ->json_has('/departures/0/messages', '.messages')
  ->json_has('/departures/0/messages/delay', '.messages.delay')
  ->json_has('/departures/0/messages/qos', '.messages.qos')
  ->json_like('/departures/0/time', qr{ ^ \d \d? : \d\d $ }x, '.time')
  ->json_is('/departures/0/train', 'S 1', '.train')
  ->json_like('/departures/0/platform', qr{ ^ 1 | 2 $}x, '.platform')
  ->json_like('/departures/0/route/0/name',
              qr{ ^ (Dortmund|Bochum|Essen|D.sseldorf|Solingen) \s Hbf $}x,
              '.route[0]')
  ->json_like('/departures/0/via/0',
              qr{ ^ Dortmund-Dorstfeld \s S.d | Dortmund-Oespel $}x,
              '.via[0]')
  ;

$t->get_ok('/EDUV?mode=marudor&version=1&callback=my_callback')
  ->status_is(200)
  ->content_like(qr{ ^ my_callback \( }x, 'json callback works');
# ) <- just here to fix bracket grouping in vim

done_testing();
