#!/usr/bin/perl

## Satan::Account
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

package Satan::Account;

use Satan::Invoice;
use Satan::Tools qw(caps);
use IO::Socket;
use DBI;
use POSIX;
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
	my $dbh_pay    = $self->{dbh_pay};

	$self->{account_show_user}     = $dbh_system->prepare("SELECT id,login,firstname,lastname,lang,type,vat,phone,company,address,postcode,city,country,mail,discount,users.date 
                                                               FROM users JOIN uids USING(id) WHERE uid=?");
	$self->{account_show_accounts} = $dbh_system->prepare("SELECT uid,login,shell,server,date,valid,block,special,sponsor,test
	                                                       FROM uids where id=?");
	$self->{account_show_payments} = $dbh_system->prepare("SELECT date,type,amount,currency FROM payments WHERE uid=? ORDER BY date DESC");

	$self->{account_update_user}   = $dbh_system->prepare("UPDATE users SET firstname=?,lastname=?,lang=?,type=?,vat=?,phone=?,mail=?,company=?,
	                                                                        address=?,postcode=?,city=?,country=? WHERE id=?");
	$self->{invoice_get}           = $dbh_system->prepare("SELECT payment_id FROM invoice WHERE uid=? AND id=?");
	$self->{invoice_get_all}       = $dbh_system->prepare("SELECT id,date,price_net,CONCAT(tax_rate,'%') AS tax_rate,price_gross,currency FROM invoice WHERE uid=? ORDER BY id DESC"); 
	$self->{event_add}             = $dbh_system->prepare("INSERT INTO events(uid,date,daemon,event,previous,current) VALUES(?,NOW(),'account',?,?,?)");	
	
	$self->{pay_user_add}          = $dbh_pay->prepare("REPLACE INTO user(id,login,amount,period,first_name,last_name,mail,lang) VALUES(?,?,?,?,?,?,?,?)");
	
	bless $self, $class;
	return $self;
}

sub show {
	my($self,@args) = @_;
	my $uid          = $self->{uid};
        my $login        = $self->{login};
	
	my $dbh_system            = $self->{dbh_system};
	my $account_show_user     = $self->{account_show_user};
	my $account_show_accounts = $self->{account_show_accounts};
	my $account_show_payments = $self->{account_show_payments};

	$account_show_user->execute($uid);
	my $output;	
	while(my $u = $account_show_user->fetchrow_hashref) {
                my $id = $u->{id};
                my $type = $u->{type};
                map { $u->{$_} = 'NULL' if not defined $u->{$_} } qw(company vat address postcode city country mail phone lang);

                $output =  "\033[1;32mUser Information\033[0m\n"
		        .  "id: $u->{id} :: type: $u->{type}\n\n"
		        .  "\033[1;30mName:\033[0m     \033[1;37m$u->{firstname} $u->{lastname}\033[0m\n"
		        .  "\033[1;30mLanguage:\033[0m $u->{lang}\n";
		$output .= "\033[1;30mCompany:\033[0m  $u->{company}\n" if $type eq 'company';
		$output .= "\033[1;30mVAT nr:\033[0m   $u->{vat}\n" if $type eq 'company';
		$output .= "\033[1;30mAddress:\033[0m  $u->{address}, $u->{postcode} $u->{city}, $u->{country}\n"
		        .  "\033[1;30mContact:\033[0m  \033[1;34m$u->{mail}\033[0m :: $u->{phone}\n\n"
		        .  "\033[1;32mShell Accounts\033[0m\n";
	
		$account_show_accounts->execute($id);
		while(my $i = $account_show_accounts->fetchrow_hashref) {
			my $account_type;
			if($i->{test} or $i->{sponsor} or $i->{special} or $i->{block}) {
                                $account_type .= 'test '      if $i->{test};
                                $account_type .= 'sponsored ' if $i->{sponsor};
                                $account_type .= 'special '   if $i->{special};
                                $account_type .= 'blocked '   if $i->{block};
                        } else {
                                $account_type = 'enabled ';
                        }
			
                        $output .= "login: \033[1;36m$i->{login}\033[0m :: uid: $i->{uid}, server: $i->{server}, shell: $i->{shell}\n"
                                 . "type: $account_type\:\: created on $i->{date}, valid until \033[1;35m$i->{valid}\033[0m\n"
                                 . ' :'."\n"
                                 . " `-> \033[1;33mPayments\033[0m\n";
                        my $is_payment;
			$account_show_payments->execute($uid);
			while(my $p = $account_show_payments->fetchrow_hashref) {
                                my $amount;
                                $amount = "$p->{amount}zł" if $p->{currency} eq 'PLN';
                                $amount = "€$p->{amount}" if $p->{currency} eq 'EUR';
                                $output .= "     $p->{date} via $p->{type} :: \033[1;33m$amount\033[0m\n";
                                $is_payment++;
                        }
                        $output .= "     \033[1;30mnone\033[0m\n" unless $is_payment;
		}
	}
	return $output;
}
	
sub try {
	my $self = shift;
	my($type,$text,$default,$special) = @_;
	my $client = $self->{client};
	$default = "" if not defined $default or $default eq 'NULL';
	while(1) {
		print $client "(INT) $text [$default]: \n";
		my $input = <$client>;
		last unless $input;
		chomp $input;
		my($answer,$regexp,$message);
		given($type) {
			when ("name") {
				$answer = join '-', map{ucfirst(lc)} split /-/, $input;
				$regexp = '($answer =~ /^\w{2,}(-\w{2,})?$/i and $answer !~ /\d/)';
				$message = "\033[1;31mYour name is incorrect. Please try again.\033[0m\n";
			}
			when ("lang") {
				$answer = lc($input);
				$regexp = '($answer =~ /^\w{2}$/)';
				$message = "\033[1;31mYour language code is incorrect. Only two letter codes are correct.\033[0m\n";
			}
			when ("type") {
				$answer = lc($input);
				$regexp = '($answer =~ /^(person|company)$/)';
				$message = "\033[1;31mThe type is incorrect. Try 'person' or 'company'.\033[0m\n";
			}
			when ("company") {
				$answer = $input;
				$regexp = '($answer =~ /^[\'\w\s\.,:\-]+$/i)';
				$message = "\033[1;31mYour company name has forbidden chars. Please try again.\033[0m\n";
			}
			when ("vat") {
				$answer = uc($input);
				$answer =~ s/\-//g;
				$answer =~ s/\s*//g;
				$answer =~ s/\.//g;
				$regexp = '($answer =~ /^[A-Z]{2}[\w]+/)';
				$message = "\033[1;31mVAT number $answer is incorrect. Please try again.\033[0m\n";
			}
			when ("postcode") {
				$answer = uc($input);
				$regexp = '($answer =~ /[A-Z\-\d]+/)';
				$message = "\033[1;31mThe postcode $answer is incorrect. Please try again.\033[0m\n";
			}
			when ("city") {
				$answer = lc($input);
				$answer =~ s/(\w+)/\u$1/g;
				$regexp = '($answer =~ /^[\w\-\s]{2,}$/i and $answer !~ /\d/)';
				$message = "\033[1;31mThe city name $answer is incorrect. Please try again.\033[0m\n";
			}
			when ("country") {
				$answer = uc($input);
				if($special and $type eq 'company') {
					$special =~ /^([A-Z]{2})/;
					$special = $1;
					$message = "\033[1;31mThe country code $answer must be the same as the country code in VAT number ($special). Please try again.\033[0m\n";
					if($answer ne $special) {
						print $client $message;
						next;
					}
				} else {
					$regexp = '($answer =~ /^[A-Z]{2}$/)';
					$message = "\033[1;31mThe country code $answer is incorrect. Please try again.\033[0m\n";
				}
			}
			when ("address") {
				$answer = $input;
				$regexp = '($answer =~ /^[\w\s\.\-\/,:]{5,}$/i)';
				$message = "\033[1;31mYour address is too short or it has forbidden chars.\033[0m\n";
			}
			when ("mail") {
				$answer = lc($input);
				$regexp = '($answer =~ /([a-z0-9_\+-]+(\.[a-z0-9_\+-]+)*@[a-z0-9-]+(\.[a-z0-9-]+)*\.([a-z]{2,4}))/)';
				$message = "\033[1;31mThe e-mail address $answer is incorrect. Please try again.\033[0m\n";
			}
			when ("phone") {
				$answer = $input;
				$answer =~ s/\.//g;
				$answer =~ s/\-//g;
				$answer =~ s/\s*//g;
				$regexp = '($answer =~ /^\+\d{6,}$/)';
				$message = "\033[1;31mThe phone number $answer is incorrect. Please try again.\033[0m\n";
			}
		}
		if($input eq "" and $default eq "") {
			print $client "\033[1;31mCannot be empty. Try again.\033[0m\n";
			next;
		}
		if(eval $regexp or $input eq "") {
			print $client "The entry was changed to: \033[1;37m$answer\033[0m\n" if $input ne $answer;
			return $default if $input eq "";
			return $answer;
		}
		print $client $message;
		next;
	}
} ## sub try end

sub edit {
        my($self,@args) = @_;                                                                                                                                                         
        my $uid          = $self->{uid};                                                                                                                                              
        my $login        = $self->{login};                                                                                                                                            
	my $client       = $self->{client};
        
	my $dbh_system          = $self->{dbh_system};      
        my $account_show_user   = $self->{account_show_user};                                                                                                                                                      
	my $account_update_user = $self->{account_update_user};
	my $event_add           = $self->{event_add};

	$account_show_user->execute($uid);
	while(my $u = $account_show_user->fetchrow_hashref) {
                my %a;
                print $client "\033[1;32mUser Information\033[0m\n";
                $a{firstname} = $self->try('name',"First name",$u->{firstname});
                $a{lastname}  = $self->try('name',"Last name",$u->{lastname});
		$a{lang}      = $self->try('lang',"Preferred language (e.g. EN)",$u->{lang});
                $a{type}      = $self->try('type',"Type (person/company)",$u->{type});
                if($a{type} eq 'company') {
                        print $client "\n\033[1;32mCompany\033[0m\n";
                        $a{company} = $self->try('company',"Company",$u->{company});
                        $a{vat}     = $self->try('vat',"VAT number (e.g. PL678-296-46-36)",$u->{vat});
                } else {
			$a{company} = 'NULL';
			$a{vat} = 'NULL';
		}
                print $client "\n\033[1;32mAddress\033[0m\n";
                $a{postcode} = $self->try('postcode',"Postcode",$u->{postcode});
                $a{city}     = $self->try('city',"City",$u->{city});
                $a{country}  = $self->try('country',"Country (two letter code, e.g. PL)",$u->{country},$a{vat});
                $a{address}  = $self->try('address',"Address",$u->{address});
                print $client "\n\033[1;32mContact\033[0m\n";
                $a{mail}  = $self->try('mail',"Mail",$u->{mail});
                $a{phone} = $self->try('phone',"Phone (e.g. +48 555 123 123)",$u->{phone});
		print $client "\n";
                print $client "(INT) \033[1;33mDo you want to save new data? [y/N]\033[0m \n";
                my $answer = <$client>;
                if($answer =~ /^(y|yes)/i) {
			my $previous = '';
			my $current  = '';
			my $event    = '';
			map {
				if($a{$_} ne $u->{$_} and $a{$_} ne 'NULL') {
					$previous .= "\"$u->{$_}\",";
					$current  .= "\"$a{$_}\",";
					$event    .= "\"$_\",";
				}
			} ('firstname','lastname','lang','type','vat','phone','mail','company','address','postcode','city','country');
			$previous =~ s/,$//;
			$current  =~ s/,$//;
			$event    =~ s/,$//;

			if($event) {
				$account_update_user->execute($a{firstname},$a{lastname},$a{lang},$a{type},$a{vat},$a{phone},$a{mail},$a{company},
  	 		        $a{address},$a{postcode},$a{city},$a{country},$u->{id}) and do {
					$event_add->execute($uid,"Changed $event",$previous,$current);
					return "Saved successfully.";
				};
				return "Failed: unable to save.";
			} else {
				return "Nothing changed.";
			}
                } else {
			return "Cancelled.";
		}
        }
}

sub pay {
	my $self   = shift;
	my $uid    = $self->{uid};
	my $login  = $self->{login};
	my $client = $self->{client};

	my $pay_user_add      = $self->{pay_user_add};
	my $account_show_user = $self->{account_show_user};
	$account_show_user->execute($uid);
	
	my $user = $account_show_user->fetchall_hashref('login');
	   $user = $user->{$login};

	my $amount = {};
	   $amount->{total} = {};

	# Currency
#	if($user->{country} =~ /^PL$/i) {
		# PLN
		$amount->{year}    = 180;
		$amount->{quarter} = 54;
		$amount->{prefix}  = '';
		$amount->{suffix}  = 'zł';
#	} else {
#		# €
#		$amount->{year}    = 50;
#		$amount->{quarter} = 15;
#		$amount->{prefix}  = '€';
#		$amount->{suffix}  = '';
#	}
	
	# VAT rate
	my $vat;
	if($user->{type} eq 'company' and $user->{country} =~ /^(BE|BG|CZ|DK|DE|EE|IE|EL|ES|FR|IT|CY|LV|LT|LU|HU|MT|NL|AT|PT|RO|SI|SK|FI|SE|UK)$/i) {
		# VAT = 0%
		$vat=0;
	} else {
		$vat = 23;
	}
	
	my $max_length=0;
	foreach my $period (qw(year quarter)) {
		$amount->{$period} = sprintf('%.2f', $amount->{$period} + ( $amount->{$period} * $vat / 100 ));
		$max_length = length($amount->{$period}) if length($amount->{$period}) > $max_length;
	}
	

	# Discount
	if($user->{discount}) {
		my $indent = {};
		foreach my $period (qw(year quarter)) {
			my $indent = " " x (6-length($amount->{$period}));
			$amount->{total}->{$period} = $indent.$amount->{prefix}.$amount->{$period}.$amount->{suffix}
			                            . " - \033[1;35m".$user->{discount}."% discount\033[0m = ";
			$amount->{$period} = sprintf('%.2f', $amount->{$period} - ( $amount->{$period} * $user->{discount} / 100 ));
			$amount->{total}->{$period} .= "\033[1m".$indent.$amount->{prefix}.$amount->{$period}.$amount->{suffix}."\033[0m";
		}
	} else {
		foreach my $period (qw(year quarter)) {
			my $indent = " " x ($max_length-length($amount->{$period}));
			$amount->{total}->{$period} = "\033[1m".$indent.$amount->{prefix}.$amount->{$period}.$amount->{suffix}."\033[0m";
		}
	}


	$client and print $client "\n\033[1;32mPayment period (incl. $vat% VAT)\033[0m\n\n"
	                        . " (Y)ear     ".$amount->{total}->{year}."\n"
	                        . " (Q)uarter  ".$amount->{total}->{quarter}."\n\n";
	
	my $period = 'year';
	if($client) {
		# interactive
		while(1) {
			print $client "(INT) \033[1;33mChoose year or quarter\033[0m [Y/q] \n";
			my $answer = <$client>;
			if($answer =~ /^(y|)$/i) {
				$period = 'year';
				last;
			} elsif($answer =~ /^q$/i) {
				$period = 'quarter';
				last;
			}
		}
		print $client ucfirst $period.".\n\n";
	}
	
	my $authcode = join('',map { ('a'..'z',0..9)[rand 36] } 1..16);
	$amount->{$period} =~ s/\.//;

	$pay_user_add->execute(
		$authcode,
		$login,
		$amount->{$period},
		$period,
		$user->{firstname},
		$user->{lastname},
		$user->{mail}, 
		$user->{lang}
	);

	if($client) {
		return "Payment URL is \033[1;34mhttps://rootnode.net/pay/".$authcode."\033[0m\n";
	} else {
		return "https://rootnode.net/pay/$authcode";
	}	
}

sub invoice {
        my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
	
	my $invoice_get     = $self->{invoice_get};	
	my $invoice_get_all = $self->{invoice_get_all};
	
	if(@args) {
		foreach my $invoice_id (@args) {
			$invoice_get->execute($uid,$invoice_id);
			if(!$invoice_get->rows) {
				print $client "Sorry, no such invoice: $invoice_id\n";
				next;
			}
			my($payment_id) = $invoice_get->fetchrow_array;
			my $invoice = Satan::Invoice->new(dbh_system=>$self->{dbh_system}, payment_id=>$payment_id);
			   $invoice->create;
			my $status = $invoice->send;
			if($status) {
				print $client "Invoice \033[1m$invoice_id\033[0m sent successfully.\n";
			} else {
				print $client "Error occured. Invoice $invoice_id could not be sent\n";
			}
		}
	} else {
		$invoice_get_all->execute($uid);
		my $listing = Satan::Tools->listing(
			db      => $invoice_get_all,
			title   => "Invoices",
			header  => ['Id','Raised at','Price','Tax','Total','Currency'],
			columns => [ qw(id date price_net tax_rate price_gross currency) ],
		) || "No invoices.";
	}
}	


sub help {
	my $self  = shift;
	my $usage = "\033[1mSatan :: Account\033[0m\n\n"
                  . "\033[1;32mSYNTAX\033[0m\n"
                  . "  account show                 show user information (default)\n"
                  . "  account edit                 edit personal data\n"
                  . "  account pay                  generate payment link\n"
	          . "  account invoice              show invoices\n"
	          . "  account invoice <id>         send pointed invoice by mail\n\n"
                  . "\033[1;32mEXAMPLE\033[0m\n"
                  . "  satan account\n"
                  . "  satan account edit\n"
	          . "  satan invoice 201100305\n";
        return $usage;
}

1;
