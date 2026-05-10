#!/usr/bin/env bash
# vm-dashboard.sh — Live terminal dashboard for all VMs
# Refreshes every N seconds, shows CPU/Mem/Disk/Net at a glance.

set -euo pipefail
REFRESH=${1:-5}
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

color_state() {
    case "$1" in
        running)   echo -e "\e[32m● running\e[0m" ;;
        paused)    echo -e "\e[33m⏸ paused\e[0m"  ;;
        shut\ off) echo -e "\e[31m○ shut off\e[0m" ;;
        *)         echo -e "\e[90m? $1\e[0m"       ;;
    esac
}

while true; do
    clear
    printf "\e[1m%-20s %-14s %6s %10s %10s %12s\e[0m\n" \
        "VM NAME" "STATE" "vCPUs" "MEM(MiB)" "DISK(GiB)" "NET-TX(KiB)"
    printf '%.0s─' {1..80}; echo

    virsh -c "$URI" list --all --name | while read -r vm; do
        [[ -z "$vm" ]] && continue
        state=$(virsh -c "$URI" domstate "$vm" 2>/dev/null || echo "unknown")
        vcpus="-"; mem="-"; disk="-"; net_tx="-"

        if [[ "$state" == "running" ]]; then
            # Grab domstats in one call for performance
            stats=$(virsh -c "$URI" domstats "$vm" --cpu-total --balloon --block --net 2>/dev/null)
            vcpus=$(virsh -c "$URI" vcpucount "$vm" --current 2>/dev/null || echo "?")
            mem=$(echo "$stats" | awk -F= '/balloon.current/{printf "%.0f", $2/1024}')
            disk=$(echo "$stats" | awk -F= '/block.0.physical/{printf "%.1f", $2/1073741824}')
            net_tx=$(echo "$stats" | awk -F= '/net.0.tx.bytes/{printf "%.0f", $2/1024}')
        fi

        printf "%-20s %-14b %6s %10s %10s %12s\n" \
            "$vm" "$(color_state "$state")" "$vcpus" "$mem" "$disk" "$net_tx"
    done

    printf '\n\e[90mRefreshing every %ss · Press Ctrl+C to exit\e[0m\n' "$REFRESH"
    sleep "$REFRESH"
done