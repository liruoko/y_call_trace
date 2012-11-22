#! /usr/bin/perl

use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

run() unless caller();

sub run
{
    require Devel::YCallTrace;
    Devel::YCallTrace::init( title => "fib.pl".join("", map {" $_"} @ARGV) );

    my $N = @ARGV > 0 ? $ARGV[0] : '';
    die "incorrect parameter" unless $N =~ /^\d+$/;

    print fib($N);
}

sub fib
{
    my ($N) = @_;

    if ($N <= 2 ){
        return 1;
    } else {
        return fib($N-1) + fib($N-2);
    }
}

