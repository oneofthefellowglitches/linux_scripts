#!/usr/bin/env bash
# =============================================================================
# vmbalancer.sh — Drain a KVM hypervisor by live-migrating all its VMs
#
# Usage:
#   vmbalancer.sh [OPTIONS]
#
# Options:
#   --hypervisors FILE    Path to hypervisors config (default: /etc/vmtk/hypervisors.conf)
#   --source HOST         Override source host (default: $(hostname -s))
#   --strategy STRAT      Target selection: round-robin|least-vms|most-ram  (default: least-vms)
#   --bandwidth MiB/s     Per-migration bandwidth cap                        (default: 0=unlimited)
#   --parallel N          Max concurrent migrations                          (default: 2)
#   --dry-run             Print plan, do nothing
#   --no-shared-storage   Add --copy-storage-all to virsh migrate
#   --log FILE            Append structured log here
#   --timeout SECS        Per-VM migration timeout                           (default: 600)
#
# hypervisors.conf format (INI-like sections):
#   [kvm-node01]             ← source host
#   targets=kvm-node02,kvm-node03
#
#   [kvm-node02]
#   targets=kvm-node01,kvm-node03
#
# Exit codes:
#   0  All VMs migrated successfully
#   1  One or more VMs failed
#   2  Fatal pre-flight failure
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/vmtk-common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
HYPERVISORS_FILE="/etc/vmtk/hypervisors.conf"
SOURCE_HOST="$(hostname -s)"
STRATEGY="least-vms"
BANDWIDTH=0
MAX_PARALLEL=2
DRY_RUN=false
NO_SHARED_STORAGE=false
VMTK_LOG="/var/log/vmtk/vmbalancer.log"
TIMEOUT=600
URI="qemu:///system"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hypervisors)       HYPERVISORS_FILE="$2"; shift ;;
        --source)            SOURCE_HOST="$2"; shift ;;
        --strategy)          STRATEGY="$2"; shift ;;
        --bandwidth)         BANDWIDTH="$2"; shift ;;
        --parallel)          MAX_PARALLEL="$2"; shift ;;
        --dry-run)           DRY_RUN=true ;;
        --no-shared-storage) NO_SHARED_STORAGE=true ;;
        --log)               VMTK_LOG="$2"; shift ;;
        --timeout)           TIMEOUT="$2"; shift ;;
        --help|-h)           grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,3\}//'; exit 0 ;;
        *)                   log ERROR "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

mkdir -p "$(dirname "$VMTK_LOG")"
touch "$VMTK_LOG"

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_cmds virsh ssh awk
[[ -f "$HYPERVISORS_FILE" ]] || {
    log ERROR "Hypervisors config not found: ${HYPERVISORS_FILE}"
    exit 2
}

log INFO "════ vmbalancer starting — $(date -Iseconds) ════"
log INFO "Source:   ${SOURCE_HOST}"
log INFO "Strategy: ${STRATEGY}"
log INFO "Parallel: ${MAX_PARALLEL}"
$DRY_RUN && log WARN "DRY-RUN MODE — no migrations will execute."

# ── Parse hypervisors.conf ────────────────────────────────────────────────────
# Returns: space-separated list of target hosts for a given source
get_targets_for_source() {
    local src="$1"
    local in_section=false
    while IFS= read -r line; do
        [[ "$line" =~ ^\[(.+)\]$ ]] && {
            [[ "${BASH_REMATCH[1]}" == "$src" ]] && in_section=true || in_section=false
            continue
        }
        $in_section && [[ "$line" =~ ^targets= ]] && {
            echo "${line#targets=}" | tr ',' ' '
            return
        }
    done < "$HYPERVISORS_FILE"
}

TARGETS_RAW=$(get_targets_for_source "$SOURCE_HOST")
if [[ -z "$TARGETS_RAW" ]]; then
    log ERROR "No targets found for source '${SOURCE_HOST}' in ${HYPERVISORS_FILE}"
    exit 2
fi
read -ra ALL_TARGETS <<< "$TARGETS_RAW"
log INFO "Target pool: ${ALL_TARGETS[*]}"

# ── Strategy: select best target host ────────────────────────────────────────
declare -A TARGET_VM_COUNTS   # host → current live VM count
declare -A TARGET_FREE_RAM    # host → free RAM in KiB

