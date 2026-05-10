#!/usr/bin/env bash
# =============================================================================
# vmnet-snapshot.sh — Snapshot all libvirt virtual networks + DHCP leases
#
# Exports:
#   1. Full XML dump of each network   → OUT_DIR/networks/NET_NAME.xml
#   2. CSV lease table                 → OUT_DIR/leases-YYYYmmddHHMM.csv
#   3. JSON lease table (optional)     → OUT_DIR/leases-YYYYmmddHHMM.json
#   4. Summary report (human-readable) → OUT_DIR/report-YYYYmmddHHMM.txt
#   5. Symlink "latest" → most recent run
#
# Usage:
#   vmnet-snapshot.sh [OPTIONS]
#
# Options:
#   --out-dir DIR      Output base directory       (default: /var/log/vmtk/netsnap)
#   --json             Also emit JSON output
#   --no-xml           Skip per-network XML dumps
#   --filter NET       Only snapshot network NET (repeatable)
#   --log FILE         Append structured log here
#   --quiet            Suppress stdout, write log only
#   --diff             Diff against previous snapshot and report changes
#
# Exit codes:
#   0  Snapshot written successfully
#   2  Fatal pre-flight failure
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/vmtk-common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
OUT_BASE="/var/log/vmtk/netsnap"
EMIT_JSON=false
SKIP_XML=false
QUIET=false
DIFF_MODE=false
FILTER_NETS=()
VMTK_LOG="/var/log/vmtk/vmnet-snapshot.log"
URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)  OUT_BASE="$2"; shift ;;
        --json)     EMIT_JSON=true ;;
        --no-xml)   SKIP_XML=true ;;
        --filter)   FILTER_NETS+=("$2"); shift ;;
        --log)      VMTK_LOG="$2"; shift ;;
        --quiet)    QUIET=true ;;
        --diff)     DIFF_MODE=true ;;
        --help|-h)
            grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,3\}//'; exit 0 ;;
        *)
            log ERROR "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

$QUIET && exec >/dev/null   # Suppress stdout if --quiet

mkdir -p "$(dirname "$VMTK_LOG")"
touch "$VMTK_LOG"

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_cmds virsh
$EMIT_JSON && require_cmds python3
check_libvirt

TS=$(date '+%Y%m%d%H%M')
OUT_DIR="${OUT_BASE}/${TS}"
NET_XML_DIR="${OUT_DIR}/networks"
CSV_FILE="${OUT_DIR}/leases-${TS}.csv"
JSON_FILE="${OUT_DIR}/leases-${TS}.json"
REPORT_FILE="${OUT_DIR}/report-${TS}.txt"

install -d -m 0755 "$OUT_DIR" "$NET_XML_DIR"

log INFO "════ vmnet-snapshot starting — $(date -Iseconds) ════"
log INFO "Output: ${OUT_DIR}"

# ── Enumerate networks ────────────────────────────────────────────────────────
mapfile -t ALL_NETS < <(virsh -c "$URI" net-list --all --name 2>/dev/null | grep -v '^$')

