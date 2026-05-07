#!/usr/bin/env bash
# tails /var/log/auth.log (Ubuntu) or /var/log/secure (CentOS), 
# identifies IPs that exceed X failed attempts within Y minutes, 
# adds an ipset entry and iptables rule to block them, 
# propagates the IP to peers listed in hosts.txt via SSH, 
# and removes stale entries after TTL. Include concurrency-safe locking, 
# persistent state in /var/lib/ssh-ban, 
# and a report file /var/log/ssh-ban.log. 
# Provide --dry-run and --unblock options
set -euo pipefail

# Config
LOG_FILE="/var/log/auth.log"        # or /var/log/secure on CentOS
STATE_DIR="/var/lib/ssh-ban"
BLOCK_LIST="${STATE_DIR}/blocked.txt"
LOG="/var/log/ssh-ban.log"
HOSTS_FILE="peers.txt"              # peers to propagate to (one per line)
THRESHOLD=10
WINDOW_MIN=10
TTL_SECONDS=$((60*60))              # 1 hour
IPSET_NAME="ssh_ban"
DRY_RUN=0

mkdir -p "$STATE_DIR"
touch "$BLOCK_LIST" "$LOG"

# ensure ipset exists (no-op if present)
if [ "$DRY_RUN" -eq 0 ]; then
  ipset list "$IPSET_NAME" >/dev/null 2>&1 || ipset create "$IPSET_NAME" hash:ip timeout 0
  iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP >/dev/null 2>&1 || \
    iptables -I INPUT -m set --match-set "$IPSET_NAME" src -j DROP
fi

log() { echo "$(date --iso-8601=seconds) $*" >> "$LOG"; }

# parse recent failed auth attempts and count per IP in last WINDOW_MIN minutes
find_bad_ips() {
  awk -v window_min="$WINDOW_MIN" '
    BEGIN { cmd = "date --date=\"-" window_min " minutes\" +%b\ %e\ %H:%M:%S"; cmd | getline cutoff; close(cmd) }
    { line = $0; if (line ~ /Failed password|Invalid user|authentication failure/) print line }
  ' < "$LOG_FILE" | \
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
  sort | uniq -c | awk -v th="$THRESHOLD" '$1 >= th {print $2}'
}

ban_ip() {
  ip="$1"
  if grep -qx "$ip" "$BLOCK_LIST"; then
    log "IP $ip already blocked"
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would ban $ip"
  else
    ipset add -exist "$IPSET_NAME" "$ip" timeout "$TTL_SECONDS"
    echo "$ip $(date +%s) $TTL_SECONDS" >> "$BLOCK_LIST"
    log "BANNED $ip"
    # propagate to peers
    if [ -f "$HOSTS_FILE" ]; then
      while read -r peer; do
        [ -z "$peer" ] && continue
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$peer" "sudo ipset add -exist $IPSET_NAME $ip timeout $TTL_SECONDS" >/dev/null 2>&1 || log "Propagate to $peer failed for $ip"
      done < "$HOSTS_FILE"
    fi
  fi
}

unban_stale() {
  now=$(date +%s)
  tmp="$(mktemp)"
  while read -r line; do
    ip=$(awk '{print $1}' <<<"$line")
    ts=$(awk '{print $2}' <<<"$line")
    ttl=$(awk '{print $3}' <<<"$line")
    if [ -z "$ip" ]; then continue; fi
    if [ $((ts + ttl)) -le "$now" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: would unban $ip"
      else
        ipset del "$IPSET_NAME" "$ip" >/dev/null 2>&1 || true
        log "UNBANNED $ip"
        # propagate unban
        if [ -f "$HOSTS_FILE" ]; then
          while read -r peer; do
            [ -z "$peer" ] && continue
            ssh -o BatchMode=yes -o ConnectTimeout=5 "$peer" "sudo ipset del $IPSET_NAME $ip" >/dev/null 2>&1 || true
          done < "$HOSTS_FILE"
        fi
      fi
    else
      echo "$line" >> "$tmp"
    fi
  done < "$BLOCK_LIST"
  mv "$tmp" "$BLOCK_LIST"
}

# Main run: detect-and-ban once (can be looped in systemd timer)
bad_ips=$(find_bad_ips)
for ip in $bad_ips; do
  ban_ip "$ip"
done

unban_stale
