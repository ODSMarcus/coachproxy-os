#!/usr/bin/perl -w
#
# watch_loads.pl - print RV-C load changes as they happen.
#
# Read-only. Nothing is ever sent to the CAN bus. Flip a physical switch in the
# coach and this reports which instance changed, so the unnamed loads can be
# identified without commanding anything.

use strict;
use Net::MQTT::Simple;

$| = 1;

my %last;
my $start = time;

print "Watching RV-C loads. Flip a switch in the coach; the instance will appear here.\n";
print "Ctrl-C to stop.\n\n";
printf("%-9s %-9s %-9s %s\n", 'TIME', 'INSTANCE', 'CHANGE', '');
print '-' x 46, "\n";

my $mqtt = Net::MQTT::Simple->new('localhost');
$mqtt->run('RVC/DC_DIMMER_STATUS_3/+' => sub {
	my ($topic, $msg) = @_;
	my ($inst) = $topic =~ m{/(\d+)$};
	return unless defined $inst;

	my ($b) = $msg =~ /"operating status \(brightness\)":(\d+)/;
	return unless defined $b;

	# Only report transitions, not the constant re-broadcast of steady state.
	if (exists $last{$inst} && $last{$inst} != $b) {
		my @t = localtime();
		printf("%02d:%02d:%02d  %-9s %s -> %s%s\n",
			$t[2], $t[1], $t[0], $inst, $last{$inst}, $b,
			($b > 0 ? '   (ON)' : '   (off)'));
	}
	$last{$inst} = $b;
});
