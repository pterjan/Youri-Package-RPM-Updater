# $Id: /mirror/youri/soft/core/trunk/Makefile.PL 1284 2006-11-06T19:46:28.041137Z guillomovitch  $
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Youri::Package::RPM::Updater',
    VERSION_FROM => 'lib/Youri/Package/RPM/Updater.pm',
    AUTHOR       => 'Youri project <youri@zarb.org>',
    PM_FILTER    => '$(PERLRUN) -p -e "s|\@sysconfdir@|$(SYSCONFDIR)|"',
    PREREQ_PM    => {
        'RPM4'               => 0,
        'DateTime'           => 0,
        'LWP::UserAgent'     => 0,
        'Test::Exception'    => 0,
        'SVN::Client'        => 0,
        'version'            => 0
    }
);

package MY;

sub post_constants {
    my ($self) = @_;
    my $sysconfdir =
        $self->{ARGS}->{SYSCONFDIR} ||
        ($self->{ARGS}->{PREFIX} ?
            $self->{ARGS}->{PREFIX} . '/etc' :
            '/usr/local/etc');
    return <<EOF;
SYSCONFDIR = $sysconfdir
EOF
}

sub postamble {
   return <<'EOF';
.PHONY: svntag
SVNPATH = svn+ssh://youri.zarb.org/home/projects/youri/svn/soft/Package-RPM-Updater

svntag:
	svn copy -m 'new release $(VERSION)'\
		$(SVNPATH)/trunk \
		$(SVNPATH)/tags/release-$(VERSION)

EOF
}

sub install {
    my ($self) = @_;
    my $install = $self->SUPER::install(@_);
    $install =~ s/install :: all pure_install doc_install/install :: all pure_install doc_install config_install/;
    $install .= <<'EOF';
config_install :
	install -d -m 755 $(DESTDIR)$(SYSCONFDIR)/youri
	install -m 644 etc/updater.conf $(DESTDIR)$(SYSCONFDIR)/youri

EOF
    return $install;
}

