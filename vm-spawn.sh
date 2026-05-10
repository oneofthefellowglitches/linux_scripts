#!/usr/bin/env bash
# vm-spawn.sh — Spawn a VM from a simple config file
# Usage: vm-spawn.sh myvm.conf
set -euo pipefail

CONFIG="${1:?Usage: vm-spawn.sh <config-file>}"
source "$CONFIG"  # loads: VM_NAME, VCPUS, MEMORY_MB, DISK_GB, OS_VARIANT, IMAGE_URL, SSH_PUBKEY

: "${VM_NAME:?}" "${VCPUS:=2}" "${MEMORY_MB:=2048}" "${DISK_GB:=20}"
: "${OS_VARIANT:=ubuntu22.04}" "${NETWORK:=default}"
: "${POOL_DIR:=/var/lib/libvirt/images}"

DISK_PATH="${POOL_DIR}/${VM_NAME}.qcow2"
CLOUD_INIT_DIR="/tmp/cloud-init-${VM_NAME}"
SEED_ISO="${CLOUD_INIT_DIR}/seed.iso"

echo "🚀 Spawning VM: $VM_NAME (${VCPUS}vCPU / ${MEMORY_MB}MiB / ${DISK_GB}GiB)"

# --- Prerequisite check ---
for cmd in virt-install virsh qemu-img cloud-localds wget; do
    command -v "$cmd" &>/dev/null || { echo "❌ Missing: $cmd"; exit 1; }
done

# --- Download cloud image if not present ---
BASE_IMG="${POOL_DIR}/$(basename "$IMAGE_URL")"
if [[ ! -f "$BASE_IMG" ]]; then
    echo "⬇️  Downloading cloud image..."
    wget -q --show-progress -O "$BASE_IMG" "$IMAGE_URL"
fi

# --- Create VM disk from base ---
echo "💾 Creating disk: $DISK_PATH"
qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK_PATH" "${DISK_GB}G"

# --- Generate cloud-init ---
mkdir -p "$CLOUD_INIT_DIR"
SSH_KEY_CONTENT=$(cat "${SSH_PUBKEY:-$HOME/.ssh/id_rsa.pub}")

cat > "${CLOUD_INIT_DIR}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
users:
  - name: vmadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_KEY_CONTENT}
package_update: true
packages: [qemu-guest-agent, curl, htop]
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

cat > "${CLOUD_INIT_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

cloud-localds "$SEED_ISO" \
    "${CLOUD_INIT_DIR}/user-data" \
    "${CLOUD_INIT_DIR}/meta-data"

# --- Launch VM ---
virt-install \
    --name "$VM_NAME" \
    --vcpus "$VCPUS" \
    --memory "$MEMORY_MB" \
    --os-variant "$OS_VARIANT" \
    --disk "path=${DISK_PATH},format=qcow2" \
    --disk "path=${SEED_ISO},device=cdrom" \
    --network "network=${NETWORK}" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import

echo "✅ VM '$VM_NAME' is booting. SSH in ~60s: ssh vmadmin@${VM_NAME}"
