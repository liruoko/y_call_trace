package Devel::YCallTrace::RoutinesWrapper;

=head1 Devel::YCallTrace::RoutinesWrapper

    Модуль для выполнения некоторого кода до или после выполнения 
    избранных функция.

=head1 SYNOPSIS

    use Devel::YCallTrace::RoutinesWrapper;

    Devel::YCallTrace::RoutinesWrapper::init(
        package => ["Common"],
        cond => sub { $_[0] =~ /Common/ && $_[1] =~ /validate/ },
        handler => [ {
              before => 'print $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC;',
              after => sub {print "After $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC;"},
              } ],
    );

=cut



use strict;
require UNIVERSAL;
require B;

my %SEEN_PACK;
our $DEBUG = 0;
my @code_names = qw/before after/;

=head2 @Devel::YCallTrace::RoutinesWrapper::SUB_ARGS

    параметры, переданные в обёрнутую функцию.

=cut
our @SUB_ARGS;

=head2 @Devel::YCallTrace::RoutinesWrapper::SUB_RET

    результат выполнения обёрнутой функции
    имеет смысл только в after

=cut
our @SUB_RET;

=head2 $Devel::YCallTrace::RoutinesWrapper::SUB_PACKAGE

    пакет, в котором содержится оборачиваемаю функция

=cut
our $SUB_PACKAGE;

=head2 $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC

    имя функции

=cut
our $SUB_FUNC;

our %SUB_ORIG;

=head2 $Devel::YCallTrace::RoutinesWrapper::SUB_CALL_ID

    порядковый номер вызова функции

=cut
our $SUB_CALL_ID = 0;
=head2 $Devel::YCallTrace::RoutinesWrapper::SUB_PARENT_CALL_ID

    порядковый номер вызова родительской функции

=cut
our $SUB_PARENT_CALL_ID = 0;

=head2 $Devel::YCallTrace::RoutinesWrapper::DISABLE

    булевская переменная, нужно лы выполнять before и after

=cut
our $DISABLE = 0;

=head2 init
    
    Оборачивание ф-ций в нужные нам обёртки.
    На вход принимает хэш из параметров:
      - package - массив из названий пекетов, функции из которых нужно оборачивать.
        Дополнительно оборачиваются функции импортированные в эти пакеты
      - sub_struct - произвольная структура данных. Все ссулки на функции оборачиваются.
      - cond - ссылка на функцию, принимающую два параметра - имя пакета и имя функции
        и возвращающая bool - нужно ли оборачивать
      - handler - массив из хэшей имеющих ключи 'before' и 'after', значениями могут быть
        ссылки на функции или строки, содержащие perl код

=cut
sub init {
    my (%PARAMS) = @_;
    print STDERR "Start init\n" if $DEBUG;
    # проверка параметров
    my (@packages, $sub_struct, %CODES, @CODES_OBJ);
    my $cond = sub { 1; };
    while(my ($name, $val) = each %PARAMS) {
        print STDERR " process $name\n" if $DEBUG;
        if ($name eq 'package') {
            @packages = ref($val) eq 'ARRAY' ? @$val : ($val);
            param_error($name) if grep {$_ ne '' && !/^[\w:]+$/} @packages;
        } elsif ($name eq 'sub_struct') {
            $sub_struct = $val;
        } elsif ($name eq 'handler') {
            my @handlers = ref($val) eq 'ARRAY' ? @$val : ($val);
            my %valid = map {$_ => 1} @code_names;
            for my $h (@handlers) {
                if (ref($h) eq 'HASH') {
                    # получаем данные из хеша
                    param_error($name) if grep {!$valid{$_}} keys %$h;
                    for my $code_name (@code_names) {
                        if ($h->{$code_name} && ref $h->{$code_name} eq 'CODE') {
                            push @CODES_OBJ, $h->{$code_name};
                            my $i = $#CODES_OBJ;
                            $CODES{$code_name} .= "\$CODES_OBJ[$i]->();";
                        } elsif ($h->{$code_name}) {
                            $CODES{$code_name} .= $h->{$code_name} 
                        }
                    }
                } elsif (!ref($h)) {
                    # читаем из пакета
                    my $pack = __PACKAGE__.'::'.$h;
                    my $h = eval "require $pack; $pack->new();";
                    param_error($name, $@) if $@;
                    add_handle_object($h, \%CODES, \@CODES_OBJ);
                } elsif (UNIVERSAL::isa($h, "UNIVERSAL")) {
                    # объект
                    add_handle_object($h, \%CODES, \@CODES_OBJ);
                } else {
                    param_error($name);
                }
            }
        } elsif ($name eq 'cond') {
            if (ref($val) eq 'CODE') {
                $cond = $val;
            } else {
                param_error($name);
            }
        } elsif ($name =~ /^(show_warnings|recurse)$/) {
            # skip
        } else {
            param_error($name);
        }
    }
    print STDERR "Params checked\n" if $DEBUG;
    @packages = ('') if !exists $PARAMS{package};
    # чистим список просмотренных пакетов
    %SEEN_PACK = ();
    # прячемся от ошибки "Constant subroutine"
    my $fh;
    if (!$PARAMS{show_warnings} && !$DEBUG) {
        open($fh, ">>", "/dev/null");
    }
    local *STDERR = $fh if $fh;
    # переопределяем все ф-ци
    for my $pack (@packages) {
        print STDERR "start cover $pack" if $DEBUG;
        cover($pack, {
            recurse => $PARAMS{recurse},
            cond => $cond,
            codes => \%CODES,
            codes_obj => \@CODES_OBJ,
              } );
    }
    cover_traverse($sub_struct, {codes => \%CODES, codes_obj => \@CODES_OBJ,});
}

