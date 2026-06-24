#!/usr/bin/env bash
# Deep dive for one ACM ManagedCluster. Hub checks are always performed.
# Optionally pass a managed-cluster kubeconfig to collect agent-side evidence.
set -uo pipefail

OC="${OC:-oc}"
CLUSTER_NAME="${1:-}"
MANAGED_KUBECONFIG="${2:-}"
TS="$(date +%Y%m%d-%H%M%S)"

if [ -z "${CLUSTER_NAME}" ]; then
  echo "Usage: $0 <managed-cluster-name> [managed-cluster-kubeconfig]" >&2
  exit 2
fi

OUT="managed-cluster-${CLUSTER_NAME}-${TS}"
mkdir -p "${OUT}/hub" "${OUT}/managed"
chmod 700 "${OUT}" 2>/dev/null || true

capture() {
  local file="$1"
  shift
  {
    echo "# Command: $*"
    echo
    "$@"
  } >"${file}" 2>&1 || true
}

"${OC}" whoami >/dev/null 2>&1 || { echo "ERROR: Log in to the ACM hub cluster first." >&2; exit 4; }

capture "${OUT}/hub/managedcluster.yaml" "${OC}" get managedcluster "${CLUSTER_NAME}" -o yaml
capture "${OUT}/hub/managedcluster-describe.txt" "${OC}" describe managedcluster "${CLUSTER_NAME}"
capture "${OUT}/hub/namespace.yaml" "${OC}" get namespace "${CLUSTER_NAME}" -o yaml
capture "${OUT}/hub/namespace-events.txt" "${OC}" get events -n "${CLUSTER_NAME}" --sort-by=.lastTimestamp
capture "${OUT}/hub/addons.yaml" "${OC}" get managedclusteraddons -n "${CLUSTER_NAME}" -o yaml
capture "${OUT}/hub/manifestworks.yaml" "${OC}" get manifestworks -n "${CLUSTER_NAME}" -o yaml
capture "${OUT}/hub/klusterletaddonconfig.yaml" "${OC}" get klusterletaddonconfig -n "${CLUSTER_NAME}" -o yaml
capture "${OUT}/hub/managedclusterinfo.yaml" "${OC}" get managedclusterinfo -n "${CLUSTER_NAME}" -o yaml
capture "${OUT}/hub/import-secret-metadata.txt" "${OC}" get secret -n "${CLUSTER_NAME}" "${CLUSTER_NAME}-import" -o custom-columns=NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp

if [ -n "${MANAGED_KUBECONFIG}" ]; then
  if [ ! -f "${MANAGED_KUBECONFIG}" ]; then
    echo "ERROR: Managed-cluster kubeconfig not found: ${MANAGED_KUBECONFIG}" >&2
    exit 5
  fi
  MOC=("${OC}" --kubeconfig "${MANAGED_KUBECONFIG}")
  capture "${OUT}/managed/version.txt" "${MOC[@]}" version
  capture "${OUT}/managed/clusteroperators.txt" "${MOC[@]}" get clusteroperators
  capture "${OUT}/managed/clusteroperators.yaml" "${MOC[@]}" get clusteroperators -o yaml
  capture "${OUT}/managed/klusterlet.yaml" "${MOC[@]}" get klusterlet klusterlet -o yaml
  capture "${OUT}/managed/agent-pods.txt" "${MOC[@]}" get pods -n open-cluster-management-agent -o wide
  capture "${OUT}/managed/agent-addon-pods.txt" "${MOC[@]}" get pods -n open-cluster-management-agent-addon -o wide
  capture "${OUT}/managed/agent-events.txt" "${MOC[@]}" get events -n open-cluster-management-agent --sort-by=.lastTimestamp
  capture "${OUT}/managed/agent-addon-events.txt" "${MOC[@]}" get events -n open-cluster-management-agent-addon --sort-by=.lastTimestamp
  capture "${OUT}/managed/agent-logs.txt" "${MOC[@]}" logs -n open-cluster-management-agent -l app=klusterlet-registration-agent --all-containers --tail=500 --prefix
  capture "${OUT}/managed/work-agent-logs.txt" "${MOC[@]}" logs -n open-cluster-management-agent -l app=klusterlet-work-agent --all-containers --tail=500 --prefix
  capture "${OUT}/managed/addon-logs.txt" "${MOC[@]}" logs -n open-cluster-management-agent-addon --all-containers --tail=300 --prefix -l component=klusterlet-addon-agent
  capture "${OUT}/managed/dns-hub-test.txt" "${MOC[@]}" get infrastructure cluster -o yaml
else
  cat > "${OUT}/managed/README.txt" <<EOF_NOTE
Managed-cluster-side collection was skipped because no kubeconfig was supplied.
Rerun:
  $0 ${CLUSTER_NAME} /secure/path/${CLUSTER_NAME}.kubeconfig
EOF_NOTE
fi

tar -czf "${OUT}.tar.gz" "${OUT}"
echo "Deep-dive archive: ${OUT}.tar.gz"
