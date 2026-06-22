#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
PLUGIN_DIR="${HOME}/.config/Headlamp/plugins"

if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
  echo "Usage: $0 <headlamp-plugin-archive.tar.gz>" >&2
  exit 1
fi

mkdir -p "${PLUGIN_DIR}"
tar xzf "${ARCHIVE}" -C "${PLUGIN_DIR}"

echo "Installed plugin archive into: ${PLUGIN_DIR}"
echo "Quit and reopen Headlamp Desktop."
