#!/usr/bin/perl
#
# Satan::DNS
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
package Satan::Dns;

use warnings;
use strict;
use Satan::Tools qw(caps);
use IO::Socket;
use DBI;
use Crypt::GeneratePassword qw(chars);
use Data::Password qw(:all);
use FindBin qw($Bin);
use Data::Validate::Domain qw(is_domain is_hostname);
use Data::Validate::IP qw(is_ipv4 is_ipv6);
use POSIX qw(isdigit);
no Smart::Comments;
use Readonly;
use feature 'switch';
use utf8;

# configuration
Readonly my $DEFAULT_PRIO   => 10;
Readonly my $DEFAULT_TTL    => 300;
Readonly my $DEFAULT_SOA    => 'ns1.rootnode.net hostmaster.rootnode.net';
Readonly my $DEFAULT_NS1    => 'ns1.rootnode.net';
Readonly my $DEFAULT_NS2    => 'ns2.rootnode.net';
Readonly my $DEFAULT_MX1    => 'mail1.rootnode.net';
Readonly my $DEFAULT_MX2    => 'mail2.rootnode.net';
Readonly my $SOA_SERIAL     => 666;
Readonly my $SOA_REFRESH    => 10800; 
Readonly my $SOA_RETRY      => 3600;  
Readonly my $SOA_EXPIRE     => 604800;
Readonly my $SOA_MIN_TTL    => 300;
Readonly my $GMAIL_MX1      => 'ASPMX.L.GOOGLE.COM';
Readonly my $GMAIL_MX2      => 'ALT1.ASPMX.L.GOOGLE.COM';
Readonly my $GMAIL_MX3      => 'ALT2.ASPMX.L.GOOGLE.COM';
Readonly my $GMAIL_MX4      => 'ASPMX2.GOOGLEMAIL.COM';
Readonly my $GMAIL_MX5      => 'ASPMX3.GOOGLEMAIL.COM';
Readonly my $GMAIL_MX1_PRIO => 1;
Readonly my $GMAIL_MX2_PRIO => 5;
Readonly my $GMAIL_MX3_PRIO => 5;
Readonly my $GMAIL_MX4_PRIO => 10;
Readonly my $GMAIL_MX5_PRIO => 10;
Readonly my $MIN_UID        => 2000;
Readonly my $MAX_UID        => 6000;

Readonly my %EXPORT_OK => (
        user  => [ qw( add del list help ) ],
        admin => [ qw( deluser ) ]
);

Readonly my @FORBIDDEN_DOMAINS => qw{ 
	rootnodestatus\.(?:com|net|org|pl) rootnode\.pl 
	vpnizer\.(?:com|net|org)
};

# default ip address for container
Readonly my %ipaddr_of => {
	web1 => '94.23.145.245',
	web2 => '94.23.146.10',
	web3 => '94.23.149.68',
};

