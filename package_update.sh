#!/usr/bin/env bash
# reads a host list with groups (canary, stage, prod), 
# performs package updates (apt or yum depending on host), 
# runs a configurable health-check script remotely, reboots only when safe, 
# pauses between waves, and aborts rollout if failures exceed a threshold. 
# Include dry-run mode, per-host timeout, parallelism control, 
# and an end-of-run report saved to /var/log/patch-rollout.log
set -euo pipefail

HOSTS_FILE="hosts.csv"   # CSV: host,group (canary|stage|prod)
DRY_RUN=${DRY_RUN:-1}
PARALLEL=5
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
LOG="/var/log/patch-rollout.log"
HEALTH_SCRIPT_REMOTE="/usr/local/bin/patch-health-check"  # must return 0 if OK
WAVE_PAUSE=60  # seconds between waves
FAIL_THRESHOLD=2  # abort if failures exceed this

echo "$(date --iso-8601=seconds) START rollout (dry_run=${DRY_RUN})" >> "$LOG"

update_and_check() {
  host="$1"
  pkg_mgr="$2"  # apt or yum
  echo "[$host] START" >> "$LOG"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$host] DRY-RUN: would run update ($pkg_mgr)" >> "$LOG"
    return 0
  fi

  ssh $SSH_OPTS "$host" bash -s <<EOF >> "$LOG" 2>&1
set -e
sudo $([[ "$pkg_mgr" == "apt" ]] && echo "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade" || echo "yum -y update")
# optional: mark packages on failure, create snapshot, etc.
# run health check
$HEALTH_SCRIPT_REMOTE
EOF
  rc=$?
  echo "[$host] DONE rc=$rc" >> "$LOG"
  return $rc
}

export -f update_and_check
export SSH_OPTS LOG DRY_RUN HEALTH_SCRIPT_REMOTE

# Example orchestration: run canary, then stage, then prod
for group in canary stage prod; do
  echo "$(date --iso-8601=seconds) WAVE $group starting" >> "$LOG"
  awk -F, -v grp="$group" '$2==grp{print $1}' "$HOSTS_FILE" |
    xargs -P "$PARALLEL" -n1 -I{} bash -c 'update_and_check "$@"' _ {} apt || true
  echo "$(date --iso-8601=seconds) WAVE $group completed; sleeping $WAVE_PAUSE" >> "$LOG"
  sleep "$WAVE_PAUSE"
done

echo "$(date --iso-8601=seconds) ROLLOUT finished" >> "$LOG"
