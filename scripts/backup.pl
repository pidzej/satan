#!/usr/bin/perl -l

## Satan backup generator
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

# THIS FILE IS DEPRECATED!

use warnings;
use strict;
use DBI;
use File::Temp qw(tempfile);
use File::Path qw(rmtree);
use File::Copy qw(mv);
use Date::Parse;
use POSIX qw(strftime);
use Email::Send;
use Encode::MIME::Header;
use Encode qw(encode decode);
use Data::Dumper;
use feature 'switch';

my $hostname = `hostname -s`;
chomp $hostname;
open STDERR,">>","/adm/backup/error.log";
chmod 0600,"/adm/backup/error.log";
`date >&2`;
my $lock="/adm/backup/lock";
if(-e $lock) {
	my $message;
	$message .= "To: marcin\@rootnode.net\n";
        $message .= "From: backup\@$hostname.rootnode.net\n";
        $message .= "Subject: Backup locked ($hostname)!\n";
        $message .= "MIME-Version: 1.0\n";
        $message .= "Content-Type: text/plain; charset=utf-8\n";
        $message .= "Content-Disposition: inline\n";
        $message .= "Content-Transfer-Encoding: 8bit\n";
        $message .= "\n";
        $message .= "Backup locked on $hostname.";
	my $mail = Email::Send->new({mailer => 'SMTP'});
        $mail->mailer_args([Host => 'mail1.rootnode.net']);
        $mail->send(decode('utf8',$message));
	exit;
} else {
	open LOCK,">",$lock;
	print LOCK time;
	close LOCK;
}
my $gid=100;
my $tmpdir = "/adm/backup/tmp";
rmtree("$tmpdir") if -d $tmpdir;
umask 0077;
mkdir $tmpdir;

# DBI
my $dbh_system = DBI->connect("dbi:mysql:rootnode;mysql_read_default_file=/adm/backup/.my.system.cnf",undef,undef,{ RaiseError => 1, PrintError => 1, AutoCommit => 1 });
$dbh_system->{mysql_auto_reconnect} = 1;
$dbh_system->{mysql_enable_utf8} = 1;

