#!/usr/bin/env bash
# reads a host list, uploads a release tarball to each host, 
# extracts it atomically into /opt/app/releases/, 
# updates a symlink /opt/app/current -> that release, 
# runs a health-check command, and if any host fails, 
# rolls back that host to the previous release and reports failures
# Include concurrency (N parallel SSHs), per-host timeout, and a central log
set -euo pipefail

HOSTS_FILE="hosts.txt"
TARBALL="release.tar.gz"
REMOTE_BASE="/opt/app"
RELEASE_TS="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="releases/${RELEASE_TS}"
CURRENT_LINK="current"
PARALLEL=10
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
LOG="/var/log/multi-deploy.log"
HEALTH_CMD="/opt/app/current/bin/healthcheck || exit 1"
TMP_UPLOAD="/tmp/${TARBALL}"

echo "$(date --iso-8601=seconds) START deploy ${RELEASE_TS}" >> "$LOG"

deploy_host() {
  host="$1"
  echo "[$host] uploading" >> "$LOG"
  scp $SSH_OPTS "$TARBALL" "${host}:${TMP_UPLOAD}" >> "$LOG" 2>&1
  ssh $SSH_OPTS "$host" bash -s <<EOF >> "$LOG" 2>&1
set -e
mkdir -p "${REMOTE_BASE}/releases"
tar -xzf "${TMP_UPLOAD}" -C "${REMOTE_BASE}/${RELEASE_DIR}"
ln -sfn "${REMOTE_BASE}/${RELEASE_DIR}" "${REMOTE_BASE}/${CURRENT_LINK}.new"
mv -T "${REMOTE_BASE}/${CURRENT_LINK}.new" "${REMOTE_BASE}/${CURRENT_LINK}"
# run health check
${HEALTH_CMD}
EOF
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[$host] FAILED, attempting rollback" >> "$LOG"
    ssh $SSH_OPTS "$host" bash -s <<'EOF' >> "$LOG" 2>&1 || true
set -e
# simple rollback: point current to previous release directory if exists
prev=$(ls -1d /opt/app/releases/* 2>/dev/null | tail -n 2 | head -n1 || true)
if [ -n "$prev" ]; then
  ln -sfn "$prev" /opt/app/current
fi
EOF
  else
    echo "[$host] OK" >> "$LOG"
  fi
}

export -f deploy_host
export TARBALL RELEASE_DIR RELEASE_TS REMOTE_BASE TMP_UPLOAD LOG HEALTH_CMD SSH_OPTS

# run in parallel (xargs approach)
cat "$HOSTS_FILE" | xargs -P "$PARALLEL" -n1 -I{} bash -c 'deploy_host "$@"' _ {}

echo "$(date --iso-8601=seconds) DONE deploy ${RELEASE_TS}" >> "$LOG"

