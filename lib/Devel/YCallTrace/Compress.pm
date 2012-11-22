package Devel::YCallTrace::Compress;

# $Id: Compress.pm 316 2012-11-22 14:19:36Z lena $

=head1 NAME

    Devel::YCallTrace::Compress

=head1 DESCRIPTION

    compress/decompress data, wrapper around Compress::Raw::Zlib

=cut

use strict;
use warnings;

use Compress::Raw::Zlib qw/Z_OK Z_STREAM_END/;

use base qw/Exporter/;
our @EXPORT = qw/
    inflate deflate
/;

=head2 deflate($data)

    compress $data

=cut
sub deflate{
    my $in = shift;
    return '' if !defined $in || $in eq '';
    my ($d, $status) = new Compress::Raw::Zlib::Deflate(-Level => 9, -AppendOutput => 1);
    die "Can't create deflate object: $status" if !$d;
    my $out;
    $d->deflate($in, $out) == Z_OK or die "Can't deflate: ".$d->msg();
    $d->flush($out) == Z_OK or die "Can't flush: ".$d->msg();
    return $out;
}

=head2 inflate($compressed_data)

    uncompress $compressed_data

=cut
sub inflate{
    my $in = shift;
    return '' if !defined $in || $in eq '';
    my ($i, $status) = new Compress::Raw::Zlib::Inflate();
    die "Can't create inflate object: $status" if !$i;
    my $out;
    $i->inflate($in, $out) == Z_STREAM_END or die "Can't inflate: ".$i->msg();
    return $out;
}

1;
