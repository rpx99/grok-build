#!/usr/bin/perl
# Mark execute-only PT_LOAD segments as readable (PF_R|PF_X).
# rustc/lld on OpenBSD amd64 emit PF_X-only .text; aws-lc-sys s2n-bignum
# stores constants there, so a load SIGSEGVs. No-op if already R+E.
use strict;
use warnings;

my $path = shift or die "usage: $0 <elf>\n";
open my $f, '+<', $path or die "$path: $!\n";
binmode $f;
read($f, my $ehdr, 64) == 64 or die "$path: short ELF header\n";
my $magic = substr($ehdr, 0, 4);
die "$path: not ELF\n" unless $magic eq "\x7fELF";
my $phoff     = unpack('Q', substr($ehdr, 32, 8));
my $phentsize = unpack('v', substr($ehdr, 54, 2));
my $phnum     = unpack('v', substr($ehdr, 56, 2));
my $n = 0;
for (my $i = 0; $i < $phnum; $i++) {
	seek $f, $phoff + $i * $phentsize, 0 or die $!;
	read($f, my $ph, $phentsize) == $phentsize or die "$path: short PHDR\n";
	my ($type, $flags) = unpack('VV', $ph);
	next unless $type == 1 && $flags == 1;    # PT_LOAD && PF_X
	substr($ph, 4, 4) = pack('V', 5);         # PF_R|PF_X
	seek $f, $phoff + $i * $phentsize, 0 or die $!;
	print $f $ph;
	$n++;
}
print STDERR "$path: marked $n execute-only PT_LOAD segment(s) readable\n";
