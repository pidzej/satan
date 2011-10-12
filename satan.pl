#!/usr/bin/perl

## Satan 
# Shell account service manager
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
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

use IO::Socket;
use DBI;
use Data::Dumper;
use feature 'switch';
use warnings;
use strict;
use utf8;

use Satan::FTP;
use Satan::Backup;
use Satan::Account;
use Satan::VPN;

$|++;
$SIG{CHLD} = 'IGNORE'; # don't wait for retarded kids

unless (@ARGV) {
	open STDOUT,">>","/adm/satan/access.log";
	open STDERR,">>","/adm/satan/error.log";
	chmod 0600,"/adm/satan/access.log";
	chmod 0600,"/adm/satan/error.log";
}
my $sockfile = '/adm/satan/satan.sock';
`rm -f -- /adm/satan/lock/*`;
unlink $sockfile;

my $socket = new IO::Socket::UNIX (
        Local => $sockfile,
        Type => SOCK_STREAM,
        Listen => 10,
        Reuse => 1,
);
die "Could not create UNIX socket: $!\n" unless $socket;
chmod 0666, $sockfile;
binmode( $socket, ':utf8' );

## dbi 
my $dbh_system = DBI->connect("dbi:mysql:rootnode;mysql_read_default_file=/root/.my.system.cnf",undef,undef,{ RaiseError => 0, AutoCommit => 1 });

$dbh_system->{mysql_auto_reconnect} = 1;
$dbh_system->{mysql_enable_utf8} = 1;

## main 
while(my $client = $socket->accept()) {
        binmode( $client, ':utf8' );
        setsockopt $client, SOL_SOCKET, SO_PASSCRED, 1;
        my($pid,$uid,$gid) = unpack "iii", $client->sockopt(SO_PEERCRED);
	my $now = localtime(time);
        if(not defined $uid) {
                print "[$now] WARNING: UID not defined!\n";
                close($client);
                next;
        }
	if($uid < 2000 or $uid >= 65000) {
		print "[$now] WARNING: UID $uid is not allowed to use Satan!\n";
		close($client);
		next;
	}
        if(fork() == 0) {
                if(-f "/adm/satan/lock/$uid" and $uid) {
			print "[$now] Connection refused: too many sessions for user $uid.\n";
                        print $client "Only one session is allowed. Dying.\n";
                        close($client);
                        exit 0;
                } else {
                        open LOCK,">","/adm/satan/lock/$uid";
                        close LOCK;
                }
                $client->autoflush(1);
                my $login = getpwuid($uid);
                if(not defined $login) {
			print "[$now] ERROR: No login name for user $uid!\n";
                        print $client "Where is your login name?\n";
                        close($client);
                        next;
                }

                while(<$client>) {
                        chomp;
                        my @args = split(/\s/,$_);
			my $pwd    = shift @args;
			my $daemon = shift @args || 'help';
			my @params = ($uid,$login,$client,@args);
			my $now = localtime(time);
                        print "[$now] Connection: $login ($uid), Request: $daemon(".join(' ',@args).")\n";
			my $return;
			given($daemon) {
				## Satan::FTP
				when ("ftp") { 
					my $ftp = Satan::FTP->new(
						login      => $login,
						uid        => $uid,
						client     => $client,
						dbh_system => $dbh_system
					);
					
					## commands
					my $command = shift @args || 'list';
					   $command = 'help' if grep(/^(help|\?)$/,@args);

					given($command) {
						when ('add')               { $return = $ftp->add(@args)    }
						when ('del')               { $return = $ftp->del(@args)    }
						when ('list')              { $return = $ftp->list(@args)   }
						when (/^(change|modify)$/) { $return = $ftp->modify(@args) }
						when ('help')              { $return = $ftp->help(@args)   }
						default {
							print $client "Command '$command' is not available. Available commands are: add, del, change, list.\n";
							print $client "See 'satan ftp help' or http://rootnode.net/satan/ftp for details.\n";
						}
					}				
				}
			
				## Satan::Account
				when ('account') {
					my $account = Satan::Account->new(
						login      => $login,
						uid        => $uid,
						client     => $client,
						dbh_system => $dbh_system,
					);

					## commands
					my $command = shift @args || 'show';
					   $command = 'help' if grep(/^(help|\?)$/,@args);
			
					given($command) {
						when('show') { $return = $account->show(@args) }
						when('edit') { $return = $account->edit(@args) }
						when('pay')  { $return = $account->pay(@args)  }
						when('help') { $return = $account->help(@args) }
						default {
							print $client "Command '$command' is not available. Available commands are: show, edit, pay.\n";
							print $client "See 'satan account help' or http://rootnode.net/satan/account for details.\n";
						}
					}
				}
			
				## Satan::Backup
				when ('backup') {
					my $backup = Satan::Backup->new(
						login      => $login,
						uid        => $uid,
						pwd        => $pwd,
						dbh_system => $dbh_system
					);
			
					## commands
					my $command = shift @args || 'list';
					   $command = 'help' if grep(/^(help|\?)$/,@args);

					given($command) {
						when ('add')                 { $return = $backup->add(@args)        }
						when ('del')                 { $return = $backup->del(@args)        }
						when (/^(include|exclude)$/) { $return = $backup->include($1,@args) }
						when ('list')                { $return = $backup->list(@args)       }
						when ('help')                { $return = $backup->help(@args)       }
						default {
							print $client "Command '$command' is not available. Available commands are: add, del, include, exclude, list.\n";
							print $client "See 'satan backup help' or http://rootnode.net/satan/backup for details.\n";
						}
					}
			
				}				
				
				## Satan::VPN
				when ('vpn') {
					my $vpn = Satan::VPN->new(
						login      => $login,
						uid        => $uid,
						client     => $client,
						dbh_system => $dbh_system
					);

					## commands
					my $command = shift @args || 'list';
					   $command = 'help' if grep(/^(help|\?)$/,@args);

					given($command) {
						when('add')    { $return = $vpn->add(@args) }
						when('del')    { $return = $vpn->del(@args) }
						when('list')   { $return = $vpn->list(@args) }
						when('config') { $return = $vpn->config(@args) }
						when('help')   { $return = $vpn->help(@args) } 
						default {
							print $client "Command '$command' is not available. Available command are: add, del, list, config.\n";
							print $client "See 'satan vpn help' or http://rootnode.net/satan/vpn for details.\n";
						}
					}
				}

				## Help
				when ("help") {
					my $usage  = "\033[1mSatan, the most hellish service manager\033[0m\n"
					           . "Usage: satan [SERVICE] [TASK] [ARGS]\n\n"
                                                   . "Available services: \033[1;32mmysql pgsql ftp domain vhost dns mail backup account vpn\033[0m\n"
					           . "Type help at the end of each command to see detailed description, e.g.:\n"
					           . "\033[1;34m\$ satan mysql help\033[0m\n\n"
					           . "For additional information, see http://rootnode.net\n"
					           . "Bug reporting on mailing list.\n\n";
					          #. "Bash completion is supported. Press TAB twice.\n";
					print $client $usage;
				}
				default {
					print $client "Available satan serices: ftp backup\n";
				}
			}
			print $client $return."\n" if $return;
			last;
                }
                close($client);
                unlink "/adm/satan/lock/$uid";
		exit;
        }
}
close($socket);
close STDOUT;
close STDERR;
