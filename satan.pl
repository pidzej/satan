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
use warnings;
use strict;
use DBI;
use JSON::XS;
use Readonly;
use YAML qw(LoadFile);
use FindBin qw($Bin); 
use IO::Socket;
use IO::Socket::Socks;
use Smart::Comments;
#use lib $Bin;

$|++; 
$SIG{CHLD} = 'IGNORE'; # braaaaains!!

# configuration
my $agent_conf = YAML::LoadFile("$Bin/../config/agent.yaml");
my $exec_conf  = YAML::LoadFile("$Bin/../config/exec.yaml");
Readonly my $SATAN_HOST => '0.0.0.0';
Readonly my $SATAN_PORT => 1600;
Readonly my $PROXY_PORT => 1605;

# json serialization
my $json = JSON::XS->new->utf8;

# usage
my $satan_services = join(q[ ], sort grep { $_ ne 'admin' } keys %$agent_conf);
Readonly my $USAGE => <<"END_USAGE";
\033[1mSatan - the most hellish service manager\033[0m
Usage: satan [SERVICE] [TASK] [ARGS]

Available services: \033[1;32m$satan_services\033[0m
Type help at the end of each command to see detailed description, e.g.:
\033[1;34m\$ satan dns help\033[0m

For additional information visit http://rootnode.net
Bug reporting on mailing list.
END_USAGE

# open logs
if (!@ARGV) {
	umask 0077;
	open STDOUT,">>","$Bin/../logs/access.log";
	open STDERR,">>","$Bin/../logs/error.log";
}

# create socket
my $s_server = IO::Socket::INET->new(
        LocalAddr => $SATAN_HOST,
        LocalPort => $SATAN_PORT,
        Proto     => 'tcp',
        Listen    => 100,
        ReuseAddr => 1,
) or die "Cannot create socket! $!\n";

# connect to db
my $dbh = DBI->connect("dbi:mysql:satan;mysql_read_default_file=$Bin/../config/my.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 1 });
$dbh->{mysql_auto_reconnect} = 1;
$dbh->{mysql_enable_utf8}    = 1;

# db statements
my $db;
$db->{get_user_credentials}  = $dbh->prepare("SELECT user_name        FROM user_auth   WHERE uid=? AND auth_key=PASSWORD(?) LIMIT 1");
$db->{get_admin_credentials} = $dbh->prepare("SELECT user_name, privs FROM admin_auth  WHERE uid=? AND auth_key=PASSWORD(?) LIMIT 1");
$db->{get_server_name}       = $dbh->prepare("SELECT id, server_name  FROM server_list WHERE id=?");  

while(my $s_client = $s_server->accept()) {
	$s_client->autoflush(1);
        if(fork() == 0) {
		my ($client, $agent, $exec, $response);

		# client ip
		$client->{ipaddr} = $s_client->peerhost;

		### client ip: $client->{ipaddr}

		# check server name
		if ($client->{ipaddr} =~ /^127\.16\.\d+\.(\d+)$/) {
			my $server_id = $1;
			$db->{get_server_name}->execute($server_id);
			( $client->{server_id}, $client->{server_name} ) = $db->{get_server_name}->fetchrow_array;
		} 
		else {
			$response = { status => 400, message => "Request came from unknown server ($client->{ipaddr})." };
			goto TERMINATE;
		}

		CLIENT:
                while(<$s_client>) {
			# skip empty lines
			chomp; /^$/ and next CLIENT;

			# check server name
			#if (!$client->{server_name}) {
			#}
	
			if(/^\[.*\]$/) { 
				# json input
				eval { 	
					$client->{request} = $json->decode($_);
				} or do {
					$response = { status => 405, message => 'Bad request. Cannot parse JSON.' };
					last CLIENT;
				}
			} 
			else { 
				# plain text input
				$client->{request} = [ split(/\s/) ];
			}

			### Client request: $client

			# client authentication
			if(! $client->{is_auth}) {
				# get uid and key from request
				($client->{uid}, $client->{key}) = @{ $client->{request} };

				# special privileges for uids < 1000
				$client->{type} = $client->{uid} < 1000 ? 'admin' : 'user';
	
				# get_user_credentials or get_admin_credentials
				my $cred_query = join('_', 'get', $client->{type}, 'credentials'); 
				
				# check user credentials against db
				$db->{$cred_query}->execute($client->{uid}, $client->{key});
				if($db->{$cred_query}->rows) {
					# user is authenticated
					$client->{is_auth} = 1;

					# drop client key
					delete $client->{key};
			
					# get user name and privs 
					( $client->{user_name}, $client->{privs} )  = $db->{$cred_query}->fetchrow_array;
				} 
				else {
					$response = { status => 401, message => 'Unauthorized.' };
					last CLIENT;
				}
				$response = { status => 0, message => 'OK' };
				print $s_client $json->encode($response);
				next CLIENT;
			}
			
			# get service name
			my $service_name = $client->{request}->[0] || 'help';

			# get command name
			my $command_name = $client->{request}->[1] || '';
			
 			# display usage
			if ($service_name eq 'help' or $service_name eq '?') {
				$response = { status => 0, message => 'OK', data => $USAGE };
				last CLIENT;
			}
			
			# admin user privilege
			if ($client->{type} eq 'admin') {
				$client->{privs} =~ s/\s+//g;             # trim whitespaces
				my @privs = split /,/, $client->{privs};  # store as array
				my %privs = map { $_ => 1 } @privs;       # store as hash

				# check if privileged
				if (not defined $privs{$command_name} or $service_name ne 'admin') { 
					$response = { status => 401, message => 'Unauthorized.' };
					last CLIENT;
				}				
			} else {
				# delete admin agent from list
				delete $agent_conf->{admin};
			}		
			
			# get agent configuration
			if ($agent = $agent_conf->{$service_name}) {
				$agent->{request} = $client;
			} 
			# throw error if agent does not exist
			else {
				$response = { status => 405, message => "Service \033[1m$service_name\033[0m NOT found. Available services are: \033[1;32m$satan_services\033[0m" };
				last CLIENT;
			}

			### Agent: $agent			
			
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
					request => $agent->{request}
				);
			}
			or do {
				$response = { status => 503, message => "Service \033[1m$service_name\033[0m unavailable. System error." };
				last CLIENT;
			};
			
			### Agent response: $agent->{response}
			
			# agent reports user error
			if ($agent->{response}->{status}) {
				print $s_client $json->encode($agent->{response});
				next CLIENT;
			} else {
				$response = $agent->{response};
			}
			
			# connect to exec
			if (defined $exec_conf->{$service_name}->{$command_name}) {

				# client uid is container id
				my $container_id = $client->{uid};

				# connect to executor (via socks proxy)
				eval {
					$exec->{sock} = worker_connect(
						type => 'socks',
						port => $container_id
					);
				} or do {
					print "Cannot connect to proxy";
					print $@;
					$response->{status}  = 502;
					$response->{message} = "Could not connect to container \033[1m" . $container_id . "\033[0m.\n\033[1;31mSome operations performed partially!\033[0m";
				};

				# prepare request for executor	
				$exec->{request} = $client->{request};
					
				# add exec key and client uid to exec request
				unshift @{ $exec->{request} }, $exec_conf->{key}, $client->{uid};

				# send data to executor	
				eval {
					$exec->{response} = worker_send(
						sock    => $exec->{sock},
						request => $exec->{request}
					);
				}
				or do {
					print "Cannot send";
					print $@;
					$response->{status}  = 503;
					$response->{message} = "Could not send data to container \033[1m" . $container_id . "\033[0m.\n\033[1;31mSome operations performed partially!\033[0m";
				};
				
				# exec reports error
				if ($exec->{response}->{status}) {
					$response = $exec->{response};
				}
			}
				
			# send response
			print $s_client $json->encode($response);

		} # while $s_client
		
		TERMINATE:
		print $s_client $json->encode($response);
		close($s_client);
		exit;
	} # fork end
}

close($s_server);
close STDOUT;
close STDERR;
exit;

sub worker_connect {
	my $worker = { @_ };
	$worker->{type}      = $worker->{type}      || 'inet';
	$worker->{host}      = $worker->{host}      || '127.0.0.1';
	$worker->{proxyhost} = $worker->{proxyhost} || '127.0.0.1';
	$worker->{proxyport} = $worker->{proxyport} || $PROXY_PORT;

	# connect to worker
	my $s_worker;
	
	# socks connection
	if ($worker->{type} eq 'socks') {
		$s_worker = IO::Socket::Socks->new(
			ProxyAddr   => $worker->{proxyhost},
			ProxyPort   => $worker->{proxyport},
			ConnectAddr => $worker->{host},
			ConnectPort => $worker->{port}
		) or die;
	} 
	# inet socket
	else {
		$s_worker = IO::Socket::INET->new(
			PeerAddr  => $worker->{host},
			PeerPort  => $worker->{port},
			Proto     => 'tcp',
			Timeout   => 1,
			ReuseAddr => 0,
		) or die;
	}

	return $s_worker;
}

sub worker_send {
	my $worker = { @_ };
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

	# return decoded data
	return $json->decode($worker->{response});
}

=schema
CREATE TABLE user_auth (
	uid SMALLINT UNSIGNED NOT NULL,
	user_name VARCHAR(32) NOT NULL,
	auth_key CHAR(41) NOT NULL,
	PRIMARY KEY(uid)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE admin_auth (
	uid SMALLINT UNSIGNED NOT NULL,
	user_name VARCHAR(32) NOT NULL,
	auth_key CHAR(41) NOT NULL,
	privs VARCHAR(255) DEFAULT '',
	PRIMARY KEY(uid)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE server_list (
	id TINYINT UNSIGNED NOT NULL, 
	server_name VARCHAR(16) NOT NULL,
	ip_address CHAR(15) NOT NULL,
	PRIMARY KEY(id),
	KEY(ip_address)
) ENGINE=InnoDB, CHARACTER SET=UTF8;
