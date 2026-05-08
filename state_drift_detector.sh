#!/usr/bin/env bash
# collects checksums and metadata for a configurable list of paths 
# and installed packages on a host,
# compares the collected state against a baseline directory
# (Git repo with expected checksums and package lists),
# outputs a concise report of added/removed/modified items
# and provides an optional --reconcile mode that, for modified files
# restores the baseline version from the Git repo (or stages a revert in /var/reconcile) 
# and restarts affected services listed per file.
# Include dry-run, per-item confirmation toggle, centralized logging (/var/log/drift-detector.log), 
# and exit codes: 0=no-drift, 1=drift-found, 2=reconcile-failed.
set -euo pipefail

# Config
BASELINE_DIR="/srv/baselines/$(hostname -s)"   # Git checkout of expected state
TARGETS=(/etc/nginx/nginx.conf /etc/ssh/sshd_config /etc/myapp/config.yml)
PKG_FILE="$BASELINE_DIR/packages.txt"
REPORT="/var/log/drift-report-$(date +%Y%m%d%H%M%S).csv"
LOG="/var/log/drift-detector.log"
RECONCILE_DIR="/var/reconcile"
DRY_RUN=1
RECONCILE=0

log(){ echo "$(date --iso-8601=seconds) $*" >> "$LOG"; }

mkdir -p "$RECONCILE_DIR"
echo "path,status,detail" > "$REPORT"

collect_checksum() {
  path="$1"
  if [ -f "$path" ]; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "<MISSING>"
  fi
}

# compare files
for p in "${TARGETS[@]}"; do
  expected=""
  if [ -f "$BASELINE_DIR/$(echo "$p" | sed 's#/#_#g')".sha256 ]; then
    expected=$(cat "$BASELINE_DIR/$(echo "$p" | sed 's#/#_#g')".sha256)
  fi
  current=$(collect_checksum "$p")
  if [ "$expected" = "" ]; then
    echo "$p,baseline-missing,$current" >> "$REPORT"
    log "Baseline missing for $p"
    continue
  fi
  if [ "$current" != "$expected" ]; then
    echo "$p,modified,$current" >> "$REPORT"
    log "Drift detected: $p"
    if [ "$RECONCILE" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: would restore $p from baseline"
      else
        cp -a "$BASELINE_DIR/$(echo "$p" | sed 's#/#_#g')" "$RECONCILE_DIR/$(basename "$p").restore"
        cp -a "$BASELINE_DIR/$(echo "$p" | sed 's#/#_#g')" "$p"
        log "Restored $p"
        # Optionally restart service mapped in baseline metadata (example)
        svcfile="$BASELINE_DIR/$(echo "$p" | sed 's#/#_#g')".service
        if [ -f "$svcfile" ]; then
          svc=$(cat "$svcfile")
          systemctl restart "$svc" && log "Restarted $svc for $p" || { log "Failed to restart $svc"; exit 2; }
        fi
      fi
    fi
  else
    echo "$p,ok," >> "$REPORT"
  fi
done

# compare packages
if [ -f "$PKG_FILE" ]; then
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --get-selections > /tmp/current_pkgs.txt
  else
    rpm -qa | sort > /tmp/current_pkgs.txt
  fi
  # simple diff report
  comm -3 <(sort "$PKG_FILE") <(sort /tmp/current_pkgs.txt) > /tmp/pkg_diff.txt || true
  if [ -s /tmp/pkg_diff.txt ]; then
    echo "packages,drift,see /tmp/pkg_diff.txt" >> "$REPORT"
    log "Package drift detected"
  else
    echo "packages,ok," >> "$REPORT"
  fi
fi

# summary exit code
if grep -qE ',modified,|baseline-missing|packages,drift' "$REPORT"; then
  echo "Drift found. Report: $REPORT"
  exit 1
else
  echo "No drift."
  exit 0
fi
