# $Id$

package Youri::Package::RPM::Updater;

=head1 NAME

Youri::Package::RPM::Updater - Update RPM packages automatically

=head1 SYNOPSIS

    my $updater = Youri::Package::RPM::Updater->new();
    $updater->build_from_source('foo-1.0-1.src.rpm', '2.0');
    $updater->build_from_spec('foo.spec', '2.0');
    $updater->build_from_repository('foo', '2.0');

=head1 DESCRIPTION

This module automatises rpm package building. When given an explicit new
version, it downloads new sources automatically, updates the spec file and
builds a new version. When not given a new version, it just updates the spec
file a builds a new release.

Warning, not every spec file syntax is supported. If you use specific syntax,
you'll have to ressort to additional processing with explicit perl expression
to evaluate for each line of the spec file.

Here is version update algorithm (only used when building a new version):

=over

=item * find the first definition of version

=item * replace it with new value

=back

Here is release update algorithm:

=over

=item * find the first definition of release

=item * if explicit B<newrelease> parameter given:

=over

=item * replace value

=back

=item * otherwise:

=over

=item * extract any macro occuring in the leftmost part (such as %mkrel)

=item * extract any occurence of B<release_suffix> option in the rightmost part

=item * if a new version is given:

=over

=item * replace with 1

=back

=item * otherwise:

=over

=item * increment by 1

=back

=back

=back

In both cases, both direct definition:

    Version:    X

or indirect definition:

    %define version X
    Version:    %{version}

are supported. Any more complex one is not.

=cut

use strict;
use Cwd;
use Carp;
use DateTime;
use File::Basename;
use File::Copy; 
use File::Spec;
use File::Path;
use File::Fetch;
use RPM4;
use version; our $VERSION = qv('0.1.0');

# silence File::Fetch warnings
$File::Fetch::WARN = 0;
# blacklist lynx handler for false positives
$File::Fetch::BLACKLIST = [ qw/ftp lynx/ ];

# add jabberstudio, collabnet, http://www.sourcefubar.net/, http://sarovar.org/
# http://jabberstudio.org/files/ejogger/
# http://jabberstudio.org/projects/ejogger/project/view.php     
my @SITES = (
    {
        from => 'http://(.*)\.(?:sourceforge|sf)\.net/?(.*)',
        to   => 'http://prdownloads.sourceforge.net/$1/$2'
    },
    { # to test
        from => 'https?://gna.org/projects/([^/]*)/(.*)',
        to   => 'http://download.gna.org/$1/$2'
    },
    {
        from => 'http://(.*)\.berlios.de/(.*)',
        to   => 'http://download.berlios.de/$1/$2'
    },
    { # to test , and to merge with regular savanah ?
        from => 'https?://savannah.nongnu.org/projects/([^/]*)/(.*)',
        to   => 'http://savannah.nongnu.org/download/$1/$2'
    },
    { # to test
        from => 'https?://savannah.gnu.org/projects/([^/]*)/(.*)',
        to   => 'http://savannah.gnu.org/download/$1/$2'
    },
    {
        from => 'http://search.cpan.org/dist/([^-]+)-.*',
        to   => 'http://www.cpan.org/modules/by-module/$1/'
    }
);

my @SF_MIRRORS = qw/
    ovh
    mesh
    switch
    belnet
    puzzle
    heanet
    kent
    voxel
    easynews
    cogent
    optusnet
    jaist
    nchc
    citkit
/;

my @EXTENSIONS = qw/
    .tar.gz
    .tgz
    .tar.Z
    .zip
/;

=head1 CLASS METHODS

=head2 new(%options)

Creates and returns a new MDV::RPM::Updater object.

Avaiable options:

=over

=item topdir $topdir

rpm top-level directory (default: rpm %_topdir macro).

=item sourcedir $sourcedir

rpm source directory (default: rpm %_sourcedir macro).

=item options $options

rpm build options.

=item download true/false

download new sources (default: true).

=item update_revision true/false

update spec file revision (release/history) (default: true).

=item update_changelog true/false

update spec file changelog (default: true).

=item build_source true/false

build source package (default: true).

=item build_binaries true/false

build binary packages (default: true).

=item build_requires_callback $callback

callback to execute before build, with build dependencies as
argument (default: none).

=item build_results_callback $callback

callback to execute after build, with build packages as argument (default:
none).

=item spec_line_callback $callback

callback to execute as filter for each spec file line (default: none).

=item new_source_callback $callback

callback to execute before build for each new source (default: none).

=item old_source_callback $callback

callback to execute before build for each old source (default: none).

=item release_suffix $suffix

suffix appended to numerical value in release tag. (default: none).

=item changelog_entries $entries

