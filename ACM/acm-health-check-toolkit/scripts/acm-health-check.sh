#!/usr/bin/env bash
# Read-only health check for Red Hat Advanced Cluster Management (RHACM/ACM).
# Validated design target: OpenShift Container Platform 4.18 and ACM 2.15.
# The script discovers installed resource names and tolerates optional components.

set -uo pipefail
IFS=$'\n\t'

OC="${OC:-oc}"
JQ="${JQ:-jq}"
OPENSSL="${OPENSSL:-openssl}"
RESTART_WARN_THRESHOLD="${RESTART_WARN_THRESHOLD:-5}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-30}"
FAIL_ON_WARN="${FAIL_ON_WARN:-false}"
COLLECT_FAILING_POD_LOGS="${COLLECT_FAILING_POD_LOGS:-true}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-acm-health-check-${TS}}"
RAW="${OUT}/raw"
LOGS="${OUT}/logs"
REPORT="${OUT}/report.md"
RESULTS="${OUT}/results.csv"
MD_ROWS="${OUT}/.findings-rows.md"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0

mkdir -p "${RAW}" "${LOGS}"
chmod 700 "${OUT}" "${RAW}" "${LOGS}" 2>/dev/null || true

csv_escape() {
  printf '%s' "$1" | sed 's/"/""/g'
}

add_result() {
  local status="$1" area="$2" check="$3" evidence="$4" recommendation="$5"
  case "${status}" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    INFO) INFO_COUNT=$((INFO_COUNT + 1)) ;;
  esac
  printf '"%s","%s","%s","%s","%s"\n' \
    "$(csv_escape "${status}")" \
    "$(csv_escape "${area}")" \
    "$(csv_escape "${check}")" \
    "$(csv_escape "${evidence}")" \
    "$(csv_escape "${recommendation}")" >> "${RESULTS}"
  evidence="${evidence//$'\n'/ }"
  recommendation="${recommendation//$'\n'/ }"
  printf '| %s | %s | %s | %s | %s |\n' \
    "${status//|/\\|}" "${area//|/\\|}" "${check//|/\\|}" \
    "${evidence//|/\\|}" "${recommendation//|/\\|}" >> "${MD_ROWS}"
}

capture_cmd() {
  local file="$1"
  shift
  local cmd="$*"
  {
    printf '# Command: %s\n' "${cmd}"
    printf '# Collected: %s\n\n' "$(date -Iseconds 2>/dev/null || date)"
    bash -o pipefail -c "${cmd}"
  } >"${file}" 2>&1 || true
}

api_exists() {
  local resource="$1"
  "${OC}" api-resources -o name 2>/dev/null | grep -qx "${resource}"
}

namespace_exists() {
  "${OC}" get namespace "$1" >/dev/null 2>&1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$1' was not found." >&2
    exit 3
  }
}

require_command "${OC}"
require_command "${JQ}"

printf '"status","area","check","evidence","recommendation"\n' > "${RESULTS}"
: > "${MD_ROWS}"

cat > "${REPORT}" <<EOF_REPORT
# ACM health-check report

