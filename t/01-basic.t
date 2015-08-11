use Test::More;
use Test::Mojo;

use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new;
$t->get_ok('/')->status_is(200)->content_like(qr/db-infoscreen/);

done_testing();
