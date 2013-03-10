package Devel::YCallTraceDbg;

use warnings;
use strict;

our @IMPORT;

sub import {
    shift;
    @IMPORT = @_;
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
    if (!$Devel::YCallTrace::STARTED && $sub=~/^main::[^:]+$/){
        require Devel::YCallTrace;
        Devel::YCallTrace::init(@Devel::YCallTraceDbg::IMPORT);
    }
    no strict 'refs';
    return &{ $sub };
}


1;