- **Generated:** $(date -Iseconds 2>/dev/null || date)
- **Output directory:** \`${OUT}\`
- **Mode:** Read-only collection and evaluation
- **Target profile:** OpenShift 4.18 / Red Hat Advanced Cluster Management 2.15

> The score at the end is a triage aid, not a Red Hat supportability certification. Validate every remediation through change control and a tested rollback plan.

EOF_REPORT

# -----------------------------------------------------------------------------
# 1. Access and platform
# -----------------------------------------------------------------------------
if ! "${OC}" whoami >/dev/null 2>&1; then
  add_result FAIL "Access" "OpenShift login" "oc whoami failed" "Authenticate to the ACM hub cluster and rerun the script."
  echo "ERROR: Not logged in to an OpenShift cluster." >&2
  exit 4
fi

WHOAMI="$("${OC}" whoami 2>/dev/null || true)"
SERVER="$("${OC}" whoami --show-server 2>/dev/null || true)"
CONTEXT="$("${OC}" config current-context 2>/dev/null || true)"
add_result PASS "Access" "OpenShift login" "user=${WHOAMI}; server=${SERVER}; context=${CONTEXT}" "None."

capture_cmd "${RAW}/oc-version.txt" "${OC} version"
capture_cmd "${RAW}/oc-version.json" "${OC} version -o json"
capture_cmd "${RAW}/whoami.txt" "${OC} whoami && ${OC} whoami --show-server && ${OC} config current-context"
capture_cmd "${RAW}/api-readyz.txt" "${OC} get --raw='/readyz?verbose'"
capture_cmd "${RAW}/cluster-version.yaml" "${OC} get clusterversion version -o yaml"
capture_cmd "${RAW}/clusteroperators.yaml" "${OC} get clusteroperators -o yaml"
capture_cmd "${RAW}/clusteroperators.txt" "${OC} get clusteroperators"
capture_cmd "${RAW}/nodes-wide.txt" "${OC} get nodes -o wide"
capture_cmd "${RAW}/nodes.yaml" "${OC} get nodes -o yaml"
capture_cmd "${RAW}/machineconfigpools.txt" "${OC} get machineconfigpools"

if "${OC}" get --raw='/readyz' 2>/dev/null | grep -q '^ok'; then
  add_result PASS "Platform" "Kubernetes API readiness" "/readyz returned ok" "None."
else
  add_result FAIL "Platform" "Kubernetes API readiness" "/readyz did not return ok" "Review API server, authentication, etcd, and network health before troubleshooting ACM components."
fi

CV_JSON="$("${OC}" get clusterversion version -o json 2>/dev/null || printf '{}')"
CV_AVAILABLE="$(printf '%s' "${CV_JSON}" | "${JQ}" -r '[.status.conditions[]? | select(.type=="Available")][0].status // "Unknown"')"
CV_FAILING="$(printf '%s' "${CV_JSON}" | "${JQ}" -r '[.status.conditions[]? | select(.type=="Failing")][0].status // "Unknown"')"
CV_PROGRESSING="$(printf '%s' "${CV_JSON}" | "${JQ}" -r '[.status.conditions[]? | select(.type=="Progressing")][0].status // "Unknown"')"
CV_VERSION="$(printf '%s' "${CV_JSON}" | "${JQ}" -r '.status.desired.version // "unknown"')"
if [ "${CV_AVAILABLE}" = "True" ] && [ "${CV_FAILING}" = "False" ]; then
  add_result PASS "Platform" "ClusterVersion health" "version=${CV_VERSION}; Available=True; Failing=False; Progressing=${CV_PROGRESSING}" "None."
else
  add_result FAIL "Platform" "ClusterVersion health" "version=${CV_VERSION}; Available=${CV_AVAILABLE}; Failing=${CV_FAILING}; Progressing=${CV_PROGRESSING}" "Resolve OpenShift ClusterVersion degradation before declaring ACM healthy."
fi

CO_JSON="$("${OC}" get clusteroperators -o json 2>/dev/null || printf '{"items":[]}')"
CO_BAD="$(printf '%s' "${CO_JSON}" | "${JQ}" '[.items[] | select((([.status.conditions[]? | select(.type=="Available")][0].status // "Unknown") != "True") or (([.status.conditions[]? | select(.type=="Degraded")][0].status // "False") == "True"))] | length')"
CO_PROGRESSING="$(printf '%s' "${CO_JSON}" | "${JQ}" '[.items[] | select((([.status.conditions[]? | select(.type=="Progressing")][0].status // "False") == "True"))] | length')"
if [ "${CO_BAD}" -eq 0 ]; then
  add_result PASS "Platform" "ClusterOperator availability" "No unavailable or degraded ClusterOperators" "None."
else
  BAD_NAMES="$(printf '%s' "${CO_JSON}" | "${JQ}" -r '.items[] | select((([.status.conditions[]? | select(.type=="Available")][0].status // "Unknown") != "True") or (([.status.conditions[]? | select(.type=="Degraded")][0].status // "False") == "True")) | .metadata.name' | paste -sd, -)"
  add_result FAIL "Platform" "ClusterOperator availability" "affected=${BAD_NAMES}" "Resolve degraded OpenShift operators; ACM depends on a healthy hub platform."
fi
if [ "${CO_PROGRESSING}" -gt 0 ]; then
  add_result WARN "Platform" "ClusterOperator progressing state" "${CO_PROGRESSING} ClusterOperator(s) are progressing" "Confirm that an intentional update or reconciliation is active and completes successfully."
else
  add_result PASS "Platform" "ClusterOperator progressing state" "No ClusterOperator reports Progressing=True" "None."
fi

NODES_JSON="$("${OC}" get nodes -o json 2>/dev/null || printf '{"items":[]}')"
NODE_NOT_READY="$(printf '%s' "${NODES_JSON}" | "${JQ}" '[.items[] | select((([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown") != "True"))] | length')"
if [ "${NODE_NOT_READY}" -eq 0 ]; then
  add_result PASS "Platform" "Node readiness" "All nodes report Ready=True" "None."
else
  NOT_READY_NAMES="$(printf '%s' "${NODES_JSON}" | "${JQ}" -r '.items[] | select((([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown") != "True")) | .metadata.name' | paste -sd, -)"
  add_result FAIL "Platform" "Node readiness" "notReady=${NOT_READY_NAMES}" "Restore node readiness and confirm ACM pods are rescheduled without resource pressure."
fi

# -----------------------------------------------------------------------------
# 2. OLM, MultiClusterHub, and MultiClusterEngine
# -----------------------------------------------------------------------------
capture_cmd "${RAW}/subscriptions.yaml" "${OC} get subscriptions.operators.coreos.com -A -o yaml"
capture_cmd "${RAW}/csvs.yaml" "${OC} get clusterserviceversions.operators.coreos.com -A -o yaml"
capture_cmd "${RAW}/installplans.yaml" "${OC} get installplans.operators.coreos.com -A -o yaml"
capture_cmd "${RAW}/catalogsources.yaml" "${OC} get catalogsources.operators.coreos.com -A -o yaml"

SUB_JSON="$("${OC}" get subscriptions.operators.coreos.com -A -o json 2>/dev/null || printf '{"items":[]}')"
ACM_SUB_COUNT="$(printf '%s' "${SUB_JSON}" | "${JQ}" '[.items[] | select((.metadata.name | test("advanced-cluster-management|multicluster-engine"; "i")) or ((.spec.name // "") | test("advanced-cluster-management|multicluster-engine"; "i")))] | length')"
if [ "${ACM_SUB_COUNT}" -ge 1 ]; then
  SUB_SUMMARY="$(printf '%s' "${SUB_JSON}" | "${JQ}" -r '.items[] | select((.metadata.name | test("advanced-cluster-management|multicluster-engine"; "i")) or ((.spec.name // "") | test("advanced-cluster-management|multicluster-engine"; "i"))) | [.metadata.namespace,.metadata.name,(.spec.channel // ""),(.spec.installPlanApproval // ""),(.status.currentCSV // "none")] | @tsv' | tr '\n' ';')"
  add_result PASS "OLM" "ACM/MCE subscriptions" "${SUB_SUMMARY}" "Confirm channels and approval mode match the documented lifecycle and change-management policy."
else
  add_result FAIL "OLM" "ACM/MCE subscriptions" "No ACM or MCE Subscription found" "Verify that ACM was installed through Operator Lifecycle Manager in the expected namespace."
fi

CSV_JSON="$("${OC}" get clusterserviceversions.operators.coreos.com -A -o json 2>/dev/null || printf '{"items":[]}')"
CURRENT_CSVS="$(printf '%s' "${SUB_JSON}" | "${JQ}" -r '.items[] | select((.metadata.name | test("advanced-cluster-management|multicluster-engine"; "i")) or ((.spec.name // "") | test("advanced-cluster-management|multicluster-engine"; "i"))) | [.metadata.namespace,(.status.currentCSV // "")] | @tsv')"
CSV_FAILURES=0
CSV_EVIDENCE=""
while IFS=$'\t' read -r ns csv; do
  [ -n "${ns:-}" ] || continue
  [ -n "${csv:-}" ] || continue
  phase="$(printf '%s' "${CSV_JSON}" | "${JQ}" -r --arg ns "${ns}" --arg csv "${csv}" '.items[] | select(.metadata.namespace==$ns and .metadata.name==$csv) | .status.phase // "NotFound"' | head -1)"
  CSV_EVIDENCE="${CSV_EVIDENCE}${ns}/${csv}=${phase};"
  [ "${phase}" = "Succeeded" ] || CSV_FAILURES=$((CSV_FAILURES + 1))
done <<EOF_CSV
${CURRENT_CSVS}
EOF_CSV
if [ "${CSV_FAILURES}" -eq 0 ] && [ -n "${CURRENT_CSVS}" ]; then
  add_result PASS "OLM" "Current ACM/MCE CSV phases" "${CSV_EVIDENCE}" "None."
else
  add_result FAIL "OLM" "Current ACM/MCE CSV phases" "${CSV_EVIDENCE:-No current CSV detected}" "Inspect Subscription conditions, InstallPlans, CatalogSources, and CSV events/logs."
fi

if api_exists "multiclusterhubs.operator.open-cluster-management.io"; then
  capture_cmd "${RAW}/multiclusterhubs.yaml" "${OC} get multiclusterhubs.operator.open-cluster-management.io -A -o yaml"
  MCH_JSON="$("${OC}" get multiclusterhubs.operator.open-cluster-management.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  MCH_COUNT="$(printf '%s' "${MCH_JSON}" | "${JQ}" '.items | length')"
  if [ "${MCH_COUNT}" -eq 0 ]; then
    add_result FAIL "ACM Hub" "MultiClusterHub instance" "CRD exists but no MultiClusterHub instance was found" "Create or restore the MultiClusterHub instance through the supported ACM installation workflow."
  else
    MCH_PHASES="$(printf '%s' "${MCH_JSON}" | "${JQ}" -r '.items[] | [.metadata.namespace,.metadata.name,(.status.phase // "Unknown"),(.status.currentVersion // "unknown"),(.status.desiredVersion // "unknown")] | @tsv' | tr '\n' ';')"
    MCH_BAD="$(printf '%s' "${MCH_JSON}" | "${JQ}" '[.items[] | select((.status.phase // "Unknown") != "Running")] | length')"
    MCH_DEADLINE="$(printf '%s' "${MCH_JSON}" | grep -c 'ProgressDeadlineExceeded' || true)"
    if [ "${MCH_BAD}" -eq 0 ] && [ "${MCH_DEADLINE}" -eq 0 ]; then
      add_result PASS "ACM Hub" "MultiClusterHub phase" "${MCH_PHASES}" "None."
    else
      add_result FAIL "ACM Hub" "MultiClusterHub phase" "${MCH_PHASES}; ProgressDeadlineExceededMatches=${MCH_DEADLINE}" "Describe the MultiClusterHub, inspect status.components, and resolve Pending/Unavailable workloads or resource pressure."
    fi
    NODE_COUNT="$(printf '%s' "${NODES_JSON}" | "${JQ}" '.items | length')"
    MCH_AVAILABILITY="$(printf '%s' "${MCH_JSON}" | "${JQ}" -r '.items[0].spec.availabilityConfig // "High(default)"')"
    if [ "${NODE_COUNT}" -le 1 ] && [ "${MCH_AVAILABILITY}" != "Basic" ]; then
      add_result WARN "Architecture" "MultiClusterHub availability mode" "nodes=${NODE_COUNT}; availabilityConfig=${MCH_AVAILABILITY}" "For a single-node OpenShift hub, validate the documented Basic availability setting and supported topology."
    elif [ "${NODE_COUNT}" -gt 1 ] && [ "${MCH_AVAILABILITY}" = "Basic" ]; then
      add_result WARN "Architecture" "MultiClusterHub availability mode" "nodes=${NODE_COUNT}; availabilityConfig=Basic" "For production multi-node hubs, evaluate High availability unless Basic was explicitly approved for capacity reasons."
    else
      add_result PASS "Architecture" "MultiClusterHub availability mode" "nodes=${NODE_COUNT}; availabilityConfig=${MCH_AVAILABILITY}" "None."
    fi
  fi
else
  add_result FAIL "ACM Hub" "MultiClusterHub API" "MultiClusterHub CRD is absent" "Verify ACM operator installation and API registration."
  MCH_JSON='{"items":[]}'
fi

if api_exists "multiclusterengines.multicluster.openshift.io"; then
  capture_cmd "${RAW}/multiclusterengines.yaml" "${OC} get multiclusterengines.multicluster.openshift.io -o yaml"
  MCE_JSON="$("${OC}" get multiclusterengines.multicluster.openshift.io -o json 2>/dev/null || printf '{"items":[]}')"
  MCE_COUNT="$(printf '%s' "${MCE_JSON}" | "${JQ}" '.items | length')"
  if [ "${MCE_COUNT}" -eq 0 ]; then
    add_result FAIL "MCE" "MultiClusterEngine instance" "CRD exists but no MultiClusterEngine instance was found" "Inspect the MultiClusterHub reconciliation and MCE Subscription/CSV."
  else
    MCE_SUMMARY="$(printf '%s' "${MCE_JSON}" | "${JQ}" -r '.items[] | [.metadata.name,(.status.phase // "Unknown"),(.status.currentVersion // "unknown"),(.status.desiredVersion // "unknown")] | @tsv' | tr '\n' ';')"
    MCE_BAD="$(printf '%s' "${MCE_JSON}" | "${JQ}" '[.items[] | select((.status.phase // "Unknown") != "Available" and (.status.phase // "Unknown") != "Running")] | length')"
    if [ "${MCE_BAD}" -eq 0 ]; then
      add_result PASS "MCE" "MultiClusterEngine phase" "${MCE_SUMMARY}" "None."
    else
      add_result FAIL "MCE" "MultiClusterEngine phase" "${MCE_SUMMARY}" "Describe the MultiClusterEngine and inspect MCE operator and operand workloads."
    fi
  fi
else
  add_result FAIL "MCE" "MultiClusterEngine API" "MultiClusterEngine CRD is absent" "Verify the ACM-managed MCE operator installation."
  MCE_JSON='{"items":[]}'
fi

# -----------------------------------------------------------------------------
# 3. ACM namespaces, workloads, PVCs, events, and optional failing logs
# -----------------------------------------------------------------------------
KNOWN_NAMESPACES="open-cluster-management multicluster-engine open-cluster-management-hub open-cluster-management-agent-addon open-cluster-management-observability open-cluster-management-backup"
MCH_NAMESPACES="$(printf '%s' "${MCH_JSON}" | "${JQ}" -r '.items[]?.metadata.namespace')"
ALL_NS="$(printf '%s\n%s\n' "${KNOWN_NAMESPACES}" "${MCH_NAMESPACES}" | tr ' ' '\n' | sed '/^$/d' | sort -u)"

WORKLOAD_FAILURES=0
POD_FAILURES=0
RESTART_WARNINGS=0
PVC_FAILURES=0
NS_FOUND=0
ACM_POD_TOTAL=0
ACM_POD_ON_INFRA=0
INFRA_NODE_COUNT="$(printf '%s' "${NODES_JSON}" | "${JQ}" '[.items[] | select(.metadata.labels["node-role.kubernetes.io/infra"] != null)] | length')"

while IFS= read -r ns; do
  [ -n "${ns}" ] || continue
  if ! namespace_exists "${ns}"; then
    continue
  fi
  NS_FOUND=$((NS_FOUND + 1))
  safe_ns="$(printf '%s' "${ns}" | tr '/:' '__')"
  capture_cmd "${RAW}/${safe_ns}-pods.yaml" "${OC} get pods -n ${ns} -o yaml"
  capture_cmd "${RAW}/${safe_ns}-pods-wide.txt" "${OC} get pods -n ${ns} -o wide"
  capture_cmd "${RAW}/${safe_ns}-deployments.yaml" "${OC} get deployments -n ${ns} -o yaml"
  capture_cmd "${RAW}/${safe_ns}-statefulsets.yaml" "${OC} get statefulsets -n ${ns} -o yaml"
  capture_cmd "${RAW}/${safe_ns}-daemonsets.yaml" "${OC} get daemonsets -n ${ns} -o yaml"
  capture_cmd "${RAW}/${safe_ns}-jobs.yaml" "${OC} get jobs -n ${ns} -o yaml"
  capture_cmd "${RAW}/${safe_ns}-pvcs.yaml" "${OC} get pvc -n ${ns} -o yaml"
  capture_cmd "${RAW}/${safe_ns}-events.txt" "${OC} get events -n ${ns} --sort-by=.lastTimestamp"

  POD_JSON="$("${OC}" get pods -n "${ns}" -o json 2>/dev/null || printf '{"items":[]}')"
  POD_TOTAL="$(printf '%s' "${POD_JSON}" | "${JQ}" '.items | length')"
  ACM_POD_TOTAL=$((ACM_POD_TOTAL + POD_TOTAL))
  NS_POD_BAD="$(printf '%s' "${POD_JSON}" | "${JQ}" '[.items[] | select((.status.phase != "Running" and .status.phase != "Succeeded") or any(.status.containerStatuses[]?; (.state.waiting.reason // "") | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|RunContainerError")))] | length')"
  NS_RESTARTS="$(printf '%s' "${POD_JSON}" | "${JQ}" --argjson threshold "${RESTART_WARN_THRESHOLD}" '[.items[] | select(([.status.containerStatuses[]?.restartCount] | add // 0) >= $threshold)] | length')"
  POD_FAILURES=$((POD_FAILURES + NS_POD_BAD))
  RESTART_WARNINGS=$((RESTART_WARNINGS + NS_RESTARTS))

  if [ "${INFRA_NODE_COUNT}" -gt 0 ]; then
    ON_INFRA="$(printf '%s' "${POD_JSON}" | "${JQ}" --argjson nodes "${NODES_JSON}" '[.items[] as $p | $nodes.items[] | select(.metadata.name == $p.spec.nodeName and .metadata.labels["node-role.kubernetes.io/infra"] != null)] | length')"
    ACM_POD_ON_INFRA=$((ACM_POD_ON_INFRA + ON_INFRA))
  fi

  DEPLOY_JSON="$("${OC}" get deployments -n "${ns}" -o json 2>/dev/null || printf '{"items":[]}')"
  STS_JSON="$("${OC}" get statefulsets -n "${ns}" -o json 2>/dev/null || printf '{"items":[]}')"
  DS_JSON="$("${OC}" get daemonsets -n "${ns}" -o json 2>/dev/null || printf '{"items":[]}')"
  DEPLOY_BAD="$(printf '%s' "${DEPLOY_JSON}" | "${JQ}" '[.items[] | select((.status.availableReplicas // 0) < (.spec.replicas // 1))] | length')"
  STS_BAD="$(printf '%s' "${STS_JSON}" | "${JQ}" '[.items[] | select((.status.readyReplicas // 0) < (.spec.replicas // 1))] | length')"
  DS_BAD="$(printf '%s' "${DS_JSON}" | "${JQ}" '[.items[] | select((.status.numberUnavailable // 0) > 0 or (.status.numberReady // 0) < (.status.desiredNumberScheduled // 0))] | length')"
  WORKLOAD_FAILURES=$((WORKLOAD_FAILURES + DEPLOY_BAD + STS_BAD + DS_BAD))

  PVC_JSON="$("${OC}" get pvc -n "${ns}" -o json 2>/dev/null || printf '{"items":[]}')"
  PVC_BAD="$(printf '%s' "${PVC_JSON}" | "${JQ}" '[.items[] | select(.status.phase != "Bound")] | length')"
  PVC_FAILURES=$((PVC_FAILURES + PVC_BAD))

  if [ "${COLLECT_FAILING_POD_LOGS}" = "true" ] && [ "${NS_POD_BAD}" -gt 0 ]; then
    BAD_PODS="$(printf '%s' "${POD_JSON}" | "${JQ}" -r '.items[] | select((.status.phase != "Running" and .status.phase != "Succeeded") or any(.status.containerStatuses[]?; (.state.waiting.reason // "") | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|RunContainerError"))) | .metadata.name')"
    while IFS= read -r pod; do
      [ -n "${pod}" ] || continue
      capture_cmd "${LOGS}/${safe_ns}__${pod}.log" "${OC} logs -n ${ns} ${pod} --all-containers --tail=300 --prefix"
      capture_cmd "${LOGS}/${safe_ns}__${pod}-previous.log" "${OC} logs -n ${ns} ${pod} --all-containers --previous --tail=300 --prefix"
      capture_cmd "${LOGS}/${safe_ns}__${pod}-describe.txt" "${OC} describe pod -n ${ns} ${pod}"
    done <<EOF_BADPODS
${BAD_PODS}
EOF_BADPODS
  fi
done <<EOF_NS
${ALL_NS}
EOF_NS

if [ "${NS_FOUND}" -gt 0 ]; then
  add_result PASS "ACM Workloads" "ACM namespaces discovered" "${NS_FOUND} known/discovered ACM namespaces are present" "None."
else
  add_result FAIL "ACM Workloads" "ACM namespaces discovered" "No expected ACM namespace was found" "Verify installation namespace and operator reconciliation."
fi

if [ "${POD_FAILURES}" -eq 0 ]; then
  add_result PASS "ACM Workloads" "Pod phases and container states" "No failed, pending, or crash-looping ACM pod detected" "None."
else
  add_result FAIL "ACM Workloads" "Pod phases and container states" "${POD_FAILURES} ACM pod(s) are not healthy" "Review namespace pod YAML, events, describes, logs, node pressure, image access, and scheduling constraints."
fi

if [ "${WORKLOAD_FAILURES}" -eq 0 ]; then
  add_result PASS "ACM Workloads" "Controller availability" "All discovered Deployments, StatefulSets, and DaemonSets meet desired availability" "None."
else
  add_result FAIL "ACM Workloads" "Controller availability" "${WORKLOAD_FAILURES} controller workload(s) do not meet desired availability" "Check rollout status, events, probes, PVCs, PDBs, topology constraints, and resource requests."
fi

if [ "${RESTART_WARNINGS}" -eq 0 ]; then
  add_result PASS "ACM Workloads" "Container restarts" "No ACM pod meets restart warning threshold (${RESTART_WARN_THRESHOLD})" "None."
else
  add_result WARN "ACM Workloads" "Container restarts" "${RESTART_WARNINGS} pod(s) have at least ${RESTART_WARN_THRESHOLD} cumulative container restarts" "Correlate restarts with OOMKilled, probe failures, node reboots, certificate rotation, or upgrades."
fi

if [ "${PVC_FAILURES}" -eq 0 ]; then
  add_result PASS "Storage" "ACM PVC binding" "All discovered ACM PVCs are Bound" "None."
else
  add_result FAIL "Storage" "ACM PVC binding" "${PVC_FAILURES} ACM PVC(s) are not Bound" "Resolve StorageClass, CSI, quota, access-mode, capacity, and topology issues."
fi

if [ "${INFRA_NODE_COUNT}" -gt 0 ]; then
  add_result INFO "Architecture" "ACM infrastructure-node placement" "infraNodes=${INFRA_NODE_COUNT}; acmPods=${ACM_POD_TOTAL}; acmPodsOnInfra=${ACM_POD_ON_INFRA}" "Confirm the placement matches the approved hub architecture; do not move stateful components without validating storage topology and support requirements."
else
  add_result INFO "Architecture" "ACM infrastructure-node placement" "No node with node-role.kubernetes.io/infra was detected" "For production, evaluate dedicated infrastructure capacity based on fleet size, observability, backup, and subscription design."
fi

# -----------------------------------------------------------------------------
# 4. Managed clusters, add-ons, ManifestWorks, and governance
# -----------------------------------------------------------------------------
if api_exists "managedclusters.cluster.open-cluster-management.io"; then
  capture_cmd "${RAW}/managedclusters.yaml" "${OC} get managedclusters.cluster.open-cluster-management.io -o yaml"
  capture_cmd "${RAW}/managedclusters.txt" "${OC} get managedclusters.cluster.open-cluster-management.io"
  MC_JSON="$("${OC}" get managedclusters.cluster.open-cluster-management.io -o json 2>/dev/null || printf '{"items":[]}')"
  MC_COUNT="$(printf '%s' "${MC_JSON}" | "${JQ}" '.items | length')"
  MC_BAD="$(printf '%s' "${MC_JSON}" | "${JQ}" '[.items[] | select(.spec.hubAcceptsClient != true or (([.status.conditions[]? | select(.type=="ManagedClusterJoined")][0].status // "False") != "True") or (([.status.conditions[]? | select(.type=="ManagedClusterConditionAvailable")][0].status // "False") != "True"))] | length')"
  if [ "${MC_COUNT}" -eq 0 ]; then
    add_result WARN "Managed Clusters" "ManagedCluster inventory" "No ManagedCluster resource found" "Import the local cluster and intended managed clusters, or document that the hub is not yet onboarding clusters."
  elif [ "${MC_BAD}" -eq 0 ]; then
    add_result PASS "Managed Clusters" "Joined and Available status" "${MC_COUNT} managed cluster(s); all accepted, Joined=True, Available=True" "None."
  else
    MC_BAD_NAMES="$(printf '%s' "${MC_JSON}" | "${JQ}" -r '.items[] | select(.spec.hubAcceptsClient != true or (([.status.conditions[]? | select(.type=="ManagedClusterJoined")][0].status // "False") != "True") or (([.status.conditions[]? | select(.type=="ManagedClusterConditionAvailable")][0].status // "False") != "True")) | .metadata.name' | paste -sd, -)"
    add_result FAIL "Managed Clusters" "Joined and Available status" "unhealthy=${MC_BAD_NAMES}; total=${MC_COUNT}" "Run the managed-cluster deep-dive script, inspect import/klusterlet conditions, DNS, proxy, certificates, and outbound hub connectivity."
  fi
else
  MC_JSON='{"items":[]}'
  add_result FAIL "Managed Clusters" "ManagedCluster API" "ManagedCluster CRD is absent" "Repair the multicluster engine installation."
fi

if api_exists "managedclusteraddons.addon.open-cluster-management.io"; then
  capture_cmd "${RAW}/managedclusteraddons.yaml" "${OC} get managedclusteraddons.addon.open-cluster-management.io -A -o yaml"
  ADDON_JSON="$("${OC}" get managedclusteraddons.addon.open-cluster-management.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  ADDON_COUNT="$(printf '%s' "${ADDON_JSON}" | "${JQ}" '.items | length')"
  ADDON_BAD="$(printf '%s' "${ADDON_JSON}" | "${JQ}" '[.items[] | select((([.status.conditions[]? | select(.type=="Available")][0].status // "False") != "True") or (([.status.conditions[]? | select(.type=="Degraded")][0].status // "False") == "True"))] | length')"
  if [ "${ADDON_COUNT}" -eq 0 ]; then
    add_result WARN "Add-ons" "ManagedClusterAddOn inventory" "No ManagedClusterAddOn resource found" "Confirm that managed clusters are imported and required add-ons are enabled."
  elif [ "${ADDON_BAD}" -eq 0 ]; then
    add_result PASS "Add-ons" "ManagedClusterAddOn availability" "${ADDON_COUNT} add-on instance(s); all report Available=True and not Degraded" "None."
  else
    ADDON_BAD_NAMES="$(printf '%s' "${ADDON_JSON}" | "${JQ}" -r '.items[] | select((([.status.conditions[]? | select(.type=="Available")][0].status // "False") != "True") or (([.status.conditions[]? | select(.type=="Degraded")][0].status // "False") == "True")) | [.metadata.namespace,.metadata.name] | join("/")' | paste -sd, -)"
    add_result FAIL "Add-ons" "ManagedClusterAddOn availability" "unhealthy=${ADDON_BAD_NAMES}" "Inspect add-on conditions, ManifestWorks, agent-addon pods, certificates, and connectivity."
  fi
else
  add_result FAIL "Add-ons" "ManagedClusterAddOn API" "ManagedClusterAddOn CRD is absent" "Repair MCE/ACM add-on manager components."
fi

if api_exists "manifestworks.work.open-cluster-management.io"; then
  capture_cmd "${RAW}/manifestworks.yaml" "${OC} get manifestworks.work.open-cluster-management.io -A -o yaml"
  MW_JSON="$("${OC}" get manifestworks.work.open-cluster-management.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  MW_COUNT="$(printf '%s' "${MW_JSON}" | "${JQ}" '.items | length')"
  MW_BAD="$(printf '%s' "${MW_JSON}" | "${JQ}" '[.items[] | select((([.status.conditions[]? | select(.type=="Applied")][0].status // "False") != "True") or (([.status.conditions[]? | select(.type=="Available")][0].status // "True") == "False"))] | length')"
  if [ "${MW_BAD}" -eq 0 ]; then
    add_result PASS "Work Distribution" "ManifestWork application" "${MW_COUNT} ManifestWork resource(s); no explicit Applied/Available failure detected" "None."
  else
    add_result FAIL "Work Distribution" "ManifestWork application" "${MW_BAD} of ${MW_COUNT} ManifestWork resource(s) show Applied/Available failure" "Inspect affected ManifestWork conditions and work-agent logs on the managed cluster."
  fi
fi

if api_exists "policies.policy.open-cluster-management.io"; then
  capture_cmd "${RAW}/policies.yaml" "${OC} get policies.policy.open-cluster-management.io -A -o yaml"
  POLICY_JSON="$("${OC}" get policies.policy.open-cluster-management.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  POLICY_COUNT="$(printf '%s' "${POLICY_JSON}" | "${JQ}" '.items | length')"
  NONCOMPLIANT="$(printf '%s' "${POLICY_JSON}" | "${JQ}" '[.items[] | select((.status.compliant // "Unknown") == "NonCompliant")] | length')"
  if [ "${POLICY_COUNT}" -eq 0 ]; then
    add_result WARN "Governance" "Policy framework usage" "Policy API exists but no Policy resource was found" "Define an inform-first governance baseline and promote selected controls to enforce only after impact testing."
  elif [ "${NONCOMPLIANT}" -eq 0 ]; then
    add_result PASS "Governance" "Policy compliance" "${POLICY_COUNT} policy resource(s); none report NonCompliant" "None."
  else
    add_result WARN "Governance" "Policy compliance" "${NONCOMPLIANT} of ${POLICY_COUNT} policy resource(s) report NonCompliant" "Review policy severity, affected clusters, remediationAction, and approved exceptions."
  fi
else
  add_result FAIL "Governance" "Policy API" "Policy CRD is absent" "Verify ACM governance components and configuration-policy add-ons."
fi

capture_cmd "${RAW}/placements.yaml" "${OC} get placements.cluster.open-cluster-management.io -A -o yaml"
capture_cmd "${RAW}/placementdecisions.yaml" "${OC} get placementdecisions.cluster.open-cluster-management.io -A -o yaml"
capture_cmd "${RAW}/managedclustersets.yaml" "${OC} get managedclustersets.cluster.open-cluster-management.io -o yaml"
capture_cmd "${RAW}/managedclustersetbindings.yaml" "${OC} get managedclustersetbindings.cluster.open-cluster-management.io -A -o yaml"

# -----------------------------------------------------------------------------
# 5. Observability
# -----------------------------------------------------------------------------
if api_exists "multiclusterobservabilities.observability.open-cluster-management.io"; then
  capture_cmd "${RAW}/multiclusterobservability.yaml" "${OC} get multiclusterobservabilities.observability.open-cluster-management.io -o yaml"
  MCO_JSON="$("${OC}" get multiclusterobservabilities.observability.open-cluster-management.io -o json 2>/dev/null || printf '{"items":[]}')"
  MCO_COUNT="$(printf '%s' "${MCO_JSON}" | "${JQ}" '.items | length')"
  if [ "${MCO_COUNT}" -eq 0 ]; then
    add_result WARN "Observability" "MultiClusterObservability service" "Operator API exists but no MultiClusterObservability instance was found" "For production fleets, evaluate enabling observability with supported, durable object storage and capacity planning."
  else
    MCO_FALSE_CONDITIONS="$(printf '%s' "${MCO_JSON}" | "${JQ}" '[.items[] | .status.conditions[]? | select(.status=="False" and (.type | test("Ready|Available|Reconciled"; "i")))] | length')"
    MCO_STORAGE_SECRET="$(printf '%s' "${MCO_JSON}" | "${JQ}" -r '.items[0].spec.storageConfig.metricObjectStorage.name // ""')"
    if [ "${MCO_FALSE_CONDITIONS}" -eq 0 ]; then
      add_result PASS "Observability" "MultiClusterObservability status" "${MCO_COUNT} instance(s); no false Ready/Available/Reconciled condition detected" "None."
    else
      add_result FAIL "Observability" "MultiClusterObservability status" "${MCO_FALSE_CONDITIONS} failing readiness condition(s)" "Inspect the MCO status, observability pods, object-storage connectivity, PVCs, and certificates."
    fi
    if [ -n "${MCO_STORAGE_SECRET}" ] && "${OC}" get secret -n open-cluster-management-observability "${MCO_STORAGE_SECRET}" >/dev/null 2>&1; then
      add_result PASS "Observability" "Object-storage secret reference" "secret=open-cluster-management-observability/${MCO_STORAGE_SECRET}" "Rotate credentials through a secret-management workflow and keep insecure_skip_verify disabled."
    else
      add_result FAIL "Observability" "Object-storage secret reference" "referencedSecret=${MCO_STORAGE_SECRET:-not-set}" "Create the supported object-storage secret and confirm the MCO storageConfig reference."
    fi
  fi
else
  add_result WARN "Observability" "MultiClusterObservability API" "Observability CRD is absent" "Confirm whether the observability component was intentionally disabled in MultiClusterHub."
fi

# -----------------------------------------------------------------------------
# 6. Backup and restore / OADP
# -----------------------------------------------------------------------------
if api_exists "backupschedules.cluster.open-cluster-management.io"; then
  capture_cmd "${RAW}/backupschedules.yaml" "${OC} get backupschedules.cluster.open-cluster-management.io -A -o yaml"
  BS_JSON="$("${OC}" get backupschedules.cluster.open-cluster-management.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  BS_COUNT="$(printf '%s' "${BS_JSON}" | "${JQ}" '.items | length')"
  if [ "${BS_COUNT}" -eq 0 ]; then
    add_result WARN "Business Continuity" "ACM BackupSchedule" "BackupSchedule API exists but no schedule is configured" "Install/configure OADP, validate BackupStorageLocation, create an ACM BackupSchedule, and perform restore tests."
  else
    BS_BAD="$(printf '%s' "${BS_JSON}" | "${JQ}" '[.items[] | select(.spec.paused == true or ((.status.phase // "Unknown") != "Enabled" and (.status.phase // "Unknown") != "Running"))] | length')"
    BS_COLLISION="$(printf '%s' "${BS_JSON}" | "${JQ}" '[.items[] | select((.status.phase // "") == "BackupCollision")] | length')"
    BS_SUMMARY="$(printf '%s' "${BS_JSON}" | "${JQ}" -r '.items[] | [.metadata.namespace,.metadata.name,(.status.phase // "Unknown"),(.spec.veleroSchedule // ""),(.spec.veleroTtl // ""),(.spec.paused // false)] | @tsv' | tr '\n' ';')"
    if [ "${BS_BAD}" -eq 0 ] && [ "${BS_COLLISION}" -eq 0 ]; then
      add_result PASS "Business Continuity" "ACM BackupSchedule" "${BS_SUMMARY}" "Confirm the schedule meets RPO/RTO and test restores on an isolated recovery hub."
    else
      add_result FAIL "Business Continuity" "ACM BackupSchedule" "${BS_SUMMARY}; collisions=${BS_COLLISION}" "Resolve validation, paused state, backup collision, OADP, credentials, or object-storage errors before relying on backups."
    fi
  fi
else
  add_result WARN "Business Continuity" "ACM BackupSchedule API" "Backup and restore operator API is absent" "Enable the ACM backup component and OADP if hub recovery is required by the production service level."
fi

if api_exists "backupstoragelocations.velero.io"; then
  capture_cmd "${RAW}/velero-backup-storage-locations.yaml" "${OC} get backupstoragelocations.velero.io -A -o yaml"
  BSL_JSON="$("${OC}" get backupstoragelocations.velero.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  BSL_COUNT="$(printf '%s' "${BSL_JSON}" | "${JQ}" '.items | length')"
  BSL_BAD="$(printf '%s' "${BSL_JSON}" | "${JQ}" '[.items[] | select((.status.phase // "Unknown") != "Available")] | length')"
  if [ "${BSL_COUNT}" -eq 0 ]; then
    add_result WARN "Business Continuity" "Velero BackupStorageLocation" "No BackupStorageLocation found" "Configure and validate a durable backup target before creating the ACM backup schedule."
  elif [ "${BSL_BAD}" -eq 0 ]; then
    add_result PASS "Business Continuity" "Velero BackupStorageLocation" "${BSL_COUNT} BackupStorageLocation resource(s); all Available" "None."
  else
    add_result FAIL "Business Continuity" "Velero BackupStorageLocation" "${BSL_BAD} of ${BSL_COUNT} locations are not Available" "Check credentials, CA trust, endpoint, bucket permissions, DNS, proxy, and network policy."
  fi
fi

if api_exists "backups.velero.io"; then
  capture_cmd "${RAW}/velero-backups.yaml" "${OC} get backups.velero.io -A -o yaml"
  VBACKUP_JSON="$("${OC}" get backups.velero.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  ACM_BACKUP_COUNT="$(printf '%s' "${VBACKUP_JSON}" | "${JQ}" '[.items[] | select(.metadata.name | startswith("acm-"))] | length')"
  ACM_BACKUP_BAD="$(printf '%s' "${VBACKUP_JSON}" | "${JQ}" '[.items[] | select(.metadata.name | startswith("acm-")) | select((.status.phase // "Unknown") != "Completed")] | length')"
  if [ "${ACM_BACKUP_COUNT}" -eq 0 ]; then
    add_result WARN "Business Continuity" "Completed ACM Velero backups" "No acm-* Velero backup found" "Wait for the first schedule or troubleshoot schedule generation and storage access."
  elif [ "${ACM_BACKUP_BAD}" -eq 0 ]; then
    add_result PASS "Business Continuity" "Completed ACM Velero backups" "${ACM_BACKUP_COUNT} ACM backup resource(s); all Completed" "Periodically prune per retention policy and perform restore validation."
  else
    add_result FAIL "Business Continuity" "Completed ACM Velero backups" "${ACM_BACKUP_BAD} of ${ACM_BACKUP_COUNT} ACM backup resource(s) are not Completed" "Describe failed/partial backups and inspect Velero, backup operator, storage, and credential logs."
  fi
fi
capture_cmd "${RAW}/data-protection-applications.yaml" "${OC} get dataprotectionapplications.oadp.openshift.io -A -o yaml"
capture_cmd "${RAW}/restores-acm.yaml" "${OC} get restores.cluster.open-cluster-management.io -A -o yaml"
capture_cmd "${RAW}/restores-velero.yaml" "${OC} get restores.velero.io -A -o yaml"

# -----------------------------------------------------------------------------
# 7. Security, RBAC, channels, TLS certificate age
# -----------------------------------------------------------------------------
capture_cmd "${RAW}/clusterrolebindings.yaml" "${OC} get clusterrolebindings -o yaml"
capture_cmd "${RAW}/acm-rbac-summary.txt" "${OC} get clusterrolebindings -o custom-columns=NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name | grep -E 'cluster-admin|open-cluster-management|multicluster' || true"

CRB_JSON="$("${OC}" get clusterrolebindings -o json 2>/dev/null || printf '{"items":[]}')"
PUBLIC_CLUSTER_ADMIN="$(printf '%s' "${CRB_JSON}" | "${JQ}" '[.items[] | select(.roleRef.name=="cluster-admin") | select(any(.subjects[]?; (.kind=="Group" and (.name=="system:authenticated" or .name=="system:unauthenticated" or .name=="system:anonymous"))))] | length')"
if [ "${PUBLIC_CLUSTER_ADMIN}" -eq 0 ]; then
  add_result PASS "Security" "Public cluster-admin binding" "No cluster-admin binding to authenticated, unauthenticated, or anonymous system groups" "Continue periodic privileged-access recertification."
else
  add_result FAIL "Security" "Public cluster-admin binding" "${PUBLIC_CLUSTER_ADMIN} dangerous ClusterRoleBinding(s) detected" "Remove broad public cluster-admin grants immediately through controlled emergency change."
fi

CLUSTER_ADMIN_BINDINGS="$(printf '%s' "${CRB_JSON}" | "${JQ}" '[.items[] | select(.roleRef.name=="cluster-admin")] | length')"
add_result INFO "Security" "Cluster-admin binding inventory" "${CLUSTER_ADMIN_BINDINGS} ClusterRoleBinding(s) reference cluster-admin" "Review human, group, automation, and break-glass subjects against least privilege and expiration requirements."

if api_exists "channels.apps.open-cluster-management.io"; then
  capture_cmd "${RAW}/channels.yaml" "${OC} get channels.apps.open-cluster-management.io -A -o yaml"
  CHANNEL_JSON="$("${OC}" get channels.apps.open-cluster-management.io -A -o json 2>/dev/null || printf '{"items":[]}')"
  INSECURE_CHANNELS="$(printf '%s' "${CHANNEL_JSON}" | "${JQ}" '[.items[] | select(.spec.insecureSkipVerify == true)] | length')"
  if [ "${INSECURE_CHANNELS}" -eq 0 ]; then
    add_result PASS "Security" "Application channel TLS verification" "No Channel resource has insecureSkipVerify=true" "None."
  else
    add_result WARN "Security" "Application channel TLS verification" "${INSECURE_CHANNELS} Channel resource(s) disable TLS verification" "Install the correct CA trust and remove insecureSkipVerify after repository validation."
  fi
fi

if command -v "${OPENSSL}" >/dev/null 2>&1 && "${OC}" auth can-i list secrets -A 2>/dev/null | grep -q yes; then
  CERT_WARNINGS=0
  CERT_CHECKED=0
  : > "${RAW}/tls-certificate-expiry.txt"
  while IFS= read -r ns; do
    [ -n "${ns}" ] || continue
    namespace_exists "${ns}" || continue
    TLS_JSON="$("${OC}" get secrets -n "${ns}" -o json 2>/dev/null || printf '{"items":[]}')"
    TLS_SECRETS="$(printf '%s' "${TLS_JSON}" | "${JQ}" -r '.items[] | select(.type=="kubernetes.io/tls" and .data["tls.crt"] != null) | .metadata.name')"
    while IFS= read -r secret; do
      [ -n "${secret}" ] || continue
      cert_file="$(mktemp)"
      if "${OC}" get secret -n "${ns}" "${secret}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "${cert_file}" 2>/dev/null && [ -s "${cert_file}" ]; then
        CERT_CHECKED=$((CERT_CHECKED + 1))
        expiry="$("${OPENSSL}" x509 -in "${cert_file}" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
        printf '%s/%s\t%s\n' "${ns}" "${secret}" "${expiry}" >> "${RAW}/tls-certificate-expiry.txt"
        if ! "${OPENSSL}" x509 -in "${cert_file}" -checkend "$((CERT_WARN_DAYS * 86400))" -noout >/dev/null 2>&1; then
          CERT_WARNINGS=$((CERT_WARNINGS + 1))
        fi
      fi
      rm -f "${cert_file}"
    done <<EOF_TLS
${TLS_SECRETS}
EOF_TLS
  done <<EOF_CERTNS
${ALL_NS}
EOF_CERTNS
  if [ "${CERT_WARNINGS}" -eq 0 ]; then
    add_result PASS "Security" "TLS certificate expiry" "checked=${CERT_CHECKED}; none expire within ${CERT_WARN_DAYS} days" "None."
  else
    add_result WARN "Security" "TLS certificate expiry" "${CERT_WARNINGS} of ${CERT_CHECKED} TLS certificate(s) expire within ${CERT_WARN_DAYS} days or are invalid" "Identify operator-managed versus custom certificates and renew custom certificates before expiry."
  fi
else
  add_result INFO "Security" "TLS certificate expiry" "Skipped because openssl or secret-list permission is unavailable" "Run with appropriate read permission or validate certificates through the supported certificate-management process."
fi

# -----------------------------------------------------------------------------
# 8. Capacity snapshots
# -----------------------------------------------------------------------------
capture_cmd "${RAW}/pod-resource-requests.txt" "${OC} get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory | grep -E 'open-cluster-management|multicluster-engine' || true"
capture_cmd "${RAW}/top-nodes.txt" "${OC} adm top nodes"
capture_cmd "${RAW}/top-acm-pods.txt" "${OC} adm top pods -A --containers | grep -E 'open-cluster-management|multicluster-engine' || true"
capture_cmd "${RAW}/resourcequotas.yaml" "${OC} get resourcequotas -A -o yaml"
capture_cmd "${RAW}/limitranges.yaml" "${OC} get limitranges -A -o yaml"
capture_cmd "${RAW}/poddisruptionbudgets.yaml" "${OC} get poddisruptionbudgets -A -o yaml"
capture_cmd "${RAW}/storageclasses.yaml" "${OC} get storageclasses.storage.k8s.io -o yaml"

# -----------------------------------------------------------------------------
# 9. Build Markdown report
# -----------------------------------------------------------------------------
SCORE=$((100 - (FAIL_COUNT * 10) - (WARN_COUNT * 3)))
[ "${SCORE}" -lt 0 ] && SCORE=0
if [ "${FAIL_COUNT}" -gt 0 ]; then
  OVERALL="FAIL"
elif [ "${WARN_COUNT}" -gt 0 ]; then
  OVERALL="WARN"
else
  OVERALL="PASS"
fi

{
  echo "## Executive summary"
  echo
  echo "- **Overall:** ${OVERALL}"
  echo "- **Heuristic score:** ${SCORE}/100"
  echo "- **PASS:** ${PASS_COUNT}"
  echo "- **WARN:** ${WARN_COUNT}"
  echo "- **FAIL:** ${FAIL_COUNT}"
  echo "- **INFO:** ${INFO_COUNT}"
  echo
  echo "## Findings"
  echo
  echo "| Status | Area | Check | Evidence | Recommendation |"
  echo "|---|---|---|---|---|"
  cat "${MD_ROWS}"
  echo
  echo "## Evidence"
  echo
  echo "- Raw object and command output: \`${RAW}/\`"
  echo "- Logs for failing pods, when enabled and authorized: \`${LOGS}/\`"
  echo "- Machine-readable findings: \`${RESULTS}\`"
  echo
  echo "## Exit-code behavior"
  echo
  echo "- \`0\`: no FAIL findings; warnings may exist."
  echo "- \`1\`: warnings exist and \`FAIL_ON_WARN=true\`."
  echo "- \`2\`: at least one FAIL finding."
  echo "- \`3-4\`: missing prerequisite or authentication failure."
} >> "${REPORT}"

printf '\nACM health check completed.\n'
printf 'Overall: %s | Score: %s/100 | PASS=%s WARN=%s FAIL=%s INFO=%s\n' "${OVERALL}" "${SCORE}" "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}" "${INFO_COUNT}"
printf 'Report: %s\n' "${REPORT}"
printf 'Results: %s\n' "${RESULTS}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 2
fi
if [ "${WARN_COUNT}" -gt 0 ] && [ "${FAIL_ON_WARN}" = "true" ]; then
  exit 1
fi
exit 0
