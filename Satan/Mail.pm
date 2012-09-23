#!/usr/bin/perl
#
# Satan::Mail
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
package Satan::Mail;

use warnings;
use strict;
use utf8;
use Satan::Tools qw(caps txt);
use IO::Socket;
use File::Copy;
use File::Path qw(make_path);
use Crypt::GeneratePassword qw(chars);
use Data::Password qw(:all);
use FindBin qw($Bin);
use Data::Validate::Email qw(is_email);
use Data::Validate::Domain qw(is_domain is_hostname);
use Data::Validate::IP qw(is_ipv4 is_ipv6);
use POSIX qw(isdigit strftime);
use Readonly;
use DBI;
no Smart::Comments;

# configuration
Readonly my $DOVEADM_BIN             => '/usr/bin/doveadm';
Readonly my $DEFAULT_PASSWORD_SCHEME => 'SHA512-CRYPT';
Readonly my $DEFAULT_HOME_DIR        => '/home/mail';
Readonly my $MAIL_DIR_GID            => 500;
Readonly my $MIN_UID                 => 2000;
Readonly my $MAX_UID                 => 6000;
Readonly my %EXPORT_OK => (
        user  => [ qw( add del list passwd help ) ],
        admin => [ qw( deluser ) ]
);

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
	my $dbh = DBI->connect("dbi:mysql:mail;mysql_read_default_file=$Bin/../config/my.cnf",undef,undef,{ RaiseError => 0, AutoCommit => 1 }) or die;
	### $self

	# Add action
	$self->{mail_add_domain}    = $dbh->prepare("INSERT INTO domains(uid,domain_name,created_at) VALUES (?,?,NOW())");
	$self->{mail_add_user}      = $dbh->prepare("INSERT INTO users(uid,domain_id,user_name,password,created_at,home) VALUES (?,?,?,?,NOW(),'$DEFAULT_HOME_DIR')");
	$self->{mail_add_alias}     = $dbh->prepare("INSERT INTO aliases(domain_id,user_name,mail,created_at) VALUES (?,?,?,NOW())");
	
	# Delete action
	$self->{mail_del_domain}    = $dbh->prepare("DELETE FROM domains WHERE uid=? AND domain_name=?");
	$self->{mail_del_user}      = $dbh->prepare("DELETE FROM users WHERE uid=? AND domain_id=? AND user_name=?");
	$self->{mail_del_alias}     = $dbh->prepare("DELETE FROM aliases WHERE domain_id=? AND user_name=?");

	# Change action
	$self->{mail_change_passwd} = $dbh->prepare("UPDATE users SET password=? WHERE uid=? AND domain_id=? AND user_name=?");
	
	# Check action
	$self->{mail_check_domain}  = $dbh->prepare("SELECT id,uid FROM domains WHERE domain_name=?");
	$self->{mail_check_user}    = $dbh->prepare("SELECT id FROM users WHERE uid=? AND domain_id=? AND user_name=?");
	$self->{mail_check_alias}   = $dbh->prepare("SELECT id FROM aliases WHERE domain_id=? AND user_name=?");

	# Listing action
	$self->{mail_list_domains}  = $dbh->prepare("
		SELECT 
			d.domain_name, 
			(SELECT count(user_name) FROM users   u WHERE u.domain_id=d.id) AS user_count,
			(SELECT count(user_name) FROM aliases a WHERE a.domain_id=d.id) AS alias_count,
			d.created_at 
		FROM domains d
		WHERE d.uid=?
	");
	$self->{mail_list_users}    = $dbh->prepare("
		SELECT CONCAT_WS('\@', u.user_name, d.domain_name) AS user_name, u.created_at 
		FROM users u 
			LEFT JOIN domains d ON u.domain_id = d.id 
		WHERE u.uid=? 
		  AND u.domain_id=?
	");
	$self->{mail_list_aliases}  = $dbh->prepare("
		SELECT CONCAT_WS('\@', a.user_name, d.domain_name) AS user_name, a.mail, a.created_at 
		FROM aliases a 
			LEFT JOIN domains d ON a.domain_id = d.id 
		WHERE a.domain_id=?
	");

	$self->{mail_deluser_domains} = $dbh->prepare("DELETE FROM domains WHERE uid=?");
	$self->{dbh} = $dbh;

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
        
	my $mail_deluser_domains = $self->{mail_deluser_domains};

        # Get uid to delete
        my $delete_uid = shift @args or return "Not enough arguments! \033[1mUid\033[0m NOT specified.";
        
	# Check uid
	isdigit($delete_uid)   or return "Uid must be a number!";
        $delete_uid < $MIN_UID and return "Uid too low. (< $MIN_UID)";
        $delete_uid > $MAX_UID and return "Uid too high. (> $MAX_UID)";

        # Check user type
        $user_type eq 'admin' or return "Access denied!";

        # Delete user files
	my $user_dir = "$DEFAULT_HOME_DIR/$delete_uid";

	my $current_date = strftime("%Y-%m-%d", localtime(time));
	my $deleted_user_dir = "$DEFAULT_HOME_DIR/deleted-$delete_uid-$current_date";
	if (-d $user_dir) {
		move( $user_dir, $deleted_user_dir ) or return "Cannot remove user directory. System error ($!).";
	}

	# Delete database records
        $mail_deluser_domains->execute($delete_uid) or return "Cannot remove mail domains for uid $delete_uid. Database error.";

        return;
}

sub add {
	my($self,@args) = @_;
	my $uid = $self->{uid};
	my $dbh = $self->{dbh};  
	my $account_name   = $self->{account_name};
	my $server_name = $self->{server_name};

	my $mail_add_domain   = $self->{mail_add_domain};
	my $mail_add_user     = $self->{mail_add_user};
	my $mail_add_alias    = $self->{mail_add_alias};
	my $mail_check_domain = $self->{mail_check_domain};
	my $mail_check_user   = $self->{mail_check_user};
	my $mail_check_alias  = $self->{mail_check_alias};

	my $command_type = shift @args or return "Not enough arguments! Please use \033[1mdomain\033[0m, \033[1muser\033[0m or \033[1malias\033[0m parameter.";
	   $command_type = lc $command_type;
	
	# satan mail add domain <domain>
	if ($command_type eq 'domain') {
		my $domain_name = shift @args or return "Not enough arguments! \033[1mDomain name\033[0m NOT specified. Please die or read help.";
		   $domain_name = lc $domain_name;		
		is_domain($domain_name) or return "Not good! \033[1m$domain_name\033[0m is NOT a proper domain name.";

		# Check if domain exists
		my $domain_id;
		$mail_check_domain->execute($domain_name);
		if ($mail_check_domain->rows) {
			($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
			if ($domain_uid != $uid) {
				return "Cannot add domain! Domain \033[1m$domain_name\033[0m is owned by another user.";
			}
                        return "Domain \033[1m$domain_name\033[0m already added. Nothing to do.";
		}
		
		# Check TXT record
		my $txt_value_for = Satan::Tools->txt($domain_name);

		# Check uid defined in TXT record
		if (!defined $txt_value_for->{uid} or !isdigit($txt_value_for->{uid})) {
			return "Domain \033[1m$domain_name\033[0m cannot be authenticated! Please add TXT record 'rootnode uid=$uid' to your domain.";
		}
		
		# User is not an owner
		if ($txt_value_for->{uid} != $uid) {
			return "Cannot add domain! Domain \033[1m$domain_name\033[0m is owned by another user.";
		}
		
		# Move files from deleted directory
		my $domain_dir = "$DEFAULT_HOME_DIR/$uid/$domain_name";
		my $deleted_domain_dir = "$domain_dir (deleted)";
		if (-d $deleted_domain_dir) {
			move( $deleted_domain_dir, $domain_dir ) or return "Cannot restore mail domain directory. System error ($!).";
		}

		# Create domain directory
		if (! -d $domain_dir) {
			umask 0007;
			make_path( $domain_dir, { group => $MAIL_DIR_GID } ) or return "Cannot create mail domain directory. System error ($!).";
		}

		# Add domain
		$mail_add_domain->execute($uid, $domain_name);
		return;	
	}
	# satan mail add user <mail> <password>
	# satan mail passwd <mail> <password>
	elsif ($command_type =~ /^(user|mail|mailbox)$/) {
		my $account_name = shift @args or return "Not enough arguments! \033[1mUser name\033[0m NOT specified. Please die or read help.";
		   $account_name = lc $account_name;
		is_email($account_name) or return "Not good! \033[1m$account_name\033[0m is NOT a proper mail address.";

		my $user_password = shift @args or return "Not enough parameters! \033[1mUser password\033[0m NOT specified.";
		my $bad_password_reason = IsBadPassword($user_password);
		if ($bad_password_reason) {
			return "Password too simple: $bad_password_reason.";
		}
		
		# Split mail into user and domain part
		my ($user_part, $domain_part) = split /@/, $account_name;
	
		# Check if domain exists		
		my $domain_id;
		$mail_check_domain->execute($domain_part);
		if ($mail_check_domain->rows) {
			($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
			if ($domain_uid != $uid) {
				return "Domain \033[1m$domain_part\033[0m exists but it is owned by another user. Cannot add mail account!";
			}
		}
		else {
			return "Domain \033[1m$domain_part\033[0m does NOT exist. Add domain first with 'satan mail add domain' command.";
		}

		# Check if user exists
		$mail_check_user->execute($uid, $domain_id, $user_part);
		if ($mail_check_user->rows) {
			return "Mail account \033[1m$account_name\033[0m already exists. Nothing to do.";
		}

		# Check if alias exists
		$mail_check_alias->execute($domain_id, $user_part);
		if ($mail_check_alias->rows) {
			return "Alias of the same name \033[1m$account_name\033[0m already exists. Cannot add mail account!";
		}
		
		# Move files from deleted directory
		my $mailbox_dir = "$DEFAULT_HOME_DIR/$uid/$domain_part/$user_part";
		my $deleted_mailbox_dir = "$mailbox_dir (deleted)";
		if (-d $deleted_mailbox_dir) {
			move( $deleted_mailbox_dir, $mailbox_dir ) or return "Cannot restore mailbox directory. System error ($!).";
		} 
	
		# Create mailbox directory
		if (! -d $mailbox_dir) {
			### $mailbox_dir
			umask 0007;
			make_path( $mailbox_dir, { group => $MAIL_DIR_GID } ) or return "Cannot create mailbox directory. System error ($!).";
		}

		# Generate user password crypt
		my $user_password_crypt = `$DOVEADM_BIN pw -s$DEFAULT_PASSWORD_SCHEME -p$user_password` or return "Cannot generate user password! System error ($!).";
		chomp $user_password_crypt;
		
		# Add mail account
		$mail_add_user->execute($uid, $domain_id, $user_part, $user_password_crypt);

		return;
	}
	
	# satan mail add alias <alias> <mail>
	elsif ($command_type eq 'alias') {
		my $alias_name = shift @args or return "Not enough arguments! \033[1mAlias\033[0m NOT specified. Please die or read help.";
		   $alias_name = lc $alias_name;
		
		# Split alias into user and domain
		my ($alias_user_part, $alias_domain_part) = split /@/, $alias_name;

		# Catch-all alias
		if ($alias_name =~ /^\@(.+)/) {
			is_domain($alias_domain_part) or return "Not good! \033[1m$alias_domain_part\033[0m is NOT a proper domain name.";
			$alias_user_part = '*' if $alias_user_part eq '';
		}
		# Regular alias
		else {
			is_email($alias_name) or return "Not good! \033[1m$alias_name\033[0m is NOT a proper mail address.";
		}

		my $account_name = shift @args or return "Not enough arguments! \033[1mUser name\033[0m NOT specified. Please die or read help.";
		   $account_name = lc $account_name;
		is_email($account_name) or return "Not good! \033[1m$account_name\033[0m is NOT a proper mail address.";

		# Check if domain exists
		my $domain_id;
		$mail_check_domain->execute($alias_domain_part);
		if ($mail_check_domain->rows) {
			($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
			if ($domain_uid != $uid) {
				return "Domain \033[1m$alias_domain_part\033[0m is owned by another user. Cannot add alias!";
			}
		}
		else {
			return "Domain \033[1m$alias_domain_part\033[0m does NOT exist. Add domain first with 'satan mail add domain' command.";
		}
		
		# Check if alias exists
		$mail_check_alias->execute($domain_id, $alias_user_part);
		if ($mail_check_alias->rows) {
			return "Alias \033[1m$alias_name\033[0m already exists. Nothing to do.";
		}	
	
		# Check if user exists
		$mail_check_user->execute($uid, $domain_id, $alias_user_part);
		if ($mail_check_user->rows) {
			return "Mail account of the same name \033[1m$alias_name\033[0m exists. Cannot add alias!";
		}
		
		# Add new alias
		$mail_add_alias->execute($domain_id, $alias_user_part, $account_name);
	
		return;
	}
	else {
	   return "Unknown parameter '$command_type'. Please use \033[1mdomain\033[0m, \033[1muser\033[0m or \033[1malias\033[0m.";
	}
}

sub del {
	my($self,@args) = @_;
        my $uid     = $self->{uid};
	
	my $mail_del_domain   = $self->{mail_del_domain};
	my $mail_del_user     = $self->{mail_del_user};
	my $mail_del_alias    = $self->{mail_del_alias};
	my $mail_check_domain = $self->{mail_check_domain};
	my $mail_check_user   = $self->{mail_check_user};
	my $mail_check_alias  = $self->{mail_check_alias};
	
	my $command_type = shift @args or return "Not enough arguments! Please use \033[1mdomain\033[0m, \033[1muser\033[0m or \033[1malias\033[0m parameter.";
	   $command_type = lc $command_type;
	
	# satan mail del domain <domain>
	if ($command_type eq 'domain') {
		my $domain_name = shift @args or return "Not enough arguments! \033[1mDomain name\033[0m NOT specified. Please die or read help.";
		   $domain_name = lc $domain_name;		
		is_domain($domain_name) or return "Not good! \033[1m$domain_name\033[0m is NOT a proper domain name.";

		# Check if domain exists
		my $domain_id;
		$mail_check_domain->execute($domain_name);
		if ($mail_check_domain->rows) {
			($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
			if ($domain_uid != $uid) {
				return "Cannot remove domain! Domain \033[1m$domain_name\033[0m is owned by another user.";
			}
		}
		
		# Move files to deleted directory
		my $domain_dir = "$DEFAULT_HOME_DIR/$uid/$domain_name";
		my $deleted_domain_dir = "$domain_dir (deleted)";
		if (-d $domain_dir) {
			move( $domain_dir, $deleted_domain_dir ) or return "Cannot remove mail domain directory. System error ($!).";
		}

		# Remove domain
		$mail_del_domain->execute($uid, $domain_name);
		return;	
	}
	# satan mail del user <mail>
	elsif ($command_type =~ /^(user|mail|mailbox)$/) {
		my $account_name = shift @args or return "Not enough arguments! \033[1mUser name\033[0m NOT specified. Please die or read help.";
		   $account_name = lc $account_name;
		is_email($account_name) or return "Not good! \033[1m$account_name\033[0m is NOT a proper mail address.";

		# Split mail into user and domain part
		my ($user_part, $domain_part) = split /@/, $account_name;

		# Check if domain exists
		my $domain_id;
		$mail_check_domain->execute($domain_part);
		if ($mail_check_domain->rows) {
			($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
			if ($domain_uid != $uid) {
				return "Cannot remove user! Domain \033[1m$domain_part\033[0m is owned by another user.";
			}
		}
	
		# Check if user exists
		$mail_check_user->execute($uid, $domain_id, $user_part);
		if (!$mail_check_user->rows) {
			return "Mail account \033[1m$account_name\033[0m NOT found. Cannot remove!";
		}

		# Move files to deleted directory
		my $mailbox_dir = "$DEFAULT_HOME_DIR/$uid/$domain_part/$user_part";
		### $mailbox_dir
		my $deleted_mailbox_dir = "$mailbox_dir (deleted)";
		if (-d $mailbox_dir) {
			move( $mailbox_dir, $deleted_mailbox_dir ) or return "Cannot remove mailbox directory. System error ($!).";
		}
	
		# Remove user from database
		$mail_del_user->execute($uid, $domain_id, $user_part);

		return;
	}
	# satan mail del alias <alias> 
	elsif ($command_type eq 'alias') {
		my $alias_name = shift @args or return "Not enough arguments! \033[1mAlias\033[0m NOT specified. Please die or read help.";
		   $alias_name = lc $alias_name;
		
		# Split alias into user and domain
		my ($alias_user_part, $alias_domain_part) = split /@/, $alias_name;

		# Catch-all alias
		if ($alias_name =~ /^\@(.+)/) {
			is_domain($alias_domain_part) or return "Not good! \033[1m$alias_domain_part\033[0m is NOT a proper domain name.";
			$alias_user_part = '*' if $alias_user_part eq '';
		}
		# Regular alias
		else {
			is_email($alias_name) or return "Not good! \033[1m$alias_name\033[0m is NOT a proper mail address.";
		}

		# Check if domain exists
		my $domain_id;
		$mail_check_domain->execute($alias_domain_part);
		if ($mail_check_domain->rows) {
			($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
			if ($domain_uid != $uid) {
				return "Cannot remove alias! Domain \033[1m$alias_domain_part\033[0m is owned by another user.";
			}
		}

		# Check if alias exists
		$mail_check_alias->execute($domain_id, $alias_user_part);
		if (!$mail_check_alias->rows) {
			return "Alias \033[1m$alias_name\033[0m NOT found. Cannot remove!";
		}	
	
		# Remove alias from database
		$mail_del_alias->execute($domain_id, $alias_user_part);
	
		return;
	}
	else {
	   return "Unknown parameter '$command_type'. Please use \033[1mdomain\033[0m, \033[1muser\033[0m or \033[1malias\033[0m.";
	}
}

sub passwd { 
	my($self,@args) = @_;
	my $uid = $self->{uid};
	my $dbh = $self->{dbh};  
	my $user_name   = $self->{user_name};
	my $server_name = $self->{server_name};

	my $mail_check_domain  = $self->{mail_check_domain};
	my $mail_check_user    = $self->{mail_check_user};
	my $mail_change_passwd = $self->{mail_change_passwd}; 
		
	my $account_name = shift @args or return "Not enough arguments! \033[1mUser name\033[0m NOT specified. Please die or read help.";
	   $account_name = lc $account_name;
	is_email($account_name) or return "Not good! \033[1m$account_name\033[0m is NOT a proper mail address.";

	my $user_password = shift @args or return "Not enough parameters! \033[1mUser password\033[0m NOT specified.";
	my $bad_password_reason = IsBadPassword($user_password);
	if ($bad_password_reason) {
		return "Password too simple: $bad_password_reason.";
	}
	
	# Split mail into user and domain part
	my ($user_part, $domain_part) = split /@/, $account_name;

	# Check if domain exists		
	my $domain_id;
	$mail_check_domain->execute($domain_part);
	if ($mail_check_domain->rows) {
		($domain_id, my $domain_uid) = $mail_check_domain->fetchrow_array;
		if ($domain_uid != $uid) {
			return "Domain \033[1m$domain_part\033[0m is owned by another user. Cannot change password!";
		}
	}
	else {
		return "Domain \033[1m$domain_part\033[0m NOT found.";
	}

	# Check if user exists
	$mail_check_user->execute($uid, $domain_id, $user_part);
	if (!$mail_check_user->rows) {
		return "Mail account \033[1m$account_name\033[0m NOT found.";
	}

	# Generate user password crypt
	my $user_password_crypt = `$DOVEADM_BIN pw -s$DEFAULT_PASSWORD_SCHEME -p$user_password` or return "Cannot generate user password! System error ($!).";
	chomp $user_password_crypt;
	
	# Change password
	$mail_change_passwd->execute($user_password_crypt, $uid, $domain_id, $user_part);

	return;
}
	
sub list {
	my($self,@args) = @_;
        my $uid     = $self->{uid};

	my $mail_check_domain = $self->{mail_check_domain};
	my $mail_list_domains = $self->{mail_list_domains};
	my $mail_list_users   = $self->{mail_list_users};
	my $mail_list_aliases = $self->{mail_list_aliases};

	my $domain_name = shift @args;
	@args > 0 and return "Too many arguments! See help.";	
	
	my $listing;
	if(not defined $domain_name) {	
		# list domains
		$mail_list_domains->execute($uid);
		$listing = Satan::Tools->listing(
			db      => $mail_list_domains,
			title   => "Domains",
			header  => ['Domain name', 'Users', 'Aliases', 'Created at'],
			columns => [ qw(domain_name user_count alias_count created_at) ],
		) || "No domains.";
	} else {
		$domain_name = lc $domain_name;
		is_domain($domain_name) or return "Domain \033[1m$domain_name\033[0m is NOT a proper domain name.";
	
		$mail_check_domain->execute($domain_name);
		if($mail_check_domain->rows) {
			my ($domain_id, $domain_uid) = $mail_check_domain->fetchrow_array;
			if($domain_uid == $uid) {
				# List users
				$mail_list_users->execute($uid, $domain_id);
				my $user_listing = Satan::Tools->listing(
					db      => $mail_list_users,
					title   => "Users for $domain_name",
					header  => ['User', 'Created at'],
					columns => [ qw(user_name created_at) ],
				) || "No mail users.";

				# List aliases
				$mail_list_aliases->execute($domain_id);
				my $alias_listing = Satan::Tools->listing(
					db      => $mail_list_aliases,
					title   => "Aliases for $domain_name",
					header  => ['Name', 'Mail', 'Created at'],
					columns => [ qw(user_name mail created_at) ],
				) || "No mail aliases.";

				$listing = join "\n", $user_listing, $alias_listing;

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
\033[1mSatan :: Mail\033[0m

\033[1;32mSYNTAX\033[0m
  mail add domain <domain>           add domain to mail system (w/o MX records)
  mail add user <mail> <password>    add new user (aka account or mailbox)
  mail add alias <alias> <mail>      add mail alias
  mail add \@<domain> <mail>          add catch-all mail alias
  
  mail del domain <domain>           delete domain, all aliases and ALL accounts
  mail del user <mail>               delete user (mailbox content will stay)
  mail del alias <alias>             delete mail alias

  mail passwd <mail> <password>      change password for mail account

  mail list                          list all user's mail domains
  mail list <domain>                 list mail accounts and aliases  
  mail help                          show help


  \033[1mWhere:\033[0m
    Command 'add domain' does NOT add MX records to the domain automatically.
    Command 'del domain' will remove ALL mail accounts and aliases within the domain.
    Command 'del user'   will remove mail account and move mailbox content to special folder.
                         Next time you create mailbox of the same name, 
                         the content will be restored.

\033[1;32mEXAMPLES\033[0m
It is a good idea to genereate password with command:
PASSWORD=\$(perl -le 'print map { ("a".."z", 0..9)[rand 36] } 1..12')
  
  satan mail add domain domain.com
  satan mail add user freddy\@domain.com \$PASSWORD
  satan mail add alias fred\@domain.com freddy\@domain.com
  satan mail add domain example.net
  satan mail add alias \@example.net freddy\@domain.com
  satan mail del alias fred\@domain.com
  satan mail del alias \@example.net
  satan mail del domain example.net
  satan mail list
  satan mail list domain.com
END_OF_USAGE

	$self->{data} = $USAGE;
	return;
}
1;
