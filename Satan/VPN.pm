#!/usr/bin/perl

## Satan::VPN
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

package Satan::VPN;

use Satan::Tools qw(caps);
use IO::Socket;
use DBI;
use Data::Dumper;
use Crypt::GeneratePassword qw(chars);
use Data::Password qw(:all);
use feature 'switch';
use utf8;
use warnings;
use strict;
$|++;

$SIG{CHLD} = 'IGNORE';

# vpn status
# -1  - to be added
# -2  - to be revoked
#  1  - added
#  2  - revoked

my $ca = do { local( @ARGV, $/ ) = '/adm/satan/ca.crt'; <> };

sub new {
	my $class = shift;
	my $self = { @_	};
	my $dbh_system = $self->{dbh_system};
	
	$self->{vpn_add}   = $dbh_system->prepare(qq{INSERT INTO vpn(uid,name,added_at,expires_at,status) VALUES(?,?,NOW(),DATE_ADD(NOW(), INTERVAL ? DAY),-1)});
	$self->{vpn_del}   = $dbh_system->prepare(qq{UPDATE vpn SET status=-2 WHERE uid=? AND name=?});
	$self->{vpn_list}  = $dbh_system->prepare(qq{
		SELECT 
			name,
			added_at,
			CONCAT(DATEDIFF(expires_at,added_at), ' days') as expires_in,
			CASE status
				WHEN -1 THEN 'to be added'
				WHEN -2 THEN 'to be revoked'
				WHEN  1 THEN 'added'
				WHEN  2 THEN 'revoked'
			END as status,
			crt_file,
			key_file 
		FROM vpn 
		WHERE uid=?
	}); 
	$self->{vpn_last}  = $dbh_system->prepare(qq{SELECT name FROM vpn WHERE uid=? ORDER BY added_at DESC LIMIT 1});
	$self->{vpn_get}   = $dbh_system->prepare(qq{SELECT name,crt_file,key_file FROM vpn WHERE uid=? AND name=?});     
	$self->{vpn_limit} = $dbh_system->prepare(qq{SELECT vpn FROM limits WHERE uid=?});
	
	$self->{event_add} = $dbh_system->prepare(qq{INSERT INTO events(uid,date,daemon,event) VALUES(?,NOW(),'vpn',?)});

	bless $self, $class;
	return $self;
}

sub add {
	my($self,@args) = @_;
	my $uid       = $self->{uid};
	my $login     = $self->{login};
	my $client    = $self->{client};

	my $vpn_add   = $self->{vpn_add};
	my $vpn_get   = $self->{vpn_get};        
	my $vpn_limit = $self->{vpn_limit}; 
	my $vpn_list  = $self->{vpn_list};
	my $event_add = $self->{event_add};

	my $name =  shift @args                or return "Insufficient arguments: VPN name not specified. Rot in hell!";
	   $name =  lc $name;
           $name =~ /^[a-z]{1}[a-z0-9]{1,15}$/ or return "VPN name '$name' is incorrect. Only alphanumeric and must start with a letter.";
	
	my $expire = shift @args || 3650;
	   $expire =~ s/d//i; # remove letter 'd'
	   $expire =  int($expire);
	   $expire >= 1                        or return "Minimum expire value is 1 day. Please try again!";
	   $expire <= 3650                     or return "Maximum expire value is 3650 days (10 years). Please try again!";

	$vpn_get->execute($uid,$name);	
	$vpn_get->rows                         and return "VPN '$name' already exists. Burn!";

        ## check limit
        my $limit = 3;
        $vpn_limit->execute($uid);
        while(my($vpnlimit) = $vpn_limit->fetchrow_array) {
                $limit = $vpnlimit;
                last;
        }
       
	$vpn_list->execute($uid);
        my $rows = $vpn_list->rows;
        $rows >= $limit and return "You have reached the limit of $limit VPN tunnels. Delete some or ask for more.";

        $vpn_add->execute($uid,$name,$expire) or do {
                return "Cannot add tunnel '$name' to database, already exists. Report a bug to admins.";
                my $now = localtime(time);
                print "[$now] BUG! Cannot add tunnel '$name' to database, already exists.\n";
        };
        $event_add->execute($uid,"Added $name");
	return;
}

sub del {
	my($self,@args) = @_;
        my $uid     = $self->{uid};
        my $login   = $self->{login};
        my $client  = $self->{client};
	
	my $vpn_del   = $self->{vpn_del};
	my $vpn_get   = $self->{vpn_get};
	my $event_add = $self->{event_add};

	my $name =  shift @args                or return "Insufficient arguments: VPN name not specified. Rot in hell!";
	   $name =  lc $name;
           $name =~ /^[a-z]{1}[a-z0-9]{1,15}$/ or return "Username is incorrect. Only alphanumeric and must start with a letter.";
	
	$vpn_get->execute($uid,$name);	
	$vpn_get->rows                         or return "VPN '$name' does NOT exist. Try again weirdo!";

        $vpn_del->execute($uid,$name) or do {
                my $now = localtime(time);
                print "[$now] BUG! Cannot del user '$name': database problem.\n";
                return "Cannot del user '$name': database problem. Report a bug to admins.";
        };
        $event_add->execute($uid,"Deleted $name");
	return;
}

