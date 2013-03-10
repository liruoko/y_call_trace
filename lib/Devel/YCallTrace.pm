package Devel::YCallTrace;

use strict;
use warnings;

use DBI;
use Encode;
use POSIX qw/strftime/;
use Data::Dumper;
use DateTime;
use FindBin qw/$Bin/;
use Aspect;
use B qw/svref_2object/;

use Devel::YCallTrace::Compress;

our $VERSION = '0.02';

our $TABLES_FORMAT = '003';

our $REQID;
our $TABLE;
our @IN_PROGRESS;
our @LOG;
our $dbh;
our $STARTED;
our $FINISHED;
our $DISABLE;

our $CALL_ID_COUNTER;
our $PARENT_CALL_ID;

BEGIN {
}


END {
    finish();
}

our $ROOT = Cwd::realpath(File::Basename::dirname($Bin));


sub finish {
    if ($STARTED && !$FINISHED){
        $DISABLE = 1;
        for my $call_rec (@IN_PROGRESS){
            $call_rec->[-5] = 1;
            $call_rec->[-1] = my_dump($?);
        }
        push @LOG, @IN_PROGRESS;
        _insert_log();
        $FINISHED = 1;
    }
}

sub new
{
    my $class = shift;

    init(@_); 
    my $self = bless({}, $class);

    return $self;
}

sub DESTROY
{
    finish();
}


# is subroutine $func defined in package $package (or is it just imported into $package from somewhere else)?
sub _in_package {
    my ($func, $package) = @_;
    no strict 'refs';
    my $cv = svref_2object(*{"${package}::$func"}{CODE});
    return if not $cv->isa('B::CV') or $cv->GV->isa('B::SPECIAL');
    return $cv->GV->STASH->NAME eq $package;
}


# is subroutine $func considered constant?
sub _is_constant
{
    my ($func) = @_;
    no strict 'refs';
    my $x = svref_2object(*{$func}{CODE})->XSUBANY; 
    return ref $x ? 1 : 0;
}


