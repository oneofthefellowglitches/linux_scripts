#!/usr/bin/env bash
# vm-resource-report.sh — Generate a resource utilization summary for all VMs
# Usage: vm-resource-report.sh [--email admin@example.com]

set -euo pipefail

REPORT="/tmp/vm-report-$(date +%Y%m%d).txt"
EMAIL=""
[[ "${1:-}" == "--email" ]] && EMAIL="${2:-}"

{
    echo "═══════════════════════════════════════════════════"
    echo " VM RESOURCE REPORT — $(date '+%A, %B %d %Y %H:%M')"
    echo " Host: $(hostname) | Kernel: $(uname -r)"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # Host overview
    TOTAL_MEM=$(free -m | awk '/Mem:/{print $2}')
    USED_MEM=$(free -m | awk '/Mem:/{print $3}')
    HOST_CPUS=$(nproc)
    RUNNING=$(virsh list --state-running --name | grep -c . || true)
    TOTAL=$(virsh list --all --name | grep -c . || true)

    printf "Host Resources: %s CPUs, %s/%s MiB RAM used\n" "$HOST_CPUS" "$USED_MEM" "$TOTAL_MEM"
    printf "VMs: %s running / %s total\n\n" "$RUNNING" "$TOTAL"

    printf "%-22s %5s %8s %10s %8s %s\n" "VM" "vCPU" "RAM(MiB)" "DISK(GiB)" "SNAPS" "STATE"
    printf '%.0s─' {1..72}; echo

    virsh list --all --name | while read -r vm; do
        [[ -z "$vm" ]] && continue
        state=$(virsh domstate "$vm" 2>/dev/null)
        vcpus=$(virsh vcpucount "$vm" --maximum 2>/dev/null || echo "?")
        maxmem=$(virsh dominfo "$vm" 2>/dev/null | awk '/Max memory/{printf "%.0f", $3/1024}')
        snaps=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -c . || echo 0)

        # Disk total
        disk_total=0
        while read -r path; do
            [[ -f "$path" ]] && {
                sz=$(qemu-img info --output=json "$path" 2>/dev/null | \
                     python3 -c "import sys,json; print(json.load(sys.stdin).get('virtual-size',0))" 2>/dev/null || echo 0)
                disk_total=$(( disk_total + sz ))
            }
        done < <(virsh domblklist "$vm" --details 2>/dev/null | awk '/file/{print $NF}')
        disk_gib=$(echo "$disk_total" | awk '{printf "%.1f", $1/1073741824}')

        printf "%-22s %5s %8s %10s %8s %s\n" "$vm" "$vcpus" "$maxmem" "$disk_gib" "$snaps" "$state"
    done

    echo ""
    echo "═══════════════════════════════════════════════════"

    # Overcommit warnings
    TOTAL_VCPUS=$(virsh list --state-running --name | while read -r v; do
        [[ -n "$v" ]] && virsh vcpucount "$v" --current 2>/dev/null
    done | awk '{s+=$1} END{print s+0}')

    TOTAL_VM_MEM=$(virsh list --state-running --name | while read -r v; do
        [[ -n "$v" ]] && virsh dominfo "$v" 2>/dev/null | awk '/Max memory/{print $3}'
    done | awk '{s+=$1} END{printf "%.0f", s/1024}')

    echo ""
    echo "⚡ Overcommit Analysis (running VMs only):"
    printf "   vCPU: %s allocated / %s physical (%.1fx)\n" \
        "$TOTAL_VCPUS" "$HOST_CPUS" "$(echo "$TOTAL_VCPUS $HOST_CPUS" | awk '{printf "%.1f", $1/$2}')"
    printf "   RAM:  %s MiB allocated / %s MiB physical (%.1fx)\n" \
        "$TOTAL_VM_MEM" "$TOTAL_MEM" "$(echo "$TOTAL_VM_MEM $TOTAL_MEM" | awk '{printf "%.1f", $1/$2}')"

} | tee "$REPORT"

# Optionally email
if [[ -n "$EMAIL" ]] && command -v mail &>/dev/null; then
    mail -s "VM Report: $(hostname) $(date +%Y-%m-%d)" "$EMAIL" < "$REPORT"
    echo "📧 Report emailed to ${EMAIL}"
fi

echo "📄 Report saved: ${REPORT}"