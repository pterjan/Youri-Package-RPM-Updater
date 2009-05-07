# $Id$

package Youri::Package::RPM::Updater;

=head1 NAME

Youri::Package::RPM::Updater - Update RPM packages

=head1 SYNOPSIS

    my $updater = Youri::Package::RPM::Updater->new();
    $updater->update_from_source('foo-1.0-1.src.rpm', '2.0');
    $updater->update_from_spec('foo.spec', '2.0');
    $updater->update_from_repository('foo', '2.0');

=head1 DESCRIPTION

This module updates rpm packages. When given an explicit new version, it
updates the spec file, and downloads new sources automatically. When not given
a new version, it just updates the spec file.

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
use SVN::Client;
use RPM4;
use Readonly;
use version; our $VERSION = qv('0.4.3');

# default values
Readonly::Scalar my $default_url_rewrite_rules => [
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
];

=head1 CLASS METHODS

=head2 new(%options)

Creates and returns a new MDV::RPM::Updater object.

Available options:

=over

=item verbose $level

verbosity level (default: 0).

=item topdir $topdir

rpm top-level directory (default: rpm %_topdir macro).

=item sourcedir $sourcedir

rpm source directory (default: rpm %_sourcedir macro).

=item release_suffix $suffix

suffix appended to numerical value in release tag. (default: none).

=item srpm_dirs $dirs

list of directories containing source packages (default: empty).

=item timeout $timeout

timeout for file downloads (default: 10)

=item agent $agent

user agent for file downloads (default: youri-package-updater/$VERSION)

=item alternate_extensions $extensions

alternate extensions to try when downloading source fails (default: tar.gz,
tgz, zip)

=item sourceforge_mirrors $mirrors

mirrors to try when downloading files hosted on sourceforge (default: ovh,
mesh, switch)

=item url_rewrite_rules $rules

list of rewrite rules to apply on source tag value for computing source URL
when this last one doesn't have any, as hasrefs of two regexeps

=item new_version_message

changelog message for new version (default: New version %%VERSION)

=item new_release_message

changelog message for new release (default: Rebuild)

=back

=cut

sub new {
    my ($class, %options) = @_;

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
        _topdir             => $topdir,
        _sourcedir          => $sourcedir,
        _verbose            => defined $options{verbose}                ? 
            $options{verbose}              : 0,
        _release_suffix     => defined $options{release_suffix}         ?
            $options{release_suffix}       : undef,
        _timeout            => defined $options{timeout}                ?
            $options{timeout}              : 10,
        _agent              => defined $options{agent}                  ?
            $options{agent}                : "youri-package-updater/$VERSION",
        _srpm_dirs          => defined $options{srpm_dirs}              ?
            $options{srpm_dirs}            : undef,
        _alternate_extensions => defined $options{alternate_extensions} ?
            $options{alternate_extensions} : [ qw/tar.gz tgz zip/ ],
        _sourceforge_mirrors => defined $options{sourceforge_mirrors}   ?
            $options{sourceforge_mirrors}  : [ qw/ovh mesh switch/ ],
        _new_version_message  => defined $options{new_version_message}  ?
            $options{new_version_message}  : 'New version %%VERSION',
        _new_release_message  => defined $options{new_release_message}  ?
            $options{new_release_message}  : 'Rebuild',
        _url_rewrite_rules    => defined $options{url_rewrite_rules}    ?
            $options{url_rewrite_rules}    : $default_url_rewrite_rules,
    }, $class;

    return $self;
}

=head1 INSTANCE METHODS

=head2 update_from_repository($name, $version, %options)

Update package with name $name to version $version.

Available options:

=over

=item release => $release

Force package release, instead of computing it.

=item download true/false

download new sources (default: true).

=item update_revision true/false

update spec file revision (release/history) (default: true).

=item update_changelog true/false

update spec file changelog (default: true).

=item spec_line_callback $callback

