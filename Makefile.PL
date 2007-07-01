# $Id: /mirror/youri/soft/core/trunk/Makefile.PL 1284 2006-11-06T19:46:28.041137Z guillomovitch  $
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Youri::Package::RPM::Updater',
    VERSION_FROM => 'lib/Youri/Package/RPM/Updater.pm',
    AUTHOR       => 'Youri project <youri@zarb.org>',
    PREREQ_PM    => {
        'RPM4'               => 0,
        'DateTime'           => 0,
        'File::Fetch'        => 0,
        'Test::Exception'    => 0,
        'SVN::Client'        => 0,
        'String::ShellQuote' => 0,
        'version'            => 0
    }
);

sub MY::postamble {
   return <<'EOF';
.PHONY: svntag
SVNPATH = svn+ssh://youri.zarb.org/home/projects/youri/svn/soft/Package-RPM-Updater

svntag:
	svn copy -m 'new release $(VERSION)'\
		$(SVNPATH)/trunk \
		$(SVNPATH)/tags/release-$(VERSION)

EOF
}
