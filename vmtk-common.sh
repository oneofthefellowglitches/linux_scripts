#!/usr/bin/env bash
# =============================================================================
# vmtk-common.sh — Shared library for the vmtk suite
# Source this file; never execute it directly.
# =============================================================================

# ── Colour palette ────────────────────────────────────────────────────────────
RED='\e[31m'; YEL='\e[33m'; GRN='\e[32m'; CYN='\e[36m'
BLD='\e[1m';  DIM='\e[2m';  RST='\e[0m'

# ── Structured logging ────────────────────────────────────────────────────────
# Usage: log INFO|WARN|ERROR|OK "message" [vm-name]
log() {
    local level="$1" msg="$2" ctx="${3:-}"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local tag colour
    case "$level" in
        INFO)  colour="$CYN"; tag="INFO " ;;
        WARN)  colour="$YEL"; tag="WARN " ;;
        ERROR) colour="$RED"; tag="ERROR" ;;
        OK)    colour="$GRN"; tag="OK   " ;;
        *)     colour="$DIM"; tag="?????" ;;
    esac
    local line="[${ts}] [${tag}]${ctx:+ [${ctx}]} ${msg}"
    printf "${colour}%s${RST}\n" "$line" >&2
    # Append plain text to global log if VMTK_LOG is set
    [[ -n "${VMTK_LOG:-}" ]] && echo "$line" >> "$VMTK_LOG"
}

# ── Dependency guard ──────────────────────────────────────────────────────────
require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "Missing required commands: ${missing[*]}"
        log ERROR "Install them and retry."
        exit 2
    fi
}

# ── Root / libvirt connectivity check ────────────────────────────────────────
check_libvirt() {
    local uri="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
    virsh -c "$uri" version &>/dev/null || {
        log ERROR "Cannot connect to libvirtd at ${uri}"
        exit 2
    }
}

# ── Blockcommit pivot: merge overlay back into backing file, re-attach ────────
# Usage: blockcommit_pivot <vm> <disk-device> <overlay-path>
blockcommit_pivot() {
    local vm="$1" dev="$2" overlay="$3"
    log INFO "  Pivoting ${dev} back to base (blockcommit)…" "$vm"

    # Start an active blockcommit so writes go back to the base while
    # the VM continues running; wait until the mirror is synced.
    virsh blockcommit "$vm" "$dev" \
        --active --verbose --pivot --wait 2>/dev/null || {
        log WARN "  blockcommit pivot failed for ${dev}; attempting blockpull…" "$vm"
        virsh blockpull "$vm" --path "$overlay" --wait 2>/dev/null || {
            log ERROR "  Both pivot strategies failed for ${dev} on ${vm}!" "$vm"
            return 1
        }
    }
    log OK "  Pivot complete for ${dev}." "$vm"
}