list of changelog entries (default: empty).

=item srpm_dirs $dirs

list of directories containing source packages (default: empty).

=back

=cut

sub new {
    my ($class, %options) = @_;

    my $self = bless {
        _topdir            =>
            $options{topdir}            || RPM4::expand('%_topdir'),
        _sourcedir        =>
            $options{sourcedir}         || RPM4::expand('%_sourcedir'),
        _options           =>
            $options{options}           || '',
        _download          =>
            $options{download}          || 1,
        _update_revision   =>
            $options{update_revision}   || 1,
        _update_changelog  =>
            $options{update_changelog}  || 1,
        _build_source      =>
            $options{build_source}      || 1,
        _build_binaries    =>
            $options{build_binaries}    || 1,
        _release_suffix    =>
            $options{release_suffix}    || undef,
        _changelog_entries =>
            $options{changelog_entries} || [],
        _srpm_dirs         =>
            $options{srpm_dirs}         || [],
        _build_requires_callback =>
            $options{build_requires_callback} || undef,
        _build_results_callback  =>
            $options{build_results_callback}  || undef,
        _spec_line_callback      =>
            $options{spec_line_callback}      || undef,
        _new_source_callback     =>
            $options{new_source_callback}     || undef,
        _old_source_callback     =>
            $options{old_source_callback}     || undef,
    }, $class;

    return $self;
}

=head1 INSTANCE METHODS

=head2 build_from_repository($name, $version, $release)

Update package with name $name to version $version and release $release.

=cut

sub build_from_repository {
    my ($self, $name, $newversion, $newrelease) = @_;
    croak "Not a class method" unless ref $self;
    my $src_file;

    foreach my $srpm_dir (@{$self->{_srpm_dirs}}) {
        $src_file = $self->_find_source_package($srpm_dir, $name);
        last if $src_file;
    }   

    croak "No source available for package $name, aborting" unless $src_file;

    return $self->build_from_source($src_file, $newversion, $newrelease);
}

=head2 build_from_source($source, $version, $release)

Update package with source file $source to version $version and release $release.

=cut

sub build_from_source {
    my ($self, $src_file, $newversion, $newrelease) = @_;
    croak "Not a class method" unless ref $self;

    my ($spec_file) = RPM4::installsrpm($src_file);

    croak "Unable to install source package $src_file, aborting"
        unless $spec_file;

    return $self->build_from_spec($spec_file, $newversion, $newrelease);
}

=head2 build_from_spec($spec, $version, $release)

Update package with spec file $spec to version $version and release $release.

=cut

