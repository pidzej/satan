#!/usr/bin/perl
#
# Satan::Vhost
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#

package Satan::Vhost;

use Satan::Tools;
use IO::Socket;
use DBI;
use Data::Dumper;
use Tie::File;
use FindBin qw($Bin);
use feature 'switch';
use utf8;
use warnings;
use strict;
use Data::Validate::Domain qw(is_domain is_hostname);
use Data::Validate::IP qw(is_ipv4 is_ipv6);
use Readonly;

$|++;
$SIG{CHLD} = 'IGNORE';

Readonly my $NGINX_MAP_FILE    => '/etc/nginx/conf.d/map.conf';
Readonly my %EXPORT_OK => (
        user  => [ qw( add del list help ) ],
        admin => [ qw( deluser ) ]
);

sub get_data {
        my $self = shift;
        return $self->{data};
}

sub get_export {
        my ($self, $user_type) = @_;
        my @export_ok = @{ $EXPORT_OK{$user_type} };
        my %export_ok = map { $_ => 1 } @export_ok;
        return %export_ok;
}

sub new {
	my $class = shift;
	my ($self) = @_;
	my $dbh = DBI->connect("dbi:mysql:nginx;mysql_read_default_file=$Bin/../config/my.cnf",undef,undef,{ RaiseError => 0, AutoCommit => 1 });
	$dbh->{mysql_auto_reconnect} = 1;
	$dbh->{mysql_enable_utf8} = 1;

	my $db;
	$db->{check_domain}    = $dbh->prepare("SELECT uid FROM domains WHERE domain_name=?");
	$db->{add_domain}      = $dbh->prepare("INSERT INTO domains(uid, domain_name, server_name) VALUES(?,?,?)");
	$db->{del_domain}      = $dbh->prepare("DELETE FROM domains WHERE uid=? AND domain_name=?");   
	$db->{get_domain_list} = $dbh->prepare("SELECT uid, domain_name FROM domains");	
	$db->{get_domains}     = $dbh->prepare("SELECT domain_name, server_name FROM domains WHERE uid=?");

	$db->{deluser_domains} = $dbh->prepare("DELETE FROM domains WHERE uid=?";
 
	$self->{db} = $db;
	bless $self, $class;
	return $self;
}
	
sub reload_nginx {
	my $self = shift;
	my $db        = $self->{db};
	my $server_id = $self->{server_id};

	# Container network based on server ID
	my $container_network = '10.' . $server_id . '.0.0';
	
	# Get domain list
	$db->{get_domain_list}->execute or die "Cannot get domain list from database.";
	
	# Prepare nginx map
	my @nginx_map;
	push @nginx_map, join("\n\t", 'map $http_host $ipaddr {', 'hostnames;', "default\t127.0.0.1;\n");
	while(my ($uid, $domain_name) = $db->{get_domain_list}->fetchrow_array) {
		my $ipaddr = Satan::Tools->get_container_ip( $uid, $container_network );
		push @nginx_map, "\t".join("\t", ".$domain_name", $ipaddr).";\n";
	}
	push @nginx_map, "}\n";

	# Save nginx map to file
	open MAP, '>', $NGINX_MAP_FILE or die "Cannot open file $NGINX_MAP_FILE";
	print MAP @nginx_map;
	close MAP;

	# Reload nginx server
	system("sudo svc -h /etc/service/nginx");
	return 1;
}

sub deluser {
	my ($self, @args) = @_;
	my $uid = $self->{uid};
	my $db  = $self->{db};
        my $user_name   = $self->{user_name};
        my $user_type   = $self->{type};
        my $server_name = $self->{server_name};

        # Get uid to delete
        my $delete_uid = shift @args or return "Not enough arguments! \033[1mUid\033[0m NOT specified.";

        # Check uid
        isdigit($delete_uid)   or return "Uid must be a number!";
        $delete_uid < $MIN_UID and return "Uid too low. (< $MIN_UID)";
        $delete_uid > $MAX_UID and return "Uid too high. (> $MAX_UID)";

        # Check user type
        $user_type eq 'admin' or return "Access denied!";

	# Delete domains
	$db->{deluser_domains}->execute($delete_uid) or return "Cannot remove vhosts for uid $delete_uid. Database error.";
	
	# reload nginx configuration
	eval { 
		$self->reload_nginx;
	} 
	or do {
		print "Cannot reload nginx. $@";
		return "Cannot reload nginx configuration. System error.";
	};

	return;
}

sub add {
	my ($self,@args) = @_;
	my $db          = $self->{db};
	my $uid         = $self->{uid};
	my $user_name   = $self->{user_name};
	my $server_name = $self->{server_name}; 

	# satan vhost add <domain> <type>
	my $domain_name = shift @args or return "Not enough arguments! \033[1mDomain name\033[0m NOT specified. Please die or read help.";
	   $domain_name = lc $domain_name;
	is_domain($domain_name)       or return "Not good! \033[1m$domain_name\033[0m is NOT a proper domain name.";
		
	# check if not official rootnode domain
	if ($domain_name =~ /\.rootnode(?:status)?\.(?:net|pl)$/ and $domain_name !~ /(^|\.)\Q$user_name\E\.rootnode(?:status)?\.(?:net|pl)$/) {
		return "You cannot use rootnode domains. Only \033[1m*.$user_name.rootnode.net\033[0m is allowed.";
	}

	$db->{check_domain}->execute($domain_name);
	if($db->{check_domain}->rows) {
		my ($domain_uid) = $db->{check_domain}->fetchrow_array;
		if ($domain_uid == $uid) {
			return "Domain \033[1m$domain_name\033[0m already added. Nothing to do.";
		} else {
			return "Cannot add vhost! Vhost \033[1m$domain_name\033[0m is owned by another user.";
		}	
	} else {
		$db->{add_domain}->execute($uid, $domain_name, $server_name) or return "Cannot add domain \033[1m$domain_name\033[0m. System error.";
	}
	
	eval { 
		$self->reload_nginx();
	} 
	or do {
		print "Cannot reload nginx. $@";
		return "Cannot reload configuration. System error.";
	};

	return;
}

sub del {
	my ($self, @args) = @_;
	my $uid = $self->{uid};
	my $db  = $self->{db};

	# satan vhost del <domain> [purge]
	my $domain_name = shift @args or return "Not enough arguments! \033[1mDomain name\033[0m NOT specified. Please die or read help.";
	   $domain_name = lc $domain_name;
	is_domain($domain_name)       or return "Not good! \033[1m$domain_name\033[0m is NOT a proper domain name.";
	
	$db->{check_domain}->execute($domain_name);
	if ($db->{check_domain}->rows) {
		my ($domain_uid) = $db->{check_domain}->fetchrow_array;
		if ($domain_uid == $uid) {
			$db->{del_domain}->execute($uid, $domain_name) or return "Cannot delete vhost \033[1m$domain_name\033[0m. System error.";
		} else {
			return "Cannot delete vhost! Vhost \033[1m$domain_name\033[0m is owned by another user.";
		}	
	} else {
		return "Vhost \033[1m$domain_name\033[0m does NOT exist.";
	}

	# reload nginx configuration
	eval { 
		$self->reload_nginx;
	} 
	or do {
		print "Cannot reload nginx. $@";
		return "Cannot reload nginx configuration. System error.";
	};

	return;
}

sub list {
	my ($self, @args) = @_;
	my $uid = $self->{uid};
	my $db  = $self->{db};

	my $listing;
	$db->{get_domains}->execute($uid);
	my $number_of_rows = $db->{get_domains}->rows;
	if ($number_of_rows) {
		$listing  = "\033[1;32mVirtual hosts\033[0m (".$number_of_rows." in total)\n\n";
		$listing .= "\033[1mDomain name\tServer name\tStatus\033[0m\n";
		while (my ($domain_name, $server_name) = $db->{get_domains}->fetchrow_array) {
			$listing .= join("\t", $domain_name, $server_name) . "\n";
		}
	} 
	else {
		$listing = "No virtual hosts.";
	}

	# statusy dopisac
	# 1. sprawdz dns
	# 2. sprawdz www

	$self->{data} = $listing;
	return;
}

sub help {
        my $self = shift;
        my $uid = $self->{uid};
	my $USAGE = <<"END_OF_USAGE";
\033[1mSatan :: Vhost\033[0m

\033[1;32mSYNTAX\033[0m
  vhost add <domain>                            
  vhost del <domain>
  vhost list 
  vhost help                       show help

  \033[1mWhere:\033[0m
    <domain> must be a canonical domain name

\033[1;32mEXAMPLES\033[0m
  satan vhost add domain.com
  satan vhost list
  satan vhost del domain.com
END_OF_USAGE

	$self->{data} = $USAGE;
	return;
}

=mysql nginx 

CREATE DATABASE nginx;
USE nginx;

CREATE TABLE domains (
	uid SMALLINT UNSIGNED NOT NULL,
	domain_name VARCHAR(128) NOT NULL,
	server_name CHAR(16) NOT NULL,
	PRIMARY KEY(uid, domain_name)
) ENGINE=InnoDB, CHARACTER SET=UTF8;
=cut

1;
