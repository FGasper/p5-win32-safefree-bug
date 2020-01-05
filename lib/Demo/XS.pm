package Demo::XS;

use strict;
use warnings;

our ($VERSION);

use XSLoader ();

BEGIN {
    $VERSION = '0.01';
    XSLoader::load();
}

*deferred = *Demo::XS::Deferred::create;

1;