sub build_from_spec {
    my ($self, $spec_file, $newversion, $newrelease) = @_;
    croak "Not a class method" unless ref $self;

    my $pkg_spec = RPM4::Spec->new($spec_file, force => 1)
        or croak "Unable to parse spec $spec_file\n"; 
    my $pkg_header = $pkg_spec->srcheader();

    my $name    = $pkg_header->tag('name');
    my $version = $pkg_header->tag('version');
    my $release = $pkg_header->tag('release');

    # handle everything dependant on new version/release
    if ($newversion) {
        print "===> Building $name $newversion\n";
    } else {    
        print "===> Rebuilding $name\n";
    }

    # install buildrequires
    if ($self->{_build_requires_callback}) {
        my @requires = $pkg_header->tag('requires');
        if (@requires) {
            print "===> Installing BuildRequires : @requires\n";
            $self->{_build_requires_callback}->(@requires);
        }
    };

    # compute sources URL
    my @sources = $pkg_spec->sources_url();

    my @remote_sources = 
        grep { /(?:ftp|svns?|https?):\/\/\S+/ } @sources;

    if (! @remote_sources) {
        print "No remote sources were found, fall back on URL tag ...\n";

        my $url = $pkg_header->tag('url');

        foreach my $site (@SITES) {
            # curiously, we need two level of quoting-evaluation here :(
            if ($url =~ s!$site->{from}!qq(qq($site->{to}))!ee) {
                last;
            }    
        }

        push(@remote_sources, "$url/$sources[0]")
    }

    # download sources
    if (
        $newversion     && # new version
        @remote_sources && # remote sources
        $self->{_download}
    ) { 
        my $found = 0;

        foreach my $remote_source (@remote_sources) {

            if ($self->{_old_source_callback}) {
                $self->{_old_source_callback}->(
                    $self->{_sourcedir} . '/' . basename($remote_source)
                );
            }

            $remote_source =~ s/$version/$newversion/g;

            # GNOME: add the major version to the URL automatically
            # for example: ftp://ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/ORbit2-2.10.0.tar.bz2
            # is rewritten in ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2
            if ($remote_source =~ m!ftp.gnome.org/pub/GNOME/sources/!) {
                (my $major = $newversion) =~ s/([^.]+\.[^.]+).*/$1/;
                $remote_source =~ s!(.*/)(.*)!$1$major/$2!;
            }

            if ($remote_source =~ m!http://prdownloads.sourceforge.net!) {
                # download from sourceforge mirrors
                foreach my $sf_mirror (@SF_MIRRORS) {
                    my $sf_remote_source = $remote_source;
                    $sf_remote_source =~ s!prdownloads.sourceforge.net!$sf_mirror.dl.sourceforge.net/sourceforge!;
                    $found = $self->_fetch_tarball($sf_remote_source);
                    last if $found;
                }
            } else {
                # download directly
                $found = $self->_fetch($remote_source);
            }

            croak "Unable to download source: $remote_source" unless $found;

            if ($self->{_new_source_callback}) {
                $self->{_new_source_callback}->(
                    $self->{_sourcedir} . '/' . basename($remote_source)
                );
            }
        }

    }

    # update spec file
    if ($self->{_update_revision} || $self->{_update_changelog}) {
        open(my $in, '<', $spec_file)
            or croak "Unable to open file $spec_file: $!";

        my $spec;
        my $newrelease = '';
        my $header = '';
        while (my $line = <$in>) {
            if ($self->{_update_revision} &&
                $newversion               && # version change needed
                $version ne $newversion   && # not already done
                $line =~ /^
                    (
                        \%define\s+version\s+ # defined as macro
                    |
                        (?i)Version:\s+       # defined as tag
                    )
                    (\S+(?:\s+\S+)*)          # definition
                    \s*                       # trailing spaces
                $/ox
            ) {
                my ($directive, $definition) = ($1, $2);
                $line = $directive . $newversion . "\n";

                # just to skip test for next lines
                $version = $newversion;
            }

            if ($self->{_update_revision} &&
                $release ne $newrelease   && # not already done
                $line =~ /^
                (
                    \%define\s+release\s+ # defined as macro
                |
                    (?i)Release:\s+       # defined as tag
                )
                (\S+(?:\s+\S+)*)          # definition
                \s*                       # trailing spaces
                $/ox
            ) {
                my ($directive, $definition) = ($1, $2);

                if (! $newrelease) {
                    # if not explicit release given, try to compute it
                    my ($macro, $value) = $definition =~ /^(%\w+\s+)?(.*)$/;

                    croak "Unable to extract release value from definition '$definition'"
                        unless $value;

                    my ($prefix, $number, $suffix); 
                    if ($newversion) {
                        $number = 1;
                    } else {
                        # optional suffix from configuration
                        my $dist_suffix = $self->{_release_suffix};

                        ($prefix, $number, $suffix) =
                            $value =~ /^(.*)(\d+)(\Q$dist_suffix\E)?$/;

                        croak "Unable to extract release number from value '$value'"
                            unless $number;

                        $number++;
                    }

                    $newrelease = 
                        ($macro ? $macro : "") .
                        ($prefix ? $prefix : "") .
                        $number .
                        ($suffix ? $suffix : "");

                }

                $line = $directive . $newrelease . "\n";

                # just to skip test for next lines
                $release = $newrelease;
            }

            $line = $self->{_spec_line_callback}->($line)
                if $self->{_spec_line_callback};
            $spec .= $line;

            if ($self->{_update_changelog} &&
                !$header                   && # not already done
                $line =~ /^\%changelog/
            ) {
                # skip until first changelog entry, as requested for bug #21389
                while ($line = <$in>) {
                    last if $line =~ /^\*/;
                    $spec .= $line;
                }

                my @entries = @{$self->{_changelog_entries}};
                if (@entries) {
                    s/\%\%VERSION/$newversion/ foreach @entries;
                } else  {
                    @entries = $newversion ?
                        "New version $newversion" :
                        'Rebuild';
                }

                $header = RPM4::expand(
                    DateTime->now()->strftime('%a %b %d %Y') . ' ' .
                    $self->_get_packager() . ' ' .
                    (
                        $pkg_header->hastag('epoch') ?
                            $pkg_header->tag('epoch') . ':' :
                            ''
                    ) .
                    $version . '-' .
                    $release
                );

                $spec .= "* $header\n";
                foreach my $entry (@entries) {
                    $spec .= "- $entry\n";
                }
                $spec .= "\n";

                # don't forget kept line
                $spec .= $line;
            }
        }
        close($in);

        open(my $out, '>', $spec_file)
            or croak "Unable to open file $spec_file: $!";
        print $out $spec;
        close($out);
    }

    my $result;
    if ($self->{_build_source} || $self->{_build_binary}) {
        my $command = "rpm";
        $command .= " --define '_topdir $self->{_topdir}'";
        $command .= " --define '_sourcedir $self->{_sourcedir}'";

        if ($self->{_build_source} && $self->{_build_binaries}) {
            $command .= " -ba $self->{_options} $spec_file";
        } elsif ($self->{_build_binaries}) {
            $command .= " -bb $self->{_options} $spec_file";
        } elsif ($self->{_build_source}) {
            $command .= " -bs $self->{_options} --nodeps $spec_file";
        }

        # normalize return value to 1 for failures
        $result = system($command) ? 1 : 0;
    } else {
        $result = 0;
    }

    if ($self->{_build_results_callback}) {
        my @rpms_upload;
        push(@rpms_upload, $pkg_spec->srcrpm);
        foreach my $pkg_bin_file ($pkg_spec->binrpm()) {
            -f $pkg_bin_file or next;
            push(@rpms_upload, $pkg_bin_file);
        }
        $self->{_build_results_callback}->(@rpms_upload);
    }

    return $result;
}

