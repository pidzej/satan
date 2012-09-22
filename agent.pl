#!/usr/bin/perl -l
#
# Satan (agent)
# Shell account service manager
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
use warnings;
use strict;
use JSON::XS;
use IO::Socket;
use YAML qw(LoadFile);
use FindBin qw($Bin);
use POSIX qw(isdigit);
use Data::Dumper;
no Smart::Comments;
use lib $Bin;

# Satan modules
use Satan::Admin;
use Satan::Dns;
use Satan::Mysql;
use Satan::Vhost;
use Satan::Ftp;
use Satan::Mail;

our $MINLEN = undef;
our $MAXLEN = undef;

# json serialization
my $json  = JSON::XS->new->utf8;

# get service name
my $service_name = shift or die "Service name not specified!\n";
my $server_name  = shift or die "Server name not specified!\n";

# load agent configuration
my $agent_conf = YAML::LoadFile("$Bin/../config/agent.yaml");
my $agent      = $agent_conf->{$service_name};

# open log files 
if (!@ARGV) {
        open STDOUT,">>","$Bin/../logs/access.log";
        open STDERR,">>","$Bin/../logs/error.log";
        chmod 0600,"$Bin/../logs/access.log";
        chmod 0600,"$Bin/../logs/error.log";
}

# get agent port
$agent->{port} = $agent->{$server_name} || $agent->{default};
isdigit($agent->{port}) or die "Agent port for server '$server_name' not found.\n";

# create socket
my $s_agent = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => $agent->{port},
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
) or die "Cannot create socket! $!\n";

# accept connections
while(my $s_server = $s_agent->accept()) {
	# buffering is lame
	$s_server->autoflush(1);

	my ($client, $response);

	SERVER:
        while(<$s_server>) {
                chomp;
		
		# get json request and split into client info and request
		eval {
			$client = $json->decode($_);
		} 
		# parse error
		or do {
			$response = { status => 503, message => 'Cannot parse JSON' };
			last SERVER;
		};

		### Client: $client

		# store request as array 
		my @request = @{ $client->{request} };
		delete $client->{request};

		# check if requested service name is the same as agent's
		my $request_service_name = shift @request;
		if ($service_name ne $request_service_name) {
			$response = { status => 503, message => "Wrong agent for service $service_name" };
			last SERVER;
		}
		
		# get command name	
		my $command_name = shift @request || 'list';
		
		# agent module name
		$agent->{module} = 'Satan::' . ucfirst $service_name;
		
		# create object	
		my $service = $agent->{module}->new($client);

		# get available command names
		my %export_ok = $service->get_export($client->{type});
		
		# send command
		if ($export_ok{$command_name}) {
			$agent->{response} = $service->$command_name(@request);
		}
		else {
			my $available_commands = join q{, }, sort keys %export_ok;
			my $help_message = "Command \033[1m$command_name\033[0m is NOT available. "
			                 . "Available commands are: \033[1;32m$available_commands\033[0m\n"
			                 . "Run \033[1;34msatan $service_name help\033[0m for help or visit "
			                 . "http://rootnode.net/satan/$service_name for details.";
			
			$response = { status => 400, message => $help_message };
			last SERVER;
		}
		
		# command finished successfully
		if(!$agent->{response}) {
			$response = { status => 0, message => 'OK' };
			
			# get data if exists
			if ($agent->{data} = $service->get_data) {
				$response->{data} = $agent->{data};
			}
		}
		# user error occured
		else {
			$response = { status => 400, message => $agent->{response} }
		}

		# send response		
		print $s_server $json->encode($response);
	}
	
	# send status
	print $s_server $json->encode($response);
	close ($s_server);
}

exit;
