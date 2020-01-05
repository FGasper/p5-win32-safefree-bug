package t::detect_memory_leaks;

use strict;
use warnings;

use Test::More;
use Test::Deep;
use File::Temp;

use Demo::XS;

{

    my $deferred = Demo::XS::deferred();

    my $pid = fork or do {
        exit;
    };
}

ok 1;

done_testing;

1;