my $backup_get_jobs    = $dbh_system->prepare("SELECT uid,id,name,type,schedule,nextbackup FROM backup_jobs WHERE DATE(nextbackup) = CURRENT_DATE() AND nextstatus='scheduled' ORDER BY nextbackup");
my $backup_get_files   = $dbh_system->prepare("SELECT filename,type,server,include from backup_files WHERE id=?");
my $backup_set_done    = $dbh_system->prepare("UPDATE backup_jobs
                                               SET laststatus='done', nextstatus='scheduled', lastbackup=NOW(), nextbackup=DATE_ADD(NOW(),INTERVAL 1 day), size=? 
                                               WHERE id=?");
my $backup_set_fail    = $dbh_system->prepare("UPDATE backup_jobs 
                                               SET laststatus=?, nextstatus='scheduled', lastbackup=NOW(), nextbackup=DATE_ADD(nextbackup,INTERVAL 1 day) 
                                               WHERE id=?");
my $backup_set_running = $dbh_system->prepare("UPDATE backup_jobs SET nextstatus='running' WHERE id=?");
my $backup_get_names   = $dbh_system->prepare("SELECT name FROM backup_jobs WHERE uid=?");

## main
$backup_get_jobs->execute;
while(my($uid,$id,$name,$type,$schedule,$nextbackup) = $backup_get_jobs->fetchrow_array) {
	## split tasks to servers
	## XXX temporarily disabled because draper is down
#	next if $hostname eq 'draper'  and $type !~ /^(home|db)$/;
#	next if $hostname eq 'allison' and $type !~ /^(www)$/;

	## get login
	my $login = getpwuid($uid) or do {
		$backup_set_fail->execute('nouser',$id);
		warn "WARNING! No user for uid $uid\n";
        	next;
        };

	my $dir = "/backup/users/$login/$name";
	umask 0077;
	if(! -d $dir) {
		mkdir $dir;
		chown $uid,$gid,$dir;
	}
	chdir $dir;

	my $date = strftime('%Y%m%d_%H%M',localtime);
	my %schedule;
	($schedule{daily},$schedule{weekly},$schedule{monthly}) = split(/:/,$schedule);

	my %last;
	foreach my $type (sort keys %schedule) {
		my @dirs = sort glob($type.'.*');
		next unless @dirs;

		## delete old directories
		for($schedule{$type}..@dirs) {
			my $dir = shift @dirs;
			print "dir to delete: $dir\n";
			rmtree($dir);
		}

		if(@dirs) {
			%last = split(/\./,pop @dirs) if @dirs;
		}
	}
	
	my @errors;
	my $is_ok;
	given($type) {
		when(/^(home|www)$/) {
			## create exclude lists
			my(%filename, %parent, %list);
			$backup_get_files->execute($id);
			while(my($filename,$type,$server,$include) = $backup_get_files->fetchrow_array) {
				$filename =~ s/\/$//;
				$filename =~ s/\\ / /g;
				given($server) {
					when('lyon')   { $parent{$server} = "/fastweb/$login/www" }
					when('wall')   { $parent{$server} = "/ruby/$login/www"    }
					when('venema') { $parent{$server} = "/web/$login/www"     }
					default        { $parent{$server} = "/home/$login"        }
				}
				
				## backup home directory only
				if($filename =~ /^\Q$parent{$server}\E$/) {
					push @{$list{$server}}, $include." *\n";
					next;
				}
				my  @path = split(/\//,$filename);
				shift @path; #first element always empty
				if($include eq '+') {
					my $last = '';
					## go down the path
					foreach my $directory (@path) {
						$last = join('/', $last, $directory);
						push @{$list{$server}}, join(' ',$include, $last);
					}
					## glob for directories
					push @{$list{$server}}, join(' ', $include, $filename)."/**" if $type eq 'directory';
				} else {
					push @{$list{$server}}, join(' ', $include, $filename) if $type eq 'directory';
				}
				push @{$list{$server}}, join(' ', $include, $filename) if $type eq 'file';
			}

			foreach my $server (keys %list) {
				my @parts = split(/\//,$parent{$server});
				shift @parts; ## first element is empty
				my @list = @{$list{$server}};
				
				## make paths relative
				my $lastdir;
				foreach my $dir (@parts) {
					$lastdir .= '/'.$dir;
					s/^[+-] \Q$lastdir\E$// for @list; 
				}
				s/^([+-]) \Q$parent{$server}\E\//$1 / for @list;
				
				## remove duplicates
				my %saw; @list = grep(!$saw{$_}++, @list);
				my($fh, $tmpfile) = tempfile($login."_".$server."_XXXXXXXXXX", DIR => $tmpdir);
				$filename{$server} = $tmpfile;

				## print list to file
				/^-/  && print $fh $_."\n" for @list;
				/^\+/ && print $fh $_."\n" for @list;
					 print $fh "- *\n";
			}

			## run rsync
			if(%last) {
				my @last = sort { $last{$a} cmp $last{$b} } keys %last;
				my $last = $last[0];
				my $src  = $last.'.'.$last{$last};
				#print "system(\"nice cp -al $src tmp\")\n";
				system("nice cp -al $src tmp");
			}

			foreach my $server (keys %filename) {
				## check SSH key
				system("ssh -oPasswordAuthentication=no -oStrictHostKeyChecking=no -i /adm/backup/backup.key $login\@$server.rootnode.net exit > /dev/null 2>&1");
				if($?) {
					push @errors, "nokey ($server)";
					next;
				} 

				#print "system(\"nice rsync -a --del -e 'ssh -i /adm/backup/backup.key' --exclude-from=$filename{$server} $login\@$server.rootnode.net:$parent{$server}/ $dir/tmp\");\n";
				system("nice rsync -a --del -e 'ssh -i /adm/backup/backup.key' --exclude-from=$filename{$server} $login\@$server.rootnode.net:$parent{$server}/ $dir/tmp");
				if($? != 0 and $? != 24) {
					push @errors, "failed ($server)";
					next;
				}          
				$is_ok++;      
			}	
		}
		when('db') {
			if(!-d "$dir/tmp") {
				mkdir "$dir/tmp";
				chown $uid,$gid,"$dir/tmp";
			}
			$backup_get_files->execute($id);
			while(my($filename,$type,$server,$include) = $backup_get_files->fetchrow_array) {
				next unless $filename =~ /^(my|pg)\Q$uid\E_\w+$/;
				my $serverdir = "$dir/tmp/$server";
				if(!-d $serverdir) {
					mkdir $serverdir;
					chown $uid,$gid,$serverdir;
				}
				my $output = "$dir/tmp/$server/$filename.sql";
				#print "mysqldump $filename to $output, type $type\n";
				$type eq 'mysql' && system("/usr/local/mysql/bin/mysqldump --defaults-extra-file=/adm/backup/.my.$server.cnf --opt $filename > $output");
				$type eq 'pgsql' && system("PGPASSFILE=/adm/backup/.pg.$server.cnf /usr/bin/pg_dump -h $server.rootnode.net -U postgres $filename -f $output");	
				chown $uid,$gid,$output;
				if($?) {
					push @errors, "failed ($filename\@$server)";
					next;
				}
				$is_ok++;
			}
		}
	}

	## backup set fail 
	if(@errors) {
		my $error = join(', ',@errors);
		$backup_set_fail->execute($error,$id);
	}
	
	## at least one must be ok
	unless($is_ok) {
		rmtree("tmp");
		next;
	}

	## daily
	if($schedule{daily} > 0) {
		# cp tmp daily.		
		my $dest = 'daily.'.$date;
		system("nice cp -al tmp $dest");
	} 

	## weekly
	if($schedule{weekly} > 0 and not defined $last{weekly}) {
		my $dest = 'weekly.'.$date;
		system("nice cp -al tmp $dest");
	} elsif($schedule{weekly} > 0) {
		# count date
		my($last) = split(/_/,$last{weekly});
		   $last = str2time($last);
		
		my($now) = $date =~ /^(\d{8})_\d{4}$/;
		   $now  = str2time($now);

		my $days = int(($now-$last)/(60*60*24));
		if($days >= 7) {
			my $dest = 'weekly.'.$date;
			system("nice cp -al tmp $dest");
		}		
	}
	
	## monthly
	if($schedule{monthly} > 0 and not defined $last{monthly}) {
		my $dest = 'monthly.'.$date;
		system("nice cp -al tmp $dest");
	} elsif($schedule{monthly} > 0) {
		my($last) = $last{monthly} =~ /^(\d{4}\d{2})\d{2}_\d{4}$/;
		my($now)  = $date =~ /^(\d{4}\d{2})\d{2}_\d{4}$/;

		if($now != $last) {
			my $dest = 'monthly.'.$date;
			system("nice cp -al tmp $dest");
		}	
	}
	
	rmtree('tmp');

	## calulate size
	open DU, "nice du -hs $dir 2>/dev/null | awk '{print \$1}' |";
	my $size = <DU>;
	chomp $size;
	close DU;
	$backup_set_done->execute($size,$id) unless @errors;
}


## remove unused backups
chdir "/backup/users";
while(<*>) {
	my $login = $_;
	#next unless $login eq 'ahes';
	next unless -d $login;
	my $uid = getpwnam($login) or next;
	$backup_get_names->execute($uid);
	my $backup = $backup_get_names->fetchall_hashref('name');
	chdir $login;
	while(<*>) {
		my $name = $_;
		next unless -d $name;
		next if defined $backup->{$name};
		my $mtime = (stat($name))[9];
		if(time-$mtime > 60*60*24*30) {
			rmtree($name);			
		}
	}
}

unlink $lock;
close STDERR;
