#!/usr/bin/perl -w
#
# hass_command.pl - bridge Home Assistant MQTT commands to CoachProxy RV-C scripts.
#
# Subscribes to RVC/command/# on the local broker and translates each message
# into the equivalent /coachproxy/rv-c/*.pl invocation. Added alongside
# CoachProxy; it does not modify or interfere with the stock flows.
#
# Topics consumed:
#   RVC/command/light/<instance>               payload: ON | OFF
#   RVC/command/light/<instance>/brightness    payload: 0-100
#   RVC/command/switch/<instance>              payload: ON | OFF
#   RVC/command/climate/<zone>/mode            payload: off | cool | auto
#   RVC/command/climate/<zone>/temperature     payload: degrees F
#   RVC/command/climate/<zone>/fan             payload: auto | low | high
#
# dc_dimmer.pl  <instance> <command> {brightness 0-100} {duration}
#                 command 0 = set level, 1 = on, 3 = off
# thermostats.pl <zone> <command> {arg}

use strict;
no strict 'refs';
use Net::MQTT::Simple;

my $DIMMER = '/coachproxy/rv-c/dc_dimmer.pl';
my $THERMO = '/coachproxy/rv-c/thermostats.pl';

# Loads mapped in the Node-RED flow. A load may sit silent for long stretches --
# RV-C only broadcasts on change -- so absence from the bus is not a reason to
# drop it from this list.
my %ALLOW = map { $_ => 1 } (1..15, 17..20, 25, 28, 29);

# Thermostat zones on this coach: 0 Front, 1 Mid, 2 Rear (3 is the Front Furnace,
# driven implicitly by thermostats.pl when an even zone setpoint is set).
my %ZONES = map { $_ => 1 } (0, 1, 2);

# Guard rails on setpoints, so a bad payload cannot ask for something absurd.
my $MIN_SETPOINT = 55;
my $MAX_SETPOINT = 90;

# thermostats.pl needs to know the current mode to pick the right fan command.
my %mode_of;

$| = 1;

sub logmsg {
	my @t = localtime();
	printf("%04d-%02d-%02d %02d:%02d:%02d %s\n",
		$t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], join(' ', @_));
}

# Never build a shell string from topic/payload data. system() with a list
# bypasses the shell entirely, so a hostile payload cannot inject anything.
sub run_cmd {
	my @cmd = @_;
	logmsg("exec: @cmd");
	my $rc = system(@cmd);
	logmsg("  -> rc=$rc") if $rc != 0;
}

sub handle_climate {
	my ($zone, $action, $message) = @_;

	unless (defined($zone) && $zone =~ /^\d+$/ && $ZONES{$zone}) {
		logmsg("ignoring unknown climate zone '$zone'");
		return;
	}
	$action = '' unless defined $action;

	if ($action eq 'mode') {
		my $m = lc($message);
		# 'heat' is deliberately not accepted yet: on this coach it is unverified
		# which appliance answers a heat command, and the furnace burns propane.
		unless (grep { $_ eq $m } qw(off cool auto)) {
			logmsg("unsupported climate mode '$message' for zone $zone");
			return;
		}
		run_cmd($THERMO, $zone, $m);
		$mode_of{$zone} = $m;
	}
	elsif ($action eq 'temperature') {
		unless ($message =~ /^-?\d+(\.\d+)?$/) {
			logmsg("bad setpoint '$message' for zone $zone");
			return;
		}
		my $t = int($message + 0.5);
		if ($t < $MIN_SETPOINT || $t > $MAX_SETPOINT) {
			logmsg("setpoint ${t}F out of range ${MIN_SETPOINT}-${MAX_SETPOINT} for zone $zone");
			return;
		}
		run_cmd($THERMO, $zone, 'set', $t);
	}
	elsif ($action eq 'fan') {
		my $f = lc($message);
		unless (grep { $_ eq $f } qw(auto low high)) {
			logmsg("bad fan mode '$message' for zone $zone");
			return;
		}
		# Passing the current mode lets thermostats.pl choose the _fanonly
		# variant when the zone is not actively heating or cooling.
		my $cur = $mode_of{$zone} // 'off';
		run_cmd($THERMO, $zone, $f, $cur);
	}
	else {
		logmsg("unknown climate action '$action'");
	}
}

sub handle {
	my ($topic, $message) = @_;

	my @p = split(m{/}, $topic);
	return unless @p >= 4 && $p[0] eq 'RVC' && $p[1] eq 'command';
	my ($kind, $id, $sub) = ($p[2], $p[3], $p[4]);

	$message = '' unless defined $message;
	$message =~ s/^\s+|\s+$//g;

	return handle_climate($id, $sub, $message) if $kind eq 'climate';

	unless (defined($id) && $id =~ /^\d+$/ && $ALLOW{$id}) {
		logmsg("ignoring unknown instance in '$topic'");
		return;
	}

	if (defined($sub) && $sub eq 'brightness') {
		return unless $kind eq 'light';
		unless ($message =~ /^\d+$/ && $message <= 100) {
			logmsg("bad brightness '$message' on $topic");
			return;
		}
		# Level 0 is not an "off" on RV-C; send a real off so the load's
		# last-command state matches what HA believes.
		if ($message == 0) { run_cmd($DIMMER, $id, 3); }
		else               { run_cmd($DIMMER, $id, 0, $message); }
		return;
	}

	return unless $kind eq 'light' || $kind eq 'switch';

	if    (uc($message) eq 'ON')  { run_cmd($DIMMER, $id, 1); }
	elsif (uc($message) eq 'OFF') { run_cmd($DIMMER, $id, 3); }
	else  { logmsg("unrecognised payload '$message' on $topic"); }
}

# Track thermostat mode so fan commands can be issued correctly.
sub track_mode {
	my ($topic, $message) = @_;
	my ($z) = $topic =~ m{/(\d+)$};
	return unless defined $z;
	if ($message =~ /"operating mode definition":"([^"]+)"/) {
		$mode_of{$z} = $1;
	}
}

logmsg("hass_command.pl starting; loads: " . join(',', sort {$a<=>$b} keys %ALLOW)
	. "; climate zones: " . join(',', sort keys %ZONES));

my $mqtt = Net::MQTT::Simple->new('localhost');
$mqtt->run(
	'RVC/command/+/+'            => \&handle,
	'RVC/command/+/+/+'          => \&handle,
	'RVC/THERMOSTAT_STATUS_1/+'  => \&track_mode,
);