callback to execute as filter for each spec file line (default: none).

=item spec_line_expression $expression

perl expression (or list of expressions) to evaluate for each spec file line
(default: none). Takes precedence over previous option.

=item changelog_entries $entries

list of changelog entries (default: empty).

=back

=cut

sub update_from_repository {
    my ($self, $name, $new_version, %options) = @_;
    croak "Not a class method" unless ref $self;
    my $src_file;

    if ($self->{_srpm_dirs}) {
        foreach my $srpm_dir (@{$self->{_srpm_dirs}}) {
            $src_file = $self->_find_source_package($srpm_dir, $name);
            last if $src_file;
        }   
    }

    croak "No source available for package $name, aborting" unless $src_file;

    $self->update_from_source($src_file, $new_version, %options);
}

=head2 update_from_source($source, $version, %options)

Update package with source file $source to version $version.

See update_from_repository() for available options.

=cut

sub update_from_source {
    my ($self, $src_file, $new_version, %options) = @_;
    croak "Not a class method" unless ref $self;

    RPM4::setverbosity(0);
    my ($spec_file) = RPM4::installsrpm($src_file);

    croak "Unable to install source package $src_file, aborting"
        unless $spec_file;

    $self->update_from_spec($spec_file, $new_version, %options);
}

=head2 update_from_spec($spec, $version, %options)

Update package with spec file $spec to version $version.

See update_from_repository() for available options.

=cut

sub update_from_spec {
    my ($self, $spec_file, $new_version, %options) = @_;
    croak "Not a class method" unless ref $self;

    $options{download}         = 1 unless defined $options{download};
    $options{update_revision}  = 1 unless defined $options{update_revision};
    $options{update_changelog} = 1 unless defined $options{update_changelog};

    my $spec = RPM4::Spec->new($spec_file, force => 1)
        or croak "Unable to parse spec $spec_file\n"; 

    $self->_update_spec($spec_file, $spec, $new_version, %options) if
        $options{update_revision}      ||
        $options{update_changelog}     ||
        $options{spec_line_callback}   ||
        $options{spec_line_expression};

    $spec = RPM4::Spec->new($spec_file, force => 1)
        or croak "Unable to parse updated spec file $spec_file\n"; 

    $self->_download_sources($spec, $new_version, %options) if
        $new_version       &&
        $options{download};
}

sub _update_spec {
    my ($self, $spec_file, $spec, $new_version, %options) = @_;

    my $header = $spec->srcheader();

    # return if old version >= new version
    my $old_version = $header->tag('version');
    return if $new_version && RPM4::rpmvercmp($old_version, $new_version) >= 0;

    my $new_release = $options{release};
    my $epoch       = $header->tag('epoch');

    if ($options{spec_line_expression}) {
        $options{spec_line_callback} =
            _get_callback($options{spec_line_expression});
    }

    open(my $in, '<', $spec_file)
        or croak "Unable to open file $spec_file: $!";

    my $content;
    my ($version_updated, $release_updated, $changelog_updated);
    while (my $line = <$in>) {
        if ($options{update_revision} && # update required
            $new_version              && # version change needed
            !$version_updated            # not already done
        ) {
            my ($directive, $value) = _get_new_version($line, $new_version);
            if ($directive && $value) {
                $line = $directive . $value . "\n";
                $new_version = $value;
                $version_updated = 1;
            }
        }

        if ($options{update_revision} && # update required
            !$release_updated            # not already done
        ) {
            my ($directive, $value) = _get_new_release($line, $new_version, $new_release, $self->{_release_suffix});
            if ($directive && $value) {
                $line = $directive . $value . "\n";
                $new_release = $value;
                $release_updated = 1;
            }
        }

        # apply global and local callbacks if any
        $line = $options{spec_line_callback}->($line)
            if $options{spec_line_callback};

        $content .= $line;

        if ($options{update_changelog} &&
            !$changelog_updated        && # not already done
            $line =~ /^\%changelog/
        ) {
            # skip until first changelog entry, as requested for bug #21389
            while ($line = <$in>) {
                last if $line =~ /^\*/;
                $content .= $line;
            }

            my @entries =
                $options{changelog_entries} ? @{$options{changelog_entries}} :
                $new_version                ? $self->{_new_version_message}  :
                                              $self->{_new_release_message}  ;
            foreach my $entry (@entries) {
                $entry =~ s/\%\%VERSION/$new_version/g;
            }

            my $title = RPM4::expand(
                DateTime->now()->strftime('%a %b %d %Y') .
                ' ' .
                $self->_get_packager() .
                ' ' .
                ($epoch ? $epoch . ':' : '') .
                ($new_version ? $new_version : $old_version) .
                '-' .
                $new_release
            );

            $content .= "* $title\n";
            foreach my $entry (@entries) {
                $content .= "- $entry\n";
            }
            $content .= "\n";

            # don't forget kept line
            $content .= $line;

            # just to skip test for next lines
            $changelog_updated = 1;
        }
    }
    close($in);

    open(my $out, '>', $spec_file)
        or croak "Unable to open file $spec_file: $!";
    print $out $content;
    close($out);
}

