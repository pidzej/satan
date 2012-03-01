#!/usr/bin/perl -l
#
# Satan (client)
# Shell account service manager
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
use strict;
use warnings;
use JSON::XS;
use IO::Socket;
use Data::Dumper;

my $json = JSON::XS->new->utf8;
my $s_client = new IO::Socket::INET ( 
	PeerAddr => '127.0.0.1',
	PeerPort => 1600, 
	Timeout  => 1,
) or die "Cannot connect to Satan! $!.\n";

open(my $fh,'<','/home/satan.key') or die "Cannot find user credentials";
my @cred = split(/\s/, <$fh>);

sub req {
	print $s_client $json->encode(shift);
	my $r = $json->decode(scalar <$s_client>);	
	if($r->{status} == 0) {
		# success
		print $r->{data} if $r->{data};
	} else {
		# failure
		print $r->{message};
	}
	return;
}

# authenticate
req(\@cred); 

# send request
req(\@ARGV); 
