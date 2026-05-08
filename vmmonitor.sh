#!/usr/bin/env bash
# "qcow2-monitor" tool that scans a configured images directory (e.g., /var/lib/libvirt/images), for each qcow2 image:
# collect qemu-img info (virtual-size, actual-size, backing-file),
# check image health with qemu-img check (non-destructive),
# compute backing-chain length recursively,
# detect rapid growth (actual-size increase > X% since last run) and deep chains (> Y),
# produce a JSON report /var/log/qcow2-monitor-report.json and append human alerts 
# to /var/log/qcow2-monitor.log,
# on severe issues, move the image to a quarantine dir (or mark for admin) and notify via syslog. 
# try --dry-run, configurable thresholds, and exit code 0=ok,1=warning,2=critical.
set -euo pipefail

IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
REPORT="/var/log/qcow2-monitor-report.json"
LOG="/var/log/qcow2-monitor.log"
QUARANTINE_DIR="/var/lib/libvirt/quarantine"
GROWTH_THRESHOLD_PERCENT=${GROWTH_THRESHOLD_PERCENT:-30}
CHAIN_THRESHOLD=${CHAIN_THRESHOLD:-4}
DRY_RUN=${DRY_RUN:-1}
STATE_DB="/var/lib/qcow2-monitor/state.db"   # format: path|bytes

mkdir -p "$(dirname "$REPORT")" "$QUARANTINE_DIR" "$(dirname "$STATE_DB")"

log(){ echo "$(date --iso-8601=seconds) $*" >> "$LOG"; logger -t qcow2-monitor "$*"; }

# helper to get qemu-img info fields
qinfo(){ qemu-img info --output=json "$1" 2>/dev/null || echo "{}"; }

# compute backing chain length
chain_length(){
  img="$1"
  len=0
  while true; do
    bf=$(qemu-img info --output=json "$img" 2>/dev/null | jq -r '.backing-filename // empty')
    [ -z "$bf" ] && break
    len=$((len+1))
    # resolve relative paths
    if [[ "$bf" != /* ]]; then
      bf="$(dirname "$img")/$bf"
    fi
    img="$bf"
    # safety cap
    [ "$len" -gt 50 ] && break
  done
  echo "$len"
}

# load previous sizes
declare -A PREV
if [ -f "$STATE_DB" ]; then
  while IFS='|' read -r path bytes; do PREV["$path"]="$bytes"; done < "$STATE_DB"
fi

# build new state and report entries
echo "[" > "$REPORT"
first=true
rc=0
for img in "$IMAGES_DIR"/*.qcow2; do
  [ -e "$img" ] || continue
  info=$(qinfo "$img")
  vsize=$(jq -r '.virtual-size // 0' <<<"$info")
  actual=$(stat -c%s "$img")
  bc=$(jq -r '.backing-filename // empty' <<<"$info")
  chain=$(chain_length "$img")
  # qemu-img check (quick, non-destructive)
  check_out=$(qemu-img check "$img" 2>&1 || true)
  check_rc=$?

  prev=${PREV["$img"]:-0}
  growth=0
  if [ "$prev" -gt 0 ]; then
    growth=$(( (actual - prev) * 100 / prev ))
  fi

  status="ok"
  if [ "$check_rc" -ne 0 ]; then status="critical"; rc=2; fi
  if [ "$chain" -ge "$CHAIN_THRESHOLD" ] && [ "$status" = "ok" ]; then status="warning"; rc=$(( rc>1?rc:1 )); fi
  if [ "$growth" -gt "$GROWTH_THRESHOLD_PERCENT" ] && [ "$status" = "ok" ]; then status="warning"; rc=$(( rc>1?rc:1 )); fi

  # JSON entry
  [ "$first" = true ] || echo "," >> "$REPORT"
  first=false
  jq -n --arg path "$img" --argjson vsize "$vsize" --argjson actual "$actual" \
    --arg backing "$bc" --argjson chain "$chain" --argjson growth "$growth" \
    --arg status "$status" --arg check "$check_out" \
    '{path:$path,virtual_size:$vsize,actual_size:$actual,backing:$backing,chain_length:$chain,growth_percent:$growth,status:$status,check_output:$check}' \
    >> "$REPORT"

  # log alerts
  if [ "$status" != "ok" ]; then
    log "ALERT $status $img chain=$chain growth=${growth}% check_rc=$check_rc"
    # quarantine severe (critical) images
    if [ "$status" = "critical" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: would quarantine $img"
      else
        mv "$img" "$QUARANTINE_DIR/" && log "Quarantined $img"
      fi
    fi
  fi

  # update state map
  NEW_STATE+=("$img|$actual")
done
echo "]" >> "$REPORT"

# write state DB atomically
tmp=$(mktemp)
for e in "${NEW_STATE[@]:-}"; do echo "$e"; done > "$tmp"
mv "$tmp" "$STATE_DB"

exit $rc
