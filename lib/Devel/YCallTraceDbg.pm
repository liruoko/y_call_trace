package Devel::YCallTraceDbg;

use warnings;
use strict;

our $MAIN_FUNC;

sub import {
    shift;
    $MAIN_FUNC = shift || 'main::run';
}

package DB;

our ($single, $trace, $signal);
our $sub;
our @args;


BEGIN {
    # Force use of debugging:
    $INC{'perl5db.pl'} = 1;
    $^P = 0x33f;
}


sub DB {
}


sub sub {
    if ($Devel::YCallTraceDbg::MAIN_FUNC && $sub eq $Devel::YCallTraceDbg::MAIN_FUNC){
        require Devel::YCallTrace;
        Devel::YCallTrace::init();
    }
    no strict 'refs';
    return &{ $sub };
}


1;

