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

$t->get_ok('/EDUV?mode=marudor_v1&backend=iris')
  ->status_is(200)
  ->json_has('/api_version', 'has api_version')
  ->json_has('/version', 'has version')
  ->json_has('/preformatted', 'has preformatted')
  ->json_has('/preformatted/0', 'has a departure')
  ->json_has('/preformatted/0/additional_stops', '.additional_stops')
  ->json_has('/preformatted/0/canceled_stops', '.canceled_stops')
  ->json_has('/preformatted/0/delay', '.delay')
  ->json_like('/preformatted/0/destination',
              qr{ ^ (Dortmund|Bochum|Essen|D.sseldorf|Solingen) \s Hbf $}x,
              '.destination')
  ->json_has('/preformatted/0/info', '.info')
  ->json_like('/preformatted/0/is_cancelled', qr{ ^ 0 | 1 $ }x, '.is_cancelled')
  ->json_has('/preformatted/0/messages', '.messages')
  ->json_has('/preformatted/0/messages/delay', '.messages.delay')
  ->json_has('/preformatted/0/messages/qos', '.messages.qos')
  ->json_like('/preformatted/0/time', qr{ ^ \d \d? : \d\d $ }x, '.time')
  ->json_is('/preformatted/0/train', 'S 1', '.train')
  ->json_like('/preformatted/0/platform', qr{ ^ 1 | 2 $}x, '.platform')
  ->json_like('/preformatted/0/scheduled_route/0',
              qr{ ^ (Dortmund|Bochum|Essen|D.sseldorf|Solingen) \s Hbf $}x,
              '.scheduled_route[0]')
  ->json_like('/preformatted/0/via/0',
              qr{ ^ Dortmund-Dorstfeld S.d | Dortmund-Oespel $}x,
              '.scheduled_route[0]')
  ;

done_testing();