sub config {
	my($self,@args) = @_;
        my $uid     = $self->{uid};
        my $login   = $self->{login};
        my $client  = $self->{client};
	
	my $vpn_get   = $self->{vpn_get};

	my $name =  shift @args                  or return "Insufficient arguments: VPN name not specified. Rot in hell!";
	   $name =  lc $name;
           $name =~ /^[a-z]{1}[a-z0-9]{1,15}$/   or return "Username is incorrect. Only alphanumeric and must start with a letter.";
	
	$vpn_get->execute($uid,$name);	
	$vpn_get->rows                           or return "VPN '$name' does NOT exist. Try again weirdo!";
	
	my $country = shift @args                or return "Incorrect VPN country. Try: fr1, pl1, uk1, nl1, us1.";
	   $country = lc $country;
	   $country =~ /^(fr1|pl1|uk1|nl1|us1)$/ or return "Incorrect VPN country. Try: fr1, pl1, uk1, nl1, us1.";

	my $config  = <<EOF;
remote $country.vpnizer.com 443
redirect-gateway def1
resolv-retry infinite
proto tcp-client
cert $name.crt
key $name.key
persist-key
persist-tun
tls-client
ca ca.crt
comp-lzo
dev tun
nobind
pull
EOF
	chomp $config;
	return $config;
}

sub list {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
        
	my $vpn_list = $self->{vpn_list};
	my $vpn_get  = $self->{vpn_get}; 
	
	my $name =  shift @args;
	my $listing;
	if(defined $name) {
        	$name = lc $name;
		$name =~ /^[a-z]{1}[a-z0-9]{1,15}$/ or return "Username is incorrect. Only alphanumeric and must start with a letter.";
		$vpn_get->execute($uid,$name);	
		$vpn_get->rows                      or return "VPN '$name' does NOT exist. Try again weirdo!";
		
		my $type   = shift @args            or return "Incorrect type. Possible types are: key, crt, ca.";
		@args                              and return "Too many arguments.";
		my $vpnget = $vpn_get->fetchall_hashref('name');
		given($type) {
			when('key')     { $listing = $vpnget->{$name}->{key_file} }
			when(/^ce?rt$/) { $listing = $vpnget->{$name}->{crt_file} }
			when('ca')      { $listing = $ca } 
			default {
				return "Incorrect type. Possible types are: key, crt, ca.";
			}
		}
		chomp $listing;
	} else {
		# vpn list
		$vpn_list->execute($uid);
 		$listing = Satan::Tools->listing(
			db      => $vpn_list,
			title   => "VPN tunnels",
			header  => ['Name','Added at','Expires in','Status'],
			columns => [ qw(name added_at expires_in status) ],
		) || "No VPN tunnels available. Try 'satan vpn add' first.";
	}
	return $listing;
}

sub help {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};

	my $vpn_last = $self->{vpn_last};
	$vpn_last->execute($uid);
	my $vpn_name = 'client';
	if($vpn_last->rows) {
		$vpn_name = $vpn_last->fetchall_arrayref->[0][0];
	} 
	
        my $usage  = "\033[1mSatan :: VPN\033[0m\n\n"
                   . "\033[1;32mSYNTAX\033[0m\n"
                   . "  vpn add <vpn name> [ <expire> ]              add new account\n"
                   . "  vpn del <vpn name>                           remove account\n"
                   . "  vpn list                                     show listing    (default)\n"
                   . "  vpn list   <vpn name> key|crt|ca             show certs and keys\n"
                   . "  vpn config <vpn name> fr1|pl1|uk1|nl1|us1    show openvpn config file\n\n"
                   . "Where:\n"
                   . "  <vpn name> must start with a letter and must have only alphanumeric characters.\n"
                   . "  <expire> is a number of days after VPN key will expire. Maximum value is 3650 days (set by default).\n\n"
                   . "\033[1mSaving certificates (copy & paste)\033[0m\n"
                   . "  export VPN_NAME='$vpn_name'\n"
                   . "  export VPN_COUNTRY='nl1'    # REMEMBER TO SET THIS CORRECTLY\n"
                   . "  mkdir \$VPN_NAME.openvpn\n"
                   . "  satan vpn list \$VPN_NAME key > \$VPN_NAME.openvpn/\$VPN_NAME.key\n"
                   . "  satan vpn list \$VPN_NAME crt > \$VPN_NAME.openvpn/\$VPN_NAME.crt\n"
                   . "  satan vpn list \$VPN_NAME ca  > \$VPN_NAME.openvpn/ca.crt\n"
                   . "  satan vpn config \$VPN_NAME \${VPN_COUNTRY:-nl1} > \$VPN_NAME.openvpn/config.ovpn\n"
                   . "  tar -zcf \$VPN_NAME.openvpn.tar.gz \$VPN_NAME.openvpn\n\n"
                   . "All certificates will be stored to ~/$vpn_name.openvpn.tar.gz archive.\n\n"
                   . "\033[1mAvalable VPN locations\033[0m\n"
                   . "  France       fr1.vpnizer.com 443  |  Netherlands  nl1.vpnizer.com 443\n"
                   . "  Poland       pl1.vpnizer.com 443  |  USA          us1.vpnizer.com 443\n"
                   . "  UK           uk1.vpnizer.com 443  |\n\n"
                   . "Every key works with every server.\n\n"
                   . "\033[1;32mEXAMPLE\033[0m\n"
                   . "  satan vpn add client\n"
                   . "  satan vpn del client\n"
                   . "  satan vpn add client 10d\n"
                   . "  satan vpn list\n"
                   . "  satan vpn list client key\n"
                   . "  satan vpn config\n\n"
                   . "After connecting to VPN visit \033[1;34mhttp://vpnizer.com\033[0m in order to check\n"
                   . "if everything is fine and to see information about your connection.\n";
	return $usage;
}

1;