sub init {
    die "won't do duplicate init()" if $STARTED;
    my (%O) = @_;
    $REQID = $O{reqid} || time();
    @LOG = ();
    @IN_PROGRESS = ();

    _init_db(%O);
    $STARTED = 1;

    for my $k (qw/packages namespaces paths/){
        $O{$k} = [$O{$k}] if $O{$k} && !ref $O{$k};
    }

    my @paths = @{$O{paths} || []};
    my $paths_re = @paths > 0 ? join("|", @paths) : '^$';
    my @namespaces = @{$O{namespaces} || []};
    my $trace_namespace = @namespaces > 0 ? "^".join("|", @namespaces) : '^$';

    my %trace_package = (main => 1);
    $trace_package{$_} = 1 for  
        grep {/^[\w:]+$/}
        map {s/\.pm$//; s/\//::/g; $_}
        sort
        grep { $INC{$_} =~ /($paths_re)/ && !/YCallTrace/ }
        keys %INC;
    $trace_package{$_} = 1 for @{$O{packages} || []};

    $CALL_ID_COUNTER = 0;
    $PARENT_CALL_ID = 0;
    around {
        if ( $DISABLE ){
            $_->proceed;
            return;
        }
        my $args = my_dump($_->args);
        my $call_id = ++$CALL_ID_COUNTER;
        my $parent_call_id = $PARENT_CALL_ID;
        local $PARENT_CALL_ID = $call_id;
        my @call_rec = (
            $REQID,
            $call_id,
            $parent_call_id,
            strftime("%Y-%m-%d %H:%M:%S", localtime),
            $_->package_name,
            $_->short_name,
            0,
            0,
            $args,
            undef,
            undef
        );
        push @IN_PROGRESS, \@call_rec;

        eval { $_->proceed };
        my $error = $@;

        my $args_dump = my_dump($_->args);
        if ($args_dump ne $call_rec[-3]) {
            $call_rec[-2] = $args_dump;
        }

        pop @IN_PROGRESS;
        push @LOG, \@call_rec;

        if ($error){
            $call_rec[-4] = 1;
            $call_rec[-1] = my_dump($error);
            _insert_log();
            die $error;
        }

        $call_rec[-1] = my_dump($_->return_value);
       
        _insert_log() if @LOG > 100;
    } call sub {
        my ($p, $f) = ($_[0] =~ /^(.*)::([^:]+)$/);
        # don't trace imported subroutines -- they don't belong here
        # don't trace constant subroutines -- they produce too many of 'constant subroutine redefined' warnings
        # don't trace AUTOLOAD subroutines -- something strange happens sometimes
        return $p && ($trace_package{$p} || $p =~ /$trace_namespace/) && _in_package($f, $p) && !_is_constant("${p}::$f") && $f ne "AUTOLOAD";
    };
}


sub _init_db
{
    my (%O) = @_;

    if ( exists $O{dbh} ){
        $dbh = $O{dbh};
    } else {
        my $dbdir = $O{dbdir} || "/tmp/y_call_trace";
        mkdir $dbdir;
        my $dbfile = "$dbdir/yct.db";
        $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die "can't connect";
    }

    my $date = DateTime->today(time_zone => 'local')->strftime('%Y%m%d');
    $TABLE = $dbh->quote_identifier("y_call_trace_${date}_$TABLES_FORMAT");
    my $meta_table = "y_call_trace_metadata_$TABLES_FORMAT";
    $dbh->do("
        CREATE TABLE IF NOT EXISTS $TABLE (
        reqid bigint unsigned not null,
        call_id int unsigned not null,
        call_parent_id int unsigned not null, 
        logtime timestamp not null,
        package varchar(100) not null,
        func varchar(100) not null,
        exited int unsigned not null default 0,
        died int unsigned not null default 0,
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

    return '';
}


sub _insert_log {
    my @fields = qw(reqid call_id call_parent_id logtime package func exited died args args_after_call ret);
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

fully automated mode (debugger style):

  perl -d:YCallTraceDbg=namespaces,App::Ack /usr/bin/ack-grep init
  perl '-d:YCallTraceDbg (namespaces=>["App::Ack"])' /usr/bin/ack-grep sub

  perl -d:YCallTraceDbg=namespaces,MyProject my-script

  perl -d:YCallTraceDbg  sample_scripts/fib_random_die.pl 9

or explicit initialization in your script:

  require Devel::YCallTrace;
  Devel::YCallTrace::init();

or

  require Devel::YCallTrace;
  Devel::YCallTrace::init( title => $0.join("", map {" $_"} @ARGV) );

=head1 DESCRIPTION

B<Devel::YCallTrace> traces function calls and then present a nice html report. 

The log goes into SQLite database /tmp/y_call_trace/yct.db

To view the report, run 

  yct_view.pl 

and point your browser to the url shown.

Note that at the moment there are two modules: B<Devel::YCallTrace> and B<Devel::YCallTraceDbg>.
B<Devel::YCallTrace> do the main job using L<Aspect>. 
B<Devel::YCallTraceDbg> is a simple frontend to B<Devel::YCallTrace> 
to make it possible to use it like a custom debugger (-d:YCallTraceDbg). 

I don't particularly like this system of two modules, 
but I haven't found another appropriate and reliable way to initialize B<Devel::YCallTrace> 
at the right moment when using it in automated mode
(initialization must be done just before the beginning of execution).
And I don't feel like using debugger hooks in B<Devel::YCallTrace>.
Any advice how to resolve this conflict is welcome!

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

        highlight_func -- regex
        subroutines matching this regex will be highlighted in report

        options to specify what to trace: 

        paths -- a string or a reference to an array of strings;
        Devel::YCallTrace will trace subroutines calls from modules whose path in %INC match one of these regexes;

        packages -- a string or a reference to an array of strings;
        Devel::YCallTrace will trace subroutines defined in these packages

        namespaces -- a string or a reference to an array of strings;
        Devel::YCallTrace will trace subroutines defined in any package under these namespaces


    Tracing will be stopped && log will be written to DB in the END block or by an explicit call of Devel::YCallTrace::finish()

=head2 new

    my $yct_guard = Devel::YCallTrace->new();
    
    Takes the same parameters as init()

    Returns guard object. 
    Tracing will be stopped && log will be written to DB when the object goes out of scope.

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

=head1 AUTHOR

Elena Bolshakova <helena at cpan.org>

=head2 CONTRIBUTORS

The first version of the module was written by Sergey Zhuravlev <zhur at yandex-team.ru>

=head1 COPYRIGHT

Copyright (c) 2012-2013 the Devel::YCallTrace L</AUTHOR> and L</CONTRIBUTORS> as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms as perl itself.

=cut

