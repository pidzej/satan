#!/usr/bin/perl
#
# Rootnode::Password
# Rootnode http://rootnode.net
# 
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#

package Rootnode::Password;

use warnings;
use strict;
use Exporter;
use Readonly;

our @ISA = qw(Exporter);
our @EXPORT = qw(apg);

Readonly my $MINLEN => 8;
Readonly my $MAXLEN => 20;

sub apg {
	my $minlen = shift || $MINLEN;
	my $maxlen = shift || $MAXLEN;
	
	# generate pronunciation if third argument present
	my $with_p = shift;
	my $opts = defined $with_p ? '-t' : '';

	# generate password
	my $password_string = `apg -a 0 -n 1 -m $minlen -x $maxlen -M NCL $opts` or die 'Cannot run apg';
	my ($password, $pronunciation) = split /\s/, $password_string;
	
	return ( $password, $pronunciation ) if $with_p;
	return $password;
}

1;
