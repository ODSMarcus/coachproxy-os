#!/bin/bash
#
# setup_hass_bridge.sh - finish the Home Assistant MQTT bridge.
#
# Prompts for the HA login created for the coach, writes the mosquitto bridge
# config, restarts the broker and verifies the connection actually came up.
# The password is read silently and never appears in shell history.

set -u

TEMPLATE=/coachproxy/etc/hass-bridge.conf.template
TARGET=/etc/mosquitto/conf.d/hass-bridge.conf
HA_BROKER_IP=192.168.3.10
HA_BROKER_PORT=1883

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo:  sudo $0" >&2
	exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
	echo "ERROR: template missing at $TEMPLATE" >&2
	exit 1
fi

echo "Home Assistant MQTT bridge setup"
echo "--------------------------------"
echo "Enter the HA login you created for the coach."
echo

printf "MQTT username: "
read -r MQTT_USER
printf "MQTT password: "
read -rs MQTT_PASS
echo
echo

if [ -z "$MQTT_USER" ] || [ -z "$MQTT_PASS" ]; then
	echo "ERROR: username and password are both required." >&2
	exit 1
fi

# Substitute with perl rather than sed so that slashes, ampersands and other
# regex-significant characters in the password are handled literally.
MQTT_USER="$MQTT_USER" MQTT_PASS="$MQTT_PASS" perl -pe '
	s/__MQTT_USER__/$ENV{MQTT_USER}/g;
	s/__MQTT_PASS__/$ENV{MQTT_PASS}/g;
' "$TEMPLATE" > "$TARGET"

# The file holds a password in cleartext, which mosquitto requires.
chown root:root "$TARGET"
chmod 600 "$TARGET"
echo "Wrote $TARGET (root-only, 0600)"

echo "Restarting mosquitto..."
systemctl restart mosquitto
sleep 6

echo
echo "Checking bridge connection to ${HA_BROKER_IP}:${HA_BROKER_PORT} ..."
if ss -tn 2>/dev/null | grep -q "${HA_BROKER_IP}:${HA_BROKER_PORT}"; then
	echo "  CONNECTED - the bridge is established."
	CONNECTED=1
else
	echo "  NOT connected yet."
	CONNECTED=0
fi

echo
echo "Recent mosquitto log lines:"
journalctl -u mosquitto -n 15 --no-pager 2>/dev/null \
	| grep -iE "bridge|connect|error|denied|refused" | tail -10

if [ "$CONNECTED" -eq 1 ]; then
	echo
	echo "Republishing discovery configs so HA picks them up..."
	systemctl restart hass-discovery.service
	echo
	echo "Done. Check Home Assistant for a device named 'Coach'."
else
	echo
	echo "Bridge did not come up. Most likely the username or password is wrong -"
	echo "look for 'Connection Refused: not authorised' above, then re-run this script."
fi