$|++;
$SIG{CHLD} = 'IGNORE';
our $MINLEN = undef;
our $MAXLEN = undef;

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
	my ($self) =  @_;
	my $dbh = DBI->connect("dbi:mysql:pdns;mysql_read_default_file=$Bin/../config/my.cnf",undef,undef,{ RaiseError => 0, AutoCommit => 1 });

	### $self

	$self->{dns_add_domain}      = $dbh->prepare("INSERT INTO domains(uid,name,type) VALUES(?,?,?)");
	$self->{dns_add_record}      = $dbh->prepare("INSERT INTO records(domain_id,name,type,content,ttl,prio,change_date) VALUES (?,?,?,?,?,?,UNIX_TIMESTAMP(NOW()))");
	$self->{dns_check_domain}    = $dbh->prepare("SELECT id,uid FROM domains WHERE name=?");
	$self->{dns_check_record}    = $dbh->prepare("SELECT id FROM records WHERE domain_id=? AND name=? AND type=? AND content=?");
	$self->{dns_check_record_id} = $dbh->prepare("SELECT r.id FROM records r INNER JOIN domains d ON r.domain_id = d.id WHERE r.id=? AND d.uid=?");   
	$self->{dns_del_domain}      = $dbh->prepare("DELETE FROM domains WHERE id=? AND uid=?");
	$self->{dns_del_record}      = $dbh->prepare("DELETE FROM records WHERE id=?");
	$self->{dns_list_domains}    = $dbh->prepare("
		SELECT 
			name,
			SUM(CASE WHEN type = 'SOA'   THEN count ELSE NULL END) AS SOA,
			SUM(CASE WHEN type = 'NS'    THEN count ELSE NULL END) AS NS,
			SUM(CASE WHEN type = 'A'     THEN count ELSE NULL END) AS A, 
			SUM(CASE WHEN type = 'AAAA'  THEN count ELSE NULL END) AS AAAA, 
			SUM(CASE WHEN type = 'CNAME' THEN count ELSE NULL END) AS CNAME,
			SUM(CASE WHEN type = 'MX'    THEN count ELSE NULL END) AS MX,
			SUM(CASE WHEN type = 'TXT'   THEN count ELSE NULL END) AS TXT,
			SUM(CASE WHEN type = 'SRV'   THEN count ELSE NULL END) AS SRV,
			SUM(CASE WHEN type = 'PTR'   THEN count ELSE NULL END) AS PTR
		FROM (
			SELECT d.name AS name,r.type AS type,count(r.type) AS count 
			FROM domains d LEFT JOIN records r ON d.id=r.domain_id 
			WHERE uid=?
			GROUP BY d.id,r.type
		) AS stats GROUP by name;
	");
	$self->{dns_list_records}    = $dbh->prepare("SELECT id, name, type, content, ttl, prio FROM records WHERE domain_id=?");

	$self->{dns_del_obsolete_records} = $dbh->prepare("DELETE FROM records WHERE domain_id=676 AND name LIKE ?"); 

	$self->{dns_deluser_domains} = $dbh->prepare("DELETE FROM domains WHERE uid=?");
	
	#$self->{dns_limit} = $dbh->prepare("SELECT dns FROM limits WHERE uid=?");
	#$self->{event_add} = $dbh->prepare("INSERT INTO events(uid,date,daemon,event) VALUES(?,NOW(),'dns',?)");
	$self->{dbh} = $dbh;

	# containers configuration
	
	bless $self, $class;
	return $self;
}

sub deluser {
	my ($self, @args) = @_;
	my $uid = $self->{uid};
	my $dbh = $self->{dbh};
	my $user_name   = $self->{user_name};
	my $user_type   = $self->{type};
	my $server_name = $self->{server_name};

	my $dns_deluser_domains = $self->{dns_deluser_domains};

	# Get uid to delete
	my $delete_uid = shift @args or return "Not enough arguments! \033[1mUid\033[0m NOT specified.";

	# Check uid
	isdigit($delete_uid)   or return "Uid must be a number!";
	$delete_uid < $MIN_UID and return "Uid too low. (< $MIN_UID)";
	$delete_uid > $MAX_UID and return "Uid too high. (> $MAX_UID)";

	# Check user type
	$user_type eq 'admin' or return "Access denied!";
	
	# Delete database records
	$dns_deluser_domains->execute($delete_uid) or return "Cannot remove DNS domains for uid $delete_uid. Database error.";

	return;
}

