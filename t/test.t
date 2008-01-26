#!/usr/bin/perl
# $Id: /mirror/youri/soft/Repository/trunk/t/test.t 2314 2007-03-22T13:41:57.774951Z guillomovitch  $

use strict;
use File::Basename;
use File::Path;
use File::Temp qw/tempdir/;
use Test::More tests => 7;
use Test::Exception;
use RPM4;

BEGIN {
    use_ok('Youri::Package::RPM::Updater');
}

my $source = dirname($0) . '/perl-File-HomeDir-0.58-1mdv2007.0.src.rpm';

my $topdir = tempdir(cleanup => 1);
foreach my $dir qw/BUILD SPECS SOURCES SRPMS RPMS tmp/ {
    mkpath(["$topdir/$dir"]);
};
foreach my $arch qw/noarch/ {
    mkpath(["$topdir/RPMS/$arch"]);
};

my $updater = Youri::Package::RPM::Updater->new(
    topdir => $topdir,
    options => '>/dev/null 2>&1'
);
isa_ok($updater, 'Youri::Package::RPM::Updater');

lives_ok {
    $updater->build_from_source($source);
} 'building from source';

my @binaries = <$topdir/RPMS/noarch/*.rpm>;
is(scalar @binaries, 1, 'one binary package');
my @sources = <$topdir/SRPMS/*.rpm>;
is(scalar @sources, 1, 'one source package');

my $package = RPM4::Header->new($sources[0]);
isa_ok($package, 'RPM4::Header');

my $release = `rpm --eval '%mkrel 2'`;
chomp $release;
is($package->release(), $release, 'expected release value');
