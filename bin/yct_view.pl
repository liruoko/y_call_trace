#!/usr/bin/perl

use strict;
use Data::Dumper;
use DateTime;
use File::Slurp;
use DBI;
use Template;
use HTTP::Daemon;
use HTTP::Status;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";

use Devel::YCallTrace::Compress;

use FindBin qw/$Bin/;

our $dbh;
our $template;

run() unless caller();


sub run
{
    my $port = $ARGV[0] ||0;
    my $dbfile = $ARGV[1] || '/tmp/y_call_trace/yct.db';

    connect_db($dbfile);
    init_template();

    my %param = (
        #LocalAddr => ...,
        ReuseAddr => 1,
    );
    $param{LocalPort} = $port if $port;

    my $d = new HTTP::Daemon( %param ) or die "$@";

    print "Please contact me at: ", $d->url, "\n";
    while (my $c = $d->accept) {
        while (my $r = $c->get_request) {
            next if $r->method ne 'GET';
            eval{
                if ($r->url->path =~ m!^/(|list)$!) {
                    my $page = generate_list_page();
                    response_text($c, $page);
                } elsif( $r->url->path =~ m!^/log/([0-9]+)$! ){
                    my $reqid = $1;
                    my $page = generate_log_page($reqid);
                    response_text($c, $page);
                } elsif( $r->url->path =~ m!^/args/([0-9]+)/([0-9]+)/([0-9]+)$! ){
                    my ($date, $reqid, $call_id) = ($1, $2, $3);
                    my $page = generate_args_page($date, $reqid, $call_id);
                    response_text($c, $page);
                } elsif( $r->url->path eq '/jquery' ){
                    $c->send_file_response("$Bin/../templates/jquery.min.js");
                } else {
                    print "can't serve url ".$r->url->path."\n";
                    $c->send_error(RC_NOT_FOUND)
                }
            };
            if ($@){
                print STDERR "$@";
                $c->send_error(RC_NOT_FOUND)
            }
        }
        $c->close;
        undef($c);
    }
}


sub connect_db
{
    my ($dbfile) = @_;
    $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die "can't connect to db";
    return '';
}


sub init_template
{
    my $template_config = {
        OUTPUT_PATH => 'report',
        INCLUDE_PATH => "$Bin/../templates",
        INTERPOLATE  => 0,
        EVAL_PERL    => 1,
        FILTERS => {
            js => sub {return $_[0];},
            html => sub {return $_[0];},
        },
    };
    $template = Template->new($template_config);
    return '';
}


sub response_text
{
    my ($c, $text) = @_;
    my $resp = HTTP::Response->new( 200, 'OK', [], $text );
    $c->send_response( $resp );
    return '';
}


sub generate_list_page
{
    my $output = "";

    my $db_records = $dbh->selectall_arrayref( "
        SELECT reqid, logtime, date_suff, title, comment 
        FROM y_call_trace_metadata
        "
    );

    my %log_by_date;
    for my $rec (@$db_records){
        my %pl;
        @pl{qw/reqid logtime date_suff title comment/} = @$rec[0,1,2,3,4];
        push @{$log_by_date{$pl{date_suff}}}, \%pl;
    }

    my $vars = {
        log_by_date => \%log_by_date,
    };
    $template->process("list.html", $vars, \$output) || die $template->error();
    return $output;
}


sub generate_log_page
{
    my ($reqid) = @_;
    my $output = "";

    #my $date = DateTime->today(time_zone => 'local')->strftime('%Y%m%d');

    my $metadata_rec = $dbh->selectall_arrayref( "
        SELECT reqid, logtime, title, comment, highlight_func, date_suff 
        FROM y_call_trace_metadata
        WHERE reqid = ?
        "
        , {}, $reqid
    ) || [];
    my %metadata;
    @metadata{qw/reqid logtime title comment highlight_func date/} = @{$metadata_rec->[0]}[0,1,2,3,4,5] if @$metadata_rec > 0;

    my $table = $dbh->quote_identifier("y_call_trace_$metadata{date}");

    my $db_records = $dbh->selectall_arrayref( "
        SELECT reqid, call_id, call_parent_id, logtime, package, func 
        FROM $table
        WHERE reqid = ?
        ORDER BY call_id"
        , {}, $reqid
    );

    my $plain_log = [];
    for my $rec (@$db_records){
        my %pl;
        @pl{qw/reqid call_id call_parent_id logtime package func/} = @$rec[0,1,2,3,4,5];
        $rec = undef;  
        push @$plain_log, \%pl;
    }

    my $main_log = [];
        my %calls = map {$_->{call_id} => $_} @$plain_log;
        for my $l (@$plain_log) {
            if ($calls{$l->{call_parent_id}}) {
                push @{$calls{$l->{call_parent_id}}->{childs}}, $l;
            } else {
                push @$main_log, $l;
            }
        }

    my $vars = {
        log => $main_log, 
        reqid => $reqid,
        metadata => \%metadata,
    };
    $template->process("main.html", $vars, \$output) || die $template->error();
    return $output;
}


sub generate_args_page
{
    my ($date, $reqid, $call_id) = @_;
    my $output = "";

    my $table = $dbh->quote_identifier("y_call_trace_$date");

    my $db_records = $dbh->selectall_arrayref( "
        SELECT 
            reqid, call_id, call_parent_id, logtime, 
            package, func, 
            args, args_after_call, ret
        FROM $table
        WHERE reqid = ?
        AND call_id = ?
        ", {}, $reqid, $call_id
    ) || [];

    my %args = ();
    if ( @$db_records > 0 ){
        my $rec = $db_records->[0];
        @args{qw/reqid call_id call_parent_id logtime package func args args_after_call ret/} = @$rec[0,1,2,3,4,5,6,7,8];
    }
    
    for my $name (qw/args args_after_call ret/) {
        $args{$name} = Encode::decode_utf8(inflate($args{$name})) if $args{$name};
    }

    my $vars = \%args;
    $template->process("args.html", $vars, \$output) || die $template->error();
    return $output;
}

