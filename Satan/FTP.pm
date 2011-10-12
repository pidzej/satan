#!/usr/bin/perl

## Satan::FTP
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

package Satan::FTP;

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

$MINLEN = 5;   # password min length
$MAXLEN = 16;  # password max length
$|++;

$SIG{CHLD} = 'IGNORE';

sub new {
	my $class = shift;
	my $self = { @_	};
	my $dbh_system = $self->{dbh_system};
	$self->{ftp_add}   = $dbh_system->prepare("INSERT INTO ftp(uid,username,directory,password,privs) VALUES(?,?,?,?,?)");
	$self->{ftp_del}   = $dbh_system->prepare("DELETE FROM ftp WHERE uid=? AND username=?");
	$self->{ftp_list}  = $dbh_system->prepare("SELECT username,directory,password,privs FROM ftp WHERE uid=?");
	$self->{ftp_get}   = $dbh_system->prepare("SELECT username,directory,password,privs FROM ftp WHERE uid=? AND username=?");
	$self->{ftp_limit} = $dbh_system->prepare("SELECT ftp FROM limits WHERE uid=?");
	$self->{event_add} = $dbh_system->prepare("INSERT INTO events(uid,date,daemon,event) VALUES(?,NOW(),'ftp',?)");
	$self->{ftp_change_password} = $dbh_system->prepare("UPDATE ftp SET password=? WHERE uid=? AND username=?");
	$self->{ftp_change_privs}    = $dbh_system->prepare("UPDATE ftp SET privs=? WHERE uid=? AND username=?");
	
	bless $self, $class;
	return $self;
}

sub add {
	my($self,@args) = @_;
	my $uid       = $self->{uid};
	my $login     = $self->{login};
	my $client    = $self->{client};
	my $ftp_limit = $self->{ftp_limit};
	my $ftp_list  = $self->{ftp_list};
	my $ftp_add   = $self->{ftp_add};
	my $event_add = $self->{event_add};

        my $user =  shift @args                         or return "Insufficient arguments: Username not specified. Rot in hell!";
           $user =~ /^ftp$uid\_[a-z]{1}[a-z0-9]{1,13}$/ or return "Username is incorrect. Try 'ftp$uid\_name'.";
        -f "/etc/vsftpd/users/$user"                    and return "Username '$user' already exists. Burn!";

        my $dir  =  shift @args or return "Insufficient arguments: Directory not specified. Rot in hell!";
           $dir  =~ /^[\/~]/    or return "Directory '$dir' must be an absolute path. Dying!";
        -d $dir                 or return "Directory '$dir' does not exist. Burn!";
        (stat($dir))[4] == $uid or return "You are not an owner of directory '$dir'. Please die!";

        ## check limit
        my $limit = 10;;
        $ftp_limit->execute($uid);
        while(my($ftplimit) = $ftp_limit->fetchrow_array) {
                $limit = $ftplimit;
                last;
        }
        $ftp_list->execute($uid);
        my $rows = $ftp_list->rows;
        $rows >= $limit and return "You have reached the limit of $limit FTP accounts. Delete few accounts or ask for more.";

        my @privs = @args;
        my $privs    = &_privs($uid,$login,$client,$user,$dir,@privs);
        my $password = &_passwd($uid,$user,$client);

        $ftp_add->execute($uid,$user,$dir,$password,$privs) or do {
                return "Cannot add user '$user' to database, already exists. Report a bug to admins.";
                my $now = localtime(time);
                print "[$now] BUG! Cannot add user '$user' to database, already exists.\n";
        };
        $event_add->execute($uid,"Added account ($user)");
	return;
}

