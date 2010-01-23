#!/usr/bin/perl
# $Id$

use strict;
use Test::More;
use Youri::Package::RPM::Updater;

my @tests = (
    [
        [ 'ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/ORbit2-2.10.0.tar.bz2', '2.10' ],
        [ 'ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2' , 0 ],
        'gnome, no version in URL'
    ],
    [
        [ 'ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.9/ORbit2-2.10.0.tar.bz2', '2.10' ],
        [ 'ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2' , 0 ],
        'gnome, old version in URL'
    ],
    [
        [ 'ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2', '2.10' ],
        [ 'ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2' , 0 ],
        'gnome, current version in URL'
    ],
    [ 
        [ 'ftp://ftp.cpan.org/pub/CPAN/modules/by-module/Acme/Acme-Ook-0.11.tar.gz', '0.11' ],

        [ 'http://www.cpan.org/modules/by-module/Acme/Acme-Ook-0.11.tar.gz', 0 ],
        'cpan, ftp scheme and tar.gz'
    ],
    [ 
        [ 'ftp://ftp.cpan.org/pub/CPAN/modules/by-module/Acme/Acme-Ook-0.11.tar.bz2', '0.11' ],

        [ 'http://www.cpan.org/modules/by-module/Acme/Acme-Ook-0.11.tar.gz', 1 ],
        'cpan, ftp scheme and tar.bz2'
    ],
    [ 
        [ 'http://www.cpan.org/modules/by-module/Acme/Acme-Ook-0.11.tar.bz2', '0.11' ],
        [ 'http://www.cpan.org/modules/by-module/Acme/Acme-Ook-0.11.tar.gz', 1 ],
        'cpan, http scheme and tar.bz2'
    ],
    [ 
        [ 'http://download.pear.php.net/package/Benchmark-0.11.tar.bz2', '0.11' ],
        [ 'http://download.pear.php.net/package/Benchmark-0.11.tgz', 1 ],
        'pear, tar.bz2'
    ],
);

plan tests => scalar @tests;

foreach my $test (@tests) {
    is_deeply(
       [ Youri::Package::RPM::Updater::_get_mangled_url(@{$test->[0]}) ],
       $test->[1],
       $test->[2],
   );
};