probe_target() {
    local host="$1"
    local uri="qemu+ssh://${host}/system"

    # Count running VMs
    TARGET_VM_COUNTS["$host"]=$(
        virsh -c "$uri" list --state-running --name 2>/dev/null | grep -c . || echo 99
    )

    # Free RAM (KiB)
    TARGET_FREE_RAM["$host"]=$(
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" \
            "virsh nodememstats 2>/dev/null | awk '/free/{s+=\$3} END{print s+0}'" \
            2>/dev/null || echo 0
    )

    log INFO "  ${host}: ${TARGET_VM_COUNTS[$host]} VMs running, ${TARGET_FREE_RAM[$host]} KiB free RAM"
}

log INFO "Probing target hosts…"
for t in "${ALL_TARGETS[@]}"; do
    if ssh -o ConnectTimeout=4 -o BatchMode=yes "$t" true 2>/dev/null; then
        probe_target "$t"
    else
        log WARN "  ${t}: SSH unreachable — excluding from pool."
        TARGET_VM_COUNTS["$t"]=9999
        TARGET_FREE_RAM["$t"]=0
    fi
done

ROUND_ROBIN_IDX=0  # state for round-robin

select_target() {
    local required_ram_kib="${1:-0}"
    local best="" best_score=999999

    case "$STRATEGY" in
        round-robin)
            local live_targets=()
            for t in "${ALL_TARGETS[@]}"; do
                (( TARGET_VM_COUNTS["$t"] < 9999 )) && live_targets+=("$t")
            done
            best="${live_targets[$(( ROUND_ROBIN_IDX % ${#live_targets[@]} ))]}"
            (( ROUND_ROBIN_IDX++ ))
            ;;
        least-vms)
            for t in "${ALL_TARGETS[@]}"; do
                local cnt="${TARGET_VM_COUNTS[$t]:-9999}"
                local free="${TARGET_FREE_RAM[$t]:-0}"
                (( free >= required_ram_kib )) || continue
                (( cnt < best_score )) && { best="$t"; best_score="$cnt"; }
            done
            ;;
        most-ram)
            local best_ram=0
            for t in "${ALL_TARGETS[@]}"; do
                local free="${TARGET_FREE_RAM[$t]:-0}"
                (( free >= required_ram_kib )) || continue
                (( free > best_ram )) && { best="$t"; best_ram="$free"; }
            done
            ;;
        *)
            log ERROR "Unknown strategy: ${STRATEGY}"; exit 2 ;;
    esac

    [[ -n "$best" ]] || { log ERROR "No eligible target found for ${required_ram_kib} KiB!"; return 1; }
    echo "$best"
}

# ── Get running VMs on source ─────────────────────────────────────────────────
mapfile -t RUNNING_VMS < <(
    virsh -c "${URI}" list --state-running --name 2>/dev/null | grep -v '^$'
)

