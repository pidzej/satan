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
use Smart::Comments;
use Data::Dumper;

#use Satan::Admin;
#use Satan::Dns;
#use Satan::Mysql;
#use Satan::Vhost;
use Satan::Admin;
use Satan::Tools;

$|++;
$SIG{CHLD} = 'IGNORE'; # braaaaains!!!
my $json  = JSON::XS->new->utf8;
my $agent = YAML::LoadFile("$Bin/../config/agent.yaml");

my $sub   = shift or die "Subsystem not specified!\n";
my @names = Satan::Tools->sub_names(ucfirst($sub));

#my $mod = 'Satan::'.ucfirst($sub);
#eval 'use $mod';

#unless (@ARGV) {
#        open STDOUT,">>","$Bin/../logs/access.log";
#        open STDERR,">>","$Bin/../logs/error.log";
#        chmod 0600,"$Bin/../logs/access.log";
#        chmod 0600,"$Bin/../logs/error.log";
#}

my $a = $agent->{$sub};
my $s_agent = new IO::Socket::INET (
        LocalAddr => '0.0.0.0',
        LocalPort => $a->{port},
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
) or die "Cannot create socket! $!\n";

while(my $s_server = $s_agent->accept()) {
        while(<$s_server>) {
                chomp;
                my($c, @in); # client info and input args
                my($err,$msg,$data) = (0, q[OK], undef);
                eval { ($c, @in) = @{$json->decode($_)} } or do {
                        ($err,$msg) = (666, 'Cannot parse JSON');
                        last;
                };
                my $cmd = shift @in || 'list';
                if(grep /^\Q$cmd\E$/, @names) {
                        my $mod = 'Satan::'.ucfirst($sub);

			### Client data
			### $c

                        my $obj = $mod->new($c);
                        $msg  = $obj->$cmd(@in) and $err = 1;
                        $msg  = $msg || 'OK';
                        $data = $obj->_get_data;
                } else {
                        $msg = "Command \033[1m$cmd\033[0m is NOT available. Available commands are: \033[1;32m".join(' ', sort @names)."\033[0m.\n"
                             . "Run \033[1;34msatan $sub help\033[0m for help or visit http://rootnode.net/satan/$sub for details.";
                        $err = 1;
                }
                my $response = { status => $err, message => $msg };
                $response->{data} = $data if $data;
                print $s_server $json->encode($response);
        }
}
