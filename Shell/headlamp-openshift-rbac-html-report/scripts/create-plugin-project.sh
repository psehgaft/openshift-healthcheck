#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_DIR="${1:-${PWD}/openshift-rbac-report}"

for command_name in node npm npx; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: ${command_name}" >&2
    exit 1
  }
done

if [[ -e "${TARGET_DIR}" ]]; then
  echo "ERROR: target already exists: ${TARGET_DIR}" >&2
  echo "Choose an empty path or remove the existing directory after preserving your work." >&2
  exit 1
fi

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( NODE_MAJOR < 22 )); then
  echo "ERROR: Headlamp plugin development currently requires Node.js 22 or later." >&2
  exit 1
fi

echo "Creating Headlamp plugin project: ${TARGET_DIR}"
npx --yes @kinvolk/headlamp-plugin create "${TARGET_DIR}"

rm -rf "${TARGET_DIR}/src"
cp -R "${TOOLKIT_DIR}/plugin-overlay/src" "${TARGET_DIR}/src"
cp "${TOOLKIT_DIR}/README.md" "${TARGET_DIR}/RBAC-REPORT-GUIDE.md"
cp -R "${TOOLKIT_DIR}/manifests" "${TARGET_DIR}/manifests"

cd "${TARGET_DIR}"
npm install
npm run build
npm run package

echo
echo "Plugin project created and packaged."
echo "Project: ${TARGET_DIR}"
echo "Archives:"
find "${TARGET_DIR}" -maxdepth 1 -name '*.tar.gz' -print
