#!/usr/bin/env bash
# Collect the official RHACM must-gather from the hub cluster.
set -Eeuo pipefail

OC="${OC:-oc}"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-acm-must-gather-${TS}}"

command -v "${OC}" >/dev/null 2>&1 || { echo "ERROR: oc is required." >&2; exit 3; }
"${OC}" whoami >/dev/null 2>&1 || { echo "ERROR: Log in to the hub cluster first." >&2; exit 4; }

if [ -n "${MUST_GATHER_IMAGE:-}" ]; then
  IMAGE="${MUST_GATHER_IMAGE}"
else
  CURRENT_VERSION="$("${OC}" get multiclusterhub -A -o jsonpath='{.items[0].status.currentVersion}' 2>/dev/null || true)"
  if [ -z "${CURRENT_VERSION}" ]; then
    echo "ERROR: Cannot determine MultiClusterHub currentVersion. Set MUST_GATHER_IMAGE explicitly." >&2
    exit 5
  fi
  MINOR_VERSION="$(printf '%s' "${CURRENT_VERSION}" | awk -F. '{print $1"."$2}')"
  IMAGE="registry.redhat.io/rhacm2/acm-must-gather-rhel9:v${MINOR_VERSION}"
fi

printf 'Collecting ACM must-gather\n'
printf 'Image: %s\n' "${IMAGE}"
printf 'Destination: %s\n' "${DEST}"

"${OC}" adm must-gather --image="${IMAGE}" --dest-dir="${DEST}"

tar -czf "${DEST}.tar.gz" "${DEST}"
printf 'Archive: %s.tar.gz\n' "${DEST}"