sub cover_traverse {
    my ($data, $opt) = @_;
    if (ref($data) eq 'CODE') {
        $data = cover_func($data, $opt);
    } elsif (ref($data) eq 'ARRAY') {
        for my $i (0 .. $#{$data}) {
            $data->[$i] = cover_traverse($data->[$i], $opt);
        }
    } elsif (ref($data) eq 'HASH') {
        while(my ($key, $val) = each %$data) {
            $data->{$key} = cover_traverse($data->{$key}, $opt);
        }
    }
    return $data;
}

sub add_handle_object {
    my ($h, $codes, $codes_obj) = @_;
    # объект
    for my $code_name (@code_names) {
        if (UNIVERSAL::can($h, "code_$code_name")) {
            $codes->{$code_name} .= eval "\$h->code_$code_name();";
            param_error('handle', $@) if $@;
        }
        if (UNIVERSAL::can($h, "handle_$code_name")) {
            push @$codes_obj, $h;
            my $i = $#{$codes_obj};
            $codes->{$code_name} .= "\$CODES_OBJ[$i]->handle_$code_name();";
        }
    }
}

# вывод ошибки
sub param_error {
    my ($name, $msg) = @_;
    die "Incorrect param '$name' in ".__PACKAGE__."::init".($msg ? " - $msg" : '');
}

sub cover {
    my ($pack, $opt) = @_;
    my @CODES_OBJ = @{$opt->{codes_obj}};
    no strict 'refs';
    #no warnings 'redefine';
    print STDERR "pack: '$pack'\n" if $DEBUG;
    return if $SEEN_PACK{$pack}++;
    my %S = %{$pack."::"};
    for my $name (sort keys %S) {
        print STDERR "  $name\n" if $DEBUG;
        if ($name =~ /^([\w:]+)::$/ && $opt->{recurse}) {
            print STDERR ">>>\n" if $DEBUG;
            cover($1, $opt);
            print STDERR "<<<\n" if $DEBUG;
        } elsif ($name =~ /^\w+$/) {
            my $func = "${pack}::$name";
            my $code = *{$func}{CODE};
            if ($code && $opt->{cond}->($pack, $func)) {
                $SUB_ORIG{$func} = $code;
                *{$func} = cover_func($code, $opt);
            }
        }
    }
}

sub cover_func {
    my ($code, $opt) = @_;
    my @CODES_OBJ = @{$opt->{codes_obj}};
    no strict 'refs';
    print STDERR "   $code\n" if $DEBUG;

    my $obj = B::svref_2object($code);
    my $func_name = $obj->GV->NAME;
    my $pkg_name = $obj->GV->STASH->NAME;

    # переопределяем ф-цию
    my $proto = prototype($code);
    my $str =
        'sub '
        .(defined $proto ? "($proto)" : '')
        .'{'
        .'local *__ANON__ = "'.$pkg_name.'::'.$func_name.'";'
        .'if ($Devel::YCallTrace::RoutinesWrapper::DISABLE) {'
        .'    return $code->(@_);'
        .'}'
        .'local $Devel::YCallTrace::RoutinesWrapper::SUB_PACKAGE = "'.$pkg_name.'";'
        .'local $Devel::YCallTrace::RoutinesWrapper::SUB_FUNC = "'.$func_name.'";'
        .'local @Devel::YCallTrace::RoutinesWrapper::SUB_ARGS = @_;'
        .'local @Devel::YCallTrace::RoutinesWrapper::SUB_RET = ();'
        .'local $Devel::YCallTrace::RoutinesWrapper::SUB_PARENT_CALL_ID = $Devel::YCallTrace::RoutinesWrapper::SUB_CALL_ID;'
        .'local $Devel::YCallTrace::RoutinesWrapper::SUB_CALL_ID = ++$Devel::YCallTrace::RoutinesWrapper::CALL_ID_COUNTER;'
        .'local $Devel::YCallTrace::RoutinesWrapper::DISABLE = 1;'
        .$opt->{codes}->{before}
        .'$Devel::YCallTrace::RoutinesWrapper::DISABLE = 0;'
        .'local @Devel::YCallTrace::RoutinesWrapper::SUB_RET = wantarray'
        .'? ($code->(@_))'
        .': scalar($code->(@_));'
        .'@Devel::YCallTrace::RoutinesWrapper::SUB_ARGS = @_;'
        .'$Devel::YCallTrace::RoutinesWrapper::DISABLE = 1;'
        .$opt->{codes}->{after}
        .'$Devel::YCallTrace::RoutinesWrapper::DISABLE = 0;'
        .'return wantarray'
        .'? @Devel::YCallTrace::RoutinesWrapper::SUB_RET'
        .': $Devel::YCallTrace::RoutinesWrapper::SUB_RET[0];'
        .'}';
    print STDERR "$str\n" if $DEBUG;
    return eval $str;
}

sub deinit {
    no strict 'refs';
    while(my ($func, $code) = each %SUB_ORIG) {
        *{$func} = $code;
        delete $SUB_ORIG{$func};
    }
}

1;
