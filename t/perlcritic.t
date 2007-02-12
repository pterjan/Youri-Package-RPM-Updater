#!/usr/bin/perl
# $Id: /mirror/youri/soft/check/trunk/t/perlcritic.t 1412 2006-12-12T21:29:04.312821Z nanardon  $

use Test::More;

BEGIN {
    eval {
        use Test::Perl::Critic;
    };
    if($@) {
        plan skip_all => "Test::Perl::Critic not availlable";
    } else {
        all_critic_ok();
    }
}