sub del {
	my($self,@args) = @_;
        my $uid     = $self->{uid};
        my $login   = $self->{login};
        my $client  = $self->{client};
	
	my $ftp_del   = $self->{ftp_del};
	my $event_add = $self->{event_add};

        my $user = shift @args                          or return "Insufficient arguments: Username not specified. Rot in hell!";
           $user =~ /^ftp$uid\_[a-z]{1}[a-z0-9]{1,13}$/ or return "Username is incorrect. Try 'ftp$uid\_name'.";
        -f "/etc/vsftpd/users/$user"                    or return "Username '$user' does not exist. Burn!";
        unlink "/etc/vsftpd/users/$user";

        &_passwd($uid,$user,$client,'del');

        $ftp_del->execute($uid,$user) or do {
                my $now = localtime(time);
                print "[$now] BUG! Cannot del user '$user': database problem.\n";
                return "Cannot del user '$user': database problem. Report a bug to admins.";
        };
        $event_add->execute($uid,"Deleted account ($user)");
	return;
}

sub modify {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
	
	my $ftp_get             = $self->{ftp_get};
	my $ftp_change_password = $self->{ftp_change_password};
	my $ftp_change_privs    = $self->{ftp_change_privs};
	my $event_add           = $self->{event_add};
	
        my $user = shift @args                          or return "Insufficient arguments: Username not specified. Rot in hell!";
           $user =~ /^ftp$uid\_[a-z]{1}[a-z0-9]{1,13}$/ or return "Username is incorrect. Try 'ftp$uid\_name'.";
        -f "/etc/vsftpd/users/$user" 			or return "Username '$user' does not exist. Burn!";

        my $action = $args[0] || 'password';
        given($action) {
                when (/^(password|passwd|pass)$/) {
                        my $password = &_passwd($uid,$user,$client);
                        $ftp_change_password->execute($password,$uid,$user);
                        $event_add->execute($uid,"Changed password ($user)");
                }
                default {
                        $ftp_get->execute($uid,$user);
                        while(my($username,$directory,$password,$privs) = $ftp_get->fetchrow_array) {
                                if($args[0] !~ /^\d+$/) { ## privilege is not a number   
					my @caps = Satan::Tools->caps($privs);
                                        my %caps = map { $_ => 1 } @caps;
                                        foreach my $priv (@args) {
                                                my($no,$num);
                                                given($priv) {
                                                        when (/^(no|)(mkdir|make|dir|create)$/) { $no = $1 ? 1 : 0; $num = 1 }
                                                        when (/^(no|)(delete|remove|rm|del)$/)  { $no = $1 ? 1 : 0; $num = 2 }
                                                        when (/^(no|)(upload|up)$/)             { $no = $1 ? 1 : 0; $num = 4 }
                                                        when (/^(no|)(read)$/)                  { $no = $1 ? 1 : 0; $num = 8 }
                                                        when (/^(no|)(ftpe?s)$/)                { $no = $1 ? 1 : 0; $num = 16 }
                                                        default                                 { return "Unknown privilege: '$priv'. Try again." }
                                                }

                                                if($no) {
                                                        $privs += $num if not $caps{$num};
                                                } else {
                                                        $privs -= $num if $caps{$num};
                                                }
                                        }
                                } else {
                                        $privs = $args[0];
                                        $privs > 31 and return "Privilege value $privs is too high! Try again.";
                                }
                                my @privs = Satan::Tools->caps($privs);
                                &_privs($uid,$login,$client,$username,$directory,@privs);
                                $ftp_change_privs->execute($privs,$uid,$user);
                                $event_add->execute($uid,"Changed privileges to $privs ($user)");
                                last;
                        }
                }
        }
	return;
}

