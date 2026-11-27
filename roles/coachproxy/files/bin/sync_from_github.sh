#!/bin/bash

# sync_from_github.sh
# Bring /coachproxy in line with roles/coachproxy/files/ from the GitHub
# repo, so changes are made in the repo and then pulled onto the coach.
#
# Usage: sudo sync_from_github.sh [--apply] [--ref <branch|commit>]
#
# Without --apply nothing is changed; it only lists what would be.
#
# - Downloads a tarball from GitHub, so git is not needed on the Pi.
# - Never deletes anything, and never touches files the Pi rewrites at
#   runtime (see PROTECTED).
# - Every file it replaces is saved under /coachproxy/backup-sync/<time>/.
# - Reloads/restarts the services that are cheap and safe to bounce, and
#   lists anything heavier as a restart for you to do.
# - Records what was deployed in /coachproxy/etc/DEPLOYED.

set -o pipefail

conf=/coachproxy/etc/sync.conf
deployed=/coachproxy/etc/DEPLOYED
log=/coachproxy/bin/cplog.sh
script=$(basename $0 .sh)

# Repo files that the Pi rewrites at runtime. Never overwrite these.
# The flows file is changed on the Pi (configurator / Node-RED editor) and
# copied back into the repo, so it only ever goes Pi -> repo.
PROTECTED=(
  ha-bridge/device.db
  node-red/flows_coachproxy.json
)

apply=false
ref=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --apply) apply=true ;;
    --ref) ref=$2; shift ;;
    *) echo "Usage: sudo $0 [--apply] [--ref <branch|commit>]" >&2; exit 2 ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

source $conf
ref=${ref:-$REF}

exec 9> /run/$script.lock
if ! flock -n 9; then
  echo "Another sync is already running." >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Resolve the branch to an exact commit, so what is reported is what is
# installed even if someone pushes mid-sync.
sha=$(curl -fsS -m 60 -H "Accept: application/vnd.github.sha" \
  "https://api.github.com/repos/$REPO/commits/$ref") || {
  echo "Could not resolve '$ref' on GitHub." >&2
  exit 1
}

echo "Repo:   $REPO"
echo "Ref:    $ref -> ${sha:0:7}"
prev=$(awk '/^commit /{print $2}' $deployed 2>/dev/null)
if [[ -n $prev ]]; then
  echo "On Pi:  ${prev:0:7} (synced $(awk '/^date /{print $2}' $deployed))"
else
  echo "On Pi:  never synced"
fi
echo

