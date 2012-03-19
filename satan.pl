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
$SIG{CHLD} = 'IGNORE'; # braaaaains!!

my $json       = JSON::XS->new->utf8;
my $agent_conf = YAML::LoadFile('config/agent.yaml');
my $exec_conf  = YAML::LoadFile('config/exec.yaml');

my $satan_services = join(q[ ], sort keys %$agent_conf);
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
$db->{get_credentials} = $dbh->prepare("SELECT user_name   FROM auth   WHERE uid=? AND auth_key=PASSWORD(?) LIMIT 1");
$db->{get_server_name} = $dbh->prepare("SELECT server_name FROM server WHERE ip_address=?");  

while(my $s_client = $s_server->accept()) {
	$s_client->autoflush(1);
        if(fork() == 0) {
		my ($client, $agent, $exec, @request, $response);
		my ($status, $message) = (0, 'OK');

		# client ip
		$client->{ipaddr} = $s_client->peerhost;

		# server name
		$db->{get_server_name}->execute($client->{ipaddr});
		$client->{server_name} = $db->{get_server_name}->fetchrow_array;

		CLIENT:
                while(<$s_client>) {
			# skip empty lines
			chomp; /^$/ and next CLIENT;
			
			if(/^\[.*\]$/) { 
				# json input
				eval { 	
					$client->{request} = $json->decode($_);
				} or do {
					$response = { status => 400, message => 'Bad request. Cannot parse JSON' };
					last CLIENT;
				}
			} 
			else { 
				# plain text input
				$client->{request} = [ split(/\s/) ];
			}
			
			# store request as array
			@request = @{$client->{request}};
			
			# client authentication
			if(! $client->{is_auth}) {
				# get uid and key from request
				($client->{uid}, $client->{key}) = @request;

				# check credentials against db
				$db->{get_credentials}->execute($client->{uid}, $client->{key});
				if($db->{get_credentials}->rows) {
					# user is authenticated
					$client->{is_auth} = 1;
					delete $client->{key};
			
					# get user name
					$client->{user_name} = $db->{get_credentials}->fetchrow_array;
				} 
				else {
					$response = { status => 401, message => 'Unauthorized' };
					last CLIENT;
				}
				$response = { status => 0, message => 'OK' };
				print $s_client $json->encode($response);
				next CLIENT;
			}
			
			# get service name
			my $service_name = shift @request || 'help';
	
			# get command name
			my $command_name = $request[0] || '';

			# push client info to request
			unshift @request, $client;
			
			# display usage
			if($service_name eq 'help') {
				$response = { status => 404, message => $USAGE };
				last CLIENT;
			}
		
			# get agent configuration
			$agent = $agent_conf->{$service_name};

			# throw error if agent does not exist
			if (!$agent) {
				$response = { status => 405, message => "Service \033[1m$service_name\033[0m NOT found. Available services are: \033[1;32m$satan_services\033[0m" };
				last CLIENT;
			}
			
			# connect to agent
			eval {
				$agent->{sock} = worker_connect (
					port => $agent->{port}
				);
			} 
			or do {
				$response = { status => 502, message => "Cannot connect to agent \033[1m$service_name\033[0m. System error." };
				last CLIENT;
				# XXX send info to admin
			};
	
			# send data to agent
			eval {
				$agent->{response} = worker_send (
					sock    => $agent->{sock}, 
					request => \@request
				);
			}
			or do {
				$response = { status => 503, message => "Service \033[1m$service_name\033[0m unavailable. System error." };
				last CLIENT;
			};

			
			# agent reports user error
			if ($agent->{response}->{status}) {
				print $s_client $json->encode($agent->{response});
				next CLIENT;
			} else {
				$response = $agent->{response};
			}
			
			# connect to exec
			if (defined $exec_conf->{$service_name}->{$command_name}) {
				my $container = $client->{uid};
				eval {
					$exec->{sock} = worker_connect (
						port => $client->{uid}				
					);
				};

				# send data to executor	
				eval {
					$exec->{response} = worker_send (
						sock    => $exec->{sock},
						request => $client->{request}
					);
				}
				or do {
					$response->{status}  = 502;
					$response->{message} = "Could not connect to container \033[1m" . $container . "\033[0m.\n\033[1;31mSome operations performed partially!\033[0m";
				};
			}

			# send response
			print $s_client $json->encode($response);

		} # while $s_client
		
		# send status
		print $s_client $json->encode($response);
		close($s_client);
		exit;
	}
}

close($s_server);
close STDOUT;
close STDERR;

sub worker_connect {
	my ($worker) = { @_ };
	$worker->{host} = $worker->{host} || '127.0.0.1';

	# connect to worker
	my $s_worker = new IO::Socket::INET (
		PeerAddr  => $worker->{host},
		PeerPort  => $worker->{port},
		Proto     => 'tcp',
		Timeout   => 1,
		ReuseAddr => 0,
	) or die;

	return $s_worker;
}

sub worker_send {
	my ($worker) = { @_ };
	my ($status, $message);
	my $s_worker = $worker->{sock};

	# send request to worker
	print $s_worker $json->encode($worker->{request});
	
	WORKER:
	while(<$s_worker>) {
		chomp;
		$worker->{is_connected} = 1;		
		$worker->{response} = $_;
		last WORKER;
	}
	close($s_worker);

	# worker is not responding 
	die if !$worker->{is_connected};

	return $json->decode($worker->{response});
}

=schema
DROP TABLE IF EXISTS auth;
CREATE TABLE auth (
	uid SMALLINT UNSIGNED NOT NULL,
	user_name VARCHAR(32) NOT NULL,
	auth_key CHAR(41) NOT NULL,
	PRIMARY KEY(uid)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE server (
	id TINYINT UNSIGNED NOT NULL, 
	server_name VARCHAR(16) NOT NULL,
	ip_address CHAR(15) NOT NULL,
	PRIMARY KEY(id),
	KEY(ip_address)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

