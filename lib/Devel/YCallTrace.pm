package Devel::YCallTrace;

use strict;
use warnings;

use DBI;
use Encode;
use POSIX qw/strftime/;
use Data::Dumper;
use DateTime;
use FindBin qw/$Bin/;

use Devel::YCallTrace::RoutinesWrapper;
use Devel::YCallTrace::Compress;


our $REQID;
our $TABLE;
our @CALL_REC;
our @LOG;
our $dbh;
our $FINISHED;

BEGIN {
}

END {
    unless ($FINISHED){
        local $Devel::YCallTrace::RoutinesWrapper::DISABLE = 1;
        _insert_log();
    }
}

our $ROOT = Cwd::realpath(File::Basename::dirname($Bin));

sub finish {
    $Devel::YCallTrace::RoutinesWrapper::DISABLE = 1;
    _insert_log();
    $FINISHED = 1;
}


sub init {
    my (%O) = @_;
    $REQID = $O{reqid} || time();
    my $to_trace = $O{to_trace} || [ $ROOT ];

    if ( exists $O{dbh} ){
        $dbh = $O{dbh};
    } else {
        my $dbdir = $O{dbdir} || "/tmp/y_call_trace";
        mkdir $dbdir;
        my $dbfile = "$dbdir/yct.db";
        $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die "can't connect";
    }

    @LOG = ();
    my $to_trace_re = @$to_trace > 0 ? join("|", @$to_trace) : '^$';

    #$Devel::YCallTrace::RoutinesWrapper::DEBUG=1;
    no warnings 'once';
    Devel::YCallTrace::RoutinesWrapper::init(
        package => [
        'main',
            grep {/^[\w:]+$/}
            map {s/\.pm$//; s/\//::/g; $_}
            sort
            grep {$INC{$_} =~ /($to_trace_re)/ && !/YCallTrace/ && !/RoutinesWrapper/}
            keys %INC
        ],
        cond => sub {
            return $_[1] !~ /need_.*_context/;
        },
        sub_struct => [],
        handler => [ {
            before => 'local @Devel::YCallTrace::CALL_REC = ();',
                     }, {
            before => \&before_call,
            after => \&after_call,
                     } ],
        );
    local $Devel::YCallTrace::RoutinesWrapper::DISABLE = 1;
    my $date = DateTime->today(time_zone => 'local')->strftime('%Y%m%d');
    $TABLE = $dbh->quote_identifier("y_call_trace_$date");
    my $meta_table = "y_call_trace_metadata";
    $dbh->do("
        CREATE TABLE IF NOT EXISTS $TABLE (
        reqid bigint unsigned not null,
        call_id int unsigned not null,
        call_parent_id int unsigned not null, 
        logtime timestamp not null,
        package varchar(100) not null,
        func varchar(100) not null,
        args mediumblob,
        args_after_call mediumblob,
        ret mediumblob,
        primary key (reqid, call_id)
        )"
    ) or die $dbh->errstr;
    $dbh->do("
        CREATE TABLE IF NOT EXISTS $meta_table (
        reqid bigint unsigned not null,
        date_suff varchar(10),
        logtime timestamp not null default CURRENT_TIMESTAMP,
        title varchar(300) not null,
        highlight_func varchar(300) not null default '',
        highlight_package varchar(300) not null default '',
        comment text,
        primary key (reqid)
        )"
    ) or die $dbh->errstr;

    my $title = $O{title} || $0;
    my $comment = $O{comment} || '';
    my $highlight_func = $O{highlight_func} || '^$';
    $dbh->do("insert into $meta_table (reqid, date_suff, title, comment, highlight_func) values (?,?,?,?,?)", {}, $REQID, $date, $title, $comment, $highlight_func) or die $dbh->errstr;
}

sub _insert_log {
    my @fields = qw(reqid call_id call_parent_id logtime package func args args_after_call ret);
    my $field_names_str = join(',', @fields);
    my $rows_count = scalar @fields;

    my $sth = $dbh->prepare("insert into $TABLE ($field_names_str) ".
                                "values ( ". join(',', ("?") x $rows_count).")" );
    $dbh->begin_work;
    for my $values ( @LOG ){
        next unless $values;
        $sth->execute( @$values );
    }
    $dbh->commit;

    @LOG = ();
}

sub before_call {
    #print STDERR "before $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC / $Devel::YCallTrace::RoutinesWrapper::SUB_PARENT_CALL_ID / $Devel::YCallTrace::RoutinesWrapper::SUB_CALL_ID\n";
    #return;
    my $args;
    # TODO Tools::dd --избавиться
    if ($Devel::YCallTrace::RoutinesWrapper::SUB_PACKAGE eq 'Tools' && $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC eq 'dd'
        && @Devel::YCallTrace::RoutinesWrapper::SUB_ARGS == 1 && !ref $Devel::YCallTrace::RoutinesWrapper::SUB_ARGS[0]
    ) {
        $args = $Devel::YCallTrace::RoutinesWrapper::SUB_ARGS[0];
        $args = deflate(Encode::is_utf8($args) ? Encode::encode_utf8($args) : $args);
    } else {
        $args = my_dump(@Devel::YCallTrace::RoutinesWrapper::SUB_ARGS);
    }    
    @CALL_REC = (
        $REQID,
        $Devel::YCallTrace::RoutinesWrapper::SUB_CALL_ID,
        $Devel::YCallTrace::RoutinesWrapper::SUB_PARENT_CALL_ID,
        strftime("%Y-%m-%d %H:%M:%S", localtime),
        $Devel::YCallTrace::RoutinesWrapper::SUB_PACKAGE,
        $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC,
        $args,
        undef,
        undef
        );
}

sub after_call {
    #print STDERR "after $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC / $Devel::YCallTrace::RoutinesWrapper::SUB_PARENT_CALL_ID / $Devel::YCallTrace::RoutinesWrapper::SUB_CALL_ID\n";

    $CALL_REC[-1] =  my_dump(@Devel::YCallTrace::RoutinesWrapper::SUB_RET);

    my $args_dump = my_dump(@Devel::YCallTrace::RoutinesWrapper::SUB_ARGS);
    if ($args_dump ne $CALL_REC[-3]) {
        $CALL_REC[-2] = $args_dump;
    }

    push @LOG, \@CALL_REC;
    _insert_log() if @LOG > 100;
}

sub my_dump {
    my @data = @_;
    local ($Data::Dumper::Indent, $Data::Dumper::Sortkeys, $Data::Dumper::Terse) = (1, 1, 1);
    my $dump_text = Data::Dumper::Dumper(\@data);
    $dump_text =~ s/\\x\{([\da-f]{2,3})\}/chr hex $1/ige;
    return deflate(Encode::encode_utf8($dump_text));
}

1;

__END__

=head1 NAME

Devel::YCallTrace - Track and report function calls

=head1 SYNOPSIS

  require Devel::YCallTrace;
  
  Devel::YCallTrace::init();

  Devel::YCallTrace::init( title => $0.join("", map {" $_"} @ARGV) );

=head1 DESCRIPTION

Devel::YCallTrace traces function calls and then present a nice html report. 

First, the Devel::YCallTrace module is used and instantiated.

  require Devel::YCallTrace;
  
  Devel::YCallTrace::init();


The log goes into SQLite database /tmp/y_call_trace/yct.db

To view the report, run 

  yct_view.pl 

and point your brouser to the url shown.

=head1 METHODS

=head2 init

    start tracing

    named parameters (optional)

        reqid -- unique identifier
        by default Devel::YCallTrace will use current timestamp

        title -- short name to distinguish between different reports

        comment -- comment, suitable for storing some details about process' context (parameters etc.)
        
        dbh -- database handle for writing collected data
        by default D::YCallTrace will try to use sqlite database /tmp/y_call_trace/yct.db

        to_trace -- reference to an array of regexes;
        Devel::YCallTrace will trace subroutines calls from modules whose path in %INC match one of these regexes;

        highlight_func -- regex
        subroutines matching this regex will be highlighted in report

=head2 finish

    Stop tracing && write all collected data to DB

    By default these actions are performed in the END block of the module.
    Usually you don't need to explicitly call this method.

=cut

=head1 SEE ALSO

Devel::CallStack, 
Devel::CallTrace, 
Devel::Calltree, 
Devel::DumpTrace,
Devel::RemoteTrace, 
Devel::Strace, 
Devel::Trace, 
Devel::Trace::Method, 
Devel::Trace::More, 
Devel::TraceCalls, 
Devel::TraceCwd, 
Devel::TraceFork, 
Devel::TraceMethods, 
Devel::TraceSubs, 
Devel::TraceVars 

=head1 COPYRIGHT

Sergey Zhuravlev

This is free software.
It is licensed under the same terms as Perl itself.

=head1 AUTHOR

    The first version of the module was written by Sergey Zhuravlev (zhur at yandex-team dot ru)
    
    The maintainer now is Elena Bolshakova (helena at cpan dot org)

=cut