curl -fsS -m 600 -L -o "$work/src.tgz" "https://codeload.github.com/$REPO/tar.gz/$sha" || {
  echo "Download failed." >&2
  exit 1
}
# GitHub's tarballs are group-writable (664/775). Extract with umask 022
# so files land as 644/755 and only git's executable bit carries over.
umask 022
tar -xzf "$work/src.tgz" -C "$work" --no-same-permissions --wildcards '*/roles/coachproxy/files/*' || {
  echo "Tarball has no roles/coachproxy/files." >&2
  exit 1
}
src=$(echo "$work"/*/roles/coachproxy/files)

# Show commits' changes that this sync cannot apply (Ansible tasks, other
# roles), so they are not silently missed.
if [[ -n $prev && $prev != "$sha" ]]; then
  outside=$(curl -fsS -m 60 "https://api.github.com/repos/$REPO/compare/$prev...$sha" |
    python3 -c '
import json, sys
for f in json.load(sys.stdin).get("files", []):
    if not f["filename"].startswith("roles/coachproxy/files/"):
        print("  " + f["filename"])
')
  if [[ -n $outside ]]; then
    echo "Changed since ${prev:0:7} but NOT applied by this sync (Ansible-only):"
    echo "$outside"
    echo
  fi
fi

stamp=$(date +%Y%m%d-%H%M%S)
backup=/coachproxy/backup-sync/$stamp
excludes=()
for p in "${PROTECTED[@]}"; do excludes+=(--exclude "/$p"); done

# No -t: compare by content only, so differing mtimes are not changes.
# No --delete: files removed from the repo are left in place.
opts=(-rlp --checksum --itemize-changes "${excludes[@]}")
if [[ $apply = true ]]; then
  opts+=(--backup --backup-dir "$backup")
else
  opts+=(--dry-run)
fi

changes=$(rsync "${opts[@]}" "$src/" /coachproxy/) || {
  echo "rsync failed." >&2
  exit 1
}

# Content changes and new files, then permission-only changes.
changed=$(echo "$changes" | awk '$1 ~ /^[>c]f/ {print $2}')
perms=$(echo "$changes" | awk '$1 ~ /^\.f/ && substr($1, 6, 1) == "p" {print $2}')

if [[ -z $changed ]]; then
  echo "No file changes; /coachproxy already matches ${sha:0:7}."
else
  echo "Files $([[ $apply = true ]] && echo updated || echo "that would change"):"
  echo "$changed" | sed 's/^/  /'
fi
if [[ -n $perms ]]; then
  echo "Permissions $([[ $apply = true ]] && echo updated || echo "that would change"):"
  echo "$perms" | sed 's/^/  /'
fi
echo

if [[ $apply != true ]]; then
  [[ -n $changed ]] && echo "Dry run. Re-run with --apply to make these changes."
  exit 0
fi

restart=()
manual=()
note_manual () { [[ " ${manual[*]} " == *" $1 "* ]] || manual+=("$1"); }

for f in $changed; do
  # Files Ansible gives to pi, except the crontab which cron requires
  # to be owned by root.
  if [[ $f = etc/cron.d/coachproxy ]]; then
    chown root:root /coachproxy/$f
  else
    chown pi:pi /coachproxy/$f
  fi

  case $f in
    etc/nginx/*) reload_nginx=true ;;
    etc/mosquitto/*) restart+=(mosquitto hass-discovery) ;;
    etc/systemd/system/*)
      unit=$(basename $f)
      cp /coachproxy/$f /etc/systemd/system/$unit
      units_changed=true
      # wifi-healthcheck.service is a oneshot its timer runs every minute.
      if [[ $unit != wifi-healthcheck.service ]] && systemctl is-active -q $unit; then
        restart+=($unit)
      fi
      ;;
    bin/hass_command.pl) restart+=(hass-command) ;;
    bin/hass_discovery.pl) restart+=(hass-discovery) ;;
    node-red/*) note_manual "sudo systemctl restart nodered" ;;
    ha-bridge/*) note_manual "sudo systemctl restart habridge" ;;
    bin/rvc2mqtt.pl|etc/rvc-spec.yml) note_manual "restart rvc2mqtt.pl (or reboot)" ;;
    configurator/*) note_manual "re-run the CoachProxy configurator to regenerate the flows" ;;
    etc/ngrok.conf-TEMPLATE|bin/apply_remote_access_settings.sh)
      # Not automatic: it restarts the tunnel, which would cut off a sync
      # being run over remote access.
      note_manual "/coachproxy/bin/apply_remote_access_settings.sh --silent (restarts ngrok)" ;;
    etc/hass-bridge.conf.template) note_manual "sudo /coachproxy/bin/setup_hass_bridge.sh (needs HA MQTT credentials)" ;;
    etc/hosts|etc/resolv.conf|etc/resolvconf.conf|etc/rc.local.coachproxy|etc/dpkg/*)
      note_manual "$f is installed by Ansible; copy it into place by hand" ;;
  esac
done

if [[ $units_changed = true ]]; then
  systemctl daemon-reload
fi

if [[ $reload_nginx = true ]]; then
  if nginx -t 2>/dev/null; then
    systemctl reload nginx && echo "Reloaded nginx."
  else
    # Put the previous config back rather than leave a broken one for
    # the next nginx restart to trip over.
    echo "ERROR: new nginx config fails 'nginx -t'; restoring the previous one."
    cp -a "$backup/etc/nginx/." /coachproxy/etc/nginx/
    nginx -t 2>&1 | tail -1
  fi
fi

# Restart each service once, in order (mosquitto before hass-discovery,
# which republishes the discovery configs mosquitto forgets on restart).
seen=" "
for s in "${restart[@]}"; do
  [[ $seen == *" $s "* ]] && continue
  seen+="$s "
  systemctl restart $s && echo "Restarted $s."
done

printf 'commit %s\nref %s\ndate %s\n' "$sha" "$ref" "$(date --rfc-3339=seconds)" > $deployed

if [[ ${#manual[@]} -gt 0 ]]; then
  echo
  echo "Not done automatically:"
  printf '  %s\n' "${manual[@]}"
fi

if [[ -d $backup ]]; then
  echo
  echo "Replaced files were saved in $backup"
fi
# Keep the 10 most recent backups.
ls -1dt /coachproxy/backup-sync/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf
$log "$script deployed $ref ${sha:0:7}$([[ -z $changed ]] && echo " (no file changes)")"
