#!/usr/bin/perl -w
#
# hass_discovery.pl - publish Home Assistant MQTT discovery configs for the coach.
#
# Publishes retained config topics to the LOCAL broker under homeassistant/.
# The mosquitto bridge forwards them to Home Assistant, which auto-creates the
# entities. Run once after any change to the maps below; retained messages mean
# HA re-discovers everything on its own restart.
#
# Nothing here touches CoachProxy's own topics or flows.

use strict;
use JSON::PP;
use Net::MQTT::Simple;

my $DISCO  = 'homeassistant';
my $AVAIL  = 'RVC/bridge/state';   # mosquitto bridge notification topic
# ascii(1) escapes non-ASCII as \uXXXX. Without it the degree sign is emitted as
# a raw latin-1 byte (B0) rather than UTF-8 (C2 B0), and Home Assistant silently
# discards the whole config as undecodable -- the entity just never appears.
my $json   = JSON::PP->new->canonical(1)->ascii(1);

# instance => [ friendly name, dimmable? ]
my %LIGHTS = (
	1  => ['Bedroom Ceiling',        1],
	2  => ['Bedroom Reading',        1],
	3  => ['Galley Ceiling',         1],
	4  => ['Living Room Ceiling',    1],
	5  => ['Hall Ceiling',           0],
	6  => ['Galley Island',          0],
	7  => ['Galley Office',          0],
	8  => ['Living Room Right Sofa', 0],
	9  => ['Galley Counter',         0],
	10 => ['Mid Bath Ceiling',       0],
	11 => ['Living Room Left Sofa',  0],
	12 => ['Living Room Sconce',     0],
	13 => ['Galley Accent',          0],
	14 => ['Awning Light',           0],
	15 => ['Porch Light',            0],
	17 => ['Hall Accent',            0],
);

# instance => friendly name  (loads that are not lights)
my %SWITCHES = (
	18 => 'Water Pump',
	19 => 'Water Heater Fuel',
	20 => 'Water Heater Electric',
	25 => 'Vent Fan 1',
	28 => 'Tank Heat',
	29 => 'Vent Fan 2',
);

# RVC/TANK_STATUS instance => friendly name
my %TANKS = (
	0  => 'Fresh Water',
	1  => 'Black Tank',
	2  => 'Gray Tank',
	3  => 'LPG',
	18 => 'Gray Tank 2',
);

# RVC/THERMOSTAT_AMBIENT_STATUS instance => friendly name
my %TEMPS = (
	0 => 'Zone 1 Temperature',
	1 => 'Zone 2 Temperature',
	2 => 'Zone 3 Temperature',
);

my %DEVICE = (
	identifiers  => ['coachproxy'],
	name         => 'Coach',
	manufacturer => 'CoachProxy',
	model        => 'RV-C Gateway',
);

my $mqtt = Net::MQTT::Simple->new('localhost');
my $count = 0;

sub publish_config {
	my ($component, $object_id, $cfg) = @_;
	$cfg->{device}             = \%DEVICE;
	$cfg->{availability_topic} = $AVAIL;
	$cfg->{payload_available}     = '1';
	$cfg->{payload_not_available} = '0';
	my $topic = "$DISCO/$component/$object_id/config";
	$mqtt->retain($topic => $json->encode($cfg));
	$count++;
	print "  $component/$object_id\n";
	# Net::MQTT::Simple is fire-and-forget with no flush. Publishing 31 configs
	# back-to-back overruns the socket and the tail is silently lost, so pace
	# them out.
	select(undef, undef, undef, 0.15);
}

print "Publishing discovery configs to local broker...\n";

# ---- lights -------------------------------------------------------------
for my $i (sort {$a<=>$b} keys %LIGHTS) {
	my ($name, $dimmable) = @{$LIGHTS{$i}};
	my $state = "RVC/DC_DIMMER_STATUS_3/$i";
	my %cfg = (
		name                 => $name,
		unique_id            => "rvc_light_$i",
		state_topic          => $state,
		state_value_template =>
			"{{ 'ON' if (value_json['operating status (brightness)'] | int(0)) > 0 else 'OFF' }}",
		command_topic        => "RVC/command/light/$i",
		payload_on           => 'ON',
		payload_off          => 'OFF',
		qos                  => 0,
	);
	if ($dimmable) {
		$cfg{brightness_state_topic}    = $state;
		$cfg{brightness_command_topic}  = "RVC/command/light/$i/brightness";
		$cfg{brightness_scale}          = 100;
		$cfg{brightness_value_template} =
			"{{ value_json['operating status (brightness)'] | int(0) }}";
		# Without this, HA follows every brightness change with a separate ON
		# payload (on_command_type defaults to "last"). dc_dimmer.pl's "on"
		# command defaults brightness to 100, so that trailing ON wipes out the
		# level just set and the light jumps to full every time. "brightness"
		# makes HA turn the light on by sending a level instead.
		$cfg{on_command_type}           = 'brightness';
	}
	publish_config('light', "rvc_light_$i", \%cfg);
}

