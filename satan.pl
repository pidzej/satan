#!/usr/bin/perl -l
#
# Satan (server)
# Shell account service manager
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
# SUCH DAMAGE.
#
use IO::Socket;
use DBI;
use Data::Dumper;
use JSON::XS;
use YAML qw(LoadFile);
use FindBin qw($Bin);
use Readonly;
use lib $Bin;
use feature 'switch';
use warnings;
use strict;

$|++;
$SIG{CHLD} = 'IGNORE'; # braaaaains!!!

my $json = JSON::XS->new->utf8;
my $agent = YAML::LoadFile('config/agent.yaml');

my $satan_services = join(q[ ], sort keys %$agent);
Readonly my $USAGE => <<"END_USAGE";
\033[1mSatan - the most hellish service manager\033[0m
Usage: satan [SERVICE] [TASK] [ARGS]

Available services: \033[1;32m$satan_services\033[0m
Type help at the end of each command to see detailed description, e.g.:
\033[1;34m\$ satan dns help\033[0m

For additional information visit http://rootnode.net
Bug reporting on mailing list.
END_USAGE

unless (@ARGV) {
	open STDOUT,">>","$Bin/access.log";
	open STDERR,">>","$Bin/error.log";
	chmod 0600,"$Bin/access.log";
	chmod 0600,"$Bin/error.log";
}

my $s_server = new IO::Socket::INET (
        LocalAddr => '0.0.0.0',
        LocalPort => 1600,
        Proto     => 'tcp',
        Listen    => 100,
        ReuseAddr => 1,
) or die "Cannot create socket! $!\n";

# connect to db
my $dbh = DBI->connect("dbi:mysql:satan;mysql_read_default_file=/root/.my.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 1 });
$dbh->{mysql_auto_reconnect} = 1;
$dbh->{mysql_enable_utf8}    = 1;

# db statements
my $db;
$db->{is_auth} = $dbh->prepare("SELECT uid FROM auth WHERE uid=? AND auth_key=PASSWORD(?) LIMIT 1");

while(my $s_client = $s_server->accept()) {
	$s_client->autoflush(1);
        if(fork() == 0) {
		my($c, $a, @in);
		my($err,$msg,$data) = (0, q[OK], q[]);
                while(<$s_client>) {
			chomp; /^$/ and next;
			{{
				# data type
				if(/^\[.*\]$/) { 
					$c->{is_json}++;
					eval { @in = @{$json->decode($_)} } or do {
					       ($err, $msg) = (666, 'Cannot parse JSON');	
					};
				} else { 
					@in = split(/\s/);
				}

				# client authentication
				if(! $c->{is_auth}) {
					($c->{uid}, $c->{key}) = @in;
					my $is_auth = $db->{is_auth};
					   $is_auth->execute($c->{uid}, $c->{key});
					   $is_auth = $is_auth->rows;
					if($is_auth) {
						$c->{is_auth}++;
					} else {
						($err,$msg) = (1, 'User not authenticated');					
					}
					last;
				}

				# get service name
				my $sub = shift @in || 'help';
				unshift @in, $c->{uid};
				
				# display usage
				if($sub eq 'help') {
					($err, $msg) = (1, $USAGE);
					last;
				}
				
				$a = $agent->{$sub};
				if(!$a) {
					($err, $msg) = (1, "Service \033[1m$sub\033[0m NOT found. Available services are: \033[1;32m".join(q[ ], sort keys %$agent)."\033[0m");
					last;
				}	
				
				# connect to agent
				my $s_agent = new IO::Socket::INET (
					PeerAddr  => '127.0.0.1',
					PeerPort  => $a->{port},
					Proto     => 'tcp',
					Timeout   => 1,
					ReuseAddr => 0
				);

				# send data to agent
				print $s_agent $json->encode(\@in);
				while(<$s_agent>) {
					chomp;
					$a->{is_connected}++;
					$a->{response} = $_;
					last;
				}
				close($s_agent);

				# agent not responding
				if(! $a->{is_connected}) {
					($err,$msg) = (666, "Service \033[1m$sub\033[0m is currently NOT available. Sorry about that.\nPlease try again later.");					
					last;
				}
						
			}}
			my $response = $a->{response} ? $a->{response} : $json->encode({ status => $err, message => $msg, data => $data });
			print $s_client $response;
			last if $err;
		} # while $s_client
		close($s_client);
		exit;
	}
}

close($s_server);
close STDOUT;
close STDERR;

=schema
DROP TABLE IF EXISTS auth;
CREATE TABLE auth (
	uid SMALLINT UNSIGNED NOT NULL,
	auth_key CHAR(41) NOT NULL,
	PRIMARY KEY(uid)
) ENGINE=InnoDB, CHARACTER SET=UTF8;
