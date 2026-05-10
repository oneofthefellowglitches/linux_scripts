#!/usr/bin/env bash
# vm-migrate-live.sh — Live-migrate a VM to another KVM host with pre-flight checks
# Usage: vm-migrate-live.sh <vm-name> <destination-host>

set -euo pipefail

VM="${1:?Usage: vm-migrate-live.sh <vm-name> <dest-host>}"
DEST="${2:?Provide destination host (e.g., kvm-node02)}"
DEST_URI="qemu+ssh://${DEST}/system"

echo "🔍 Pre-flight checks for migrating '${VM}' → ${DEST}..."

# 1. VM must be running
STATE=$(virsh domstate "$VM")
[[ "$STATE" == "running" ]] || { echo "❌ VM is '${STATE}', must be 'running'"; exit 1; }

# 2. Destination host must be reachable
ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEST" true 2>/dev/null \
    || { echo "❌ Cannot SSH to ${DEST}"; exit 1; }

# 3. Check destination has enough resources
NEEDED_MEM=$(virsh dominfo "$VM" | awk '/Max memory/{print $3}')  # KiB
DEST_FREE_MEM=$(ssh "$DEST" "virsh nodememstats | awk '/free/{print \$3}'")
if (( DEST_FREE_MEM < NEEDED_MEM )); then
    echo "❌ Destination has ${DEST_FREE_MEM} KiB free, VM needs ${NEEDED_MEM} KiB"
    exit 1
fi

# 4. Check libvirtd on destination
ssh "$DEST" "systemctl is-active libvirtd" &>/dev/null \
    || { echo "❌ libvirtd not active on ${DEST}"; exit 1; }

echo "✅ All checks passed. Starting live migration..."
echo "   VM:   ${VM}"
echo "   From: $(hostname)"
echo "   To:   ${DEST}"

virsh migrate \
    --live \
    --persistent \
    --undefinesource \
    --verbose \
    "$VM" \
    "$DEST_URI"

echo "🎉 Migration complete! '${VM}' is now on ${DEST}"
echo "   Verify: ssh ${DEST} 'virsh list --all'"