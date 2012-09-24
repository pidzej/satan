#!/usr/bin/perl
#
# Satan::FTP
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#

package Satan::Ftp;

use warnings;
use strict;
use utf8;
use Satan::Tools;
use FindBin qw($Bin);
use POSIX qw(isdigit);
use Data::Password qw(IsBadPassword);
use Readonly;
use Smart::Comments;

$|++;
$SIG{CHLD} = 'IGNORE';

Readonly my $MIN_UID => 2000;
Readonly my $MAX_UID => 6000;
Readonly my $DIR_MAXLEN => 255;
Readonly my %IS_PRIV => (
	nomkdir  => 1,
	nodelete => 1,
	noupload => 1,
	noread   => 1,
	nossl    => 1,
);
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

	my $dbh = DBI->connect("dbi:mysql:ftp;mysql_read_default_file=$Bin/../config/my.cnf", undef, undef, { RaiseError => 0, AutoCommit => 1 });
	$dbh->{mysql_auto_reconnect} = 1;
	$dbh->{mysql_enable_utf8}    = 1;

	my $db;
	$db->{add_user} = $dbh->prepare("INSERT INTO all_users(uid, user_name, server_name, password, directory, mkdir_priv, delete_priv, upload_priv, read_priv, ssl_priv, created_at, updated_at, owner) VALUES (?, ?, ?, PASSWORD(?), ?, ?, ?, ?, ?, ?, NOW(), NOW(), ?)");
	$db->{del_user} = $dbh->prepare("DELETE FROM all_users WHERE uid=? AND user_name=? LIMIT 1");
	$db->{get_user} = $dbh->prepare("
		SELECT 
			user_name, 
			directory, 
			IF (mkdir_priv  =  1, 'yes', 'no') AS mkdir_priv, 
			IF (delete_priv =  1, 'yes', 'no') AS delete_priv, 
			IF (upload_priv =  1, 'yes', 'no') AS upload_priv, 
			IF (read_priv   =  1, 'yes', 'no') AS read_priv, 
			IF (ssl_priv    =  1, 'yes', 'no') AS ssl_priv, 
			created_at, 
			updated_at 
		FROM all_users 
		WHERE uid=? AND user_name LIKE ?
	");

	$db->{deluser_users} = $dbh->prepare("DELETE FROM all_users WHERE uid=?");

	$db->{dbh} = $dbh;
	$self->{db} = $db;
	bless $self, $class;
	return $self;
}

sub deluser {
        my ($self, @args) = @_;
        my $uid = $self->{uid};
        my $db  = $self->{db};
        my $user_name   = $self->{user_name};
        my $user_type   = $self->{type};
        my $server_name = $self->{server_name};

        my $deluser_users = $self->{deluser_users};

        # Get uid to delete
        my $delete_uid = shift @args or return "Not enough arguments! \033[1mUid\033[0m NOT specified.";

        # Check uid
        isdigit($delete_uid)   or return "Uid must be a number!";
        $delete_uid < $MIN_UID and return "Uid too low. (< $MIN_UID)";
        $delete_uid > $MAX_UID and return "Uid too high. (> $MAX_UID)";

        # Check user type
        $user_type eq 'admin' or return "Access denied!";

        # Delete database records
        $db->{deluser_users}->execute($delete_uid) or return "Cannot remove FTP users for uid $delete_uid. Database error.";

        return;
}

