#!/usr/bin/env bash
# vm-clone-fleet.sh — Clone a template VM into a fleet of N instances
# Usage: vm-clone-fleet.sh <template-vm> <prefix> <count> [start-index]

set -euo pipefail

TEMPLATE="${1:?Usage: vm-clone-fleet.sh <template> <prefix> <count> [start-idx]}"
PREFIX="${2:?Provide a naming prefix (e.g., 'worker')}"
COUNT="${3:?How many clones?}"
START="${4:-1}"

# Template must be shut off
STATE=$(virsh domstate "$TEMPLATE" 2>/dev/null)
[[ "$STATE" == "shut off" ]] || { echo "❌ Template must be shut off (currently: $STATE)"; exit 1; }

echo "🏭 Cloning '${TEMPLATE}' → ${COUNT} VMs as '${PREFIX}-{${START}..$(( START + COUNT - 1 ))}'..."

for i in $(seq "$START" "$(( START + COUNT - 1 ))"); do
    CLONE_NAME="${PREFIX}-$(printf '%02d' "$i")"
    CLONE_DISK="/var/lib/libvirt/images/${CLONE_NAME}.qcow2"

    if virsh dominfo "$CLONE_NAME" &>/dev/null; then
        echo "   ⏭️  ${CLONE_NAME} already exists, skipping"
        continue
    fi

    echo -n "   🔄 ${CLONE_NAME}..."
    virt-clone \
        --original "$TEMPLATE" \
        --name "$CLONE_NAME" \
        --file "$CLONE_DISK" \
        --auto-clone \
        &>/dev/null

    # Customize hostname inside the image (requires libguestfs)
    if command -v virt-customize &>/dev/null; then
        virt-customize -a "$CLONE_DISK" \
            --hostname "$CLONE_NAME" \
            --selinux-relabel \
            &>/dev/null
    fi

    echo " ✅"
done

echo ""
echo "🎉 Fleet ready! Start all with:"
echo "   for vm in ${PREFIX}-{$(printf '%02d' "$START")..$(printf '%02d' "$(( START + COUNT - 1 ))")}; do virsh start \$vm; done"