sub add {
	my($self,@args) = @_;
	my $uid = $self->{uid};
	my $dbh = $self->{dbh};  
	my $user_name   = $self->{user_name};
	my $server_name = $self->{server_name};

	my $dns_add_domain   = $self->{dns_add_domain};
	my $dns_add_record   = $self->{dns_add_record};
	my $dns_check_domain = $self->{dns_check_domain};
	my $dns_check_record = $self->{dns_check_record};
				
	my $dns_del_obsolete_records = $self->{dns_del_obsolete_records};

	my $domain_id;
	my $domain_name = shift @args or return "Not enough arguments! \033[1mDomain name\033[0m NOT specified. Please die or read help.";
	   $domain_name = lc $domain_name;
	is_domain($domain_name)       or return "Not good! \033[1m$domain_name\033[0m is NOT a proper domain name.";
	
	my $record_type = shift @args;
	$record_type = lc $record_type;
	
	# check if domain exists
	$dns_check_domain->execute($domain_name);
	if($dns_check_domain->rows) {
		($domain_id, my $domain_uid) = $dns_check_domain->fetchrow_array;
		if ($domain_uid != $uid) {
			if ($record_type !~ /^(a|aaaa|cname|mx|txt|srv|soa|ns|ptr)$/i) {
				return "Cannot add domain! Domain \033[1m$domain_name\033[0m is owned by another user.";
			}
			return "Cannot add record! You are not the owner of \033[1m$domain_name\033[0m domain.";
		}
		if ($record_type !~ /^(a|aaaa|cname|mx|txt|srv|soa|ns|ptr)$/i) {
			return "Domain \033[1m$domain_name\033[0m already added. Nothing to do.";
		}
	# domain doesn't exist
	} else {
		# put record type back to args
		unshift @args, $record_type;

		# forbidden domains
		foreach my $forbidden_domain (@FORBIDDEN_DOMAINS) {
			if ($domain_name =~ /$forbidden_domain$/) {
				return "You cannot use this domain. Only \033[1m$user_name.rootnode.net\033[0m is allowed.";
			}
		}

	        # rootnode domain
	        if ($domain_name =~ /\.rootnode\.net$/) {
			if ($domain_name !~ /^\Q$user_name\E\.rootnode\.net$/) {
				return "You cannot use this domain. Only \033[1m$user_name.rootnode.net\033[0m is allowed.";
			} 
			else {
				# drop deprecated dns entries
				$dns_del_obsolete_records->execute("$user_name.rootnode.net");
				$dns_del_obsolete_records->execute("%.$user_name.rootnode.net");
			}
		}

		# add domain
		$dns_add_domain->execute($uid,$domain_name,'NATIVE');
		$domain_id = $dbh->{mysql_insertid};
		
		# add basic records
		my $soa_record = join(' ', $DEFAULT_SOA, $SOA_SERIAL, $SOA_REFRESH, $SOA_RETRY, $SOA_EXPIRE, $SOA_MIN_TTL);
		$self->{dns_add_record}->execute($domain_id, $domain_name, 'SOA', $soa_record, $DEFAULT_TTL, undef);
		$self->{dns_add_record}->execute($domain_id, $domain_name, 'NS', $DEFAULT_NS1, $DEFAULT_TTL, undef);
		$self->{dns_add_record}->execute($domain_id, $domain_name, 'NS', $DEFAULT_NS2, $DEFAULT_TTL, undef);

		my $ipaddr = shift @args || $ipaddr_of{$server_name};

		# put mail options back to arguments
		if ($ipaddr eq 'nomail' or $ipaddr eq 'gmail') {
			unshift @args, $ipaddr;
			$ipaddr = $ipaddr_of{$server_name};
		}

		if (defined $ipaddr) {
			if (is_ipv4($ipaddr)) {
				$self->{dns_add_record}->execute($domain_id, $domain_name, 'A', $ipaddr, $DEFAULT_TTL, undef);
			} 
			elsif (is_ipv6($ipaddr)) {
				$self->{dns_add_record}->execute($domain_id, $domain_name, 'AAAA', $ipaddr, $DEFAULT_TTL, undef);
			} 
			elsif ($ipaddr =~ /^(a|aaaa|cname|mx|txt|srv|soa|ns|ptr)$/i) {
				# probably a typo in domain name
				return "Domain \033[1m$domain_name\033[0m does NOT exist! Please double check the name or\n"
				     . "add the domain first with \033[1;32msatan dns add domain.com\033[0m command.";
			}
			else {
				return "IP \033[1m$ipaddr\033[0m is NOT a proper IP address. Some basic records not added."; 
			}
			
			# add record to db
			$self->{dns_add_record}->execute($domain_id, "*.$domain_name", 'CNAME', $domain_name, $DEFAULT_TTL, undef);
		}

		# add mx
		my $mail = shift @args || '';
		if ($mail eq 'nomail') {
			# do nothing
		} 
		elsif ($mail eq 'gmail') {
			# gmail mx
			$self->{dns_add_record}->execute($domain_id, "mail.$domain_name", 'CNAME', 'ghs.google.com', $DEFAULT_TTL, undef);
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $GMAIL_MX1, $DEFAULT_TTL, $GMAIL_MX1_PRIO);
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $GMAIL_MX2, $DEFAULT_TTL, $GMAIL_MX2_PRIO);
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $GMAIL_MX3, $DEFAULT_TTL, $GMAIL_MX3_PRIO);
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $GMAIL_MX4, $DEFAULT_TTL, $GMAIL_MX4_PRIO);
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $GMAIL_MX5, $DEFAULT_TTL, $GMAIL_MX5_PRIO);
		}
		elsif ($mail eq '') {
			# rootnode mx
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $DEFAULT_MX1, $DEFAULT_TTL, $DEFAULT_PRIO);
			$self->{dns_add_record}->execute($domain_id, $domain_name, 'MX', $DEFAULT_MX2, $DEFAULT_TTL, $DEFAULT_PRIO);
		} 
		else {
			return "Option \033[1m$mail\033[0m NOT recognized. Some basic records not added.";
		}
		
		return;
	}

	# subroutines for record type
	sub get_record_name {
		my($host_name,$domain_name) = @_;
		($host_name and $domain_name) or die "Not enough parameters in get_record_name sub.";

		my $record_name;
		if($host_name eq '@') {
			$record_name = $domain_name;
		} elsif($host_name eq '.') {
			$record_name = '*.'.$domain_name;
		} elsif(substr($host_name,0,1) eq '.') {
			$record_name = join('.', '*', substr($host_name,1), $domain_name);
		} else {
			$record_name = join('.', $host_name, $domain_name);
		}

		return $record_name;
	}
	
	sub check_host_name {
		my($host_name) = @_;
		($host_name) or die "Not enough parameters in check_host_name sub.";

		if($host_name eq '@' or $host_name eq '.') {
			# nothing to do
			return;
		} elsif(substr($host_name,0,1) eq '.') {
			# .host
			my $real_host_name = substr($host_name,1);
			is_hostname($real_host_name) or return "Host \033[1m$real_host_name\033[0m is NOT a proper host name.";
		} else {
			is_hostname($host_name) or return "Host \033[1m$host_name\033[0m is NOT a proper host name.";
		}
	
		return; # success
	}
	
	my($record_ttl, $record_prio) = ($DEFAULT_TTL, undef);

	my $host_name = shift @args or return "Not enough arguments! \033[1mHost name\033[0m NOT specified. Please die or read help.";
	   $host_name = lc $host_name;
	my $check_host_name = check_host_name($host_name);
	   $check_host_name and return $check_host_name;

	my $record_name = get_record_name($host_name, $domain_name);
	my $record_content;

	given($record_type) {
		when(/^(a|aaaa)$/) {
			# satan dns add domain.com a <host|@|.> <IP>
			$record_content = shift @args or return "Not enough arguments! \033[1mIP address\033[0m NOT specified. Please die or read help.";
			$record_content = lc $record_content;
			if($record_type eq 'a') {
				is_ipv4($record_content) or return "Address \033[1m$record_content\033[0m is NOT a proper IPv4 address.";				
			} else {
				is_ipv6($record_content) or return "Address \033[1m$record_content\033[0m is NOT a proper IPv6 address.";
			}
		}
		when('cname') {
			# satan dns add domain.com cname <host> <domain>
			$record_content = shift @args or return "Not enough arguments! \033[1mIP address\033[0m NOT specified. Please die or read help.";
			$record_content = lc $record_content;
			is_hostname($record_content) or return "Domain \033[1m$record_content\033[0m is NOT a proper domain name.";
		}
		when('mx') {
			# satan dns add domain.com mx <host> <domain> <prio>
			$record_content = shift @args or return "Not enough arguments! \033[1mIP address\033[0m NOT specified. Please die or read help.";
			$record_content = lc $record_content;
			is_hostname($record_content) or return "Domain \033[1m$record_content\033[0m is NOT a proper domain name.";

			$record_prio = shift @args || $DEFAULT_PRIO;
			$record_prio =~ /^([^0]\d*|0)$/ or return "Priority \033[1m$record_prio\033[0m must be a number! Try again.";
			$record_prio > 65535           and return "Priority \033[1m$record_prio\033[0m too high! Up in smoke.";
		}
		when('txt') {
			$record_content = shift @args or return "Not enough arguments! \033[1mText\033[0m NOT specified. Please die or read help.";
			length($record_content) > 255   and return "Text record too long! Only 255 chars possible.";
		}
		when('srv') {
			# satan dns add domain.com srv <host> <prio> <weight> <port> <domain>
			my($host_service, $host_proto) = $host_name =~ /^_(.+)\._(.+)$/; # split host name into <service> and <proto>
			($host_service and $host_proto)   or return "Bad host name \033[1m$host_name\033[0m! Please use _<service>._<proto> host name.";
			is_hostname($host_service)        or return "Service \033[1m$host_service\033[0m is NOT a proper host name.";
			$host_proto =~ /^(tcp|udp)$/      or return "Bad protocol \033[1m$host_proto\033[0m. Only TCP and UDP is supported.";

			my $srv_prio = shift @args        or return "Not enough arguments! \033[1mPriority\033[0m NOT specified. Please die or read help.";
			   $srv_prio =~ /^([^0]\d*|0)$/   or return "Priority \033[1m$srv_prio\033[0m must be a number! Try again.";
			   $srv_prio > 65535             and return "Priority \033[1m$srv_prio\033[0m too high! Up in smoke.";

			my $srv_weight = shift @args      or return "Not enough arguments! \033[1mWeight\033[0m NOT specified. Please die or read help.";
			   $srv_weight =~ /^([^0]\d*|0)$/ or return "Weight \033[1m$srv_weight\033[0m must be a number! Try again.";
			   $srv_weight > 255             and return "Weight \033[1m$srv_weight\033[0m too high! Up in smoke.";

			my $srv_port = shift @args or return "Not enough arguments! \033[1mPort\033[0m NOT specified. Please die or read help.";
			   $srv_port =~ /^\d+$/    or return "Port \033[1m$srv_port\033[0m must be a number! Try againa.";
			 ( $srv_port < 1024 or $srv_port > 65535 ) and return "Port \033[1m$srv_port\033[0m must be between 1024 and 65535. Try again";
	
			my $srv_domain = shift @args or return "Not enough arguments! \033[1Domain\033[0m NOT specified. Please die or read help.";
			is_domain($srv_domain) or return "Domain \033[1m$srv_domain\033[0m is NOT a proper domain name.";

			$record_content = join(' ', $srv_prio, $srv_weight, $srv_port, $srv_domain);
		}
		when('soa') {
			# satan dns add domain.com soa <host> <ns> <mail>
			substr($host_name,0,1) eq '.' and return "Wildcard entry is not possible for SOA record.";

			my $soa_ns = shift @args or return "Not enough arguments! \033[1mNameserver\033[0m NOT specified. Please die or read help.";
			   $soa_ns = lc $soa_ns;
			is_domain($soa_ns) or return "Nameserver \033[1m$soa_ns\033[0m is NOT a proper domain name.";
		
			my $soa_mail = shift @args or return "Not enough arguments! \033[1mMail\033[0m NOT specified. Please die or read help.";
			   $soa_mail = lc $soa_mail;
			   $soa_mail =~ s/@/\./;
			is_domain($soa_mail) or return "Mail \033[1m$soa_mail\033[0m is NOT a proper domain name.";

			$record_content = join(' ', $soa_ns, $soa_mail, $SOA_SERIAL, $SOA_REFRESH, $SOA_RETRY, $SOA_EXPIRE, $SOA_MIN_TTL);
		}
		when(/^(ns|ptr)$/) {
			# satan dns add domain.com ns <host> <domain>
			substr($host_name,0,1) eq '.' and return "Wildcard entry is not possible for ".uc($record_type)." record.";

			$record_content = shift @args or return "Not enough arguments! \033[1mDomain\033[0m NOT specified. Please die or read help.";
			$record_content = lc $record_content;
			is_hostname($record_content) or return "Domain \033[1m$record_content\033[0m is NOT a proper domain name.";
		}
		default {
			return "Not good! \033[1m$record_type\033[0m is NOT a proper record type. See help.";
		}
	}

	@args > 0 and return "Too many arguments! See help.";	
	$record_type = uc $record_type;

	$dns_check_record->execute($domain_id,$record_name,$record_type,$record_content);
	if($dns_check_record->rows) {
		my($record_id) = $dns_check_record->fetchrow_array;
		#my $record_entry = join(' ', $record_name, uc($record_type), $record_content);
		return "Record \033[1m$record_id\033[0m already added. Nothing to do.";
	}

	$dns_add_record->execute($domain_id,$record_name,$record_type,$record_content,$record_ttl,$record_prio);
	return; # suckcess
}

