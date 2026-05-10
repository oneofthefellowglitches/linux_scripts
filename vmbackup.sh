#!/usr/bin/env bash
# =============================================================================
# vmbackup.sh — Live external-snapshot backup with retention rotation
#
# Usage:
#   vmbackup.sh [OPTIONS] <vm-name>
#   vmbackup.sh [OPTIONS] --all
#
# Options:
#   --all                  Backup every defined VM
#   --backup-root DIR      Base backup directory      (default: /backups/vms)
#   --keep N               Daily backups to retain    (default: 7)
#   --remote DEST          rclone/rsync remote target (e.g. "s3:mybucket/vms")
#   --remote-tool TOOL     "rclone" or "rsync"        (default: rclone)
#   --snap-dir DIR         Temp snapshot overlay dir  (default: /tmp/vmsnaps)
#   --log FILE             Append structured log here
#   --dry-run              Print actions, do nothing
#   --no-quiesce           Skip --quiesce even for running VMs (no qemu-ga)
#
# Exit codes:
#   0  All VMs backed up successfully
#   1  One or more VMs failed (partial success)
#   2  Fatal pre-flight failure
#
# Dependencies: virsh, qemu-img, rclone OR rsync, pigz (optional)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/vmtk-common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backups/vms"
KEEP=7
REMOTE=""
REMOTE_TOOL="rclone"
SNAP_DIR="/tmp/vmsnaps"
DRY_RUN=false
NO_QUIESCE=false
VMTK_LOG="/var/log/vmtk/vmbackup.log"
TARGET_VMS=()
BACKUP_ALL=false
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,3\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)            BACKUP_ALL=true ;;
        --backup-root)    BACKUP_ROOT="$2"; shift ;;
        --keep)           KEEP="$2"; shift ;;
        --remote)         REMOTE="$2"; shift ;;
        --remote-tool)    REMOTE_TOOL="$2"; shift ;;
        --snap-dir)       SNAP_DIR="$2"; shift ;;
        --log)            VMTK_LOG="$2"; shift ;;
        --dry-run)        DRY_RUN=true ;;
        --no-quiesce)     NO_QUIESCE=true ;;
        --help|-h)        usage ;;
        -*)               log ERROR "Unknown option: $1"; exit 2 ;;
        *)                TARGET_VMS+=("$1") ;;
    esac
    shift
done

mkdir -p "$(dirname "$VMTK_LOG")" "$(dirname "$VMTK_LOG")"
touch "$VMTK_LOG"

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_cmds virsh qemu-img
[[ -n "$REMOTE" ]] && require_cmds "$REMOTE_TOOL"
check_libvirt

if $BACKUP_ALL; then
    mapfile -t TARGET_VMS < <(virsh -c "$URI" list --all --name | grep -v '^$')
fi

