#!/usr/bin/env bash
# vm-snapshot-rotate.sh — Create a snapshot and enforce retention policy
# Usage: vm-snapshot-rotate.sh <vm-name> [max-snapshots=5]

set -euo pipefail

VM="${1:?Usage: vm-snapshot-rotate.sh <vm-name> [max-snapshots]}"
MAX_SNAPS="${2:-5}"
SNAP_NAME="${VM}-snap-$(date +%Y%m%d-%H%M%S)"

echo "📸 Creating snapshot '${SNAP_NAME}' for VM '${VM}'..."
virsh snapshot-create-as "$VM" "$SNAP_NAME" \
    --description "Auto-snapshot $(date -Iseconds)" \
    --atomic

# --- Enforce rotation ---
SNAP_LIST=$(virsh snapshot-list "$VM" --name | sort)
SNAP_COUNT=$(echo "$SNAP_LIST" | grep -c .)

if (( SNAP_COUNT > MAX_SNAPS )); then
    TO_DELETE=$((SNAP_COUNT - MAX_SNAPS))
    echo "🗑️  Pruning ${TO_DELETE} old snapshot(s)..."
    echo "$SNAP_LIST" | head -n "$TO_DELETE" | while read -r old_snap; do
        echo "   Deleting: $old_snap"
        virsh snapshot-delete "$VM" "$old_snap" --metadata 2>/dev/null || \
        virsh snapshot-delete "$VM" "$old_snap"
    done
fi

echo "✅ Snapshots for '${VM}': $(virsh snapshot-list "$VM" --name | wc -l) / ${MAX_SNAPS} max"