sub del {
	my($self,@args) = @_;
        my $uid     = $self->{uid};
	
	my $dns_del_domain      = $self->{dns_del_domain};
	my $dns_del_record      = $self->{dns_del_record};
	my $dns_check_domain    = $self->{dns_check_domain};
	my $dns_check_record_id = $self->{dns_check_record_id};
	
	my $domain_id;
	my $domain_name = shift @args or return "Not enough arguments! \033[1mDomain name\033[0m or \033[1mrecord id\033[0m NOT specified. Please die or read help.";

	@args > 0 and return "Too many arguments! See help.";	

	if($domain_name =~ /^\d+$/) {
		# record id
		my $record_id = $domain_name;
		$dns_check_record_id->execute($record_id, $uid);
		if($dns_check_record_id->rows) {
			# record exists
			$dns_del_record->execute($record_id);
		} else {
			return "Record \033[1m$record_id\033[0m does NOT exist. Please double check the id.";
		}
	} else {
		# domain name
		is_domain($domain_name) or return "Domain \033[1m$domain_name\033[0m is NOT a proper domain name.";
		$dns_check_domain->execute($domain_name);
		if($dns_check_domain->rows) {
			($domain_id, my $domain_uid) = $dns_check_domain->fetchrow_array;
			if($domain_uid == $uid) {
				$dns_del_domain->execute($domain_id, $uid);
			} else {
				return "Domain \033[1m$domain_name\033[0m is NOT your domain! Cannot delete.";
			}
		} else {
			return "Domain \033[1m$domain_name\033[0m does NOT exist! Please double check the name.";
		}
	}
	
        #$event_add->execute($uid,"Deleted domain ($user)");

	return; #suckcess
}