sub _fetch {
    my ($self, $url) = @_;
    # if you add a handler here, do not forget to add it to the body of build()
    return $self->_fetch_tarball($url) if $url =~ m!^(ftp|https?)://!;
    return $self->_fetch_svn($url) if $url =~ m!^svns?://!; 
}

sub _fetch_svn {
    my ($self, $url) = @_;
    my ($basename, $repos);

    $basename = basename($url);
    ($repos = $url) =~ s|/$basename$||;
    $repos =~ s/^svn/http/;
    croak "Cannot extract revision number from the name."
        if $basename !~ /^(.*)-([^-]*rev)(\d\d*).tar.bz2$/;
    my ($name, $prefix, $release) = ($1, $2, $3);
    my $dir="$ENV{TMP}/rpmbuildupdate-$$"; 
    my $current_dir = cwd();
    mkdir $dir or croak "Cannot create dir $dir";
    chdir $dir or croak "Cannot change dir to $dir";
    system("svn co -r $release $repos", "svn checkout failed on $repos");
    my $basedir = basename($repos);

    # FIXME quite inelegant, should use a dedicated cpan module.
    my $complete_name = "$name-$prefix$release";
    move($basedir, $complete_name);
    system("find $complete_name -name '.svn' | xargs rm -Rf");
    system("tar -cjf $complete_name.tar.bz2 $complete_name", "tar failed");
    system("mv -f $complete_name.tar.bz2 $current_dir");
    chdir $current_dir;
}

sub _fetch_tarball {
    my ($self, $url) = @_;

    print "attempting to download $url\n";
    my $ff = File::Fetch->new(uri => $url);
    my $result = $ff->fetch(to => $self->{_sourcedir});
    if ($result) {
        return 1;
    } else {
        my $filename = basename($url);
        foreach my $extension (@EXTENSIONS) {
            my $alternate_url = $url;
            my $alternate_filename = $filename;
            $alternate_url =~ s/\.tar\.bz2/$extension/;
            $alternate_filename =~ s/\.tar\.bz2/$extension/;
            print "attempting to download $alternate_url\n";
            $ff = File::Fetch->new(uri => $alternate_url);
            $result = $ff->fetch(to => $self->{_sourcedir});

            if ($result) {
                system("bzme -f -F $self->{_sourcedir}/$alternate_filename");
                return 1;
            }
        }
    }

    # failure
    return;
}



sub _get_packager {
    my ($self) = @_;
    my $packager = RPM4::expand('%packager');
    if ($packager eq '%packager') {
        my ($login, $gecos) = (getpwuid($<))[0,6];
        $packager = $ENV{EMAIL} ?
            "$login <$ENV{EMAIL}>" :
            "$login <$login\@mandriva.com>";
    }
    return $packager;
}


sub _find_source_package {
    my ($self, $dir, $name) = @_;

    my $file;
    opendir(my $DIR, $dir) or croak "Unable to open $dir: $!";
    while (my $entry = readdir($DIR)) {
        if ($entry =~ /^\Q$name\E-[^-]+-[^-]+\.src.rpm$/) {
            $file = "$dir/$entry";
            last;
        }
    }
    closedir($DIR);
    return $file;
}

__END__

=head1 AUTHORS

Julien Danjou <danjou@mandriva.com>

Michael Scherer <misc@mandriva.org>

Guillaume Rousse <guillomovitch@mandriva.org>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2003-2007 Mandriva.

Permission to use, copy, modify, and distribute this software and its
documentation under the terms of the GNU General Public License is hereby 
granted. No representations are made about the suitability of this software 
for any purpose. It is provided "as is" without express or implied warranty.
See the GNU General Public License for more details.