sub list {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
        
	my $ftp_list = $self->{ftp_list};

        $ftp_list->execute($uid);
        my $rows = $ftp_list->rows;
        return "No FTP accounts." unless $rows;

	my $list = "\033[1;32mFTP accounts\033[0m ($rows in total)\n\n";
	my($l_user,$l_dir,$l_password) = (
		length('Username'),
		length('Directory'),
		length('Password')
	);
	my @table;
	while(my($user,$dir,$password,$privs) = $ftp_list->fetchrow_array) {
		$l_user     = length($user)     if length($user)     > $l_user;
		$l_dir      = length($dir)      if length($dir)      > $l_dir;
		$l_password = length($password) if length($password) > $l_password;
		push @table,[$user,$dir,$password,$privs];
	}
	my $top    = "\033[1m" .sprintf("%-${l_user}s","Username")." "x3
		   . sprintf("%-${l_dir}s","Directory")." "x3
		   . sprintf("%-${l_password}s","Password")." "x3
		   . sprintf("%-5s","mkdir")." "x3
		   . sprintf("%-6s","delete")." "x3
		   . sprintf("%-6s","upload")." "x3
		   . sprintf("%-4s","read")." "x3
		   . sprintf("%-5s","ftpes")."\033[0m\n";
	$list .= $top;

	foreach my $line (@table) {
		my($user,$dir,$password,$privs) = @$line;
		my @privs = Satan::Tools->caps($privs);
		my($mkdir,$delete,$upload,$read,$ftpes) = ('yes','yes','yes','yes','yes');
		foreach my $priv (@privs) {
			$priv == 1  and $mkdir  = 'no';
			$priv == 2  and $delete = 'no';
			$priv == 4  and $upload = 'no';
			$priv == 8  and $read   = 'no';
			$priv == 16 and $ftpes  = 'no';
		}
		my $format = sprintf("%-${l_user}s",$user)." "x3
			   . sprintf("%-${l_dir}s",$dir)." "x3
			   . sprintf("%-${l_password}s",$password)." "x3
			   . "\033[1;34m"
			   . sprintf("%-5s"," ".$mkdir)." "x3
			   . sprintf("%-6s","  ".$delete)." "x3
			   . sprintf("%-6s","  ".$upload)." "x3
			   . sprintf("%-4s",$read)." "x3
			   . sprintf("%-5s"," ".$ftpes)."\033[0m\n";
		$list .= $format;
	}
	return $list;
}
	
sub help {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
        my $usage  = "\033[1mSatan :: FTP\033[0m\n\n"
                   . "\033[1;32mSYNTAX\033[0m\n"
                   . "  ftp add <username> <directory> <privs>      add new account\n"
                   . "  ftp del <username>                          remove account\n"
                   . "  ftp list                                    show listing    (default)\n"
                   . "  ftp change <username> password              change password (default)\n"
                   . "  ftp change <username> <privs>               change privileges\n\n"
                   . "Where:\n"
                   . "  <username>  has a format of '\033[1mftp\033[0m\033[1;34mUID\033[0m\033[1m_\033[0m\033[1;34mname\033[0m', e.g. ftp${uid}_fastweb\n"
                   . "  <directory> is an absolute path to directory existing in the filesystem\n"
                   . "  <privs>\n\n"
                   . "\033[1mAvailable privileges\033[0m\n"
                   . "  nomkdir  (1)     no permission to create new directories\n"
                   . "  nodelete (2)     no permission to delete and rename files and directories\n"
                   . "  noupload (4)     no permission to upload files\n"
                   . "  noread   (8)     no permission to read non world readable files\n"
                   . "  noftpes  (16)    no forced SSL\n\n"
                   . "All privileges are enabled by default.\n"
                   . "Numeric value in bracket can be used to set privileges. Default value is 0.\n"
                   . "You can combine privileges by adding values e.g. noupload+noftpes = 20\n\n"
                   . "\033[1;32mEXAMPLE\033[0m\n"
                   . "  satan ftp add ftp${uid}_web ~/fastweb/$login.rootnode.net/htdocs nomkdir nodelete\n"
                   . "  satan ftp add ftp${uid}_upload /home/$login/upload 18\n"
                   . "  satan ftp (default action would be 'list')\n"
                   . "  satan ftp change ftp${uid}_bongo password (password is a keyword here, not actually password)\n"
                   . "  satan ftp change ftp${uid}_bongo mkdir delete noftpes\n"
                   . "  satan ftp change ftp${uid}_upload 0\n";
	return $usage;
}

