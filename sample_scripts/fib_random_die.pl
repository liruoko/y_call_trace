#! /usr/bin/perl

use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

our $DIE_RATE;

run() unless caller();

sub run
{
    my $N = @ARGV > 0 ? $ARGV[0] : '';
    die "incorrect parameter" unless $N =~ /^\d+$/;

    $DIE_RATE = $ARGV[1] ||100;

    eval{print fib($N);};
    print fib($N+1);
}

sub fib
{
    my ($N) = @_;

    die "lucky you! ($N)" if int(rand $DIE_RATE) == 0;

    if ($N <= 2 ){
        return 1;
    } else {
        return fib($N-1) + fib($N-2);
    }
}