sub list {
	my($self,@args) = @_;
        my $uid     = $self->{uid};

	my $dns_check_domain = $self->{dns_check_domain};
	my $dns_list_domains = $self->{dns_list_domains};
	my $dns_list_records = $self->{dns_list_records};
	
	my $domain_name = shift @args;
	@args > 0 and return "Too many arguments! See help.";	
	
	my $listing;
	if(not defined $domain_name) {	
		# list domains
		$dns_list_domains->execute($uid);
		$listing = Satan::Tools->listing(
			db      => $dns_list_domains,
			title   => "Domains",
			header  => ['Name','SOA','NS','A','AAAA','CNAME','MX','TXT','SRV','PTR'],
			columns => [ qw(name SOA NS A AAAA CNAME MX TXT SRV PTR) ],
		) || "No domains.";
	} else {
		$domain_name = lc $domain_name;
		is_domain($domain_name) or return "Domain \033[1m$domain_name\033[0m is NOT a proper domain name.";
	
		$dns_check_domain->execute($domain_name);
		if($dns_check_domain->rows) {
			my($domain_id, $domain_uid) = $dns_check_domain->fetchrow_array;
			if($domain_uid == $uid) {
				$dns_list_records->execute($domain_id);
				$listing = Satan::Tools->listing(
					db      => $dns_list_records,
					title   => "Domain $domain_name",
					header  => ['ID','Name','Type','Content','TTL','Priority'],
					columns => [ qw(id name type content ttl prio) ],
				) || "No records.";
			} else {
				return "Domain \033[1m$domain_name\033[0m is NOT your domain! Cannot list.";
			}
		} else {
			return "Domain \033[1m$domain_name\033[0m does NOT exist! Please double check the name.";
		}
	}
	$self->{data} = $listing;	
	return;
}

