#!/usr/bin/perl

## Satan::Invoice
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

package Satan::Invoice;

use Satan::Tools qw(caps);
use IO::Socket;
use DBI;
use POSIX;
use Data::Dumper;
use Net::Domain qw(hostname);
use File::Path qw(make_path);
use feature 'switch';
use utf8;
use warnings;
use strict;
$|++;

use YAML;
use JSON;
use REST::Client;
use FindBin qw($Bin);
use Data::Dumper;

sub new {
	my $class = shift;
	my $self = { @_	};

	my $config_file = "../config/invoice.yaml";
	-f $config_file or die "Config file $config_file not found!\n";
	my $config = YAML::LoadFile($config_file);

	$self->{rest} = REST::Client->new();
	$self->{rest}->setHost('https://'.$config->{login}.':'.$config->{password}.'@'.$config->{host});
	$self->{dir} = $config->{directory};

	my $dbh_system = $self->{dbh_system};	

	$self->{invoice_add}     = $dbh_system->prepare("INSERT INTO invoice(id,uid,payment_id,date,price_net,tax_rate,price_gross,currency,login,name,address1,address2,tax_id,mail,lang) 
	                                                 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
	$self->{invoice_get}     = $dbh_system->prepare("SELECT * FROM invoice WHERE payment_id=?");
	$self->{invoice_last_id} = $dbh_system->prepare("SELECT id FROM invoice WHERE MONTH(date) = ? AND YEAR(date) = ? ORDER BY id DESC LIMIT 1");
	$self->{invoice_send}    = $dbh_system->prepare("UPDATE invoice SET was_sent=1 WHERE payment_id=?");
	$self->{user_get}        = $dbh_system->prepare("SELECT uid,login,company,address,postcode,city,country,vat,mail,lang 
	                                                 FROM uids LEFT JOIN users USING(id) where type='company' AND uid=?");
	$self->{payment_get}     = $dbh_system->prepare("SELECT id, uid, date, amount, currency FROM payments WHERE id=?");

	#$self->{event_add}       = $dbh_system->prepare("INSERT INTO events(uid,date,daemon,event,previous,current) VALUES(?,NOW(),'account',?,?,?)");
	
	bless $self, $class;
	return $self;
}

sub add {
	my $self = shift;
	my $rest = $self->{rest};

	my $payment_id  = $self->{payment_id};
	my $invoice_add = $self->{invoice_add};

	# get payment
	$self->{payment_get}->execute($payment_id);
	my $payment = $self->{payment_get}->fetchall_hashref('id');
	   $payment = $payment->{$payment_id};

	($payment->{year},$payment->{month},$payment->{day}) = split('-',$payment->{date});

	# get user
	$self->{user_get}->execute($payment->{uid});
	my $user = $self->{user_get}->fetchall_hashref('uid');	
	   $user = $user->{$payment->{uid}};
	
	#die "Wrong account type" unless $user;
	if(!$user) {
		return;
	}

	# check if invoice exists
	$self->{invoice_get}->execute($payment_id);
	if($self->{invoice_get}->rows) {
		return;
	}

	# last id
	$self->{invoice_last_id}->execute($payment->{month},$payment->{year});
	my $invoice_last_id = $self->{invoice_last_id}->fetchrow_array || $payment->{year}.$payment->{month}.'00';
	my $invoice_id = $invoice_last_id+1;
	
	my $tax_rate = $user->{country} =~ /^(BE|BG|CZ|DK|DE|EE|IE|EL|ES|FR|IT|CY|LV|LT|LU|HU|MT|NL|AT|PT|RO|SI|SK|FI|SE|UK)$/i ? 0 : 23;
	my $price = sprintf('%.2f', $payment->{amount} / ($tax_rate/100 + 1));

	my $language = lc $user->{lang} eq 'pl' ? 'pl' : 'en';	

	$invoice_add->execute(
		$invoice_id,
		$user->{uid},
		$payment->{id},
		$payment->{date},
		$price,
		$tax_rate,
		$payment->{amount},
		$payment->{currency},
		$user->{login},
		$user->{company},
		$user->{address},
		$user->{postcode}.' '.$user->{city}.', '.$user->{country},
		$user->{vat},
		$user->{mail},
		$language
	) or die;

	return 1;
}				
sub create {
	my $self = shift;

	my $rest       = $self->{rest};
	my $payment_id = $self->{payment_id};

	my $invoice_get = $self->{invoice_get};
	   $invoice_get->execute($payment_id);

	my $invoice = $invoice_get->fetchall_hashref('payment_id');
	   $invoice = $invoice->{$payment_id};

	my $description  = $invoice->{lang} eq 'pl' ? 'Konto shellowe' : 'Shell account';
	   $description .= ' ('.$invoice->{login}.')';

	my $invoice_json = {
		invoice_id       => 'RN/'.$invoice->{id},
		type             => 'invoice',
		auto_numbering   => 0,
		invoice_type     => 'regular',
		status           => 'raised',
		currency_symbol  => $invoice->{currency},
		language         => $invoice->{lang},
		customer_name    => $invoice->{name},
		customer_address => $invoice->{address1}."\n".$invoice->{address2},
		customer_tax_id  => $invoice->{tax_id},
		customer_email   => $invoice->{mail},
		date             => $invoice->{date},
		date_raised      => $invoice->{date},
		payment_due      => 0,
		items => [{
			description => $description,
			unit_price  => $invoice->{price_net},
			unit        => 'u',
			amount      => 1,
			tax_rate    => $invoice->{tax_rate},
			product_id  => '72.30.23'
		}]
	};

	$rest->POST('/api/1.0/invoices/?format=json', to_json($invoice_json, {utf8=>1}), {'Content-Type' => 'application/json' });
	
	if($rest->responseCode != 200) {
		die $rest->responseContent();
	}

	my $response = from_json($rest->responseContent());
	my $resource_uri = $response->{resource_uri};

	# save to file
	$rest->GET($resource_uri.'/?format=pdf&parts=copy');
	
	if($rest->responseCode != 200) {
		die $rest->responseContent();
	}
	
	my $invoice_pdf = $rest->responseContent();

	my $dir = $self->{dir};
	if(! -d $dir) {
		die "Path $dir does not exist\n";
	}

	my($dir_year,$dir_month) = $invoice->{id} =~ /^(\d{4})(\d{2})\d+$/;
	if(! -d "$dir/$dir_year/$dir_month") {
		make_path("$dir/$dir_year/$dir_month");
	}

	open INVOICE, '>', "$dir/$dir_year/$dir_month/RN".$invoice->{id}.'_'.$invoice->{login}.'.pdf';
	print INVOICE $invoice_pdf;
	close INVOICE;
	
	$self->{resource_uri} = $resource_uri;
	return 1;
}

sub send {
	my $self = shift;

	my $rest         = $self->{rest};
	my $payment_id   = $self->{payment_id};
	my $resource_uri = $self->{resource_uri};

	my $payment_get  = $self->{payment_get};
	my $user_get     = $self->{user_get};
	my $invoice_send = $self->{invoice_send}; 

	$payment_get->execute($payment_id);
	my $payment = $payment_get->fetchall_hashref('id');
	   $payment = $payment->{$payment_id};	

	my $uid = $payment->{uid};

	$user_get->execute($uid);
	my $user = $user_get->fetchall_hashref('uid');
	   $user = $user->{$uid};

	my($description,$body);
	given($user->{lang}) {
		when('pl') {
			$description = 'Konto shellowe';
			$body = "W załączniku znajdziesz swoją fakturę.\nRzuć okiem, czy wszystkie dane się zgadzają.\n\n"
			      . "Dostęp do faktur archiwalnych możliwy za pomocą polecenia:\nsatan account invoice";
		}
		default { 
			$description = 'Shell account';
			$body = "You will find your invoice in attachment.\nTake a look if everything is correct.\n\n"
			      . "To get archive invoices please use following command:\nsatan account invoice";
		}	
	}
	
	$description .= ' ('.$user->{login}.')';

	my $mail_json = {
		body   => $body,
		type   => 'invoice',
		parts  => ['original'],
		emails => [ 'marcin@rootnode.net', $user->{mail} ],
		with_accounts_info => 0
	};	

	# send e-mail
	$rest->POST($resource_uri.'email/', to_json($mail_json, {utf8=>1}), {'Content-Type' => 'application/json' });	
	if($rest->responseCode != 200) {
		die $rest->responseContent();
	}

	$invoice_send->execute($payment_id);

	return 1;
}

sub DESTROY {
	my $self = shift;

	my $rest         = $self->{rest};
	my $resource_uri = $self->{resource_uri};
	$rest->DELETE($resource_uri);
	return 1;
}

	
1;
=schema
DROP TABLE IF EXISTS invoice;
CREATE TABLE invoice (
	id INT UNSIGNED,
	uid SMALLINT UNSIGNED NOT NULL,
	payment_id INT UNSIGNED NOT NULL,
	date DATE NOT NULL, 
	price_net float(5,2) NOT NULL,
	tax_rate TINYINT UNSIGNED NOT NULL,
	price_gross float(5,2) NOT NULL,
	currency ENUM('PLN','EUR','GBP','USD'),
	login VARCHAR(20) NOT NULL,
	name VARCHAR(128) NOT NULL,
	address1 VARCHAR(128) NOT NULL,
	address2 VARCHAR(128) NOT NULL,
	tax_id VARCHAR(30) NOT NULL,
	mail VARCHAR(60) NOT NULL,
	lang CHAR(2) NOT NULL,
	was_sent BOOLEAN DEFAULT 0,
	PRIMARY KEY(id),
	KEY(date),
	KEY(payment_id),
	KEY(uid)
) ENGINE=InnoDB, CHARACTER SET=utf8;

=cut	