sub add {
	my ($self, @args) = @_;
	my $db          = $self->{db};
	my $uid         = $self->{uid};
	my $user_name   = $self->{user_name};	
	my $server_name = $self->{server_name};
	
	# satan ftp add <user>[@<server>] <password> <directory> [no<privs>]
	
	# Get username
	my $ftp_user = shift @args or return "Not enough arguments! \033[1mUser name\033[0m NOT specified. Go to hell or read help.";
	   $ftp_user = lc $ftp_user;
	   $ftp_user =~ /^[a-z0-9]{1,32}$/ or return "Not good! User name \033[1m$ftp_user\033[0m is incorrect.";
	
	# Check account in database
	$db->{get_user}->execute($uid, $ftp_user);
	my $is_existing_user = $db->{get_user}->rows;

	# Account already exists
	if ($is_existing_user) {
		return "User \033[1m$ftp_user\033[0m already added. Nothing to do.";
	}

	# Get password
	my $ftp_password = shift @args or return "Not enough parameters! \033[1mUser password\033[0m NOT specified.";
	
	my $bad_password_reason = IsBadPassword($ftp_password);
	if ($bad_password_reason) {
		return "Password too simple: $bad_password_reason.";
	}

	# Get directory
	my $ftp_directory = shift @args or return "Not enough arguments! \033[1mDirectory\033[0m NOT specified. Go to hell or read help.";

	length($ftp_directory) > $DIR_MAXLEN and return "Directory path too long (>$DIR_MAXLEN).";
	
	# Check privileges
	my @privs = @args;
	foreach my $priv_name (@privs) {
		next if $IS_PRIV{$priv_name};
		next if $IS_PRIV{"no$priv_name"};
		return "Argument \033[1m$priv_name\033[0m is NOT a proper privilege name.";
	}	
		
	# Store privs as hash table
	my %priv = map { $_ => 1 } @privs;
	
	# All privileges are enabled by default
	my $mkdir_priv  = defined $priv{nomkdir}  ? 0 : 1;
	my $delete_priv = defined $priv{nodelete} ? 0 : 1;
	my $upload_priv = defined $priv{noupload} ? 0 : 1;
	my $read_priv   = defined $priv{noread}   ? 0 : 1;
	my $ssl_priv    = defined $priv{nossl}    ? 0 : 1;

	# Add account to database
	$db->{add_user}->execute($uid, $ftp_user, $server_name, $ftp_password, $ftp_directory, 
	                         $mkdir_priv, $delete_priv, $upload_priv, $read_priv, $ssl_priv,
				 $uid) or return "Cannot add FTP account \033[1m$ftp_user\033[0m. System error."; 
	
	return;
}



sub del {
	my ($self, @args) = @_;
	my $db          = $self->{db};
	my $uid         = $self->{uid};
	my $user_name   = $self->{user_name};	
	my $server_name = $self->{server_name};

	# satan ftp del <user>[@<server>]
	
	# Get username
	my $ftp_user = shift @args or return "Not enough arguments! \033[1mUser name\033[0m NOT specified. Go to hell or read help.";
	   $ftp_user = lc $ftp_user;
	   $ftp_user =~ /^[a-z0-9]{1,32}$/ or return "Not good! User name \033[1m$ftp_user\033[0m is incorrect.";

	# Check account in database
	$db->{get_user}->execute($uid, $ftp_user);
	my $is_existing_user = $db->{get_user}->rows;
	
	# Account doesn't exist
	if (!$is_existing_user) {
		return "User \033[1m$ftp_user\033[0m NOT found.";
	}
	
	# Delete from database
	$db->{del_user}->execute($uid, $ftp_user) or return "Cannot delete FTP account \033[1m$ftp_user\033[0m. System error.";

	return;
}

sub list {
	my ($self, @args) = @_;
	my $db          = $self->{db};
	my $uid         = $self->{uid};
	my $user_name   = $self->{user_name};	
	my $server_name = $self->{server_name};

	# satan ftp list [<server>]
	
	# Get accounts from database
	$db->{get_user}->execute($uid, '%');
	my $has_ftp_users = $db->{get_user}->rows;

	# Check if user has accounts
	if (!$has_ftp_users) {
		return "No accounts.";
	}

	my $listing = Satan::Tools->listing(
		db      => $db->{get_user},
		title   => 'FTP accounts',
		header  => [ 'User name', 'Directory', 'mkdir', 'delete', 'upload', 'read', 'ssl', 'Created at', 'Updated at' ],
		columns => [ qw(user_name directory mkdir_priv delete_priv upload_priv read_priv ssl_priv created_at updated_at) ],
	);
	
	$self->{data} = $listing;
	return;
}

sub help {
        my $self = shift;
        my $uid = $self->{uid};
my $USAGE = <<"END_OF_USAGE";
\033[1mSatan :: Ftp\033[0m

\033[1;32mSYNTAX\033[0m
  ftp add <user> <password> <directory> [no<privs>]   add ftp account
  ftp del <user>                                      delete ftp account
  ftp list                                            list all accounts
  ftp help                                            show help

It is a good idea to genereate password with command:
PASSWORD=\$(perl -le 'print map { ("a".."z", 0..9)[rand 36] } 1..12')

END_OF_USAGE

	$self->{data} = $USAGE;
	return;
}

1;
