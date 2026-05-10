#!/usr/bin/env bash
# vm-patrol.sh — Monitor VMs and auto-restart critical ones that crash
# Reads a watchlist file: <vm-name> <action: restart|alert|ignore>

set -euo pipefail

WATCHLIST="${1:-/etc/vmtk/watchlist.conf}"
LOG="/var/log/vmtk/patrol.log"
WEBHOOK_URL="${VMTK_WEBHOOK:-}"  # Slack/Discord/Mattermost webhook

mkdir -p "$(dirname "$LOG")"
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

notify() {
    local msg="$1"
    echo "[$(timestamp)] $msg" | tee -a "$LOG"
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "{\"text\": \"🚨 VM-PATROL: ${msg}\"}" \
            "$WEBHOOK_URL" &>/dev/null || true
    fi
}

[[ -f "$WATCHLIST" ]] || { echo "❌ Watchlist not found: $WATCHLIST"; exit 1; }

while IFS=' ' read -r vm action; do
    [[ "$vm" =~ ^#.*$ || -z "$vm" ]] && continue
    state=$(virsh domstate "$vm" 2>/dev/null || echo "undefined")

    if [[ "$state" != "running" ]]; then
        case "${action:-alert}" in
            restart)
                notify "⚠️  ${vm} is '${state}' — attempting restart..."
                if virsh start "$vm" &>/dev/null; then
                    notify "✅ ${vm} restarted successfully"
                else
                    notify "❌ ${vm} FAILED to restart!"
                fi
                ;;
            alert)
                notify "⚠️  ${vm} is '${state}' — alert only (no auto-restart)"
                ;;
            ignore)
                ;;
        esac
    fi
done < "$WATCHLIST"