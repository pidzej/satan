#!/usr/bin/perl
#
# Rootnode::Validate 
# Rootnode http://rootnode.net
# 
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#

package Rootnode::Validate;

use warnings;
use strict;
use Exporter;
use Readonly;

our @ISA = qw(Exporter);
our @EXPORT = qw(validate_uid validate_username);

Readonly my $MIN_UID => 2000;
Readonly my $MAX_UID => 6500;
Readonly my $MIN_USERNAME => 2;
Readonly my $MAX_USERNAME => 20;

sub validate_uid {
	my ($uid) = @_;
	
	$uid =~ /^[^0]\d+$/ or return "Only numbers accepted";
        $uid < $MIN_UID    and return "Too low (min $MIN_UID)";
        $uid > $MAX_UID    and return "Too high (max $MAX_UID)";

	return;
}

sub validate_username {
	my ($user_name, %opts) = @_;
	
	$user_name =~ /^[a-z0-9]+$/         or return "Only chars and digits possible";
	length($user_name) < $MIN_USERNAME and return "Too short (min $MIN_USERNAME)";
	length($user_name) > $MAX_USERNAME and return "Too long (max $MAX_USERNAME)";

	return;
}



1;
