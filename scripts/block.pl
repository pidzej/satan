#!/usr/bin/perl
# ahes

use warnings;
use strict;
use lib '/home/ahes/rootnode/satan/';
use Satan::Account;
use Email::Send;
use Encode::MIME::Header;
use Encode qw{encode decode};
use DBI;
$|++;

my $dbh_pay    = DBI->connect("dbi:mysql:my6667_pay;mysql_read_default_file=/root/.my.pay.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 1});
my $dbh_system = DBI->connect("dbi:mysql:rootnode;mysql_read_default_file=/root/.my.system.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 1 });

my $uid_reminder_get = $dbh_system->prepare("SELECT uid,login,mail,type,lang,valid FROM uids LEFT JOIN users USING(id) WHERE DATE_ADD(CURDATE(),INTERVAL ? DAY) = valid");
my $uid_block_get    = $dbh_system->prepare("SELECT ui.uid,ui.login,u.mail,u.type,u.lang FROM uids ui JOIN users u USING(id) WHERE block=0 AND valid < CURDATE()");
my $uid_block        = $dbh_system->prepare("UPDATE uids SET shell='/bin/blocked',block=1 WHERE uid=?");
my $uid_delete       = $dbh_system->prepare("UPDATE uids SET del=1 WHERE valid < DATE_SUB(CURDATE(), INTERVAL 30 DAY) AND block=1 AND special=0");
my $event_add        = $dbh_system->prepare("INSERT INTO events(uid,date,daemon,event) VALUES(?,NOW(),?,?)");
my $payu_user_get    = $dbh_pay->prepare("SELECT id FROM user WHERE login=?");

sub get_url {
	my($login,$uid) = @_;
	$payu_user_get->execute($login);
	if($payu_user_get->rows) {
		# url exists
		my $id = $payu_user_get->fetchrow_array;
		return 'https://rootnode.net/pay/'.$id;
	} else {
		# generate url
		my $account = Satan::Account->new(
			login      => $login, 
			uid        => $uid, 
			dbh_system => $dbh_system, 
			dbh_pay    => $dbh_pay
		);
		return $account->pay;
	}		
}

# Reminder message
foreach my $days (30,20,10,7,1) {
	$uid_reminder_get->execute($days);
	while(my($uid,$login,$mail,$type,$lang,$valid) = $uid_reminder_get->fetchrow_array) {
		#my($uid,$login,$mail,$type,$lang,$valid,$days) = ('6666','ahes','marcin@hlybin.com','person','en','2011-01-01',30);
		print "reminder: $login\n";
		my $url = &get_url($login,$uid);
		my($subject,$body);
		if(lc $lang eq 'pl') {
			my $in_days = $days == 1 ? "JUTRO" : "za $days dni";
			$subject = "Rootnode - konto wygasa $in_days ($login)";
			$body = "Twoje konto na Rootnode wygasa ${valid}.\n"
			      . "Link do płatności: ${url}\n\n"
			      . "Dziękujemy.\n\n"
			      . "-- \nKochani Administratorzy\n";
		} else {
			my $in_days = $days == 1 ? "TOMORROW" : "in $days days";
			$subject = "Rootnode - account expires $in_days ($login)";
			$body = "Your Rootnode account expires at ${valid}.\n"
			      . "Payment link: ${url}\n\n"
			      . "Thank you.\n\n"
			      . "-- \nBeloved Administrators\n";
		}

		my $status = &mail($mail,$subject,$body);
		$event_add->execute($uid,'reminder',$status);
	}
}

# Block account
$uid_block_get->execute;
while(my($uid,$login,$mail,$type,$lang) = $uid_block_get->fetchrow_array) {
	#my($uid,$login,$mail,$type,$lang,$valid,$days) = ('6666','ahes','marcin@hlybin.com','person','en','2011-01-01',30);

	print "block: $login\n";
	$uid_block->execute($uid) or die;
	
	my $url = &get_url($login,$uid);
	my($subject,$body);
	if(lc $lang eq 'pl') {
		$subject = "Rootnode - konto zablokowane ($login)";
		$body = "Twoje konto na Rootnode zostało zablokowane.\n"
		      . "Link do płatności: ${url}\n\n"
		      . "Nie pozwól, aby guru był smutny.\n\n"
		      . "-- \nKochani Administratorzy\n";
	} else {
		$subject = "Rootnode - account blocked ($login)";
		$body = "Your Rootnode account has been blocked.\n"
		      . "Payment link: ${url}\n\n"
		      . "Don't let guru be sad.\n\n"
		      . "-- \nBeloved Administrators\n";
	}
	
	my $status = &mail($mail,$subject,$body);
	$event_add->execute($uid,'block',$status);
}

## delete users
$uid_delete->execute;

sub mail {
	my($mail,$subject,$body) = @_;
	my $headers = "To: $mail\n"
		    . "From: Rootnode <admins\@rootnode.net>\n"
		    . "Subject: ".encode("MIME-Header", decode('utf8',$subject))."\n"
		    . "MIME-Version: 1.0\n"
		    . "Content-Type: text/plain; charset=utf-8\n"
		    . "Content-Disposition: inline\n"
		    . "Content-Transfer-Encoding: 8bit\n"
		    . "X-Rootnode-Powered: God bless those who read headers!\n\n";

	my $message = decode('utf8', $headers.$body);
	my $sender = Email::Send->new({mailer => 'SMTP'});
           $sender->mailer_args([Host => 'mail1.rootnode.net']);

        my $status = $sender->send($message) ? "Message sent to $mail" : "Message NOT sent to $mail.";
	return $status;
}
