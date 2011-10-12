#!/usr/bin/perl

## Satan::Tools
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2011 Marcin Hlybin
# All rights reserved.

package Satan::Tools;

use warnings;
use strict;
use Data::Dumper;

sub caps {
	## Split number/caps into bits
	## Syntax
	## my @caps = Satan::Tools->caps($number)
	my $self = shift;
	my($d)   = @_;
        my $b    = 1;

        my @caps;
        push @caps, '0' if $d == 0;
        while ($d) {
		($d & $b) and push @caps, $b;
		$d &= ~$b;
		$b *= 2;
        }
        return @caps;
}

sub id {
	## Find free ID in table
	## Syntax
	## Satan::Tools->id(
	## 	dbh    => $dbh,
	##	column => 'id',
	##	table  => 'tablename',
	##	min    => 1
	## );

	my $self = shift;
	my $param = { @_ };
	my $dbh    = $param->{dbh};
	my $column = $param->{column};
	my $table  = $param->{table};
	my $min    = $param->{min} || 1;
	
	my $sth = $dbh->prepare("SELECT $column FROM $table WHERE $column >= $min;");
        $sth->execute();
        my @ids;
        while(my($row) = $sth->fetchrow_array) {
                push @ids,$row;
        }
        @ids=sort {$a <=> $b} @ids;
	print Dumper(@ids);
        for my $i (0 .. @ids) {
                my $id = $i+$min;
                if(not defined $ids[$i] or $id != $ids[$i]) {
                        return $id;
                }
        }
}

sub listing {
	## Display data from DB as table
	## Syntax
	## Satan::Tools->listing( 
 	##  	db      => $sth->execute
	##      title   => 'Table title',
	##	header  => [ 'Column', 'Titles', 'Go', 'Here' ],
	##	columns => [ qw(column names go here) ],
	##	empty   => { columnname => 'desc if null' }
	## );

	my $self = shift;
	my $param = { @_ };
	my $db      = $param->{db};
	my $title   = $param->{title};
	my @header  = @{$param->{header}};
	my @columns = @{$param->{columns}};
	my %empty   = %{$param->{empty}} if defined $param->{empty};

	my %map_names = map { $columns[$_] => $header[$_] } (0..$#header);
	my $rows = $db->rows;
	return unless $rows;
	my $listing = "\033[1;32m$title\033[0m ($rows in total)\n\n";
	my %length = map { eval "$_ => length(\$map_names{$_})" } @columns; # count length of column names
	
	my @results;
	while(my $ref = $db->fetchrow_hashref) {
		## If column in DB is NULL use '-' sign 
		 # or value from %empty hash.
		%$ref = map { 
			if(defined $$ref{$_}) { 
				$_ => $$ref{$_};
			} elsif(defined $empty{$_}) {
				$_ => $empty{$_};
			} else {
				 $_ => '-';
			}
		} keys %$ref;
		
		## count the length of the word in column
		map { eval "\$length{$_} = length(\$\$ref{$_}) if length(\$\$ref{$_}) > \$length{$_}"
		    } @columns;

		## save rows as hash with column name keys in @results array.
		push @results, { map { $_ => $$ref{$_} } @columns };
	}

	## format row
	$listing .= "\033[1m";
        map { eval "\$listing .= sprintf(\"%-\$length{$_}s\",\$map_names{$_}).' 'x3"
            } @columns;
	$listing .= "\033[0m\n";
	
	## display rows
	foreach my $line (@results) {
		my %results = %$line;
		map { eval "\$listing .= sprintf(\"%-\$length{$_}s\",\$results{$_}).' 'x3"
                    } @columns;
		$listing .= "\n";
	}
	return $listing;
}

1;
