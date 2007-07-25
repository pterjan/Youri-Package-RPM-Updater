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
use File::Temp qw/tempdir/;
use LWP::UserAgent;
use String::ShellQuote;
use SVN::Client;
use File::Temp qw/tempdir/;
use File::Temp qw/tempdir/;
use RPM4;
use version; our $VERSION = qv('0.3.0');

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
/;

my @EXTENSIONS = qw/
    .tar.gz
    .tgz
    .zip
/;

=head1 CLASS METHODS

=head2 new(%options)

Creates and returns a new MDV::RPM::Updater object.

Avaiable options:

=over

=item verbose $level

verbosity level (default: 0).

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

callback to execute before build, with build dependencies as argument (default:
none).

=item build_requires_command $command

external command (or list of commands) to execute before build, with build
dependencies as argument (default: none). Takes precedence over previous option.

=item build_results_callback $callback

callback to execute after build, with build packages as argument (default:
none).

=item build_results_command $command

external command (or list of commands) to execute after build, with build packages as argument (default: none). Takes precedence over previous option.

=item spec_line_callback $callback

callback to execute as filter for each spec file line (default: none).

=item spec_line_expression $expression

perl expression (or list of expressions) to evaluate for each spec file line
(default: none). Takes precedence over previous option.

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

    if ($options{build_requires_command}) {
        $options{build_requires_callback} = sub {
            foreach my $command (
                ref $options{build_requires_command} eq 'ARRAY' ?
                    @{$options{build_requires_command}} :
                    $options{build_requires_command}
            ) {
                # we can't use multiple args version of system here, as we
                # can't assume given command is just a program name,
                # as in 'sudo rurpmi' case
                system($command . ' ' . shell_quote(@_));
            }
        }
    }

    if ($options{build_results_command}) {
        $options{build_results_callback} = sub {
            foreach my $command (
                ref $options{build_results_command} eq 'ARRAY' ?
                    @{$options{build_results_command}} :
                    $options{build_results_command}
            ) {
                # same issue here
                system($command . ' ' . shell_quote(@_));
            }
        }
    }

     if ($options{spec_line_expression}) {
        my $code;
        $code .= '$options{spec_line_callback} = sub {';
        $code .= '$_ = $_[0];';
        foreach my $expression (
            ref $options{spec_line_expression} eq 'ARRAY' ?
                @{$options{spec_line_expression}} :
                $options{spec_line_expression}
        ) {
            $code .= $expression;
            $code .= ";\n" unless $expression =~ /;$/;
        }
        $code .= 'return $_;';
        $code .= '}';
        ## no critic ProhibitStringyEva
        eval $code;
        ## use critic
        warn "unable to compile given expression into code $code, skipping"
            if $@;
    }

    # force internal rpmlib configuration
    my ($topdir, $sourcedir);
    if ($options{topdir}) {
        $topdir = File::Spec->rel2abs($options{topdir});
        RPM4::add_macro("_topdir $topdir");
    } else {
        $topdir = RPM4::expand('%_topdir');
    }
    if ($options{sourcedir}) {
        $sourcedir = File::Spec->rel2abs($options{sourcedir});
        RPM4::add_macro("_sourcedir $sourcedir");
    } else {
        $sourcedir = RPM4::expand('%_sourcedir');
    }

    my $self = bless {
        _verbose           =>
            $options{verbose}           || 0,
        _topdir            => $topdir,
        _sourcedir         => $sourcedir,
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

=head2 build_from_repository($name, $version, %options)

Update package with name $name to version $version.

=cut

sub build_from_repository {
    my ($self, $name, $new_version, %options) = @_;
    croak "Not a class method" unless ref $self;
    my $src_file;

    foreach my $srpm_dir (@{$self->{_srpm_dirs}}) {
        $src_file = $self->_find_source_package($srpm_dir, $name);
        last if $src_file;
    }   

    croak "No source available for package $name, aborting" unless $src_file;

    $self->build_from_source($src_file, $new_version, %options);
}

=head2 build_from_source($source, $version, %options)

Update package with source file $source to version $version.

Available options:

=over

=item release => $release

Force package release, instead of computing it.

=back

=cut

sub build_from_source {
    my ($self, $src_file, $new_version, %options) = @_;
    croak "Not a class method" unless ref $self;

    my ($spec_file) = RPM4::installsrpm($src_file);

    croak "Unable to install source package $src_file, aborting"
        unless $spec_file;

    $self->build_from_spec($spec_file, $new_version, %options);
}

=head2 build_from_spec($spec, $version, %options)

Update package with spec file $spec to version $version.

=cut

sub build_from_spec {
    my ($self, $spec_file, $new_version, %options) = @_;
    croak "Not a class method" unless ref $self;

    my $spec = RPM4::Spec->new($spec_file, force => 1)
        or croak "Unable to parse spec $spec_file\n"; 
    my $header = $spec->srcheader();

    my $name        = $header->tag('name');
    my $old_version = $header->tag('version');
    my $old_release = $header->tag('release');
    my $new_release = $options{release};
    
    # keep track of initial sources if needed for comparaison
    my (@sources_before, @sources_after);
    if (
        $new_version     && # new version
        $self->{_download}
    ) {
        @sources_before = $self->_get_sources($spec, $header);
    }

    # handle everything dependant on new version/release
    if ($self->{_verbose}) {
        print $new_version ?
            "building $name $new_version\n" :
            "rebuilding $name\n";
    }

    # update spec file
    if ($self->{_update_revision}    ||
        $self->{_update_changelog}   ||
        $self->{_spec_line_callback}
    ) {
        open(my $in, '<', $spec_file)
            or croak "Unable to open file $spec_file: $!";

        my $spec;
        my ($version_updated, $release_updated, $changelog_updated);
        while (my $line = <$in>) {
            if ($self->{_update_revision} &&
                $new_version               && # version change needed
                !$version_updated          && # not already done
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
                $line = $directive . $new_version . "\n";

                # just to skip test for next lines
                $version_updated = 1;
            }

            if ($self->{_update_revision} &&
                !$release_updated         && # not already done
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

                if (! $new_release) {
                    # if not explicit release given, try to compute it
                    my ($macro, $value) = $definition =~ /^(%\w+\s+)?(.*)$/;

                    croak "Unable to extract release value from definition '$definition'"
                        unless $value;

                    my ($prefix, $number, $suffix); 
                    if ($new_version) {
                        $number = 1;
                    } else {
                        # optional suffix from configuration
                        my $dist_suffix = $self->{_release_suffix};

                        ($prefix, $number, $suffix) =
                            $value =~ /^(.*?)(\d+)(\Q$dist_suffix\E)?$/;

                        croak "Unable to extract release number from value '$value'"
                            unless $number;

                        $number++;
                    }

                    $new_release = 
                        ($macro ? $macro : "") .
                        ($prefix ? $prefix : "") .
                        $number .
                        ($suffix ? $suffix : "");

                }

                $line = $directive . $new_release . "\n";

                # just to skip test for next lines
                $release_updated = 1;
            }

            $line = $self->{_spec_line_callback}->($line)
                if $self->{_spec_line_callback};
            $spec .= $line;

            if ($self->{_update_changelog} &&
                !$changelog_updated        && # not already done
                $line =~ /^\%changelog/
            ) {
                # skip until first changelog entry, as requested for bug #21389
                while ($line = <$in>) {
                    last if $line =~ /^\*/;
                    $spec .= $line;
                }

                my @entries = @{$self->{_changelog_entries}};
                if (@entries) {
                    s/\%\%VERSION/$new_version/ foreach @entries;
                } else  {
                    @entries = $new_version ?
                        "New version $new_version" :
                        'Rebuild';
                }

                my $header = RPM4::expand(
                    DateTime->now()->strftime('%a %b %d %Y') . ' ' .
                    $self->_get_packager() . ' ' .
                    (
                        $header->hastag('epoch') ?
                            $header->tag('epoch') . ':' :
                            ''
                    ) .
                    $new_version . '-' .
                    $new_release
                );

                $spec .= "* $header\n";
                foreach my $entry (@entries) {
                    $spec .= "- $entry\n";
                }
                $spec .= "\n";

                # don't forget kept line
                $spec .= $line;

                # just to skip test for next lines
                $changelog_updated = 1;
            }
        }
        close($in);

        open(my $out, '>', $spec_file)
            or croak "Unable to open file $spec_file: $!";
        print $out $spec;
        close($out);
    }

    # download sources
    if (
        $new_version     && # new version
        $self->{_download}
    ) {
        # parse updated spec file
        $spec = RPM4::Spec->new($spec_file, force => 1)
            or croak "Unable to parse updated spec file $spec_file\n"; 

        @sources_after = $self->_get_sources($spec, $header);
        my %seen_before = map { $_ => 1 } @sources_before;
        my %seen_after  = map { $_ => 1 } @sources_after;

        my @new_sources = grep { !$seen_before{$_} } @sources_after;
        my @old_sources = grep { !$seen_after{$_} }  @sources_before;

        foreach my $new_source (@new_sources) {

            my $found;

            # Sourceforge: attempt different mirrors
            if ($new_source =~ m!http://prdownloads.sourceforge.net!) {
                foreach my $sf_mirror (@SF_MIRRORS) {
                    my $sf_new_source = $new_source;
                    $sf_new_source =~ s!prdownloads.sourceforge.net!$sf_mirror.dl.sourceforge.net/sourceforge!;
                    $found = $self->_fetch_tarball($sf_new_source);
                    last if $found;
                }
            } else {
                # GNOME: add the major version to the URL automatically
                # ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/ORbit2-2.10.0.tar.bz2
                # is rewritten in
                # ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2
                if ($new_source =~ m!ftp.gnome.org/pub/GNOME/sources/!) {
                    (my $major = $new_version) =~ s/([^.]+\.[^.]+).*/$1/;
                    $new_source =~ s!(.*/)(.*)!$1$major/$2!;
                }

                # single attempt
                $found = $self->_fetch($new_source);
            }

            croak "Unable to download source: $new_source" unless $found;

        }

        if ($self->{_old_source_callback}) {
            foreach my $old_source (@old_sources) {
                $self->{_old_source_callback}->(
                    $self->{_sourcedir} . '/' . basename($old_source)
                );
            }
        }

        if ($self->{_new_source_callback}) {
            foreach my $new_source (@new_sources) {
                $self->{_new_source_callback}->(
                    $self->{_sourcedir} . '/' . basename($new_source)
                );
            }
        }

    }

    # build new package
    if ($self->{_build_source} || $self->{_build_binary}) {

        if ($self->{_build_requires_callback}) {
            my @requires = $header->tag('requires');
            if (@requires) {
                print "managing build dependencies : @requires\n"
                    if $self->{_verbose};
                $self->{_build_requires_callback}->(@requires);
            }
        }

        my $command = "rpm";
        $command .= " --define '_topdir $self->{_topdir}'";
        $command .= " --define '_sourcedir $self->{_sourcedir}'";

        my @dirs = qw/builddir/;
        if ($self->{_build_source} && $self->{_build_binaries}) {
            $command .= " -ba $self->{_options} $spec_file";
            push(@dirs, qw/rpmdir srcrpmdir/);
        } elsif ($self->{_build_binaries}) {
            $command .= " -bb $self->{_options} $spec_file";
            push(@dirs, qw/rpmdir/);
        } elsif ($self->{_build_source}) {
            $command .= " -bs $self->{_options} --nodeps $spec_file";
            push(@dirs, qw/srcrpmdir/);
        }
        $command .= " >/dev/null 2>&1" unless $self->{_verbose} > 1;

        # check needed directories exist
        foreach my $dir (map { RPM4::expand("\%_$_") } @dirs) {
            next if -d $dir;
            mkdir $dir or croak "Can't create directory $dir: $!\n";
        }

        my $result = system($command) ? 1 : 0;
        croak("Build error\n")
            unless $result == 0;

        if ($self->{_build_results_callback}) {
            my @results =
                grep { -f $_ }
                $spec->srcrpm(),
                $spec->binrpm();
            print "managing build results : @results\n"
                if $self->{_verbose};
            $self->{_build_results_callback}->(@results)
        }
    }
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

    # extract repository in a temp directory
    my $dir = tempdir(CLEANUP => 1);
    my $archive = "$name-$prefix$release";
    my $svn = SVN::Client->new();
    $svn->export($repos, "$dir/$archive", $release);

    # archive and compress result
    my $result = system("tar -cjf $archive.tar.bz2 -C $dir $archive");
    croak("Error during archive creation: $?\n")
        unless $result == 0;
}

sub _fetch_tarball {
    my ($self, $url) = @_;

    print "attempting to download $url\n" if $self->{_verbose};
    my $agent = LWP::UserAgent->new();
    $agent->env_proxy();

    my $file = $self->_fetch_potential_tarball($agent, $url);

    # Mandriva policy implies to recompress sources, so if the one that was
    # just looked for was missing, check with other formats
    if (!$file and $url =~ /\.tar\.bz2$/) {
        foreach my $extension (@EXTENSIONS) {
            my $alternate_url = $url;
            $alternate_url =~ s/\.tar\.bz2$/$extension/;
            print "attempting to download $alternate_url\n"
                if $self->{_verbose};
            $file = $self->_fetch_potential_tarball($agent, $alternate_url);
            if ($file) {
                system("bzme -f -F $file");
                $file =~ s/$extension$/\.tar\.bz2/;
                last;
            }
        }
    }

    return $file;
}

sub _fetch_potential_tarball {
    my ($self, $agent, $url) = @_;

    my $filename = basename($url);
    my $dest = "$self->{_sourcedir}/$filename";

    # don't attempt to download file if already present
    return $dest if -f $dest;

    my $response = $agent->mirror($url, $dest);
    if ($response->is_success) {
        print "response: OK\n" if $self->{_verbose} > 1;
        # check content type
        my $type = $response->header('Content-Type');
        print "content-type: $type\n" if $self->{_verbose} > 1;
        if ($type =~ m!^application/x-(tar|gz|gzip|bz2|bzip2)$!) {
            return $dest;
        } else {
            # wrong type
            unlink $dest;
            return;
        }
    }
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

sub _get_sources {
    my ($self, $spec, $header) = @_;

    my @sources =
        grep { /(?:ftp|svns?|https?):\/\/\S+/ }
        $spec->sources_url();

    if (! @sources) {
        print "No remote sources were found, fall back on URL tag ...\n"
            if $self->{_verbose};

        my $url = $header->tag('url');

        foreach my $site (@SITES) {
            # curiously, we need two level of quoting-evaluation here :(
            if ($url =~ s!$site->{from}!qq(qq($site->{to}))!ee) {
                last;
            }    
        }

        @sources = ( $url . '/' . ($spec->sources_url())[0] );
    }

    return @sources;
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