sub _privs {
        my($uid,$login,$client,$user,$dir,@privs) = @_;
        ## default privs
        my $anon_mkdir_write_enable="YES"; # mkdir
        my $anon_other_write_enable="YES"; # delete
        my $anon_upload_enable="YES";      # upload
        my $anon_world_readable_only="NO"; # read
        my $force_anon_data_ssl="YES";     # ftpes
        my $force_anon_logins_ssl="YES";   # ftpes

        if(@privs == 1 and $privs[0] =~ /^\d+$/) {
                $privs[0] > 31 and return "Privilege value $privs[0] is too high! Try again.";
                @privs = Satan::Tools->caps($privs[0]);
        }
        my $privs=0;
        foreach my $priv (@privs) {
                given($priv) {
                        when (/^(1|(no|)(mkdir|make|dir|create))$/) { last unless $1; $anon_mkdir_write_enable="NO";   $privs+=1; }
                        when (/^(2|(no|)(delete|remove|rm|del))$/)  { last unless $1; $anon_other_write_enable="NO";   $privs+=2; }
                        when (/^(4|(no|)(upload|up))$/)             { last unless $1; $anon_upload_enable="NO";        $privs+=4; }
                        when (/^(8|(no|)(read))$/)                  { last unless $1; $anon_world_readable_only="YES"; $privs+=8; }
                        when (/^(16|(no|)(ftpe?s))$/)               { last unless $1; $force_anon_data_ssl="NO";
                                                                                      $force_anon_logins_ssl="NO";     $privs+=16; }
                        when (/^0$/)                                { 1; }
                        default                                     { return "Unknown privilege: '$priv'. Try again." }
                }
        }
        -l "/etc/vsftpd/users/$user" and return "Cannot create config. Dying.";
        open CONF,">","/etc/vsftpd/users/$user" or die;
        chmod 0600,"/etc/vsftpd/users/$user";
        print CONF "local_root=".$dir."\n";
        print CONF "guest_username=".$login."\n";
        print CONF "anon_mkdir_write_enable=".$anon_mkdir_write_enable."\n";
        print CONF "anon_other_write_enable=".$anon_other_write_enable."\n";
        print CONF "anon_upload_enable=".$anon_upload_enable."\n";
        print CONF "anon_world_readable_only=".$anon_world_readable_only."\n";
        print CONF "force_anon_data_ssl=".$force_anon_data_ssl."\n";
        print CONF "force_anon_logins_ssl=".$force_anon_logins_ssl."\n";
        close CONF;
        return $privs;
}

sub _passwd {
        ## XXX race condition here. Change to db generation when notifyd ready.
        my($uid,$user,$client,$switch) = @_;
        $switch = 'gen' unless defined $switch;

        my($password,$crypt);
        if($switch eq 'gen') {
		while (1) {
	                my $salt = q($1$).int(rand(1e8));
	                print $client "(PASS) \033[1mPassword\033[0m (or press Enter to generate): "."\n";;
	                my $input = <$client>;
	                chomp $input;
	                if(! $input) {
	                        $password = chars(8, 12);
	                        print $client "Your password is \033[1;32m$password\033[0m (copy it to your FTP client)";
	                } else {
	                        $password = $input;
	                        my $bad = IsBadPassword($password);
	                        if($bad) {
	                                #unlink "/etc/vsftpd/users/$user";
	                                print $client "Password too simple: $bad. Try again!\n";
					next;
	                        }
	                }
	                $crypt = crypt($password,$salt);
			last;
		}
        }

        my %passwd;
        if(-f "/etc/vsftpd/passwd") {
                open PASSWD,"<","/etc/vsftpd/passwd" or die "Cannot open /etc/vsftpd/passwd file!\n";
                my @passwd = <PASSWD>;
                close PASSWD;
                foreach my $auth (@passwd) {
                        chomp $auth;
                        my($login,$password) = split(/:/,$auth);
                        next unless defined $login and $password;
                        $passwd{$login} = $password;
                }
        }

        if($switch eq 'del') {
                ## del user
                delete $passwd{$user};
        } else {
                ## add user     
                $passwd{$user} = $crypt;
        }

        my $passwdtmp = "/etc/vsftpd/passwd.$$";
        open PASSWDTMP,">",$passwdtmp;
        chmod 0600,$passwdtmp;
        foreach my $user (sort keys %passwd) {
                print PASSWDTMP $user.':'.$passwd{$user}."\n";
        }
        close PASSWDTMP;
        rename($passwdtmp,"/etc/vsftpd/passwd") or die "Cannot rename passwd file\n";
        return $password;
}

1;
