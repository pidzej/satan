#!/usr/bin/perl

## Satan::Backup
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

# THIS FILE IS DEPRECATED!

package Satan::Backup;

use Satan::Tools qw(caps);
use IO::Socket;
use Cwd qw(abs_path);
use DBI;
use Data::Dumper;
use Net::Domain qw(hostname);
use feature 'switch';
use utf8;
use warnings;
use strict;
$|++;

sub new {
	my $class = shift;
	my $self = { @_	};
	my $dbh_system = $self->{dbh_system};
	
	$self->{backup_add_job}     = $dbh_system->prepare("INSERT INTO backup_jobs(id,uid,name,type,schedule,laststatus,nextstatus,lastbackup,nextbackup)
	                                                    VALUES (?,?,?,?,?,'n/a','scheduled',NULL,DATE_ADD(CURRENT_DATE(),INTERVAL 1 DAY))");
	$self->{backup_del_job}     = $dbh_system->prepare("DELETE FROM backup_jobs WHERE uid=? AND name=?");
	$self->{backup_del_file}    = $dbh_system->prepare("DELETE FROM files USING backup_files files JOIN backup_jobs jobs USING(id) 
	                                                    WHERE jobs.uid=? AND files.fid=?");
	$self->{backup_check_job}   = $dbh_system->prepare("SELECT name,type FROM backup_jobs WHERE uid=? AND name=?");
	$self->{backup_list_jobs}   = $dbh_system->prepare("SELECT name,type,size,CONCAT_WS(' ',CONCAT(SUBSTRING_INDEX(schedule,':',1),'d'),CONCAT(SUBSTRING_INDEX(SUBSTRING_INDEX(schedule, ':', 2),':',-1),'w'),CONCAT(SUBSTRING_INDEX(schedule,':',-1),'m')) as schedule,laststatus,nextstatus,lastbackup,nextbackup FROM backup_jobs WHERE uid=?");
	$self->{backup_list_files}  = $dbh_system->prepare("SELECT files.fid as fid,CONCAT(files.include,' ',files.filename) as filename,files.type as type,files.server as server
	                                                    FROM backup_files files JOIN backup_jobs jobs USING(id) WHERE jobs.uid=? AND jobs.name=?");
	$self->{backup_include}     = $dbh_system->prepare("INSERT INTO backup_files(id,fid,filename,type,server,include) 
	                                                    VALUES((SELECT id FROM backup_jobs WHERE uid=? AND name=?),?,?,?,?,?)");
	$self->{backup_check_file}  = $dbh_system->prepare("SELECT files.fid FROM backup_files files JOIN backup_jobs jobs USING(id) 
	                                                    WHERE jobs.uid=? AND jobs.name=? AND files.filename=? AND files.server=?");
	$self->{vhost_check}        = $dbh_system->prepare("SELECT vhost FROM vhosts WHERE uid=? and vhost=? and version=?");
	bless $self, $class;
	return $self;
}

sub add {
	my($self,@args) = @_;
	my $uid          = $self->{uid};
        my $login        = $self->{login};
	
	my $dbh_system = $self->{dbh_system};
	my $backup_add_job   = $self->{backup_add_job};
	my $backup_check_job = $self->{backup_check_job};

	my $job_name = shift @args         or return "Insufficient arguments: Backup name not specified. Rot in hell!";
	   $job_name = lc $job_name;
	   $job_name =~ /^[a-z]{1}[a-z0-9]{1,13}$/    or return "Backup name '$job_name' is incorrect.\nMaximum length is 14. Cannot start with number. Only letters and numbers allowed.";
	   $job_name eq 'local'           and return "Name 'local' is reserved. Try another one.";
	
	$backup_check_job->execute($uid,$job_name);
	$backup_check_job->rows       and return "Backup '$job_name' already exists! Try another name.";

	my $type = shift @args || 'home';
	   $type =~ /^(home|www|db)$/     or return "Invalid backup type '$type'. Available types are: home, www, db.";

	my $schedule = shift @args || 'lite';
	   $schedule =~ /^(lite|full|\d{1,2}:\d{1,2}:\d{1,2})$/ or return "Invalid backup schedule '$schedule'. Available schedules are: full, lite.";
	   $schedule eq 'full' and $schedule = '7:3:0';
	   $schedule eq 'lite' and $schedule = '3:0:0';
	
	my($schedule_days,$schedule_weeks,$schedule_months) = $schedule =~ /^(\d{1,2}):(\d{1,2}):(\d{1,2})$/;
	   $schedule_days   > 31 and return "You cannot specify more schedule days than 31."; 
	   $schedule_weeks  > 6  and return "You cannot specify more schedule weeks than 6.";
	   $schedule_months > 12 and return "You cannot specify more schedule months than 12.";

	## ssh key
	#my $backup_server_ip = '89.248.171.139'; 
	my $ssh_pubkey = "no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command=\"/usr/local/bin/backup.sh\" " .
	                 "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAppCOimL0L7RUjVSyFubKq9IHkTp12THKNuruEwZAdy4GJE/EZrOJv1znKUUTAlFJbMTDxFJN1EFtsR1DmFLqsT/7k" .
                         "X6JhoQxyqSfP4NIYK9tMTLmJdgUmK9x1yd7Jfu0GgXmNRWihgs/kul5oBB3YX/A7xGtLS0e69/exDwhm4CbQrt/v6VKvNZ1ALK9alNSdLaRZCXp3A10ArwISupPBl" .
                         "rW9ZQzTPG3MrOohrd903dOWx+8DfGT7j1Mr+OXSmZ/QIScbgW4QhmqopT5KpTgloIZZzksbgapTvhYsxRiD0a3y8W4wkHNGUHSjTATpGbLmfcfhFrJuKbaN8DfjBNGxQ==";
	
	my $pid = fork();
	if($pid == 0) {
		$)=$uid; $>=$uid;	
		mkdir "/home/$login/.ssh" unless -d "/home/$login/.ssh";
		open SSH,"+>>","/home/$login/.ssh/authorized_keys";
		seek(SSH,0,0);
		print SSH "$ssh_pubkey\n" unless grep(/\Q$ssh_pubkey\E/,<SSH>);
		close SSH;

		mkdir "/home/$login/.backup" unless -d "/home/$login/.backup";
		my $backup_server = $type eq 'www' ? 'allison' : 'draper';
		symlink "/backup/$backup_server/$login/$job_name", "/home/$login/.backup/$job_name";
		exit;
	}

	my $id = Satan::Tools->id(
		dbh    => $dbh_system,
		column => 'id',
		table  => 'backup_jobs',
		min    => 1
	);

	print "id: $id\n";
	$backup_add_job->execute($id,$uid,$job_name,$type,$schedule);
	waitpid($pid,0);
	return;
}

sub del {
	## Trigger on table 'backups'.
	my($self,@args) = @_;
	my $uid          = $self->{uid};
        my $login        = $self->{login};

	my $backup_del_job   = $self->{backup_del_job};
	my $backup_del_file  = $self->{backup_del_file};
	my $backup_check_job = $self->{backup_check_job};

	my $job_name = shift @args           or return "Insufficient arguments: Backup name not specified. Rot in hell!";
	if($job_name =~ /^\d+$/) {
		## name is file ID (fid)
		$backup_del_file->execute($uid,$job_name);
	} else {
		$job_name = lc $job_name;
		$job_name =~ /^[a-z]{1}[a-z0-9]{1,13}$/ or return "Backup name '$job_name' is incorrect.";
		$job_name eq 'local'                   and return "Deleting local backup is forbidden.";

		$backup_check_job->execute($uid,$job_name);
		$backup_check_job->rows or return "No such backup '$job_name'.";
	
		$backup_del_job->execute($uid,$job_name);
		unlink "/home/$login/.backup/$job_name" if -l "/home/$login/.backup/$job_name";
	}
	return;
}

sub include {
	my($self,$mode,@args) = @_;
	my $uid   = $self->{uid};
	my $login = $self->{login};
	my $pwd   = $self->{pwd};

	my $dbh_system        = $self->{dbh_system};
	my $backup_include    = $self->{backup_include};	
	my $backup_check_job  = $self->{backup_check_job};
	my $backup_check_file = $self->{backup_check_file};
	my $vhost_check       = $self->{vhost_check};

	my $job_name = shift @args            or return "Insufficient arguments: Backup name not specified. Rot in hell!";
	   $job_name = lc $job_name;
	   $job_name =~ /^[a-z]{1}[a-z0-9]{1,13}$/ or return "Backup name '$job_name' is incorrect.";
	   $job_name eq 'local'                   and return "Cannot include files to local backup.";	
	
	$backup_check_job->execute($uid,$job_name);
	$backup_check_job->rows           or return "Backup '$job_name' does not exist!";
	my $backup_type = $backup_check_job->fetchall_hashref('name');
	   $backup_type = $backup_type->{$job_name}->{type};
	
	my $include = $mode eq 'include' ? '+' : '-';

	my $filename = shift @args        or return "Insufficient arguments: File or directory not specified. Rot in hell!";
	my($type,$server);
	given($backup_type) {
		when('db') {
			my $dbname = lc $filename;
			   $dbname =~ /^(my|pg)\Q$uid\E_\w+$/ or return "Incorrect database name '$dbname'.";
			   $type   = $1.'sql';
			
			   $server = shift @args || 'error';
			given($server) {
				when(/^(esr|venema|e|v|web)$/)          { $server = 'esr'    }
				when(/^(lyon|fastweb|l)$/)              { $server = 'lyon'   }
				when(/^(wall|fastweb2|w|ruby|python)$/) { $server = 'wall'   }
				when(/^(pgsql|psql|f|farmer|f|pg)$/)    { $server = 'farmer' }
				default {
					return "Please specify database server name.\n".
					       "MySQL databases: \033[1mesr\033[0m (venema), \033[1mlyon\033[0m (fastweb), \033[1mwall\033[0m (ruby).\n".
					       "PostgreSQL databases: \033[1mfarmer\033[0m (pgsql).\n";
				}
			}
			
		}
		when('home') {
	   		$filename = join('/',$pwd,$filename) if $filename !~ /^\//;
			$filename =~ s/\/$//;
			-l $filename                  and return "Symlinks are forbidden! Sorry.";
			(-d $filename or -f $filename) or return "No such file or directory. Try again.";
			$filename = abs_path($filename);

			if(((stat($filename))[4]) != $uid) {
				my $hoax = `banner burn`;
				return "\033[1;31m".$hoax."\033[0m\033[1mNASTY BOY TRIES TO BACKUP OTHER USERS' FILES!\nPLEASE DIE.\033[0m\n";
			}
			$filename !~ /^\/home\/$login(\/|$)/ and return "Incorrect path for '$backup_type' backup type.";
			$server = hostname;
		        $server =~ /^(stallman|stallman2|korn)$/ or return "Server name '$server' seems to be wrong. Ask administrator for help.";

			$type = 'directory' if -d $filename;
			$type = 'file'      if -f $filename;
		}
		when('www') {
	   		$filename = join('/',$pwd,$filename) if $filename !~ /^\//;
			$filename =~ s/\/$//;
                        -l $filename                  and return "Symlinks are forbidden! Sorry.";
                        (-d $filename or -f $filename) or return "No such file or directory. Try again.";
			$filename = abs_path($filename);

			$type = 'directory' if -d $filename;
			$type = 'file'      if -f $filename;

			my($vhost,$version);
			if($filename =~ /^\/fastweb\/$login\/www\/(.+?)(\/|$)/) {
				$vhost = $1;
				$version = 2;
				$server = 'lyon';
			} elsif($filename =~ /^\/ruby\/$login\/www\/(.+?)(\/|$)/) {
				$vhost = $1;
				$version = 3;
				$server = 'wall';
			} elsif($filename =~ /^\/web\/$login\/www\/(.+?)(\/|$)/) {
				$vhost = $1;
				$version = 1;
				$server = 'venema';
			} else {
				return "For '$backup_type' backup type you cannot add files and directories outside web servers.";
			}
			#$vhost_check->execute($uid,$vhost,$version);
			#$vhost_check->rows or return "Vhost $vhost on $server server does not exist. Better double check.\n";
		}
	}
	$backup_check_file->execute($uid,$job_name,$filename,$server);
	$backup_check_file->rows and return "$filename ($server) already on the list!";	

	# file id
	my $fid = Satan::Tools->id(
		dbh    => $dbh_system,
		column => 'fid',
		table  => 'backup_files',
		min    => 1
	);
	
	$backup_include->execute($uid,$job_name,$fid,$filename,$type,$server,$include) or return "ERROR: Database problem. Please report to administrator."; 
	return;
}

sub list {
	my($self,@args) = @_;
	my $uid   = $self->{uid};
	my $login = $self->{login};

	my $backup_list_jobs  = $self->{backup_list_jobs};
	my $backup_list_files = $self->{backup_list_files};
	my $backup_check_job  = $self->{backup_check_job};

	my $name = shift @args;
	my $listing;
	if(defined $name) {
		## listing of backup files
		$name = lc $name;
		$name =~ /^[a-z]{1}[a-z0-9]{1,13}$/ or return "Backup name '$name' is incorrect.";

		$backup_check_job->execute($uid,$name);
		$backup_check_job->rows or return "No such backup '$name'.";
	
		$backup_list_files->execute($uid,$name);
		$listing = Satan::Tools->listing(
			db      => $backup_list_files,
			title   => "Backup $name",
			header  => ['ID','Filename','Type','Server'],
			columns => [ qw(fid filename type server) ],
		) || "Nothing included yet. Try 'satan backup include'.";
	} else {
		## listing of backup jobs
		$backup_list_jobs->execute($uid);
		$listing = Satan::Tools->listing(
			db      => $backup_list_jobs,
			title   => 'Backups',
			header  => ['Name','Type','Size','Schedule','Last backup','Status','Next backup','Status'],
			columns => [ qw(name type size schedule lastbackup laststatus nextbackup nextstatus) ],
			empty   => { lastbackup => 'never' }
		) || "No backups. Try 'satan backup add' first.";
	}
	return $listing;
}

sub help {
        my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};

	my $usage  = "\033[1mSatan:: Backup\033[0m\n\n"
                   . "\033[1;32mSYNTAX\033[0m\n"
	           . "  backup add <name> [type] [schedule]         add new backup\n"
	           . "  backup del <name>                           delete backup\n"
	           . "  backup del <fileid>                         delete file or directory from include list\n"
	           . "  backup include <name> <file or directory>   include file, directory or database to backup\n" 
                   . "  backup include <name> <database> <server>   include database to backup\n"
	           . "  backup exclude <name> <file or directory>   as above but exclude\n"
	           . "  backup list                                 list backup jobs (default)\n"
	           . "  backup list <name>                          show include/exclude list\n\n"
                   . "\033[1mBackup types\033[0m\n"
	           . "  home (default)      Use it to backup shell servers (stallman2 or korn).\n"
	           . "  www                 Use it to backup web servers (venema, lyon, wall)\n"
	           . "  db                  Use it to backup MySQL and PostgreSQL databases\n\n"
                   . "\033[1mSchedule types\033[0m\n"
	           . "  lite (default)      Alias for schedule 3:0:0 (or keep 3 daily backups)\n"
	           . "  full                Alias for schedule 7:3:0 (or keep 7 daily and 3 weekly backups)\n"
	           . "  d:w:m               Amount of daily, weekly and monthly backups to be stored.\n\n"
		   . "\033[1mNotice\033[0m\n"
	           . "  For security reasons deleted backup is not erased immediately. It takes 30 days.\n"
	           . "  Please do not exceed 10GB of backup space.\n"
	           . "  Plan your schedules wisely. You hardly need 3-month-old files.\n"
	           . "  Backup (read-only) is available in ~/.backup directory\n\n"
                   . "\033[1;32mEXAMPLE\033[0m\n"
	           . "  satan backup add mybackup\n"
	           . "  satan backup add mybackup www 0:3:0\n"
	           . "  satan backup add mydb db lite\n"
	           . "  satan backup add myweb www 3:3:0\n"
	           . "  satan backup include mybackup /home/$login\n"
	           . "  satan backup exclude mybackup /home/$login/bigfiles\n"
	           . "  satan backup include mydb my${uid}_drupal lyon\n"
	           . "  satan backup include myweb fastweb/my.vhost.com/htdocs\n"
	           . "  satan backup list\n"
	           . "  satan backup list mybackup\n";
        return $usage;
}

1;
