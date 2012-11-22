#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Data::Dumper;

run() unless caller();

sub run
{

    require Devel::YCallTrace;
    Devel::YCallTrace::init(highlight_func => 'explain_state');

    my $board = read_board();

    print_board($board);
    solve($board);

    explain_hypothesis($board);

    print "result:\n";
    print_board($board);

    exit 0;
}


sub read_board
{
    my @arr;
    while(my $str = <>){
        chomp($str);
        push @arr, grep {!/^\s+$/}  split "", $str;
    }
    die "expected 81 cells" unless scalar @arr == 81;

    my $board;

    for my $i ( 1 .. 9 ){
        for my $j (1 .. 9){
            my $c = shift @arr;
            if ($c eq '.'){
                $board->{"$i$j"} = {
                    type => 'solution',
                    content => '',
                    hypothesis => { map { $_ => 1 } 1 .. 9 },
                };
            } elsif ($c =~ /^\d$/){
                $board->{"$i$j"} = {
                    type => 'given',
                    content => $c,
                };
            } else {
                die;
            }
        }
    }
    return $board;
}

sub generate_groups
{
    my @groups;
    for my $i (1..9){
        for my $j (1..9){
            my $n = int(($i-1) / 3); 
            my $m = int(($j-1) / 3); 
            push @{$groups[ $n *3 + $m ]}, "$i$j";
        }
    }
    for my $i (1..9){
        my @h;
        my @v;
        for my $j (1..9){
            push @h, "$i$j";
            push @v, "$j$i";
        }
        push @groups, \@h, \@v;
    }
    die "wrong groups" unless scalar @groups == 27;
    return \@groups;
}


sub generate_subsets
{
    my @subsets;

    for my $n (1 .. 255){
        my @mask = reverse split "", sprintf "%b", $n;
        my @subset;
        for my $i (1 .. 9){
            push @subset, $i if $mask[$i - 1];
        }
        next if @subset == 1;
        push @subsets, \@subset;
    }

    @subsets = sort {@$a <=> @$b} @subsets;

    return \@subsets;
}


sub solve
{
    my ($board) = @_;

    my $groups = generate_groups();
    my $subsets = generate_subsets();

    my $changed = 1;
    while ($changed){
        explain_hypothesis($board);
        $changed = 0;
        for my $g (@$groups){
            $changed ||= rule_0($board, $g);
            $changed ||= rule_1($board, $g);
            $changed ||= rule_2($board, $g);
            $changed ||= rule_3($board, $g, $subsets);
        }

        explain_state($board) if $changed;
    }
}


sub print_board
{
    my ($board) = @_;

    for my $i (1..9){
        for my $j (1..9){
            print $board->{"$i$j"}->{content}||'.';
            print " " if $j % 3 == 0;
            print "\n" if $i % 3 == 0 && $j == 9;
        }
        print "\n";
    }

    return '';
}

sub print_hypothesis
{
    my ($board) = @_;

    for my $i (1..9){
        for my $j (1..9){
            my $ind = "$i$j";
            if ($board->{"$i$j"}->{content}){
                print "$ind ==".$board->{"$i$j"}->{content};
            } else {
                print "$ind ~~".join("", grep { $board->{$ind}->{hypothesis}->{$_} } 1 .. 9);
            }
            print "\n";
        }
        print "\n";
    }

    return '';
}


sub rule_0
{
    my ($board, $g) = @_;

    my $changed = 0;

    for my $ind (@$g){
        next if $board->{$ind}->{content};
        my @h = grep { $board->{$ind}->{hypothesis}->{$_} } 1 .. 9;
        next if @h != 1;
        my $d = $h[0];
        explain(0, "$ind ==$d");
        $board->{$ind}->{content} = $d;
        $changed = 1;
    }

    return $changed;
}

sub rule_1
{
    my ($board, $g) = @_;

    my $changed = 0;

    my %exists;
    for my $i (@$g){
        next unless $board->{$i}->{content};
        $exists{$board->{$i}->{content}} = 1;
    }
    for my $i (@$g){
        for my $d (keys %exists){
            next if $board->{$i}->{content};
            next if $board->{$i}->{hypothesis}->{$d} == 0;
            $board->{$i}->{hypothesis}->{$d} = 0;
            explain(1, "$i --$d ".join(",", @$g));
            $changed = 1;
        }
    }

    return $changed;
}


sub rule_2
{
    my ($board, $g) = @_;

    my $changed = 0;

    my %cells;
    for my $ind (@$g){
        next if $board->{$ind}->{content};
        for my $d (keys %{$board->{$ind}->{hypothesis}}) {
            next if $board->{$ind}->{hypothesis}->{$d} == 0;
            push @{$cells{$d}}, $ind;
        }
    }
    while (my ($d, $indices) = each %cells) {
        next if scalar @$indices != 1;
        my $ind = $indices->[0];
        $board->{$ind}->{content} = $d;
        explain(2, "$ind ==$d ".join(",", @$g));
        $changed = 1;
    }

    return $changed;
}


sub rule_3
{
    my ($board, $g, $subsets) = @_;
    my $changed = 0;

    SUBSET: for my $s (@$subsets){
        my %index;
        my %digit;
        for my $j (@$s){
            my $ind = $g->[$j];
            next SUBSET if $board->{$ind}->{content};
            $index{$ind} = 1;
            for my $d (keys %{$board->{$ind}->{hypothesis}}) {
                next if $board->{$ind}->{hypothesis}->{$d} == 0;
                $digit{$d} = 1;
            }
        }
        next unless keys %index == keys %digit;
        for my $ind (@$g){
            next if $index{$ind};
            next if $board->{$ind}->{content};
            for my $d (keys %digit) {
                next if $board->{$ind}->{hypothesis}->{$d} == 0;
                $board->{$ind}->{hypothesis}->{$d} = 0;
                explain(3, "$ind --$d ".join(",", keys %index)." => ".join(",", keys %digit));
                $changed = 1;
                last SUBSET;
            }
        }
    }

    return $changed;
}


sub explain 
{
    my ($rule, $str) = @_;

    return unless $ENV{EXPLAIN};

    print "($rule) $str\n";
}

sub explain_state
{
    my ($board) = @_;

    return unless $ENV{EXPLAIN};

    print "\n\n";
    print_board($board);
}

sub explain_hypothesis
{
    my ($board) = @_;

    return unless $ENV{EXPLAIN};

    print "hypothesis:\n";
    print_hypothesis($board);
}
