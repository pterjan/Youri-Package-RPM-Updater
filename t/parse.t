#!/usr/bin/perl
# $Id: /mirror/youri/soft/Repository/trunk/t/test.t 2314 2007-03-22T13:41:57.774951Z guillomovitch  $

use strict;
use Test::More;
use Youri::Package::RPM::Updater;

my @version_tests = (
    [ 'Version: 1', 'Version: ', '1', 'tag, simple value' ],
    [ 'Version: 1.01', 'Version: ', '1.01', 'tag, decimal value' ],
    [ 'Version: 1.0.1', 'Version: ', '1.0.1', 'tag, dotted value' ],
    [ 'version: 1', 'version: ', '1', 'lowercased tag' ],
    [ 'version:   1', 'version:   ', '1', 'tag, multiple spaces' ],
    [ 'version:	1', 'version:	', '1', 'tag, tabulation' ],
    [ 'version:	 1', 'version:	 ', '1', 'tag, mixed spacing' ],
    [ 'version: 1  ', 'version: ', '1', 'tag, trailing spaces' ],
    [ '%define version 1', '%define version ', '1', 'macro, simple value' ],
    [ '%define version 1.01', '%define version ', '1.01', 'macro, decimal value' ],
    [ '%define version 1.0.1', '%define version ', '1.0.1', 'macro, dotted value' ],
    [ '%define  version  1', '%define  version  ', '1', 'macro, multiple spaces' ],
    [ '%define	version	1', '%define	version	', '1', 'macro, tabulations' ],
    [ '%define	version 1', '%define	version ', '1', 'macro, mixed spacing' ],
    [ '%define version 1  ', '%define version ', '1', 'macro, trailing spaces' ],
);

my @release_tests = (
    [ 'Release: 1', 'Release: ', '2', 'tag, simple value' ],

);

plan tests => scalar @version_tests + @release_tests;

foreach my $test (@version_tests) {
    is_deeply(
       [ Youri::Package::RPM::Updater::_get_new_version($test->[0]) ],
       [ $test->[1], $test->[2] ],
       $test->[3],
   );
};

foreach my $test (@release_tests) {
    is_deeply(
       [ Youri::Package::RPM::Updater::_extract_release($test->[0]) ],
       [ $test->[1], $test->[2] ],
       $test->[3],
   );
};
