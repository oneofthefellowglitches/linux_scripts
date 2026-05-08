#!/usr/bin/env bash
# script takes: base image path, VM name prefix, count, CPUs, RAM (MB), 
# disk size (GB), SSH public key, parallelism, and network name; 
# it should create per-VM qcow2 disks using the base as backing file, 
# generate cloud-init ISOs with unique hostnames and the provided SSH key, 
# run virt-install to create/import each VM, skip already-existing VMs, 
# and log to /var/log/vm-spawn.log. 
# try a --dry-run flag and exit nonzero on fatal errors.
set -euo pipefail

BASE_IMG="${1:-/var/lib/libvirt/images/ubuntu-22.04-cloud.qcow2}"
PREFIX="${2:-node}"
COUNT="${3:-3}"
CPUS="${4:-2}"
RAM="${5:-2048}"
DISK_GB="${6:-20}"
SSH_PUBKEY="${7:-$(cat ~/.ssh/id_rsa.pub)}"
PARALLEL="${8:-4}"
NETWORK="${9:-default}"
LOG="/var/log/vm-spawn.log"
IMG_DIR="/var/lib/libvirt/images"
DRY_RUN=0   # set to 1 to test

log(){ echo "$(date --iso-8601=seconds) $*" >> "$LOG"; }

ensure_tools(){
  for t in qemu-img cloud-localds virt-install virsh; do
    command -v "$t" >/dev/null 2>&1 || { echo "Missing $t"; exit 2; }
  done
}

create_one(){
  idx="$1"
  name="${PREFIX}-${idx}"
  disk="${IMG_DIR}/${name}.qcow2"
  cidata="${IMG_DIR}/${name}-cidata.iso"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    log "Skipping existing $name"
    echo "$name:EXISTS"
    return 0
  fi

  log "Preparing $name"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would create disk $disk and cidata $cidata and run virt-install"
    echo "$name:DRYRUN"
    return 0
  fi

  # create thin qcow2 with backing file
  qemu-img create -f qcow2 -o backing_file="$BASE_IMG" "$disk" "${DISK_GB}G"

  # cloud-init data
  tmpd=$(mktemp -d)
  cat > "$tmpd/user-data" <<EOF
#cloud-config
hostname: $name
ssh_authorized_keys:
  - $SSH_PUBKEY
EOF
  echo "instance-id: $name" > "$tmpd/meta-data"
  cloud-localds -v "$cidata" "$tmpd/user-data" "$tmpd/meta-data"
  rm -rf "$tmpd"

  virt-install --name "$name" --ram "$RAM" --vcpus "$CPUS" \
    --disk "path=${disk},format=qcow2" --disk "path=${cidata},device=cdrom" \
    --os-variant ubuntu22.04 --import --network network=${NETWORK} --noautoconsole --quiet

  log "Created $name"
  echo "$name:CREATED"
}

main(){
  ensure_tools
  seq 1 "$COUNT" | xargs -P "$PARALLEL" -n1 -I{} bash -c 'create_one "$@"' _ {}
}

main