if (( ${#TARGET_VMS[@]} == 0 )); then
    log ERROR "No VMs specified. Use --all or pass VM name(s)."
    exit 2
fi

log INFO "════ vmbackup starting — $(date -Iseconds) ════"
log INFO "VMs targeted: ${TARGET_VMS[*]}"
log INFO "Backup root:  ${BACKUP_ROOT}  |  Keep: ${KEEP}  |  Snap dir: ${SNAP_DIR}"
$DRY_RUN && log WARN "DRY-RUN MODE — no changes will be made."

# ── Per-VM backup logic ───────────────────────────────────────────────────────
FAILED_VMS=()

backup_vm() {
    local vm="$1"
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local dest="${BACKUP_ROOT}/${vm}/${ts}"
    local snap_name="${vm}-snap-${ts}"

    log INFO "┌─ Starting backup" "$vm"

    # ── 0. State check ──────────────────────────────────────────────────────
    local state
    state=$(virsh -c "$URI" domstate "$vm" 2>/dev/null) || {
        log ERROR "Cannot query VM state. Does it exist?" "$vm"
        return 1
    }
    log INFO "  State: ${state}" "$vm"

    # ── 1. Enumerate disks ──────────────────────────────────────────────────
    # virsh domblklist --details: columns are Type Device Target Source
    # We only want type=file devices (not CDROMs / network / block)
    local -A disk_targets   # device_target → source_path
    while IFS= read -r line; do
        local dtype target source
        dtype=$(awk '{print $1}' <<< "$line")
        target=$(awk '{print $3}' <<< "$line")
        source=$(awk '{print $4}' <<< "$line")
        [[ "$dtype" == "file" && -n "$source" && "$source" != "-" ]] || continue
        disk_targets["$target"]="$source"
    done < <(virsh -c "$URI" domblklist "$vm" --details 2>/dev/null | tail -n +3)

    if (( ${#disk_targets[@]} == 0 )); then
        log WARN "  No file-backed disks found — skipping." "$vm"
        return 0
    fi

    log INFO "  Disks: $(echo "${!disk_targets[@]}" | tr ' ' ',')" "$vm"

    # ── 2. Create output directory ──────────────────────────────────────────
    $DRY_RUN || install -d -m 0750 "$dest"
    install -d -m 0750 "$SNAP_DIR"

    # ── 3. Build --diskspec arguments for each disk ─────────────────────────
    local diskspec_args=()
    local -A snap_paths   # device → overlay path
    for target in "${!disk_targets[@]}"; do
        local overlay="${SNAP_DIR}/${vm}-${target}-${ts}.qcow2"
        snap_paths["$target"]="$overlay"
        diskspec_args+=("--diskspec" "${target},snapshot=external,file=${overlay}")
    done

    # ── 4. Take live external snapshot ──────────────────────────────────────
    # quiesce only works if qemu-guest-agent is running and VM is up
    local snap_opts=("--disk-only" "--atomic")
    if [[ "$state" == "running" ]] && ! $NO_QUIESCE; then
        # Probe for guest agent
        if virsh -c "$URI" domfsinfo "$vm" &>/dev/null 2>&1; then
            snap_opts+=("--quiesce")
            log INFO "  qemu-ga detected → adding --quiesce" "$vm"
        else
            log WARN "  qemu-ga not responding; skipping --quiesce" "$vm"
        fi
    fi

    log INFO "  Creating external snapshot '${snap_name}'…" "$vm"
    if ! $DRY_RUN; then
        virsh -c "$URI" snapshot-create-as "$vm" "$snap_name" \
            "Auto-backup ${ts}" \
            "${snap_opts[@]}" \
            "${diskspec_args[@]}" || {
            log ERROR "  snapshot-create-as failed!" "$vm"
            return 1
        }
    fi

    # ── 5. Copy each backing (pre-snapshot) disk image to backup dest ────────
    local disk_idx=0
    local copy_ok=true
    for target in "${!disk_targets[@]}"; do
        local src="${disk_targets[$target]}"
        local backup_file="${dest}/disk${disk_idx}_${target}.qcow2"
        log INFO "  Copying ${target}: ${src} → ${backup_file}" "$vm"

        if ! $DRY_RUN; then
            # Use pigz threads if available for inline compression via pipe
            if command -v pigz &>/dev/null; then
                qemu-img convert -f qcow2 -O qcow2 \
                    -o compression_type=zstd \
                    -p "$src" "$backup_file" 2>/dev/null || {
                    log WARN "  zstd compression failed; retrying plain qcow2…" "$vm"
                    qemu-img convert -f qcow2 -O qcow2 -p "$src" "$backup_file" || {
                        log ERROR "  qemu-img convert failed for ${target}!" "$vm"
                        copy_ok=false
                    }
                }
            else
                qemu-img convert -f qcow2 -O qcow2 -p "$src" "$backup_file" || {
                    log ERROR "  qemu-img convert failed for ${target}!" "$vm"
                    copy_ok=false
                }
            fi
        fi
        (( disk_idx++ ))
    done

    # ── 6. Save VM XML definition alongside the disk backup ──────────────────
    log INFO "  Saving VM XML definition…" "$vm"
    $DRY_RUN || virsh -c "$URI" dumpxml "$vm" > "${dest}/vm-definition.xml"

    # ── 7. Pivot back: merge overlay into base, delete temp snapshot ────────
    log INFO "  Pivoting snapshots back to base images…" "$vm"
    if ! $DRY_RUN; then
        if [[ "$state" == "running" ]]; then
            for target in "${!snap_paths[@]}"; do
                blockcommit_pivot "$vm" "$target" "${snap_paths[$target]}" || copy_ok=false
            done
        else
            # For offline VMs, simply delete the external snapshot metadata and
            # overlay; the overlay is empty (VM was not running), so nothing to merge.
            virsh -c "$URI" snapshot-delete "$vm" "$snap_name" --metadata 2>/dev/null || true
            for overlay in "${snap_paths[@]}"; do
                [[ -f "$overlay" ]] && rm -f "$overlay"
            done
        fi
    fi

    $copy_ok || { log ERROR "  Disk copy step had errors; backup may be incomplete." "$vm"; return 1; }

    # ── 8. Write manifest ────────────────────────────────────────────────────
    if ! $DRY_RUN; then
        {
            echo "vm=${vm}"
            echo "timestamp=${ts}"
            echo "host=$(hostname -f)"
            echo "state_at_backup=${state}"
            echo "virsh_version=$(virsh -c "$URI" version --daemon 2>/dev/null | head -1)"
            for target in "${!disk_targets[@]}"; do
                echo "disk_${target}=${disk_targets[$target]}"
            done
        } > "${dest}/MANIFEST"
        # Compute SHA256 for each backup disk
        (cd "$dest" && sha256sum disk*.qcow2 > SHA256SUMS 2>/dev/null || true)
    fi

    log OK "  Backup written to: ${dest}" "$vm"

    # ── 9. Remote push ───────────────────────────────────────────────────────
    if [[ -n "$REMOTE" ]]; then
        log INFO "  Pushing to remote: ${REMOTE}" "$vm"
        if ! $DRY_RUN; then
            case "$REMOTE_TOOL" in
                rclone)
                    rclone copy "$dest" "${REMOTE}/${vm}/${ts}" \
                        --progress --transfers=4 \
                        --retries=3 --low-level-retries=10 || \
                        log WARN "  rclone push failed (non-fatal)" "$vm"
                    ;;
                rsync)
                    rsync -avz --compress-choice=zstd \
                        "${dest}/" "${REMOTE}/${vm}/${ts}/" || \
                        log WARN "  rsync push failed (non-fatal)" "$vm"
                    ;;
                *)
                    log WARN "  Unknown remote tool: ${REMOTE_TOOL}" "$vm"
                    ;;
            esac
        fi
    fi

    # ── 10. Retention rotation ───────────────────────────────────────────────
    rotate_backups "$vm"

    log OK "└─ Backup complete" "$vm"
}

# ── Retention rotation ────────────────────────────────────────────────────────
rotate_backups() {
    local vm="$1"
    local vm_dir="${BACKUP_ROOT}/${vm}"
    [[ -d "$vm_dir" ]] || return 0

    # Directories are named YYYYmmdd-HHMMSS — sort is lexicographic = chronological
    mapfile -t all_backups < <(find "$vm_dir" -mindepth 1 -maxdepth 1 -type d | sort)
    local count="${#all_backups[@]}"

    if (( count > KEEP )); then
        local to_delete=$(( count - KEEP ))
        log INFO "  Rotation: ${count} backups found, pruning ${to_delete} oldest (keep=${KEEP})" "$vm"
        for (( i=0; i<to_delete; i++ )); do
            local old_dir="${all_backups[$i]}"
            log INFO "  Deleting: ${old_dir}" "$vm"
            $DRY_RUN || rm -rf "$old_dir"
        done
    else
        log INFO "  Rotation: ${count}/${KEEP} slots used — nothing to prune." "$vm"
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for vm in "${TARGET_VMS[@]}"; do
    if backup_vm "$vm"; then
        log OK "VM backed up successfully" "$vm"
    else
        log ERROR "VM backup FAILED" "$vm"
        FAILED_VMS+=("$vm")
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log INFO "════ vmbackup summary ════"
log INFO "Total:   ${#TARGET_VMS[@]}"
log OK   "Success: $(( ${#TARGET_VMS[@]} - ${#FAILED_VMS[@]} ))"
if (( ${#FAILED_VMS[@]} > 0 )); then
    log ERROR "Failed:  ${#FAILED_VMS[@]} — ${FAILED_VMS[*]}"
    exit 1
fi
log OK "All backups completed successfully."
exit 0