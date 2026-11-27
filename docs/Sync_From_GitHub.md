Updating a running CoachProxy from GitHub
=========================================

Changes are made in this repo, pushed to GitHub, and then pulled onto
the Pi with `/coachproxy/bin/sync_from_github.sh`. Nothing should be
edited directly on the Pi; if a quick fix is made there, copy it back
into the repo and commit it.

What it does
------------

The script brings `/coachproxy` in line with `roles/coachproxy/files/`
at the branch named in `/coachproxy/etc/sync.conf`.

* It downloads a tarball from GitHub, so git and SSH keys are not
  needed on the Pi.
* It never deletes files, and never overwrites files the Pi rewrites at
  runtime (`ha-bridge/device.db`).
* Every file it replaces is saved under `/coachproxy/backup-sync/<time>/`
  (the 10 most recent are kept).
* It reloads nginx (after `nginx -t`; a failing config is rolled back),
  installs changed systemd units, and restarts mosquitto and the Home
  Assistant bridge services when their files change.
* Anything heavier (Node-RED, ha-bridge, rvc2mqtt, the configurator,
  the ngrok tunnel) is listed as a restart for you to do.
* Changes in the commits that it cannot apply, such as Ansible tasks,
  are listed so they are not missed.
* The deployed commit is recorded in `/coachproxy/etc/DEPLOYED`.

Usage
-----

Preview what would change (makes no changes):

    ssh pi@coachproxyos sudo /coachproxy/bin/sync_from_github.sh

Apply it:

    ssh pi@coachproxyos sudo /coachproxy/bin/sync_from_github.sh --apply

Deploy a different branch or commit once, without changing `sync.conf`:

    sudo /coachproxy/bin/sync_from_github.sh --ref <branch|commit>

To change which branch the coach follows, edit `REF` in
`roles/coachproxy/files/etc/sync.conf`, commit, and sync.

Rolling back
------------

Either sync an earlier commit with `--ref`, or copy files back from
`/coachproxy/backup-sync/<time>/`, which mirrors the `/coachproxy` layout.