if (( ${#FILTER_NETS[@]} > 0 )); then
    mapfile -t NETS < <(
        for n in "${ALL_NETS[@]}"; do
            for f in "${FILTER_NETS[@]}"; do
                [[ "$n" == "$f" ]] && echo "$n" && break
            done
        done
    )
else
    NETS=("${ALL_NETS[@]}")
fi

if (( ${#NETS[@]} == 0 )); then
    log WARN "No networks found to snapshot."
    exit 0
fi

log INFO "Networks: ${NETS[*]}"

# ── Lease data structures ─────────────────────────────────────────────────────
# We accumulate lease records as plain arrays for portability
LEASE_RECORDS=()  # Each element: "network|mac|ip|hostname|expiry|iface"

# ── CSV header ────────────────────────────────────────────────────────────────
echo "timestamp,network,mac_address,ip_address,hostname,lease_expiry,interface" > "$CSV_FILE"

# ── JSON accumulator (built as a string, flushed at end) ──────────────────────
json_records=""

# ── Per-network processing ────────────────────────────────────────────────────
declare -A NET_STATES
declare -A NET_ACTIVE_LEASES
TOTAL_LEASES=0

for net in "${NETS[@]}"; do
    NET_STATES["$net"]=$(virsh -c "$URI" net-info "$net" 2>/dev/null | awk '/Active/{print $2}')

    # ── a) Dump XML ────────────────────────────────────────────────────────
    if ! $SKIP_XML; then
        local_xml="${NET_XML_DIR}/${net}.xml"
        if virsh -c "$URI" net-dumpxml "$net" > "$local_xml" 2>/dev/null; then
            log INFO "  XML saved: ${local_xml}" "$net"
        else
            log WARN "  net-dumpxml failed" "$net"
        fi
    fi

    # ── b) Extract static DHCP hosts from XML ─────────────────────────────
    # virsh net-dumpxml contains <host mac='..' name='..' ip='..'> entries
    static_count=0
    if [[ -f "${NET_XML_DIR}/${net}.xml" ]]; then
        while IFS= read -r host_line; do
            local_mac=$(echo "$host_line" | grep -oP '(?<=mac=")[^"]+' || true)
            local_name=$(echo "$host_line" | grep -oP '(?<=name=")[^"]+' || echo "(static-unnamed)")
            local_ip=$(echo "$host_line" | grep -oP '(?<=ip=")[^"]+' || true)
            [[ -z "$local_mac" || -z "$local_ip" ]] && continue
            LEASE_RECORDS+=("${net}|${local_mac}|${local_ip}|${local_name}|STATIC|static")
            printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "$TS" "$net" "$local_mac" "$local_ip" "$local_name" "STATIC" "static" \
                >> "$CSV_FILE"
            (( static_count++ ))
            (( TOTAL_LEASES++ ))
        done < <(grep '<host ' "${NET_XML_DIR}/${net}.xml" 2>/dev/null || true)
    fi

    # ── c) Dynamic DHCP leases (active / recent) ──────────────────────────
    # Output format: "Expiry(epoch) MAC IP Hostname Interface"
    dynamic_count=0
    while IFS= read -r lease_line; do
        # Skip header lines
        [[ "$lease_line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$lease_line" =~ ^Expiry ]] && continue
        [[ "$lease_line" =~ ^-+ ]] && continue

        # Parse columns (space-separated, variable whitespace)
        read -r expiry_raw mac ip hostname iface <<< \
            "$(echo "$lease_line" | awk '{print $1" "$2" "$3" "$4" "$5}')"

        [[ -z "$mac" || -z "$ip" ]] && continue

        # Convert epoch to human-readable
        local_expiry="$expiry_raw"
        if [[ "$expiry_raw" =~ ^[0-9]+$ ]]; then
            local_expiry=$(date -d "@${expiry_raw}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
                           || date -r "$expiry_raw" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
                           || echo "$expiry_raw")
        fi

        LEASE_RECORDS+=("${net}|${mac}|${ip}|${hostname:-'(noname)'}|${local_expiry}|${iface:-'?'}")
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$TS" "$net" "$mac" "$ip" "${hostname:-(noname)}" "$local_expiry" "${iface:-?}" \
            >> "$CSV_FILE"
        (( dynamic_count++ ))
        (( TOTAL_LEASES++ ))

    done < <(virsh -c "$URI" net-dhcp-leases "$net" 2>/dev/null || true)

    NET_ACTIVE_LEASES["$net"]=$(( static_count + dynamic_count ))
    log INFO "  Leases: ${static_count} static + ${dynamic_count} dynamic" "$net"
done

# ── JSON output ───────────────────────────────────────────────────────────────
if $EMIT_JSON; then
    python3 - "$CSV_FILE" "$JSON_FILE" << 'PYEOF'
import csv, json, sys
csv_path, json_path = sys.argv[1], sys.argv[2]
rows = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        rows.append(row)
with open(json_path, 'w') as f:
    json.dump({"generated": rows[0]["timestamp"] if rows else "", "leases": rows},
              f, indent=2)
print(f"JSON written: {json_path}")
PYEOF
    log INFO "JSON written: ${JSON_FILE}"
fi

# ── Human-readable report ─────────────────────────────────────────────────────
{
    echo "══════════════════════════════════════════════════════════"
    echo " VMNET SNAPSHOT REPORT"
    printf " Generated : %s\n" "$(date -Iseconds)"
    printf " Host      : %s\n" "$(hostname -f)"
    printf " Networks  : %d\n" "${#NETS[@]}"
    printf " Total IPs : %d\n" "$TOTAL_LEASES"
    echo "══════════════════════════════════════════════════════════"
    echo ""

    for net in "${NETS[@]}"; do
        local_state="${NET_STATES[$net]:-unknown}"
        local_count="${NET_ACTIVE_LEASES[$net]:-0}"
        printf "┌── Network: %-30s [%s]\n" "$net" "$local_state"
        printf "│   XML: %s\n" "${NET_XML_DIR}/${net}.xml"

        # Extract bridge/IP from XML if available
        if [[ -f "${NET_XML_DIR}/${net}.xml" ]]; then
            bridge=$(grep -oP '(?<=<bridge name=")[^"]+' "${NET_XML_DIR}/${net}.xml" 2>/dev/null || echo "?")
            gw_ip=$(grep -oP '(?<= ip address=")[^"]+' "${NET_XML_DIR}/${net}.xml" 2>/dev/null | head -1 || echo "?")
            net_mask=$(grep -oP '(?<=netmask=")[^"]+' "${NET_XML_DIR}/${net}.xml" 2>/dev/null | head -1 || echo "?")
            dhcp_start=$(grep -oP '(?<=<range start=")[^"]+' "${NET_XML_DIR}/${net}.xml" 2>/dev/null || echo "?")
            dhcp_end=$(grep -oP '(?<=end=")[^"]+' "${NET_XML_DIR}/${net}.xml" 2>/dev/null || echo "?")
            printf "│   Bridge: %-15s  GW: %-15s  Mask: %s\n" "$bridge" "$gw_ip" "$net_mask"
            printf "│   DHCP range: %s – %s\n" "$dhcp_start" "$dhcp_end"
        fi
        printf "│   Active leases: %d\n" "$local_count"
        echo  "│"
        printf "│   %-19s %-17s %-15s %-20s %s\n" \
            "EXPIRY/TYPE" "MAC" "IP" "HOSTNAME" "IFACE"
        printf "│   %.0s─" {1..80}; echo ""

        for rec in "${LEASE_RECORDS[@]}"; do
            IFS='|' read -r r_net r_mac r_ip r_host r_exp r_iface <<< "$rec"
            [[ "$r_net" == "$net" ]] || continue
            printf "│   %-19s %-17s %-15s %-20s %s\n" \
                "${r_exp:0:19}" "$r_mac" "$r_ip" "${r_host:0:20}" "$r_iface"
        done
        echo "└────────────────────────────────────────────────────────"
        echo ""
    done

    echo "══ Files ══════════════════════════════════════════════════"
    echo "  CSV:    ${CSV_FILE}"
    $EMIT_JSON && echo "  JSON:   ${JSON_FILE}" || true
    ! $SKIP_XML && echo "  XML:    ${NET_XML_DIR}/" || true
    echo "══════════════════════════════════════════════════════════"
} | tee "$REPORT_FILE"

# ── Diff against previous snapshot ───────────────────────────────────────────
if $DIFF_MODE; then
    PREV_CSV=$(find "$OUT_BASE" -name "leases-*.csv" \
        ! -path "${OUT_DIR}/*" | sort | tail -n 1)

    if [[ -n "$PREV_CSV" && -f "$PREV_CSV" ]]; then
        log INFO "Diffing against previous snapshot: ${PREV_CSV}"
        echo ""
        echo "══ DIFF vs previous snapshot ════════════════════════════"
        # Lines in new not in old → new leases
        new_leases=$(comm -23 <(sort "$CSV_FILE") <(sort "$PREV_CSV") | wc -l)
        gone_leases=$(comm -13 <(sort "$CSV_FILE") <(sort "$PREV_CSV") | wc -l)
        echo "  New leases  : ${new_leases}"
        echo "  Gone leases : ${gone_leases}"
        if (( new_leases > 0 )); then
            echo "  ── New IPs ──────────────────────────────────────────"
            comm -23 <(sort "$CSV_FILE") <(sort "$PREV_CSV") | \
                awk -F',' '{printf "  + %-15s %-17s %s\n", $4, $3, $5}'
        fi
        if (( gone_leases > 0 )); then
            echo "  ── Removed IPs ──────────────────────────────────────"
            comm -13 <(sort "$CSV_FILE") <(sort "$PREV_CSV") | \
                awk -F',' '{printf "  - %-15s %-17s %s\n", $4, $3, $5}'
        fi
        echo "══════════════════════════════════════════════════════════"
    else
        log INFO "No previous snapshot found; diff skipped."
    fi
fi

# ── Symlink "latest" ──────────────────────────────────────────────────────────
ln -sfn "$OUT_DIR" "${OUT_BASE}/latest"

log OK "Snapshot written: ${OUT_DIR}"
log OK "Symlink updated: ${OUT_BASE}/latest → ${OUT_DIR}"
exit 0