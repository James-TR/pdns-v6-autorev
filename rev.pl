#!/usr/bin/perl

##
# IPv6 automatic reverse/forward generator script by Aki Tuomi
# Released under the GNU GENERAL PUBLIC LICENSE v2
##

use strict;
use warnings;
use 5.005;

# Configure domains to give reply for, note that you *must* configure
# SOA to somewhere else. 
# 
my $domaintable = {
        'dyn.powerdns.com' => 'fe80:3eec:c804'
};

my $debug = 0;

# end of configuration.

# These helpers are for 16->32 and 32->16 conversions
my %v2b = do {
    my $i = 0;
    map { $_ => sprintf( "%05b", $i++ ) } ( '0' .. '9', 'A' .. 'V' );
};
my %b2v = reverse %v2b;

sub from32 {
  my $str = shift;
  $str =~ tr/ybndrfg8ejkmcpqxot1uwisza345h769/0-9A-V/;
  $str =~ tr/0-9A-V//cd;
  $str =~ s/(.)/$v2b{$1}/g;
  my $padlen = (length $str) % 8;
  $str =~ s/0{$padlen}\z//;
  return scalar pack "B*", $str;
}

sub to32 {
  my $str = shift;
  my $ret = unpack "B*", $str;
  $ret .= 0 while ( length $ret ) % 5;
  $ret =~ s/(.....)/$b2v{$1}/g;
  $ret =~ tr/0-9A-V/ybndrfg8ejkmcpqxot1uwisza345h769/;
  return $ret;
}

sub from16 {
  my $str = shift;
  $str =~ tr/0-9a-f//cd;
  return scalar pack "H*", lc $str;
}

sub to16 {
  my $str = shift;
  return unpack "H*", $str;
}

$|=1;

# perform handshake. we support ABI 1

my $helo = <>;
chomp($helo);

unless($helo eq 'HELO	1') {
	print "FAIL\n";
	while(<>) {};
	exit;
}

my $domains;

# Build domain table based on configuration
while(my ($dom,$prefix) = each %$domaintable) {
        $domains->{$dom} = $prefix;

	# build reverse lookup domain
        my $tmp = $prefix;
        $tmp=~s/://g;

	# this is needed for compression
        my $bits = length($tmp)*4;

        $tmp = join '.', reverse split //,$tmp;
        $tmp=~s/^[.]//;
        $tmp=~s/[.]$//;
	
	# forward lookup
        $domains->{$dom} = { prefix => $prefix, bits => $bits };
	# reverse lookup
        $domains->{"$tmp.ip6.arpa"} = { domain => $dom, bits => $bits };

	# ensure the n. of bits is divisable by 16 (otherwise bad stuff happens)
        unless (($bits%16)==0) {
		print "OK	$dom has $prefix that is not divisable with 8\n";
		while(<>) {
			print "END\n";
		};
		exit 0;
	}
}

print "OK	Automatic reverse generator v1.0 starting\n";

while(<>) {
	chomp;
	my @arr=split(/\t/);
	if(@arr<6) {
		print "LOG	PowerDNS sent unparseable line\n";
		print "FAIL\n";
		next;
	}

	# get the request
	my ($type,$qname,$qclass,$qtype,$id,$ip)=@arr;

	print "LOG	$qname $qclass $qtype?\n" if ($debug);

	# forward lookup handler
	if (($qtype eq 'AAAA' || $qtype eq 'ANY') && $qname=~/node-([^.]*).(.*)/) {
		my $node = $1;
		my $dom = $2;

		print "LOG	$node $dom and ", $domains->{$dom}{prefix}, "\n" if ($debug);

		# make sure it's our domain first and reasonable
		if ($domains->{$dom} and $node=~m/^[ybndrfg8ejkmcpqxot1uwisza345h769]+$/) {
			my $n = (128 - $domains->{$dom}{bits}) / 5;

			while(length($node) < $n) {
				$node = "y$node";
			}

			$node = to16(from32($node));

			print "LOG	$node\n";

			$n = (128 - $domains->{$dom}{bits}) / 4;

			# only process correct length
			if (length($node) == $n) {
				# convert
				my $dname = $node;
				# hmm
				my $tmp = $domains->{$dom}{prefix};
					
				# build whole IPv6 address and add : to correct placs
				$tmp=~s/://g;
				$dname = $tmp.$dname;
				$dname=~s/(.{4})/$1:/g;
				$dname=~s/:$//;
	
				# reply with value
                                print "LOG	$qname  $qclass AAAA    60      $id     $dname\n" if ($debug);
				print "DATA	$qname	$qclass	AAAA	60	$id	$dname\n";
			}
		}
	# reverse lookup
	} elsif (($qtype eq 'PTR' || $qtype eq 'ANY') && $qname=~/(.*\.arpa$)/) {
		my $node = $1;

		# look for our domain
		foreach(keys %$domains) {
			my $key = $_;
			my $dom = $domains->{$_}{domain};
			$key=~s/[.]/\\./g;
			if ($node=~/(.*).$key$/) {
				$qname = $node;
				$node = $1;

				$node = join '', reverse split /\./, $node;

				# recode to base32
				$node = to32(from16($node));

				# compress
				$node =~ s/^y*//;
				$node = 'y' if ($node eq '');

				print "LOG	$qname  $qclass PTR     60      $id     node-$node.$dom\n" if ($debug);
				print "DATA	$qname	$qclass	PTR	60	$id	node-$node.$dom\n";
			}
		}
	}
	
	#end of data
	print "END	\n";
}