sub help {
        my $self = shift;
        my $uid = $self->{uid};
	my $USAGE = <<"END_OF_USAGE";
\033[1mSatan :: DNS\033[0m

\033[1;32mSYNTAX\033[0m
  dns add <domain> [<ipaddr>] [nomail|gmail]             add domain (incl. basic records)
  dns add <domain> a     <host|@|.> <ipv4>               add A record
  dns add <domain> aaaa  <host|@|.> <ipv6>               add AAAA record
  dns add <domain> cname <host|@|.> <domain>             add CNAME record
  dns add <domain> mx    <host|@|.> <domain> [<prio>]    add MX record
  dns add <domain> txt   <host|@|.> "<txt>"              add TXT record
  dns add <domain> srv   <host> <prio> <weight> <port> <domain>     
                                                         add SRV record
  dns add <domain> soa   <host|@|.> <ns> <mail>          add SOA record (or delegate a subdomain)
  dns add <domain> ns    <host|@|.> <domain>             add NS record
  dns add <domain> ptr   <host|@|.> <domain>             add PTR record             
  dns del <domain>                                       delete domain and ALL RECORDS!
  dne del <id>                                           delete record
  dns list                                               list domains
  dns list <domain>                                      list records
  dns help                                               show help

  \033[1mWhere:\033[0m
    <domain> must be a canonical domain name

    In <host> you can use:
       \033[1m@\033[0m for a main domain entry
       \033[1m.\033[0m for a wildcard entry (starting with *)

    In SRV record <host> should be in format _service._proto,
    e.g.: _xmpp-client._tcp

    In TXT recond you must use quotes "".
   
\033[1;32mEXAMPLES\033[0m
  satan dns add domain.com
  satan dns list
  satan dns add domain.com a @ 8.8.8.8    
  satan dns add domain.com txt test "This is test text" 
  satan dns add domain.com soa friend ns1.rootnode.net mail\@domain.com
  satan dns list domain.com
  satan dns del 12 
  satan dns del domain.com
END_OF_USAGE

	$self->{data} = $USAGE;
	return;
}

=mysql backend pdns

create table domains (
 id		 INT auto_increment,
 uid             SMALLINT UNSIGNED NOT NULL,
 name		 VARCHAR(255) UNIQUE NOT NULL,
 master		 VARCHAR(128) DEFAULT NULL,
 last_check	 INT DEFAULT NULL,
 type		 VARCHAR(6) NOT NULL,
 notified_serial INT DEFAULT NULL, 
 account         VARCHAR(40) DEFAULT NULL,
 primary key (id),
 KEY(uid),
 KEY(name)
) Engine=InnoDB;

CREATE TABLE records (
  id              INT auto_increment,
  domain_id       INT NOT NULL,
  name            VARCHAR(255) DEFAULT NULL,
  type            VARCHAR(10) DEFAULT NULL,
  content         VARCHAR(4096) DEFAULT NULL,
  ttl             INT DEFAULT 300,
  prio            INT DEFAULT NULL,
  change_date     INT DEFAULT NULL,
  primary key(id),
  KEY(name),
  KEY(name,type),
  KEY(domain_id),
  FOREIGN KEY (domain_id) REFERENCES domains(id) ON DELETE CASCADE
)Engine=InnoDB;

create table supermasters (
  ip VARCHAR(25) NOT NULL, 
  nameserver VARCHAR(255) NOT NULL, 
  account VARCHAR(40) DEFAULT NULL
) Engine=InnoDB;

#GRANT SELECT ON supermasters TO pdns;
GRANT ALL ON domains TO pdns;
GRANT ALL ON records TO pdns;
=cut

1;
