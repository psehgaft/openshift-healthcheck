#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file|--cluster-name|--output|--target-namespaces)
      ENV_ARGS+=("$1" "$2"); shift 2;;
    --no-sanitize)
      ENV_ARGS+=("$1"); shift;;
    --help|-h)
      cat <<USAGE
Run all OpenShift 4.18+ deep-dive collectors.

Usage:
  ./ocp418-run-all-deep-dives.sh --env-file ./.ocp-deep.env --cluster-name non-prod-ocp

This executes:
  - ocp418-deep-error-followup.sh
  - ocp418-network-deep-dive.sh
  - ocp418-storage-deep-dive.sh
  - ocp418-ai-workloads-deep-dive.sh
USAGE
      exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

for script in \
  ocp418-deep-error-followup.sh \
  ocp418-network-deep-dive.sh \
  ocp418-storage-deep-dive.sh \
  ocp418-ai-workloads-deep-dive.sh; do
  echo "===== Running $script ====="
  "$SCRIPT_DIR/$script" "${ENV_ARGS[@]}"
done