if (( ${#RUNNING_VMS[@]} == 0 )); then
    log OK "No running VMs on ${SOURCE_HOST} — nothing to drain."
    exit 0
fi
log INFO "Running VMs to migrate: ${#RUNNING_VMS[@]} — ${RUNNING_VMS[*]}"

# ── Migration worker function ─────────────────────────────────────────────────
FAILED_MIGRATIONS=()
PASSED_MIGRATIONS=()
declare -A MIGRATION_MAP  # vm → target

migrate_vm() {
    local vm="$1"
    local target="$2"
    local dest_uri="qemu+ssh://${target}/system"
    local ts; ts=$(date '+%H:%M:%S')

    log INFO "┌─ [${ts}] Migrating → ${target}" "$vm"

    # Build migrate command
    local migrate_cmd=(
        virsh migrate
        --live
        --persistent
        --undefinesource
        --verbose
        --timeout "$TIMEOUT"
        "$vm"
        "$dest_uri"
    )
    (( BANDWIDTH > 0 )) && migrate_cmd+=(--bandwidth "$BANDWIDTH")
    $NO_SHARED_STORAGE    && migrate_cmd+=(--copy-storage-all)

    if $DRY_RUN; then
        log INFO "  [DRY-RUN] Would execute: ${migrate_cmd[*]}" "$vm"
        return 0
    fi

    local start_ts; start_ts=$(date +%s)
    if "${migrate_cmd[@]}" 2>&1 | while IFS= read -r mline; do
            log INFO "  ↳ ${mline}" "$vm"
        done; then
        local elapsed=$(( $(date +%s) - start_ts ))
        log OK "└─ Migration complete in ${elapsed}s → ${target}" "$vm"
        # Update target's in-memory VM count
        TARGET_VM_COUNTS["$target"]=$(( ${TARGET_VM_COUNTS[$target]} + 1 ))
        return 0
    else
        log ERROR "└─ Migration FAILED → ${target}" "$vm"
        return 1
    fi
}

# ── Migration dispatcher with --parallel concurrency ─────────────────────────
ACTIVE_PIDS=()   # PID list for background jobs
declare -A PID_TO_VM
declare -A PID_TO_TARGET

wait_for_slot() {
    while (( ${#ACTIVE_PIDS[@]} >= MAX_PARALLEL )); do
        local new_pids=()
        for pid in "${ACTIVE_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            else
                # Reap result
                local rc=0
                wait "$pid" || rc=$?
                local finished_vm="${PID_TO_VM[$pid]}"
                local finished_target="${PID_TO_TARGET[$pid]}"
                if (( rc == 0 )); then
                    PASSED_MIGRATIONS+=("${finished_vm}→${finished_target}")
                else
                    FAILED_MIGRATIONS+=("${finished_vm}→${finished_target}")
                fi
                unset "PID_TO_VM[$pid]" "PID_TO_TARGET[$pid]"
            fi
        done
        ACTIVE_PIDS=("${new_pids[@]}")
        (( ${#ACTIVE_PIDS[@]} >= MAX_PARALLEL )) && sleep 1
    done
}

for vm in "${RUNNING_VMS[@]}"; do
    # Determine required RAM for this VM (KiB)
    req_ram=$(virsh dominfo "$vm" 2>/dev/null | awk '/Max memory/{print $3}' || echo 0)

    target=$(select_target "$req_ram") || {
        log ERROR "Cannot place ${vm} — no eligible target. Skipping." "$vm"
        FAILED_MIGRATIONS+=("${vm}→NONE")
        continue
    }

    MIGRATION_MAP["$vm"]="$target"
    log INFO "Scheduled: ${vm} → ${target} (needs ${req_ram} KiB, strategy: ${STRATEGY})"

    wait_for_slot

    # Launch migration in background subshell
    (
        migrate_vm "$vm" "$target"
    ) &
    local_pid=$!
    ACTIVE_PIDS+=("$local_pid")
    PID_TO_VM["$local_pid"]="$vm"
    PID_TO_TARGET["$local_pid"]="$target"
done

# ── Wait for all remaining migrations ────────────────────────────────────────
for pid in "${ACTIVE_PIDS[@]}"; do
    rc=0
    wait "$pid" || rc=$?
    finished_vm="${PID_TO_VM[$pid]:-unknown}"
    finished_target="${PID_TO_TARGET[$pid]:-unknown}"
    if (( rc == 0 )); then
        PASSED_MIGRATIONS+=("${finished_vm}→${finished_target}")
    else
        FAILED_MIGRATIONS+=("${finished_vm}→${finished_target}")
    fi
done

# ── Final summary report ──────────────────────────────────────────────────────
echo ""
echo -e "${BLD}════════════════════ VMBALANCER REPORT ════════════════════${RST}"
printf "%-5s %-6s %-30s %s\n" "No." "RESULT" "VM" "TARGET"
printf '%.0s─' {1..70}; echo

idx=1
for entry in "${PASSED_MIGRATIONS[@]}"; do
    vm="${entry%%→*}"; tgt="${entry##*→}"
    printf "%-5s ${GRN}%-6s${RST} %-30s %s\n" "$idx" "OK" "$vm" "$tgt"
    (( idx++ ))
done
for entry in "${FAILED_MIGRATIONS[@]}"; do
    vm="${entry%%→*}"; tgt="${entry##*→}"
    printf "%-5s ${RED}%-6s${RST} %-30s %s\n" "$idx" "FAILED" "$vm" "$tgt"
    (( idx++ ))
done

echo ""
log INFO "Total:   $(( ${#PASSED_MIGRATIONS[@]} + ${#FAILED_MIGRATIONS[@]} ))"
log OK   "Success: ${#PASSED_MIGRATIONS[@]}"
(( ${#FAILED_MIGRATIONS[@]} > 0 )) && log ERROR "Failed:  ${#FAILED_MIGRATIONS[@]}"

# Full report to log
{
    echo "=== vmbalancer run $(date -Iseconds) ==="
    echo "Source: ${SOURCE_HOST}"
    echo "Strategy: ${STRATEGY}"
    for entry in "${PASSED_MIGRATIONS[@]}"; do echo "OK    ${entry}"; done
    for entry in "${FAILED_MIGRATIONS[@]}"; do echo "FAIL  ${entry}"; done
} >> "$VMTK_LOG"

(( ${#FAILED_MIGRATIONS[@]} > 0 )) && exit 1
exit 0