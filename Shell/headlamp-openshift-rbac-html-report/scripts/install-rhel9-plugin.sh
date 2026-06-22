#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
PLUGIN_DIR="${PLUGIN_DIR:-/opt/headlamp/plugins}"

if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
  echo "Usage: sudo $0 <headlamp-plugin-archive.tar.gz>" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this script with sudo or as root." >&2
  exit 1
fi

install -d -o root -g root -m 0755 "${PLUGIN_DIR}"
tar xzf "${ARCHIVE}" -C "${PLUGIN_DIR}"
chown -R root:root "${PLUGIN_DIR}"
find "${PLUGIN_DIR}" -type d -exec chmod 0755 {} +
find "${PLUGIN_DIR}" -type f -exec chmod 0644 {} +
restorecon -RF "${PLUGIN_DIR}" 2>/dev/null || true

cat <<EOF
Plugin extracted into ${PLUGIN_DIR}.

The Headlamp container must include:
  Volume=${PLUGIN_DIR}:/headlamp/plugins:ro,Z

The Headlamp command must include:
  --plugins-dir=/headlamp/plugins

After updating the Quadlet or container configuration, run:
  systemctl daemon-reload
  systemctl restart headlamp.service
  journalctl -u headlamp.service -n 100 --no-pager

EOF
