use strict;
use warnings FATAL => 'all';
use inc::Module::Install;

all_from('lib/Devel/YCallTrace.pm');

install_script('bin/yct_view.pl');

WriteAll;

