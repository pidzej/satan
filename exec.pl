#!/usr/bin/perl -l
#
# Satan (exec)
# Shell account service manager
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#

use warnings;
use strict;
use JSON::XS;
use English;
use File::Path qw(make_path remove_tree);
use File::Copy;
use File::Slurp;
use IO::Socket;
use Digest::MD5 qw(md5_base64);
use Readonly;
use FindBin qw($Bin);
use lib $Bin;
use Rootnode::Password qw(apg);
no Smart::Comments;

$|++;
$SIG{CHLD} = 'IGNORE'; # braaaaains!!!

Readonly my $EXEC_HOST => '127.0.0.1';
Readonly my $EXEC_PORT => '999';
Readonly my $EXEC_KEY  => '/home/etc/satan/key';
Readonly my $TEMPLATE_DIR => '/usr/satan/templates';

# json serialization
my $json  = JSON::XS->new->utf8;

# create socket
my $s_exec = IO::Socket::INET->new(
        LocalAddr => $EXEC_HOST,
        LocalPort => $EXEC_PORT,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
) or die "Cannot create socket! $!\n";

# get exec key
-f $EXEC_KEY or die "Cannot find key file ($EXEC_KEY).\n";
open my $fh, '<', $EXEC_KEY or die "Cannot open key file ($EXEC_KEY).\n";
my (undef, $exec_key) = split /\s+/, <$fh>;
chomp $exec_key;
$exec_key = md5_base64($exec_key);

while (my $s_server = $s_exec->accept()) {
	$s_server->autoflush(1);
	
	# spawn child with user privileges
	if (fork() == 0) {
		my ($is_auth, $response);
		SERVER:
		while (<$s_server>) {
			chomp; /^$/ and next SERVER;
			
			# decode request
			my @request = @{ $json->decode($_) };
			
			### Request: @request
			
			my ($auth_key, $uid, $subsystem, $command, @args) = @request;		
			
			# check if authorized
			if ($auth_key ne $exec_key) {
				$response = { status => 401, message => 'Executor: Unauthorized' };
				last SERVER;
			}
	
			# change user
			my $user_name = getpwuid($uid);
			if (defined $user_name) {
				$EGID = $uid;
				$EUID = $uid;
			} 
			else {
				$response = { status => 503, message => "Executor: no such user ($uid) in container" };
				last SERVER;
			}

			# run commands
			my $action = join('_', $subsystem, $command);
			eval {
				$response = __PACKAGE__->$action({ 
					args      => \@args,
					uid       => $uid,
					user_name => $user_name,
				}); 
			} 
			or do {
				$response = { status => 503, message => "Executor: cannot run action $action in container: $@" };
				last SERVER;
			};

			last SERVER;
		}

		print $s_server $json->encode($response);
		close($s_server);

		exit;
	}
}

sub template {
	my ($template_name, $value_of) = @_;

	my $template;

	### Variables: $value_of
	
	# read template file
	my $template_file = "$TEMPLATE_DIR/$template_name.tmpl";

	### $template_file

	if (-f $template_file) {
		open my $fh, '<', $template_file or die "Cannot open template file $template_file";
		local $/;
		$template = <$fh>;
		close $fh;
	} 
	else {
		die "Template $template_name file ($template_file) not found.";
	}
	
	# check if empty template
	if (!$template) {
		die "Template is empty.";
	}

	# convert template
	foreach my $var (keys %$value_of) {
		$template =~ s/%%\Q$var\E%%/$value_of->{$var}/gi;
		delete $value_of->{$var};
	}
	
	# check if all variables used
	if (%$value_of) {
		die "Not enough variables in template. Surplus vars: " . keys %$value_of;
	}
	
	# check if no variables left in template
	if (my @variables_left = $template =~ /%%(.+)%%/) {
        	die "Not all variables from template are changed: ". join(', ', @variables_left);
	}

	### Template: $template;
	return $template;
}

sub vhost_del {
	my ($self, $client) = @_;
	my ($vhost_name) = @{ $client->{args} };
	my $vhost_path = "/home/$client->{user_name}/web/$vhost_name";

	# move vhost directory 
	if (-d $vhost_path) {
		move($vhost_path, $vhost_path.' (deleted)') 
			or return { 
				status => 403,
				message => "Executor: cannot delete directory $vhost_path. Probably permission problem"
			};
	} else {
		return { 
			status => 404, 
			message => "Executor: vhost directory $vhost_path NOT found. Cannot delete" 
		};
	}

	# apache2 config
	my $apache2_config_file = "/etc/apache2/sites-enabled/$vhost_name";
	if (-l $apache2_config_file) {
		unlink $apache2_config_file;	
	}

	# nginx config
	my $nginx_config_file = "/etc/nginx/sites-enabled/$vhost_name";
	if (-l $nginx_config_file) {
		unlink $nginx_config_file;
	}

	return { status => 0, message => 'OK' };	
}

