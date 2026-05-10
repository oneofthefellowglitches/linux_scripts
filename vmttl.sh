#!/usr/bin/env bash
# "vmttl" – TTL manager and reaper for ephemeral libvirt VMs.
#
# Features:
#  - Track VMs with a configured TTL (e.g. "2h", "3d", "1w30m").
#  - Persist a small DB: /var/lib/vmttl/db.txt (vm|created_epoch|ttl_seconds|action).
#  - On "reap": for expired entries:
#      - destroy: power off and undefine the VM.
#      - shutdown: graceful shutdown only (leave defined).
#      - snapshot-destroy: take a disk-only snapshot, then delete the VM.
#  - Logs to /var/log/vmttl.log.
#  - Safe to run from cron; idempotent.
#
# Usage:
#   vmttl.sh add <vmname> <ttl> [destroy|shutdown|snapshot-destroy]
#   vmttl.sh list
#   vmttl.sh reap
#
# Example:
#   vmttl.sh add lab-ubuntu 3d destroy
#   vmttl.sh reap   # put into cron
set -euo pipefail

DB="${DB:-/var/lib/vmttl/db.txt}"
LOG="${LOG:-/var/log/vmttl.log}"
DEFAULT_ACTION="${DEFAULT_ACTION:-destroy}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$(dirname "$DB")" "$(dirname "$LOG")"

log() {
  echo "$(date --iso-8601=seconds) $*" >> "$LOG"
}

usage() {
  cat <<USAGE
Usage:
  $0 add <vmname> <ttl> [destroy|shutdown|snapshot-destroy]
  $0 list
  $0 reap

TTL format: a sequence of <number><unit>, units in [s,m,h,d,w], e.g.:
  30m, 2h, 1d12h, 1w

Examples:
  $0 add lab-ubuntu 3d destroy
  DRY_RUN=1 $0 reap
USAGE
  exit 1
}

# parse TTL string like "1h30m" -> seconds
parse_ttl() {
  local ttl_str="$1"
  local total=0
  local num unit rest="$ttl_str"

  [[ -n "$rest" ]] || { echo "0"; return; }

  while [[ "$rest" =~ ^([0-9]+)([smhdw])(.*)$ ]]; do
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    case "$unit" in
      s) total=$(( total + num )) ;;
      m) total=$(( total + num * 60 )) ;;
      h) total=$(( total + num * 3600 )) ;;
      d) total=$(( total + num * 86400 )) ;;
      w) total=$(( total + num * 604800 )) ;;
      *) echo "Invalid unit in TTL: $unit" >&2; exit 2 ;;
    esac
  done

  if [[ -n "$rest" ]]; then
    echo "Invalid TTL format: $ttl_str" >&2
    exit 2
  fi

  echo "$total"
}

ensure_vm_exists() {
  local vm="$1"
  if ! virsh dominfo "$vm" >/dev/null 2>&1; then
    echo "VM $vm does not exist" >&2
    exit 2
  fi
}

cmd_add() {
  local vm ttl_str action created ttl

  vm="$1"
  ttl_str="$2"
  action="${3:-$DEFAULT_ACTION}"

  case "$action" in
    destroy|shutdown|snapshot-destroy) ;;
    *) echo "Invalid action: $action" >&2; exit 2 ;;
  esac

  ensure_vm_exists "$vm"

  ttl="$(parse_ttl "$ttl_str")"
  if [[ "$ttl" -le 0 ]]; then
    echo "TTL must be > 0" >&2
    exit 2
  fi

  created="$(date +%s)"

  # lock and rewrite DB atomically
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$DB" ]]; then
    awk -F'|' -v vm="$vm" '$1!=vm' "$DB" > "$tmp"
  fi
  echo "$vm|$created|$ttl|$action" >> "$tmp"
  mv "$tmp" "$DB"

  log "ADD vm=$vm ttl=$ttl_str ($ttl s) action=$action created=$created"
  echo "Registered TTL for $vm: $ttl_str ($ttl seconds), action=$action"
}

cmd_list() {
  if [[ ! -f "$DB" ]] || [[ ! -s "$DB" ]]; then
    echo "No entries in $DB"
    return 0
  fi
  printf "%-25s %-20s %-20s %-18s %-20s\n" "VM" "CREATED" "EXPIRES" "TTL(s)" "ACTION"
  while IFS='|' read -r vm created ttl action; do
    [[ -z "$vm" ]] && continue
    local exp
    exp=$(( created + ttl ))
    printf "%-25s %-20s %-20s %-18s %-20s\n" \
      "$vm" \
      "$(date -d "@$created" '+%Y-%m-%d %H:%M:%S')" \
      "$(date -d "@$exp" '+%Y-%m-%d %H:%M:%S')" \
      "$ttl" \
      "$action"
  done < "$DB"
}

destroy_vm() {
  local vm="$1"
  log "DESTROY requested for $vm"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would destroy and undefine $vm"
    return
  fi

  if virsh domstate "$vm" 2>/dev/null | grep -q running; then
    virsh destroy "$vm"
  fi
  # safer default: do NOT remove-all-storage automatically
  virsh undefine "$vm" || true
  log "Destroyed $vm"
}

shutdown_vm() {
  local vm="$1"
  log "SHUTDOWN requested for $vm"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would shutdown $vm"
    return
  fi

  virsh shutdown "$vm" || true
  log "Shutdown signal sent to $vm"
}

snapshot_and_destroy_vm() {
  local vm="$1"
  local snap="ttl-expired-$(date +%Y%m%d%H%M%S)"
  log "SNAPSHOT+DESTROY requested for $vm"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would snapshot ($snap) and destroy $vm"
    return
  fi

  if virsh dominfo "$vm" >/dev/null 2>&1; then
    virsh snapshot-create-as --domain "$vm" --name "$snap" \
      --disk-only --atomic --quiesce || log "Snapshot failed for $vm (continuing)"
    destroy_vm "$vm"
  else
    log "VM $vm not found when attempting snapshot-destroy"
  fi
}

cmd_reap() {
  [[ -f "$DB" ]] || { echo "No DB at $DB, nothing to reap."; exit 0; }

  local now tmp changes
  now="$(date +%s)"
  tmp="$(mktemp)"
  changes=0

  while IFS='|' read -r vm created ttl action; do
    [[ -z "$vm" ]] && continue
    local exp
    exp=$(( created + ttl ))

    # If VM gone, drop entry silently
    if ! virsh dominfo "$vm" >/dev/null 2>&1; then
      log "VM $vm no longer exists; removing TTL entry"
      changes=1
      continue
    fi

    if [[ "$now" -ge "$exp" ]]; then
      log "TTL EXPIRED vm=$vm created=$created ttl=$ttl action=$action"
      changes=1
      case "$action" in
        destroy)          destroy_vm "$vm" ;;
        shutdown)         shutdown_vm "$vm" ;;
        snapshot-destroy) snapshot_and_destroy_vm "$vm" ;;
      esac
      # do not re-add to DB
    else
      # still valid, keep in DB
      echo "$vm|$created|$ttl|$action" >> "$tmp"
    fi
  done < "$DB"

  mv "$tmp" "$DB"

  if [[ "$changes" -eq 0 ]]; then
    echo "No TTL expirations."
    exit 0
  else
    echo "Reap completed; some actions executed (see $LOG)."
    exit 0
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    add)
      [[ $# -ge 3 ]] || usage
      shift
      cmd_add "$@"
      ;;
    list)
      cmd_list
      ;;
    reap)
      cmd_reap
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
