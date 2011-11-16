#!/usr/bin/perl
# ahes

use warnings;
use strict;
use Email::Send;
use Encode::MIME::Header;
use Encode qw{encode decode};
use utf8;
use DBI;
use FindBin qw($Bin);
use lib "$Bin/..";
use Satan::Account;
use Satan::Invoice;
$|++;

my $dbh_system = DBI->connect("dbi:mysql:rootnode;mysql_read_default_file=/root/.my.system.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 1 });
$dbh_system->{mysql_auto_reconnect} = 1;
$dbh_system->{mysql_enable_utf8}    = 1;

my $payment_get = $dbh_system->prepare("SELECT p.id,p.uid,login,p.date,p.type,p.bank,p.amount,p.currency FROM payments p LEFT JOIN uids ON p.uid=uids.uid WHERE p.id=?");

my $payment_id = shift or die "Usage: $0 payment_id\n";
$payment_get->execute($payment_id);
die "No such payment.\n" unless $payment_get->rows;
my $payment = $payment_get->fetchall_hashref('id');
   $payment = $payment->{$payment_id};

map { print $payment->{$_}."\t" } qw(id uid login date type bank amount currency);
print "\nProceed? ";
<STDIN>;
my $invoice = Satan::Invoice->new(dbh_system=>$dbh_system, payment_id => $payment_id);
   $invoice->add or die "Invoice exists.\n";
   $invoice->create;
   $invoice->send;

#select payments.id from payments LEFT JOIN invoice ON payments.id=invoice.payment_id LEFT JOIN uids ON payments.uid=uids.uid LEFT JOIN users on uids.id=users.id where trans_id IS NOT NULL AND bank != 't' AND users.type='company' AND invoice.was_sent is null;