sub ftp_add {
	my ($self, $client) = @_;
	my $uid       = $client->{uid};
	my $user_name = $client->{user_name};
	my ($ftp_user, $ftp_password, $ftp_directory) = @{ $client->{args} };
	
	my $message;
	my $directory_owner = (stat($ftp_directory))[4];

	# Check if absolute path
	if ($ftp_directory !~ /^\// ) {
		$message = "Directory \033[1m$ftp_directory\033[0m must be an absolute path.";
	} 
	# Check if directory exists
	elsif (!-d $ftp_directory) {
		$message = "Directory \033[1m$ftp_directory\033[0m NOT found.";
	}
	# Check owner
	elsif ($directory_owner != $uid) {
		$message = "You are not an owner of \033[1m$ftp_directory\033[0m directory!";
	}

	# Do rollback
	if (defined $message) {
		system("/usr/bin/perl /usr/satan/prod/client.pl ftp del $ftp_user");	
		return { status => 403, message => $message };
	}

	# Restart vsftpd
	system("/usr/bin/sudo /usr/bin/svc -t /etc/service/vsftpd");

	return { status => 0, message => 'OK' };
}

sub vhost_add {
	my ($self, $client) = @_;
	my ($vhost_name) = @{ $client->{args} };
	my $web_path   = "/home/$client->{user_name}/web";
	my $vhost_path = "$web_path/$vhost_name";

	# create web directory
	if (!-d $web_path) {
		mkdir $web_path, 0711 or return { 
			status => 403, 
			message => "Executor: cannot create directory $web_path" 
		};
	}	
	
	# check if deleted vhost directory exists
	my $deleted_vhost_path = "$vhost_path (deleted)";
	if (-d $deleted_vhost_path and !-d $vhost_path) {
		move($deleted_vhost_path, $vhost_path) or return {
			status  => 403, 
			message => "Executor: cannot move $deleted_vhost_path to $vhost_path"
		};
	}
	# both deleted and new directory exists
	elsif (-d $deleted_vhost_path and -d $vhost_path) {
		return { 
			status  => 304,
			message => "Executor: both deleted and new vhost directory exists. Please clean up by yourself"
		};
	}	
	# create vhost directory
	elsif (!-d $vhost_path) {
		mkdir $vhost_path, 0711 or return { 
			status => 403, 
			message => "Executor: cannot create directory $vhost_path" 
		};

		# create vhost subdirectories
		for ( qw(htdocs logs conf) ) {
			my $dir_name = $_;
			mkdir "$vhost_path/$dir_name", 0711 or return { 
				status => 403, 
				message => "Executor: cannot create directory $vhost_path/$dir_name" 
				};
		}
	}

	# generate wordpress key
	my $wordpress_key = apg(8,12);

	# apache2 config
	my $apache2_config_file = "/etc/apache2/sites-available/$vhost_name";

	if (!-f $apache2_config_file) {
		my $apache2_config;
		eval {
			$apache2_config = template('apache2', {
				vhost_name => $vhost_name,
				vhost_path => $vhost_path,
			});
		}
		or do {
			return { status => 500, message => $@ };
		};

		open my $apache2_fh, '>', $apache2_config_file or die $!;
		print $apache2_fh $apache2_config;
		close $apache2_fh;
	}

	symlink("../sites-available/$vhost_name", "/etc/apache2/sites-enabled/$vhost_name") or die;

	# nginx config
	my $nginx_config_file = "/etc/nginx/sites-available/$vhost_name";
	
	if (!-f $nginx_config_file) {
		my $nginx_config;
		eval {
			$nginx_config = template('nginx', {
				vhost_name    => $vhost_name,
				vhost_path    => $vhost_path,
				wordpress_key => $wordpress_key,
			});
		}
		or do {
			return { status => 500, message => $@ };
		};

		### Nginx config: $nginx_config
		
		open my $nginx_fh, '>', $nginx_config_file or die;
		print $nginx_fh $nginx_config;
		close $nginx_fh;
	}

	symlink("../sites-available/$vhost_name", "/etc/nginx/sites-enabled/$vhost_name") or die;

	return { status => 0, message => 'OK' };	
}

exit;
