#!/usr/bin/perl

## Satan client
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

use strict;
use IO::Socket;
use Encode;
use FindBin qw($Bin);
use utf8;
$|++;

$SIG{INT} = 'IGNORE';
my $sock = new IO::Socket::UNIX (
				Peer => "$Bin/satan.sock",
                                Type => SOCK_STREAM,
				Timeout => 10, 
                                );
die "Could not connect to Satan: $!\n" unless $sock;
binmode(STDOUT,':utf8');
binmode(STDIN,':utf8');
binmode($sock, ':utf8');

my $args = join(' ',$ENV{PWD},@ARGV);
print $sock $args."\n";
#my $interactive;
while(<$sock>) {
	chomp;
	my $response = $_;
	if($response =~ /^\((INT|PASS)\)\s(.*)$/) {
		print $2;
		my $input;
		if($1 eq 'PASS') {
			system 'stty -echo';
			$input = <STDIN>;
			system 'stty echo';
			print "\n";
		} else {
			$input = <STDIN>;
		}
		print $sock $input;
	} else {
		print $response."\n";
	}
}	

close($sock);