sub _download_sources {
    my ($self, $spec, $new_version, %options) = @_;

    foreach my $new_source ($self->_get_sources($spec)) {

        # work on a copy, so as to not mess with original list
        my $source = $new_source;
        my ($found, $need_bzme);

        # Sourceforge: attempt different mirrors
        if ($source =~ m!http://prdownloads.sourceforge.net!) {
            foreach my $mirror (@{$self->{_sourceforge_mirrors}}) {
                my $sf_source = $source;
                $sf_source =~ s!prdownloads.sourceforge.net!$mirror.dl.sourceforge.net/sourceforge!;
                $found = $self->_fetch_tarball($sf_source);
                last if $found;
            }
        } else {
            if ($source =~ m!ftp.gnome.org/pub/GNOME/sources/!) {
                # GNOME: add the major version to the URL automatically
                # ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/ORbit2-2.10.0.tar.bz2
                # is rewritten in
                # ftp://ftp.gnome.org/pub/GNOME/sources/ORbit2/2.10/ORbit2-2.10.0.tar.bz2
                (my $major = $new_version) =~ s/([^.]+\.[^.]+).*/$1/;
                $source =~ s!(.*/)(.*)!$1$major/$2!;
            } elsif ($source =~ m!\w+\.(perl|cpan)\.org/!) {
                # CPAN: force http and tar.gz
                $need_bzme = $source =~ s!\.tar\.bz2$!.tar.gz!;
                $source =~ s!ftp://ftp\.(perl|cpan)\.org/pub/CPAN!http://www.cpan.org!;
            }

            # single attempt
            $found = $self->_fetch($source);
        }

        croak "Unable to download source: $source" unless $found;

        # recompress if needed
        $found = _bzme($found) if $need_bzme;
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

    my $agent = LWP::UserAgent->new();
    $agent->env_proxy();
    $agent->timeout($self->{_timeout});
    $agent->agent($self->{_agent});

    my $file = $self->_fetch_potential_tarball($agent, $url);

    # Mandriva policy implies to recompress sources, so if the one that was
    # just looked for was missing, check with other formats
    if (!$file and $url =~ /\.tar\.bz2$/) {
        foreach my $extension (@{$self->{_alternate_extensions}}) {
            my $alternate_url = $url;
            $alternate_url =~ s/\.tar\.bz2$/.$extension/;
            $file = $self->_fetch_potential_tarball($agent, $alternate_url);
            if ($file) {
                $file = _bzme($file);
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

    print "attempting to download $url\n" if $self->{_verbose};
    my $response = $agent->mirror($url, $dest);
    if ($response->is_success) {
        print "response: OK\n" if $self->{_verbose} > 1;
        # check content type for archives
        if ($filename =~ /\.(?:tar|gz|gzip|bz2|bzip2|lzma)$/) {
            my $type = $response->header('Content-Type');
            print "content-type: $type\n" if $self->{_verbose} > 1;
            if ($type !~ m!^application/(?:x-(?:tar|gz|gzip|bz2|bzip2|lzma|download)|octet-stream)$!) {
                # wrong type
                unlink $dest;
                return;
            }
        }
        return $dest;
    }
}


sub _get_packager {
    my ($self) = @_;
    my $packager = RPM4::expand('%packager');
    if ($packager eq '%packager') {
        my $login = (getpwuid($<))[0];
        $packager = $ENV{EMAIL} ? "$login <$ENV{EMAIL}>" : $login;
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
    my ($self, $spec) = @_;

    my @sources =
        grep { /(?:ftp|svns?|https?):\/\/\S+/ }
        $spec->sources_url();

    if (! @sources) {
        print "No remote sources were found, fall back on URL tag ...\n"
            if $self->{_verbose};

        my $url = $spec->srcheader()->tag('url');

        foreach my $rule (@{$self->{_url_rewrite_rules}}) {
            # curiously, we need two level of quoting-evaluation here :(
            if ($url =~ s!$rule->{from}!qq(qq($rule->{to}))!ee) {
                last;
            }    
        }

        @sources = ( $url . '/' . ($spec->sources_url())[0] );
    }

    return @sources;
}

sub _get_callback {
    my ($expressions) = @_;

    my ($code, $sub);;
    $code .= '$sub = sub {';
    $code .= '$_ = $_[0];';
    foreach my $expression (
        ref $expressions eq 'ARRAY' ?
            @{$expressions} : $expressions
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

    return $sub;
}

sub _bzme {
    my ($file) = @_;

    system("bzme -f -F $file >/dev/null 2>&1");
    $file =~ s/\.(?:tar\.gz|tgz|zip)$/.tar.bz2/;

    return $file;
}

sub _get_new_version {
    my ($line, $new_version) = @_;

    return unless $line =~ /^
        (
            \%define\s+version\s+ # defined as macro
        |
            (?i)Version:\s+       # defined as tag
        )
        (\S+(?:\s+\S+)*)          # definition
        \s*                       # trailing spaces
    $/ox;

    my ($directive, $value) = ($1, $2);

    if ($new_version) {
        $value = $new_version;
    }

    return ($directive, $value);
}
sub _get_new_release {
    my ($line, $new_version, $new_release, $release_suffix) = @_;

    return unless $line =~ /^
    (
        \%define\s+rel(?:ease)?\s+ # defined as macro
    |
        (?i)Release:\s+            # defined as tag
    )
    (\S+(?:\s+\S+)*)               # definition
    \s*                            # trailing spaces
    $/ox;

    my ($directive, $value) = ($1, $2);

    if ($new_release) {
        $value = $new_release;
    } else {
        # if not explicit release given, try to compute it
        my ($macro_name, $macro_value) = $value =~ /^(%\w+\s+)?(.*)$/;

        croak "Unable to extract release value from value '$value'"
            unless $macro_value;

        my ($prefix, $number, $suffix); 
        if ($new_version) {
            $number = 1;
        } else {
            # optional suffix from configuration
            $release_suffix = $release_suffix ?
                quotemeta($release_suffix) : '';
            ($prefix, $number, $suffix) =
                $macro_value =~ /^(.*?)(\d+)($release_suffix)?$/;

            croak "Unable to extract release number from value '$macro_value'"
                unless $number;

            $number++;
        }

        $value = 
            ($macro_name ? $macro_name : "") .
            ($prefix ? $prefix : "") .
            $number .
            ($suffix ? $suffix : "");

    }

    return ($directive, $value);
}

1;
