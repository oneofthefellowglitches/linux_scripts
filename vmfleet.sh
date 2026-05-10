#!/usr/bin/env bash
# "vmfleet" – run commands in parallel across libvirt VMs discovered by name.
#
# Features:
#   - Discover VMs by name glob pattern or from a list file.
#   - Resolve guest IP via "virsh domifaddr" (guest agent or lease).
#   - Run an arbitrary SSH command against each VM in parallel.
#   - Logs to /var/log/vmfleet.log, reports success/failure.
#
# Usage:
#   vmfleet.sh exec <pattern> -- <command...>
#   vmfleet.sh exec-file <file> -- <command...>
#
# Env:
#   SSH_USER   - user for SSH (default: root)
#   PARALLEL   - concurrency level (default: 10)
#   DRY_RUN    - if 1, do not actually run SSH commands
#
# Examples:
#   vmfleet.sh exec "web-*" -- uptime
#   vmfleet.sh exec-file vms.txt -- sudo systemctl restart nginx
set -euo pipefail

LOG="${LOG:-/var/log/vmfleet.log}"
SSH_USER="${SSH_USER:-root}"
PARALLEL="${PARALLEL:-10}"
DRY_RUN="${DRY_RUN:-0}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8}"

mkdir -p "$(dirname "$LOG")"

log() {
  echo "$(date --iso-8601=seconds) $*" >> "$LOG"
}

usage() {
  cat <<USAGE
Usage:
  $0 exec <pattern> -- <command...>
  $0 exec-file <file> -- <command...>

Env:
  SSH_USER   (default: root)
  PARALLEL   (default: 10)
  DRY_RUN    (0/1)
  SSH_OPTS   (additional ssh options)

Examples:
  $0 exec "web-*" -- uptime
  SSH_USER=ubuntu PARALLEL=20 $0 exec-file vms.txt -- uname -a
USAGE
  exit 1
}

# Get IP for a VM using virsh domifaddr (agent preferred, then lease)
vm_ip() {
  local vm="$1"
  local ip

  # Try guest agent first
  ip=$(virsh domifaddr "$vm" --source agent 2>/dev/null \
        | awk '/ipv4/ {print $4}' | head -n1 | cut -d/ -f1 || true)
  if [[ -n "${ip:-}" ]]; then
    echo "$ip"
    return 0
  fi

  # Fallback: DHCP lease
  ip=$(virsh domifaddr "$vm" --source lease 2>/dev/null \
        | awk '/ipv4/ {print $4}' | head -n1 | cut -d/ -f1 || true)
  if [[ -n "${ip:-}" ]]; then
    echo "$ip"
    return 0
  fi

  return 1
}

run_one() {
  local vm="$1"; shift
  local -a cmd=("$@")
  local ip

  if ! ip=$(vm_ip "$vm"); then
    log "SKIP $vm (no IP found)"
    echo "$vm,SKIP,no_ip"
    return 1
  fi

  log "TARGET $vm ip=$ip cmd=${cmd[*]}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would ssh $SSH_USER@$ip ${cmd[*]}"
    echo "$vm,DRY_RUN,$ip"
    return 0
  fi

  if ssh $SSH_OPTS "$SSH_USER@$ip" "${cmd[@]}"; then
    log "OK $vm $ip"
    echo "$vm,OK,$ip"
    return 0
  else
    log "FAIL $vm $ip"
    echo "$vm,FAIL,$ip"
    return 1
  fi
}

collect_vms_pattern() {
  local pattern="$1"
  # virsh list --all --name | grep pattern-as-glob
  virsh list --all --name | awk -v pat="$pattern" '
    BEGIN {
      # convert shell glob to regex (very simple)
      gsub(/\./,"\\.",pat);
      gsub(/\*/,".*",pat);
      gsub(/\?/,".",pat);
    }
    $0 ~ "^" pat "$" {print $0}
  ' | sed '/^$/d'
}

collect_vms_file() {
  local file="$1"
  sed 's/#.*$//' "$file" | sed '/^[[:space:]]*$/d'
}

cmd_exec() {
  local pattern="$1"; shift
  [[ "${1:-}" == "--" ]] || usage
  shift
  local -a cmd=("$@")

  mapfile -t vms < <(collect_vms_pattern "$pattern")
  if [[ "${#vms[@]}" -eq 0 ]]; then
    echo "No VMs matched pattern: $pattern" >&2
    exit 1
  fi

  log "EXEC pattern=$pattern vms=${#vms[@]} cmd=${cmd[*]}"
  export -f vm_ip run_one
  export LOG SSH_USER DRY_RUN SSH_OPTS

  printf "%s\n" "${vms[@]}" | xargs -P "$PARALLEL" -n1 -I{} bash -c \
    'run_one "$@"' _ {} "${cmd[@]}"
}

cmd_exec_file() {
  local file="$1"; shift
  [[ "${1:-}" == "--" ]] || usage
  shift
  local -a cmd=("$@")

  mapfile -t vms < <(collect_vms_file "$file")
  if [[ "${#vms[@]}" -eq 0 ]]; then
    echo "No VMs found in file: $file" >&2
    exit 1
  fi

  log "EXEC-FILE file=$file vms=${#vms[@]} cmd=${cmd[*]}"
  export -f vm_ip run_one
  export LOG SSH_USER DRY_RUN SSH_OPTS

  printf "%s\n" "${vms[@]}" | xargs -P "$PARALLEL" -n1 -I{} bash -c \
    'run_one "$@"' _ {} "${cmd[@]}"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    exec)
      [[ $# -ge 3 ]] || usage
      shift
      cmd_exec "$@"
      ;;
    exec-file)
      [[ $# -ge 3 ]] || usage
      shift
      cmd_exec_file "$@"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
