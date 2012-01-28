#!/usr/bin/perl 

use warnings;
use strict;
use Text::Template;
use DBI;
use feature 'switch';
use Data::Dumper;
use Email::Send;
use Encode::MIME::Header;
use Encode qw{encode decode};
use DateTime;
use FindBin qw($Bin);
use lib "$Bin/..";
binmode(STDOUT,':utf8');

use Satan::Invoice;
use Satan::Tools;
$|++;

my $dbh_pay    = DBI->connect("dbi:mysql:my6667_pay;mysql_read_default_file=/root/.my.pay.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 0});
my $dbh_system = DBI->connect("dbi:mysql:rootnode;mysql_read_default_file=/root/.my.system.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 0 });
$dbh_system->{mysql_auto_reconnect} = 1;
$dbh_system->{mysql_enable_utf8}    = 1;
$dbh_pay->{mysql_auto_reconnect} = 1;
$dbh_pay->{mysql_enable_utf8}    = 1;

my $payu_get  = $dbh_pay->prepare("SELECT login, trans_id, trans_amount, trans_desc2, trans_pay_type, DATE(trans_create), UNIX_TIMESTAMP(trans_create) FROM payu WHERE trans_status=99 AND trans_pay_type != 't' AND done=0");
my $payu_done = $dbh_pay->prepare("UPDATE payu SET done=1 WHERE trans_id=?");
my $payu_fix  = $dbh_pay->prepare("UPDATE payu SET trans_desc2=? WHERE trans_amount=? AND trans_desc2='' AND trans_status=99");

my $payment_add  = $dbh_system->prepare("INSERT INTO payments(uid,trans_id,date,type,bank,amount,currency) VALUES (?,?,?,?,?,?,?)");
my $payment_get  = $dbh_system->prepare("SELECT id FROM payments WHERE trans_id=?");
my $user_get     = $dbh_system->prepare("SELECT id,uid,mail,lang,UNIX_TIMESTAMP(valid),block,del,type FROM users LEFT JOIN uids USING(id) WHERE login=?");
my $uid_update   = $dbh_system->prepare("UPDATE uids SET block=0, del=0, shell=IF(shell='/bin/blocked','/bin/bash',shell), valid=? WHERE uid=?");
my $user_update  = $dbh_system->prepare("UPDATE users SET discount=0 WHERE id=?");
my $event_add    = $dbh_system->prepare("INSERT INTO events(uid,date,daemon,event) VALUES(?,NOW(),'adduser',?)");

# fix
$payu_fix->execute('year',15498);
$payu_fix->execute('quarter',4649);

# payu
$payu_get->execute;
while(my($login,$trans_id,$trans_amount, $trans_desc2, $trans_pay_type, $date, $date_epoch) = $payu_get->fetchrow_array) {
#	print $login."\n";
#	next unless $login eq 'ahes';

	# add dot to price
	my $amount = $trans_amount;
	   $amount =~ s/(\d\d)$/\.$1/;
	   $amount =~ s/^\./0\./;
	
	# set period 
	my $period;
	given($trans_desc2) {
		when('year')    { $period = 12 }
		when('quarter') { $period =  3 }
		default         { die "No desc2. Cannot set period" }
	}

	# check if payment exists
	$payment_get->execute($trans_id);
	if($payment_get->rows) {
		#$payu_done->execute->$trans_id;
		print "payment exists\n";
		next;
	}

	# check if user exists
	$user_get->execute($login);
	if(!$user_get->rows) {
		# adduser
		# we need to add user
		print "we need to add user";
	}

	my($subject,$body);
	my($id,$uid,$mail,$lang,$valid_epoch,$block,$del,$type) = @{$user_get->fetchrow_arrayref};

	# calculate new expire date	
	my $start_date;
	my $dt1 = DateTime->from_epoch(epoch=>$valid_epoch);
	my $dt2 = DateTime->now;
	my $sub = $dt2->subtract_datetime($dt1);
	
	if($sub->in_units('months') > 0) {
		# greater than 1 month	
		$start_date = $date_epoch; # start date = payment date
	} else {
		$start_date = $valid_epoch; # start date = valid date
	}

	my $valid = DateTime->from_epoch(epoch=>$start_date)->add(months=>$period, days=>1)->ymd;	

	if($block and $del) {
		# undel
		print 'need to be undeleted';
		next;
	} else {
		# prolong
		if(lc $lang eq 'pl') {
			$subject = "Rootnode - płatność zaakceptowana ($login)";
			$body = "Otrzymaliśmy twoją opłatę w wysokości ${amount}zł za konto '${login}' na Rootnode.\n"
			      . "Konto wygasa ${valid}.\n\n"
			      . "Dziękujemy.\n\n"
			      . "-- \nKochani Administratorzy\n"; 
		} else {
			$subject = "Rootnode - payment accepted ($login)";
			$body = "We have received your payment of ${amount}zl for '${login}' account on Rootnode.\n"
			      . "Account expires at ${valid}.\n\n"
			      . "Thank you.\n\n"
			      . "-- \nBeloved Administrators\n";
		}
	}

	my $headers = "To: $mail\n"
	            . "From: Rootnode <admins\@rootnode.net>\n"
	            . "Subject: ".encode("MIME-Header", decode('utf8', $subject))."\n"
	            . "MIME-Version: 1.0\n"
	            . "Content-Type: text/plain; charset=utf-8\n"
	            . "Content-Disposition: inline\n"
	            . "Content-Transfer-Encoding: 8bit\n"
	            . "X-Rootnode-Powered: God bless those who read headers!\n\n";
	
	my $message = decode('utf8', $headers.$body);
	
	$payment_add->execute($uid,$trans_id,$date,'payu',$trans_pay_type,$amount,'PLN');
	$payu_done->execute($trans_id);
	$uid_update->execute($valid, $uid);
	$user_update->execute($id);

	# invoice
	if($type eq 'company') {
		$payment_get->execute($trans_id);
		my $payment_id = $payment_get->fetchrow_array;	
		my $invoice = Satan::Invoice->new(dbh_system=>$dbh_system, payment_id => $payment_id);
		$invoice->add or die;
		$invoice->create;
		$invoice->send;
	}
	
	my $sender = Email::Send->new({mailer => 'SMTP'});
           $sender->mailer_args([Host => 'mail1.rootnode.net']);
       
	my $status = $sender->send($message) ? "Message sent to $mail" : "Message NOT sent to $mail.";
        $event_add->execute($uid,$status);
}
$dbh_system->commit;
$dbh_pay->commit;

# reload passwd
if($payu_get->rows) {
	system("/usr/local/sbin/passwd.pl");
}