# ---- non-light loads ----------------------------------------------------
for my $i (sort {$a<=>$b} keys %SWITCHES) {
	publish_config('switch', "rvc_switch_$i", {
		name                 => $SWITCHES{$i},
		unique_id            => "rvc_switch_$i",
		state_topic          => "RVC/DC_DIMMER_STATUS_3/$i",
		state_value_template =>
			"{{ 'ON' if (value_json['operating status (brightness)'] | int(0)) > 0 else 'OFF' }}",
		command_topic        => "RVC/command/switch/$i",
		payload_on           => 'ON',
		payload_off          => 'OFF',
	});
}

# ---- tanks --------------------------------------------------------------
# RV-C reports relative level against a resolution, not a percentage.
for my $i (sort {$a<=>$b} keys %TANKS) {
	publish_config('sensor', "rvc_tank_$i", {
		name                => $TANKS{$i},
		unique_id           => "rvc_tank_$i",
		state_topic         => "RVC/TANK_STATUS/$i",
		unit_of_measurement => '%',
		icon                => 'mdi:gauge',
		state_class         => 'measurement',
		value_template      =>
			"{% set r = value_json['resolution'] | float(0) %}"
			. "{{ ((value_json['relative level'] | float(0)) / r * 100) | round(0) if r > 0 else 0 }}",
	});
}

# ---- temperatures -------------------------------------------------------
for my $i (sort {$a<=>$b} keys %TEMPS) {
	publish_config('sensor', "rvc_temp_$i", {
		name                => $TEMPS{$i},
		unique_id           => "rvc_temp_$i",
		state_topic         => "RVC/THERMOSTAT_AMBIENT_STATUS/$i",
		device_class        => 'temperature',
		state_class         => 'measurement',
		unit_of_measurement => "\N{DEGREE SIGN}F",
		value_template      => "{{ value_json['ambient temp F'] | float(0) | round(1) }}",
	});
}

# ---- climate zones ------------------------------------------------------
# Zone numbering is CoachProxy's "Lowline" map, which matches the instances this
# coach actually reports (0/1/2 thermostats, 3 = Front Furnace). The furnace is
# not exposed separately: thermostats.pl already pushes the setpoint to zone+3
# whenever an even zone is set.
my %CLIMATE = (
	0 => 'Front',
	1 => 'Mid',
	2 => 'Rear',
);

for my $z (sort {$a<=>$b} keys %CLIMATE) {
	my $stat = "RVC/THERMOSTAT_STATUS_1/$z";
	publish_config('climate', "rvc_climate_$z", {
		name      => $CLIMATE{$z},
		unique_id => "rvc_climate_$z",

		# 'heat' is intentionally absent: which appliance answers a heat command
		# on this coach is unverified, and the furnace burns propane.
		modes     => ['off', 'cool', 'auto'],
		fan_modes => ['auto', 'low', 'high'],

		temperature_unit => 'F',
		min_temp         => 55,
		max_temp         => 90,
		temp_step        => 1,

		current_temperature_topic    => "RVC/THERMOSTAT_AMBIENT_STATUS/$z",
		current_temperature_template => "{{ value_json['ambient temp F'] | float(0) | round(1) }}",

		mode_state_topic    => $stat,
		mode_state_template =>
			"{% set m = value_json['operating mode definition'] %}"
			. "{{ m if m in ['off','cool','auto'] else 'off' }}",
		mode_command_topic  => "RVC/command/climate/$z/mode",

		temperature_state_topic    => $stat,
		temperature_state_template => "{{ value_json['setpoint temp cool F'] | float(0) | round(0, 'floor') }}",
		temperature_command_topic  => "RVC/command/climate/$z/temperature",

		fan_mode_state_topic    => $stat,
		fan_mode_state_template =>
			"{% set f = value_json['fan mode definition'] %}"
			. "{{ f if f in ['auto','low','high'] else 'auto' }}",
		fan_mode_command_topic  => "RVC/command/climate/$z/fan",
	});
}

# ---- house battery ------------------------------------------------------
publish_config('sensor', 'rvc_battery_voltage', {
	name                => 'House Battery Voltage',
	unique_id           => 'rvc_battery_voltage',
	state_topic         => 'RVC/DC_SOURCE_STATUS_1/1',
	device_class        => 'voltage',
	state_class         => 'measurement',
	unit_of_measurement => 'V',
	value_template      => "{{ value_json['dc voltage'] | float(0) }}",
});

# Give the socket time to drain before the process exits and takes any
# unsent buffer with it.
sleep 3;

print "\nPublished $count retained discovery configs.\n";
