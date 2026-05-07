#!/usr/bin/env bash
# script that creates a timestamped snapshot of /srv/data 
# into /backups using rsync with hardlinks to the previous snapshot
# retains 7 daily snapshots, 4 weekly snapshots and 6 monthly snapshots
# and logs actions to /var/log/backup-script.log
set -euo pipefail

SRC="/srv/data"
DEST_BASE="/backups"
LOG="/var/log/backup-script.log"
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
now="$(date +%Y-%m-%d_%H%M%S)"
snapshot="${DEST_BASE}/daily-${now}"
latest_link="${DEST_BASE}/latest"

mkdir -p "$DEST_BASE"
echo "$(date --iso-8601=seconds) START backup $now" >> "$LOG"

# Use --link-dest to hardlink unchanged files from previous snapshot
if [ -e "$latest_link" ]; then
  rsync -aHAX --delete --link-dest="$latest_link" "$SRC/" "$snapshot/" >> "$LOG" 2>&1
else
  rsync -aHAX --delete "$SRC/" "$snapshot/" >> "$LOG" 2>&1
fi

# update 'latest' symlink atomically
ln -sfn "$snapshot" "$latest_link"

echo "$(date --iso-8601=seconds) DONE backup $now" >> "$LOG"

# Rotation: keep only last $KEEP_DAILY daily snapshots (simple example)
ls -1dt "${DEST_BASE}"/daily-* 2>/dev/null | tail -n +$((KEEP_DAILY+1)) | xargs -r rm -rf
# (Extend this script to implement weekly/monthly promotion and retention)
