#!/bin/bash
#
# wifi_healthcheck.sh - detect and recover a dead wlan0 on the CoachProxy Pi.
#
# Two failure modes were observed on 2026-08-30, both leaving the Pi running
# happily while unreachable:
#   1. wpa_supplicant association failures (logged, noisy)
#   2. associated but passing no traffic at all (silent - nothing logged)
# Only an active reachability test catches the second one, so this pings the
# MoFi's LAN gateway and escalates through progressively harder recoveries.
#
# Runs every 60s via wifi-healthcheck.timer. Logs to syslog under this tag.

GW=192.168.10.1
IFACE=wlan0
STATE=/run/wifi_healthcheck.fails
BOOTGUARD=/run/wifi_healthcheck.rebooted
TAG=wifi-healthcheck

log() { logger -t "$TAG" "$*"; }

# Don't act during the first two minutes after boot - the interface is still
# coming up and a false positive here could start a reboot loop.
UP=$(cut -d. -f1 /proc/uptime)
[ "$UP" -lt 120 ] && exit 0

if ping -c 3 -W 2 -I "$IFACE" "$GW" >/dev/null 2>&1; then
	if [ -s "$STATE" ] && [ "$(cat "$STATE")" -gt 0 ]; then
		log "link recovered after $(cat "$STATE") failed check(s)"
	fi
	echo 0 > "$STATE"
	exit 0
fi

FAILS=$(( $( [ -s "$STATE" ] && cat "$STATE" || echo 0 ) + 1 ))
echo "$FAILS" > "$STATE"
log "gateway $GW unreachable (consecutive failures: $FAILS)"

case "$FAILS" in
	3)
		log "escalation 1: asking wpa_supplicant to reassociate"
		/sbin/wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1
		;;
	6)
		log "escalation 2: bouncing $IFACE and restarting dhcpcd"
		/sbin/ip link set "$IFACE" down
		sleep 3
		/sbin/ip link set "$IFACE" up
		systemctl restart dhcpcd >/dev/null 2>&1
		;;
	10)
		# Last resort. Guarded so a persistent outage cannot cause a reboot
		# loop - at most one automatic reboot per boot.
		if [ -f "$BOOTGUARD" ]; then
			log "escalation 3 skipped: already rebooted once this boot"
		else
			touch "$BOOTGUARD"
			log "escalation 3: rebooting - link dead for 10 consecutive checks"
			/sbin/shutdown -r +0 "wifi-healthcheck: wlan0 unrecoverable"
		fi
		;;
esac

exit 0
