#!/usr/bin/env bash
# vm-firecracker.sh — Emergency VM fleet controls
# Usage: vm-firecracker.sh <stop-all|start-all|drain|freeze|thaw>

set -euo pipefail
ACTION="${1:?Usage: vm-firecracker.sh <stop-all|start-all|drain|freeze|thaw>}"

confirm() {
    read -rp "⚠️  ${1} Are you sure? (type YES): " ans
    [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 0; }
}

case "$ACTION" in
    stop-all)
        confirm "This will SHUT DOWN every running VM."
        virsh list --state-running --name | while read -r vm; do
            [[ -n "$vm" ]] && { echo "🛑 Stopping $vm..."; virsh shutdown "$vm"; }
        done
        echo "⏳ Sent shutdown signal to all VMs. Use 'virsh list' to monitor."
        ;;
    start-all)
        virsh list --state-shutoff --name | while read -r vm; do
            [[ -n "$vm" ]] && { echo "▶️  Starting $vm..."; virsh start "$vm"; }
        done
        ;;
    drain)
        confirm "This will gracefully shut down VMs one-by-one with 30s intervals."
        virsh list --state-running --name | while read -r vm; do
            [[ -n "$vm" ]] && {
                echo "🔽 Draining $vm..."
                virsh shutdown "$vm"
                sleep 30
            }
        done
        ;;
    freeze)
        confirm "This will PAUSE (suspend) all running VMs."
        virsh list --state-running --name | while read -r vm; do
            [[ -n "$vm" ]] && { echo "❄️  Freezing $vm..."; virsh suspend "$vm"; }
        done
        ;;
    thaw)
        virsh list --state-paused --name | while read -r vm; do
            [[ -n "$vm" ]] && { echo "🔥 Resuming $vm..."; virsh resume "$vm"; }
        done
        ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Valid: stop-all | start-all | drain | freeze | thaw"
        exit 1
        ;;
esac