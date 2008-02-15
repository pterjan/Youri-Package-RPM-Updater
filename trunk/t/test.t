#!/usr/bin/perl
# $Id: /mirror/youri/soft/Repository/trunk/t/test.t 2314 2007-03-22T13:41:57.774951Z guillomovitch  $

use strict;
use DateTime;
use File::Basename;
use File::Copy;
use File::Temp qw/tempdir/;
use Test::More tests => 25;
use Test::Exception;
use RPM4;

BEGIN {
    use_ok('Youri::Package::RPM::Updater');
}

my $spec_file = dirname($0) . '/perl-File-HomeDir.spec';

my $topdir = tempdir(CLEANUP => $ENV{TEST_DEBUG} ? 0 : 1);

# force default packager
my $packager = (getpwuid($<))[0];
RPM4::add_macro("packager $packager");

my $updater = Youri::Package::RPM::Updater->new();
isa_ok($updater, 'Youri::Package::RPM::Updater');

my $new_version_spec_file = $topdir . '/new_version.spec';
copy($spec_file, $new_version_spec_file);

lives_ok {
    $updater->update_from_spec($new_version_spec_file, '0.60', download => 0);
} 'updating to a new version';

my $new_version_spec = RPM4::Spec->new($new_version_spec_file, force => 1);
isa_ok($new_version_spec, 'RPM4::Spec', 'spec syntax');

my $new_version_header = $new_version_spec->srcheader();
is($new_version_header->tag('version'), '0.60', 'new version');
is($new_version_header->tag('release'), '1'   , 'new release');

is(
    ($new_version_header->tag('changelogname'))[0],
    "$packager 0.60-1",
    'new changelog entry author'
);
is(
    DateTime->from_epoch(epoch =>
        ($new_version_header->tag('changelogtime'))[0]
    )->strftime('%a %b %d %Y'),
    DateTime->now()->strftime('%a %b %d %Y'),
    'new changelog entry date'
);
is(
    ($new_version_header->tag('changelogtext'))[0],
    '- New version 0.60',
    'new changelog entry text'
);

my $new_release_spec_file = $topdir . '/new_release.spec';
copy($spec_file, $new_release_spec_file);

lives_ok {
    $updater->update_from_spec($new_release_spec_file);
} 'updating to a new release';

my $new_release_spec = RPM4::Spec->new($new_release_spec_file, force => 1);
isa_ok($new_release_spec, 'RPM4::Spec', 'spec syntax');

my $new_release_header = $new_release_spec->srcheader();
is($new_release_header->tag('version'), '0.58', 'new version');
is($new_release_header->tag('release'), '2'   , 'new release');

is(
    ($new_release_header->tag('changelogname'))[0],
    "$packager 0.58-2",
    'new changelog entry author'
);
is(
    DateTime->from_epoch(epoch =>
        ($new_release_header->tag('changelogtime'))[0]
    )->strftime('%a %b %d %Y'),
    DateTime->now()->strftime('%a %b %d %Y'),
    'new changelog entry date'
);
is(
    ($new_release_header->tag('changelogtext'))[0],
    '- Rebuild',
    'new changelog entry text'
);

my $no_changelog_spec_file = $topdir . '/no_changelog.spec';
copy($spec_file, $no_changelog_spec_file);

lives_ok {
    $updater->update_from_spec($no_changelog_spec_file, undef, update_changelog => 0);
} 'updating to a new release without updating changelog';

my $no_changelog_spec = RPM4::Spec->new($no_changelog_spec_file, force => 1);
isa_ok($no_changelog_spec, 'RPM4::Spec', 'spec syntax');
my $no_changelog_header = $no_changelog_spec->srcheader();

is(
    ($no_changelog_header->tag('changelogname'))[0],
    'Guillaume Rousse <guillomovitch@mandriva.org> 0.58-1',
    'no new changelog entry (author)'
);
is(
    DateTime->from_epoch(epoch =>
        ($no_changelog_header->tag('changelogtime'))[0]
    )->strftime('%a %b %d %Y'),
    'Wed May 31 2006',
    'no new changelog entry (date)'
);
is(
    ($no_changelog_header->tag('changelogtext'))[0],
    '- test release',
    'no new changelog entry (text)'
);

my $no_revision_spec_file = $topdir . '/no_revision.spec';
copy($spec_file, $no_revision_spec_file);

lives_ok {
    $updater->update_from_spec($no_revision_spec_file, undef, update_revision => 0);
} 'updating to a new release without updating revision';

my $no_revision_spec = RPM4::Spec->new($no_revision_spec_file, force => 1);
isa_ok($no_revision_spec, 'RPM4::Spec', 'spec syntax');

my $no_revision_header = $no_revision_spec->srcheader();
is($no_revision_header->tag('version'), '0.58', 'new version');
is($no_revision_header->tag('release'), '1'   , 'new release');
