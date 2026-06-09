#!/usr/bin/env bash
# OpenShift 4.18+ Health Check CER Collector
# Read-only collector that gathers evidence, logs, a small HTML report, and CER-ready item files.
# Provided as-is. Review generated findings before delivery.

set -u
set -o pipefail

###############################################################################
# Example variables - adjust here or provide an env file with --env-file.
###############################################################################
CLUSTER_NAME_HINT="${CLUSTER_NAME_HINT:-ocp-production}"
ENGAGEMENT_NAME="${ENGAGEMENT_NAME:-OpenShift Health Check}"
OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-./ocp-healthcheck-runs}"
MIN_OCP_VERSION="${MIN_OCP_VERSION:-4.18}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
DEEP="${DEEP:-false}"
RUN_MUST_GATHER="${RUN_MUST_GATHER:-false}"
COLLECT_PROBLEM_POD_LOGS="${COLLECT_PROBLEM_POD_LOGS:-true}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-300}"
MAX_PROBLEM_PODS="${MAX_PROBLEM_PODS:-40}"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-10}"
RUN_PROMETHEUS_ALERTS="${RUN_PROMETHEUS_ALERTS:-true}"
EVENT_LIMIT="${EVENT_LIMIT:-500}"
COLLECT_NAMESPACED_WORKLOADS="${COLLECT_NAMESPACED_WORKLOADS:-true}"
COLLECT_OPENSHIFT_VIRTUALIZATION="${COLLECT_OPENSHIFT_VIRTUALIZATION:-true}"
COLLECT_ODF="${COLLECT_ODF:-true}"
COLLECT_ACM="${COLLECT_ACM:-true}"
COLLECT_ACS="${COLLECT_ACS:-true}"
COLLECT_GITOPS_PIPELINES="${COLLECT_GITOPS_PIPELINES:-true}"
COLLECT_NODE_DEBUG="${COLLECT_NODE_DEBUG:-false}"
WRITE_CER_ITEMS_TO_REPO="${WRITE_CER_ITEMS_TO_REPO:-false}"
CER_REPO_ROOT="${CER_REPO_ROOT:-}"
SANITIZE_DELIVERY_OUTPUT="${SANITIZE_DELIVERY_OUTPUT:-true}"
REDACTION_PATTERNS_FILE="${REDACTION_PATTERNS_FILE:-}"
CREATE_PACKAGES="${CREATE_PACKAGES:-true}"
STOP_ON_VERSION_BELOW_MIN="${STOP_ON_VERSION_BELOW_MIN:-true}"

###############################################################################
# Runtime globals
###############################################################################
SCRIPT_NAME="$(basename "$0")"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR=""
RAW_DIR=""
LOG_DIR=""
DESC_DIR=""
CER_DIR=""
ITEM_DIR=""
TMP_DIR=""
COMMAND_INDEX=""
RESULTS_TSV=""
SUMMARY_TXT=""
RUN_LOG=""
GLOBAL_STATUS="HEALTHY"
WARN_COUNT=0
CRIT_COUNT=0
INFO_COUNT=0
HAVE_JQ=false
OCP_VERSION="unknown"
SERVER_VERSION="unknown"
CONSOLE_URL="unknown"
CLUSTER_ID="unknown"
INFRA_NAME="unknown"

###############################################################################
# CLI parsing
###############################################################################
usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options]

Options:
  --env-file FILE                Load variables from FILE.
  --cluster-name NAME            Set CLUSTER_NAME_HINT.
  --output DIR                   Set OUTPUT_BASE_DIR.
  --deep                         Collect additional evidence.
  --must-gather                  Run oc adm must-gather into the run directory.
  --no-must-gather               Do not run must-gather.
  --no-pod-logs                  Do not collect logs from problem pods.
  --tail-lines N                 Tail N lines from problem pod logs. Default: ${LOG_TAIL_LINES}.
  --max-problem-pods N           Maximum problem pods for log collection. Default: ${MAX_PROBLEM_PODS}.
  --cer-root DIR                 CER repository root. Used only when WRITE_CER_ITEMS_TO_REPO=true.
  --write-cer-items              Copy generated .item files to CER_REPO_ROOT/content/healthcheck-items.
  --no-sanitize                  Do not create sanitized delivery outputs.
  --help                         Show this help.

Examples:
  oc login https://api.<cluster>:6443
  ./${SCRIPT_NAME} --cluster-name prod-ocp --deep
  ./${SCRIPT_NAME} --env-file ./.ocp-healthcheck.env --must-gather
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --env-file" >&2; exit 2; }
      # shellcheck disable=SC1090
      source "$1"
      ;;
    --cluster-name)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --cluster-name" >&2; exit 2; }
      CLUSTER_NAME_HINT="$1"
      ;;
    --output)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --output" >&2; exit 2; }
      OUTPUT_BASE_DIR="$1"
      ;;
    --deep) DEEP="true" ;;
    --must-gather) RUN_MUST_GATHER="true" ;;
    --no-must-gather) RUN_MUST_GATHER="false" ;;
    --no-pod-logs) COLLECT_PROBLEM_POD_LOGS="false" ;;
    --tail-lines)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --tail-lines" >&2; exit 2; }
      LOG_TAIL_LINES="$1"
      ;;
    --max-problem-pods)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --max-problem-pods" >&2; exit 2; }
      MAX_PROBLEM_PODS="$1"
      ;;
    --cer-root)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --cer-root" >&2; exit 2; }
      CER_REPO_ROOT="$1"
      ;;
    --write-cer-items) WRITE_CER_ITEMS_TO_REPO="true" ;;
    --no-sanitize) SANITIZE_DELIVERY_OUTPUT="false" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

###############################################################################
# Utility functions
###############################################################################
have_cmd() { command -v "$1" >/dev/null 2>&1; }

log() {
  local msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | tee -a "${RUN_LOG:-/dev/null}"
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

csv_escape() {
  local s="$1"
  s=${s//\"/\"\"}
  printf '"%s"' "$s"
}

sanitize_stream() {
  if [[ "${SANITIZE_DELIVERY_OUTPUT}" != "true" || -z "${REDACTION_PATTERNS_FILE}" || ! -f "${REDACTION_PATTERNS_FILE}" ]]; then
    cat
    return
  fi
  local sed_args=()
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" ]] && continue
    [[ "$pattern" =~ ^# ]] && continue
    sed_args+=(-e "s/${pattern}/[REDACTED]/gI")
  done < "${REDACTION_PATTERNS_FILE}"
  if [[ ${#sed_args[@]} -eq 0 ]]; then
    cat
  else
    sed "${sed_args[@]}"
  fi
}

sanitize_value() {
  printf '%s' "$1" | sanitize_stream
}

mark_warning() {
  WARN_COUNT=$((WARN_COUNT + 1))
  [[ "$GLOBAL_STATUS" != "CRITICAL" ]] && GLOBAL_STATUS="WARNING"
}

mark_critical() {
  CRIT_COUNT=$((CRIT_COUNT + 1))
  GLOBAL_STATUS="CRITICAL"
}

mark_info() {
  INFO_COUNT=$((INFO_COUNT + 1))
}

version_ge() {
  local current="$1"
  local minimum="$2"
  [[ "$current" == "unknown" || -z "$current" ]] && return 1
  local lowest
  lowest=$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)
  [[ "$lowest" == "$minimum" ]]
}

init_dirs() {
  mkdir -p "$OUTPUT_BASE_DIR"
  RUN_DIR="${OUTPUT_BASE_DIR}/ocp418-cer-healthcheck-$(safe_name "$CLUSTER_NAME_HINT")-${RUN_TS}"
  RAW_DIR="${RUN_DIR}/raw"
  LOG_DIR="${RUN_DIR}/logs/problem-pods"
  DESC_DIR="${RUN_DIR}/describes/problem-pods"
  CER_DIR="${RUN_DIR}/cer"
  ITEM_DIR="${CER_DIR}/healthcheck-items"
  TMP_DIR="${RUN_DIR}/tmp"
  COMMAND_INDEX="${RUN_DIR}/command-index.tsv"
  RESULTS_TSV="${CER_DIR}/findings.tsv"
  SUMMARY_TXT="${RUN_DIR}/summary.txt"
  RUN_LOG="${RUN_DIR}/run.log"
  mkdir -p "$RAW_DIR" "$LOG_DIR" "$DESC_DIR" "$CER_DIR" "$ITEM_DIR" "$TMP_DIR"
  : > "$RUN_LOG"
  printf 'timestamp\tkey\tcategory\trc\toutput_file\tcommand\n' > "$COMMAND_INDEX"
  printf 'category\tsubcategory\titem\tobserved\trecommendation\tevidence\timpact\tremediation\tcomments\n' > "$RESULTS_TSV"
}

run_capture() {
  local key="$1"
  local category="$2"
  local cmd="$3"
  local cat_dir outfile rc start_ts
  cat_dir="${RAW_DIR}/$(safe_name "$category")"
  mkdir -p "$cat_dir"
  outfile="${cat_dir}/$(safe_name "$key").txt"
  start_ts="$(date -Iseconds)"
  log "Collecting [${category}] ${key}"
  {
    echo "# Timestamp: ${start_ts}"
    echo "# Command: ${cmd}"
    echo
    if have_cmd timeout; then
      timeout "${TIMEOUT_SECONDS}" bash -o pipefail -c "$cmd"
    else
      bash -o pipefail -c "$cmd"
    fi
  } > "$outfile" 2>&1
  rc=$?
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$start_ts" "$key" "$category" "$rc" "$outfile" "$cmd" >> "$COMMAND_INDEX"
  if [[ $rc -ne 0 ]]; then
    log "WARN: command failed rc=${rc}: ${key}"
  fi
  return 0
}

run_oc_if_api_exists() {
  local resource="$1"
  local key="$2"
  local category="$3"
  local cmd="$4"
  if oc api-resources --verbs=list -o name 2>/dev/null | grep -qx "$resource"; then
    run_capture "$key" "$category" "$cmd"
  else
    log "Skipping ${key}; API resource not available: ${resource}"
    local cat_dir outfile
    cat_dir="${RAW_DIR}/$(safe_name "$category")"
    mkdir -p "$cat_dir"
    outfile="${cat_dir}/$(safe_name "$key").txt"
    echo "API resource not available: ${resource}" > "$outfile"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$key" "$category" "0" "$outfile" "skipped: ${resource}" >> "$COMMAND_INDEX"
  fi
}

record_result() {
  local category="$1" subcategory="$2" item="$3" observed="$4" recommendation="$5" evidence="$6" impact="$7" remediation="$8" comments="$9"
  case "$recommendation" in
    changes_required) mark_critical ;;
    changes_recommended|advisory) mark_warning ;;
    no_change|not_applicable|tbe) mark_info ;;
    *) recommendation="tbe"; mark_info ;;
  esac
  observed="$(sanitize_value "$observed")"
  impact="$(sanitize_value "$impact")"
  remediation="$(sanitize_value "$remediation")"
  comments="$(sanitize_value "$comments")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$category" "$subcategory" "$item" "$observed" "$recommendation" "$evidence" "$impact" "$remediation" "$comments" >> "$RESULTS_TSV"
}

write_item_file() {
  local idx="$1" category="$2" subcategory="$3" item="$4" observed="$5" recommendation="$6" evidence="$7" impact="$8" remediation="$9" comments="${10}"
  local file slug item_esc observed_esc
  item_esc=${item//\"/\\\"}
  observed_esc=${observed//\"/\\\"}
  slug="$(safe_name "${idx}-${category}-${subcategory}-${item}")"
  file="${ITEM_DIR}/${slug}.item"
  cat > "$file" <<ITEM
---
version: v1
metadata:
  category_key: "$(safe_name "$category")"
  item_evaluated: "${item_esc}"
  references:
    - title: "Red Hat OpenShift documentation"
      url: "https://docs.redhat.com/"
  check_procedures:
    - type: cli
      question: "Review the generated evidence referenced by this item."
results:
  recommendation: ${recommendation}
  acceptance_criteria_id: ""
  result_short_text: "${observed_esc}"
  result_long_text: |
    Evidence collected by ${SCRIPT_NAME} during the OpenShift health check.
    Evidence reference: ${evidence}
  impact_risk_additional_text: |
    ${impact}
  remediation_additional_text: |
    ${remediation}
  additional_comments_text: |
    ${comments}
ITEM
}

###############################################################################
# Preflight and metadata
###############################################################################
preflight() {
  log "Starting OpenShift 4.18+ Health Check CER Collector"
  if ! have_cmd oc; then
    echo "ERROR: oc CLI is required." >&2
    exit 1
  fi
  if have_cmd jq; then
    HAVE_JQ=true
  else
    HAVE_JQ=false
    log "WARN: jq not found. Reports will be generated with reduced automated analysis."
  fi
  if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: oc is not logged in or the current user cannot access the cluster." >&2
    exit 1
  fi
  run_capture "oc-whoami" "00-preflight" "oc whoami && oc whoami --show-server"
  run_capture "oc-version" "00-preflight" "oc version"
  run_capture "cluster-version-json" "00-preflight" "oc get clusterversion version -o json"
  OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
  [[ -z "$OCP_VERSION" ]] && OCP_VERSION="unknown"
  SERVER_VERSION=$(oc version -o json 2>/dev/null | sed -n 's/.*"gitVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)
  [[ -z "$SERVER_VERSION" ]] && SERVER_VERSION="unknown"
  CONSOLE_URL=$(oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}' 2>/dev/null || true)
  [[ -z "$CONSOLE_URL" ]] && CONSOLE_URL="unknown"
  CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || true)
  [[ -z "$CLUSTER_ID" ]] && CLUSTER_ID="unknown"
  INFRA_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true)
  [[ -z "$INFRA_NAME" ]] && INFRA_NAME="unknown"

  if ! version_ge "$OCP_VERSION" "$MIN_OCP_VERSION"; then
    record_result "Platform" "Lifecycle Management" "Cluster Version" \
      "OpenShift version ${OCP_VERSION} is below the minimum expected version ${MIN_OCP_VERSION}." \
      "changes_required" "raw/00-preflight/cluster-version-json.txt" \
      "Running below the defined baseline can affect supportability and lifecycle planning." \
      "Plan an OpenShift update to a supported version aligned with the engagement baseline." \
      "Version check was performed before full data collection."
    if [[ "$STOP_ON_VERSION_BELOW_MIN" == "true" ]]; then
      log "ERROR: OpenShift version ${OCP_VERSION} is below ${MIN_OCP_VERSION}. Set STOP_ON_VERSION_BELOW_MIN=false to continue."
      finalize_reports
      exit 1
    fi
  else
    record_result "Platform" "Lifecycle Management" "Cluster Version" \
      "OpenShift version ${OCP_VERSION} meets the minimum expected version ${MIN_OCP_VERSION}." \
      "no_change" "raw/00-preflight/cluster-version-json.txt" \
      "No immediate lifecycle risk was identified from the version baseline check." \
      "Continue managing updates through the standard OpenShift lifecycle process." \
      "Automated version check."
  fi
}

###############################################################################
# Data collection
###############################################################################
collect_core() {
  run_capture "clusteroperators" "01-core" "oc get clusteroperators"
  run_capture "clusteroperators-yaml" "01-core" "oc get clusteroperators -o yaml"
  run_capture "clusterversion" "01-core" "oc get clusterversion version -o yaml"
  run_capture "nodes-wide" "01-core" "oc get nodes -o wide"
  run_capture "nodes-yaml" "01-core" "oc get nodes -o yaml"
  run_capture "nodes-describe" "01-core" "oc describe nodes"
  run_capture "machineconfigpools" "01-core" "oc get machineconfigpools -o wide"
  run_capture "machineconfigpools-yaml" "01-core" "oc get machineconfigpools -o yaml"
  run_capture "events-warning" "01-core" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -n ${EVENT_LIMIT}"
  run_capture "apiservices" "01-core" "oc get apiservices"
  run_capture "csr" "01-core" "oc get csr"
  run_capture "namespaces" "01-core" "oc get namespaces --show-labels"
  run_capture "pods-wide" "01-core" "oc get pods -A -o wide"
  run_capture "pods-json" "01-core" "oc get pods -A -o json"
  run_capture "resource-capacity-top-nodes" "01-core" "oc adm top nodes || true"
  run_capture "resource-capacity-top-pods" "01-core" "oc adm top pods -A || true"
}

collect_infrastructure() {
  run_capture "infrastructure" "02-infrastructure" "oc get infrastructure cluster -o yaml"
  run_capture "dns" "02-infrastructure" "oc get dns cluster -o yaml"
  run_capture "network" "02-infrastructure" "oc get network cluster -o yaml"
  run_capture "proxy" "02-infrastructure" "oc get proxy cluster -o yaml"
  run_capture "ingresscontrollers" "02-infrastructure" "oc -n openshift-ingress-operator get ingresscontroller -o yaml"
  run_capture "routes" "02-infrastructure" "oc get routes -A"
  run_capture "endpoints-core" "02-infrastructure" "oc get endpoints,endpointslices -A | head -n 300"
  run_capture "networkpolicies" "02-infrastructure" "oc get networkpolicy -A"
  run_oc_if_api_exists "egressips.k8s.ovn.org" "egressips" "02-infrastructure" "oc get egressips.k8s.ovn.org -A -o yaml"
  run_oc_if_api_exists "egressfirewalls.k8s.ovn.org" "egressfirewalls" "02-infrastructure" "oc get egressfirewalls.k8s.ovn.org -A -o yaml"
  run_oc_if_api_exists "adminnetworkpolicies.policy.networking.k8s.io" "adminnetworkpolicies" "02-infrastructure" "oc get adminnetworkpolicies.policy.networking.k8s.io -A -o yaml"
  run_oc_if_api_exists "baselineadminnetworkpolicies.policy.networking.k8s.io" "baselineadminnetworkpolicies" "02-infrastructure" "oc get baselineadminnetworkpolicies.policy.networking.k8s.io -A -o yaml"
  run_oc_if_api_exists "nmstateconfigs.agent-install.openshift.io" "nmstateconfigs" "02-infrastructure" "oc get nmstateconfigs.agent-install.openshift.io -A -o yaml"
  run_capture "machineconfigs" "02-infrastructure" "oc get machineconfigs -o yaml"
  run_oc_if_api_exists "kubeletconfigs.machineconfiguration.openshift.io" "kubeletconfigs" "02-infrastructure" "oc get kubeletconfigs.machineconfiguration.openshift.io -o yaml"
  run_oc_if_api_exists "tuneds.tuned.openshift.io" "tuneds" "02-infrastructure" "oc get tuneds.tuned.openshift.io -A -o yaml"
  run_oc_if_api_exists "performanceprofiles.performance.openshift.io" "performanceprofiles" "02-infrastructure" "oc get performanceprofiles.performance.openshift.io -A -o yaml"
}

collect_storage() {
  run_capture "storageclasses" "03-storage" "oc get storageclass -o yaml"
  run_capture "persistentvolumes" "03-storage" "oc get pv -o wide"
  run_capture "persistentvolumeclaims" "03-storage" "oc get pvc -A -o wide"
  run_capture "volumeattachments" "03-storage" "oc get volumeattachments -o yaml || true"
  run_capture "csidrivers" "03-storage" "oc get csidrivers -o yaml || true"
  run_capture "storage-operators" "03-storage" "oc get csv -A | grep -Ei 'storage|odf|ocs|local|lvms|data foundation' || true"
  if [[ "$COLLECT_ODF" == "true" ]]; then
    run_oc_if_api_exists "storageclusters.ocs.openshift.io" "odf-storageclusters" "03-storage" "oc get storageclusters.ocs.openshift.io -A -o yaml"
    run_oc_if_api_exists "cephclusters.ceph.rook.io" "odf-cephclusters" "03-storage" "oc get cephclusters.ceph.rook.io -A -o yaml"
    run_oc_if_api_exists "cephblockpools.ceph.rook.io" "odf-cephblockpools" "03-storage" "oc get cephblockpools.ceph.rook.io -A -o yaml"
    run_oc_if_api_exists "cephfilesystems.ceph.rook.io" "odf-cephfilesystems" "03-storage" "oc get cephfilesystems.ceph.rook.io -A -o yaml"
    run_oc_if_api_exists "objectbucketclaims.objectbucket.io" "odf-objectbucketclaims" "03-storage" "oc get objectbucketclaims.objectbucket.io -A -o yaml"
  fi
}

collect_platform() {
  run_capture "olm-clusterserviceversions" "04-platform" "oc get csv -A"
  run_capture "olm-subscriptions" "04-platform" "oc get subscriptions.operators.coreos.com -A -o yaml || true"
  run_capture "olm-installplans" "04-platform" "oc get installplans.operators.coreos.com -A || true"
  run_capture "olm-catalogsources" "04-platform" "oc get catalogsources.operators.coreos.com -A -o yaml || true"
  run_capture "operatorhub" "04-platform" "oc get operatorhub cluster -o yaml || true"
  run_capture "image-config" "04-platform" "oc get image.config.openshift.io cluster -o yaml"
  run_capture "image-registry-config" "04-platform" "oc get configs.imageregistry.operator.openshift.io cluster -o yaml || true"
  run_oc_if_api_exists "imagedigestmirrorsets.config.openshift.io" "image-digest-mirror-sets" "04-platform" "oc get imagedigestmirrorsets.config.openshift.io -o yaml"
  run_oc_if_api_exists "imagetagmirrorsets.config.openshift.io" "image-tag-mirror-sets" "04-platform" "oc get imagetagmirrorsets.config.openshift.io -o yaml"
  run_oc_if_api_exists "imagecontentsourcepolicies.operator.openshift.io" "image-content-source-policies" "04-platform" "oc get imagecontentsourcepolicies.operator.openshift.io -o yaml"
  run_capture "oauth-config" "04-platform" "oc get oauth cluster -o yaml"
  run_capture "kubeadmin-secret-presence" "04-platform" "oc -n kube-system get secret kubeadmin -o name 2>/dev/null || true"
  run_capture "self-provisioner" "04-platform" "oc describe clusterrolebinding self-provisioners 2>/dev/null || true"
  run_capture "apiserver-config" "04-platform" "oc get apiserver cluster -o yaml"
  run_capture "authentication-config" "04-platform" "oc get authentication cluster -o yaml"
  run_capture "console-config" "04-platform" "oc get console cluster -o yaml"
  run_capture "etcd-cluster" "04-platform" "oc get etcd cluster -o yaml"
  run_capture "etcd-pods" "04-platform" "oc -n openshift-etcd get pods -o wide"
  run_capture "etcd-backup-cronjobs" "04-platform" "oc get cronjobs -A | grep -Ei 'etcd|backup' || true"
  run_capture "etcd-encryption" "04-platform" "oc get apiserver cluster -o jsonpath='{.spec.encryption.type}{\"\\n\"}' 2>/dev/null || true"
  run_capture "resourcequotas" "04-platform" "oc get resourcequotas -A"
  run_capture "limitranges" "04-platform" "oc get limitranges -A"
  run_capture "pdb" "04-platform" "oc get poddisruptionbudgets -A"
  run_capture "hpa" "04-platform" "oc get hpa -A"
  run_capture "cluster-autoscaler" "04-platform" "oc get clusterautoscaler,autoscaler,machineautoscaler -A 2>/dev/null || true"
}

collect_monitoring_logging() {
  run_capture "monitoring-pods" "05-monitoring-logging" "oc -n openshift-monitoring get pods -o wide"
  run_capture "monitoring-configmaps" "05-monitoring-logging" "oc -n openshift-monitoring get configmap cluster-monitoring-config user-workload-monitoring-config -o yaml 2>/dev/null || true"
  run_capture "prometheus-k8s" "05-monitoring-logging" "oc -n openshift-monitoring get prometheus,alertmanager,thanosquerier -o yaml 2>/dev/null || true"
  run_capture "prometheus-rules" "05-monitoring-logging" "oc get prometheusrules -A"
  run_capture "service-monitors" "05-monitoring-logging" "oc get servicemonitors -A | head -n 300"
  run_capture "pod-monitors" "05-monitoring-logging" "oc get podmonitors -A | head -n 300"
  if [[ "$RUN_PROMETHEUS_ALERTS" == "true" ]]; then
    run_capture "alertmanager-alerts-json" "05-monitoring-logging" "oc get --raw /api/v1/namespaces/openshift-monitoring/services/alertmanager-main:web/proxy/api/v2/alerts || true"
    run_capture "prometheus-firing-alerts-json" "05-monitoring-logging" "oc get --raw '/api/v1/namespaces/openshift-monitoring/services/prometheus-k8s:web/proxy/api/v1/query?query=ALERTS%7Balertstate%3D%22firing%22%7D' || true"
  fi
  run_oc_if_api_exists "clusterloggings.logging.openshift.io" "clusterloggings" "05-monitoring-logging" "oc get clusterloggings.logging.openshift.io -A -o yaml"
  run_oc_if_api_exists "clusterlogforwarders.logging.openshift.io" "clusterlogforwarders" "05-monitoring-logging" "oc get clusterlogforwarders.logging.openshift.io -A -o yaml"
  run_oc_if_api_exists "lokistacks.loki.grafana.com" "lokistacks" "05-monitoring-logging" "oc get lokistacks.loki.grafana.com -A -o yaml"
}

collect_security() {
  run_capture "scc-list" "06-security" "oc get scc"
  run_capture "cluster-admin-bindings" "06-security" "oc get clusterrolebinding -o jsonpath='{range .items[?(@.roleRef.name==\"cluster-admin\")]}{.metadata.name}{\"\\t\"}{range .subjects[*]}{.kind}:{.name}{\",\"}{end}{\"\\n\"}{end}' || true"
  run_capture "rolebindings-sample" "06-security" "oc get rolebindings,clusterrolebindings -A | head -n 500"
  run_capture "secrets-type-count" "06-security" "oc get secrets -A -o jsonpath='{range .items[*]}{.type}{\"\\n\"}{end}' | sort | uniq -c | sort -nr"
  run_capture "serviceaccounts" "06-security" "oc get serviceaccounts -A | head -n 500"
  run_capture "certificatesigningrequests" "06-security" "oc get csr -o yaml"
  run_capture "compliance-operators" "06-security" "oc get csv -A | grep -Ei 'compliance|advanced cluster security|acs|security' || true"
  if [[ "$COLLECT_ACS" == "true" ]]; then
    run_oc_if_api_exists "centrals.platform.stackrox.io" "acs-centrals" "06-security" "oc get centrals.platform.stackrox.io -A -o yaml"
    run_oc_if_api_exists "securedclusters.platform.stackrox.io" "acs-securedclusters" "06-security" "oc get securedclusters.platform.stackrox.io -A -o yaml"
  fi
}

collect_app_dev() {
  [[ "$COLLECT_NAMESPACED_WORKLOADS" != "true" ]] && return
  run_capture "workloads-summary" "07-application-development" "oc get deployments,deploymentconfigs,statefulsets,daemonsets,replicasets,replicationcontrollers,jobs,cronjobs -A | head -n 1000"
  run_capture "buildconfigs" "07-application-development" "oc get buildconfigs -A 2>/dev/null || true"
  run_capture "imagestreams" "07-application-development" "oc get imagestreams -A 2>/dev/null || true"
  run_capture "routes-application" "07-application-development" "oc get routes -A | head -n 1000"
  run_capture "services" "07-application-development" "oc get services -A | head -n 1000"
  run_capture "probes-scan-json" "07-application-development" "oc get deploy,statefulset,daemonset -A -o json 2>/dev/null || true"
  if [[ "$COLLECT_GITOPS_PIPELINES" == "true" ]]; then
    run_oc_if_api_exists "applications.argoproj.io" "gitops-applications" "07-application-development" "oc get applications.argoproj.io -A -o yaml"
    run_oc_if_api_exists "pipelines.tekton.dev" "pipeline-definitions" "07-application-development" "oc get pipelines.tekton.dev -A -o yaml"
    run_oc_if_api_exists "pipelineruns.tekton.dev" "pipeline-runs" "07-application-development" "oc get pipelineruns.tekton.dev -A | tail -n 300"
  fi
}

collect_virtualization() {
  [[ "$COLLECT_OPENSHIFT_VIRTUALIZATION" != "true" ]] && return
  run_oc_if_api_exists "hyperconvergeds.hco.kubevirt.io" "virtualization-hyperconverged" "08-openshift-virtualization" "oc get hyperconvergeds.hco.kubevirt.io -A -o yaml"
  run_oc_if_api_exists "kubevirts.kubevirt.io" "virtualization-kubevirt" "08-openshift-virtualization" "oc get kubevirts.kubevirt.io -A -o yaml"
  run_oc_if_api_exists "virtualmachines.kubevirt.io" "virtualization-vms" "08-openshift-virtualization" "oc get virtualmachines.kubevirt.io -A -o wide"
  run_oc_if_api_exists "virtualmachineinstances.kubevirt.io" "virtualization-vmis" "08-openshift-virtualization" "oc get virtualmachineinstances.kubevirt.io -A -o wide"
  run_oc_if_api_exists "datavolumes.cdi.kubevirt.io" "virtualization-datavolumes" "08-openshift-virtualization" "oc get datavolumes.cdi.kubevirt.io -A -o wide"
  run_oc_if_api_exists "virtualmachineinstancemigrations.kubevirt.io" "virtualization-migrations" "08-openshift-virtualization" "oc get virtualmachineinstancemigrations.kubevirt.io -A -o wide"
  run_capture "network-attachment-definitions" "08-openshift-virtualization" "oc get network-attachment-definitions -A -o yaml 2>/dev/null || true"
}

collect_acm() {
  [[ "$COLLECT_ACM" != "true" ]] && return
  run_oc_if_api_exists "multiclusterhubs.operator.open-cluster-management.io" "acm-multiclusterhubs" "09-redhat-management" "oc get multiclusterhubs.operator.open-cluster-management.io -A -o yaml"
  run_oc_if_api_exists "managedclusters.cluster.open-cluster-management.io" "acm-managedclusters" "09-redhat-management" "oc get managedclusters.cluster.open-cluster-management.io -o yaml"
  run_oc_if_api_exists "policies.policy.open-cluster-management.io" "acm-policies" "09-redhat-management" "oc get policies.policy.open-cluster-management.io -A -o yaml"
}

collect_deep() {
  [[ "$DEEP" != "true" ]] && return
  run_capture "all-cluster-scoped-resources-list" "10-deep" "oc api-resources --namespaced=false --verbs=list -o name | sort"
  run_capture "all-namespaced-resources-list" "10-deep" "oc api-resources --namespaced=true --verbs=list -o name | sort"
  run_capture "operators-all" "10-deep" "oc get operators -A 2>/dev/null || true"
  run_capture "installed-operators-namespaces" "10-deep" "oc get ns | grep -E 'openshift|operator|redhat' || true"
  if [[ "$COLLECT_NODE_DEBUG" == "true" ]]; then
    log "Node debug collection is enabled. This may take time."
    # Intentionally not implemented by default to keep this collector low impact.
  fi
}

collect_must_gather() {
  [[ "$RUN_MUST_GATHER" != "true" ]] && return
  local mg_dir="${RUN_DIR}/must-gather"
  mkdir -p "$mg_dir"
  log "Running oc adm must-gather into ${mg_dir}"
  (cd "$mg_dir" && oc adm must-gather) >> "$RUN_LOG" 2>&1 || log "WARN: must-gather failed. Review ${RUN_LOG}."
}

###############################################################################
# Problem pod log collection and analysis
###############################################################################
extract_problem_pods() {
  local pods_json="${RAW_DIR}/01-core/pods-json.txt"
  local problem_tsv="${TMP_DIR}/problem-pods.tsv"
  : > "$problem_tsv"
  if [[ "$HAVE_JQ" == "true" && -s "$pods_json" ]]; then
    sed '/^#/d; /^$/d' "$pods_json" > "${TMP_DIR}/pods.json" || true
    cat > "${TMP_DIR}/problem-pods.jq" <<'JQ'
.items[] as $p |
  (($p.status.initContainerStatuses // []) + ($p.status.containerStatuses // [])) as $statuses |
  ($statuses | map(.restartCount // 0) | add // 0) as $restarts |
  ($statuses | map(.state.waiting.reason? // .state.terminated.reason? // empty) | join(",")) as $reasons |
  select(
    ($p.status.phase != "Running" and $p.status.phase != "Succeeded") or
    ($reasons | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|OOMKilled|Error|ContainerStatusUnknown")) or
    ($restarts >= $threshold)
  ) |
  [$p.metadata.namespace, $p.metadata.name, $p.status.phase, $reasons, ($restarts|tostring)] | @tsv
JQ
    jq -r --argjson threshold "${RESTART_THRESHOLD}" -f "${TMP_DIR}/problem-pods.jq" "${TMP_DIR}/pods.json" > "$problem_tsv" 2>/dev/null || true
  else
    oc get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed" {print $1"\t"$2"\t"$4"\tmanual-review\t"$5}' > "$problem_tsv" || true
  fi
  cp "$problem_tsv" "${RAW_DIR}/01-core/problem-pods.tsv"
}

collect_problem_pod_logs() {
  extract_problem_pods
  [[ "$COLLECT_PROBLEM_POD_LOGS" != "true" ]] && return
  local count=0 ns pod phase reasons restarts safe
  while IFS=$'\t' read -r ns pod phase reasons restarts; do
    [[ -z "$ns" || -z "$pod" ]] && continue
    count=$((count + 1))
    [[ "$count" -gt "$MAX_PROBLEM_PODS" ]] && break
    safe="$(safe_name "${ns}-${pod}")"
    log "Collecting logs for problem pod ${ns}/${pod}"
    oc -n "$ns" describe pod "$pod" > "${DESC_DIR}/${safe}.describe.txt" 2>&1 || true
    oc -n "$ns" logs "$pod" --all-containers --tail="${LOG_TAIL_LINES}" > "${LOG_DIR}/${safe}.logs.txt" 2>&1 || true
    oc -n "$ns" logs "$pod" --all-containers --previous --tail="${LOG_TAIL_LINES}" > "${LOG_DIR}/${safe}.previous.logs.txt" 2>&1 || true
  done < "${TMP_DIR}/problem-pods.tsv"
}

###############################################################################
# Automated findings
###############################################################################
analyze_core() {
  local co_unavailable co_degraded node_notready mcp_bad problem_pods warning_events api_false csr_pending
  co_unavailable=$(oc get co --no-headers 2>/dev/null | awk '$3 != "False" {print $1}' | wc -l | tr -d ' ')
  co_degraded=$(oc get co --no-headers 2>/dev/null | awk '$4 != "False" {print $1}' | wc -l | tr -d ' ')
  node_notready=$(oc get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/ || $2 ~ /NotReady/ {print $1}' | wc -l | tr -d ' ')
  mcp_bad=$(oc get mcp --no-headers 2>/dev/null | awk '$3 != "False" || $4 != "False" || $5 != "False" {print $1}' | wc -l | tr -d ' ')
  problem_pods=$(wc -l < "${TMP_DIR}/problem-pods.tsv" 2>/dev/null || echo 0)
  warning_events=$(grep -cv '^#' "${RAW_DIR}/01-core/events-warning.txt" 2>/dev/null || echo 0)
  api_false=$(oc get apiservices --no-headers 2>/dev/null | awk '$2 == "False" {print $1}' | wc -l | tr -d ' ')
  csr_pending=$(oc get csr --no-headers 2>/dev/null | awk '$6 == "Pending" {print $1}' | wc -l | tr -d ' ')

  if [[ "$co_unavailable" -gt 0 || "$co_degraded" -gt 0 ]]; then
    record_result "Platform" "Cluster Health" "Cluster Operators" \
      "Detected ${co_unavailable} unavailable and ${co_degraded} degraded ClusterOperators." \
      "changes_required" "raw/01-core/clusteroperators.txt" \
      "Unavailable or degraded ClusterOperators can indicate platform control plane or operand issues." \
      "Review each affected ClusterOperator condition, related pods, and events; remediate root causes before upgrades or production changes." \
      "Automated CLI evaluation."
  else
    record_result "Platform" "Cluster Health" "Cluster Operators" \
      "All ClusterOperators report Available=True and Degraded=False." \
      "no_change" "raw/01-core/clusteroperators.txt" \
      "No immediate ClusterOperator health risk was identified." \
      "Continue normal monitoring and lifecycle governance." \
      "Automated CLI evaluation."
  fi

  if [[ "$node_notready" -gt 0 ]]; then
    record_result "Infrastructure" "Compute" "OpenShift Node Readiness" \
      "Detected ${node_notready} node(s) that are not Ready." \
      "changes_required" "raw/01-core/nodes-wide.txt" \
      "NotReady nodes reduce scheduling capacity and may affect workload availability." \
      "Review node conditions, kubelet status, network reachability, and MachineConfigPool state." \
      "Automated CLI evaluation."
  else
    record_result "Infrastructure" "Compute" "OpenShift Node Readiness" \
      "All nodes are reporting Ready." \
      "no_change" "raw/01-core/nodes-wide.txt" \
      "No immediate node readiness risk was identified." \
      "Continue monitoring node pressure, capacity, and lifecycle state." \
      "Automated CLI evaluation."
  fi

  if [[ "$mcp_bad" -gt 0 ]]; then
    record_result "Platform" "Machine Configs" "MachineConfigPools" \
      "Detected ${mcp_bad} MachineConfigPool(s) updating, degraded, or unhealthy." \
      "changes_required" "raw/01-core/machineconfigpools.txt" \
      "MachineConfigPool drift or degraded state can block node updates and affect cluster lifecycle operations." \
      "Review rendered MachineConfigs, node annotations, paused pools, and degraded reasons before proceeding with platform updates." \
      "Automated CLI evaluation."
  else
    record_result "Platform" "Machine Configs" "MachineConfigPools" \
      "MachineConfigPools do not show degraded or updating state." \
      "no_change" "raw/01-core/machineconfigpools.txt" \
      "No immediate MachineConfigPool lifecycle risk was identified." \
      "Continue standard change control for MachineConfig and KubeletConfig objects." \
      "Automated CLI evaluation."
  fi

  if [[ "$problem_pods" -gt 0 ]]; then
    record_result "Platform" "Workloads" "Problem Pods" \
      "Detected ${problem_pods} pod(s) requiring review due to phase, waiting reason, termination reason, or restart count." \
      "changes_required" "raw/01-core/problem-pods.tsv" \
      "Problem pods can indicate application, operator, image, scheduling, quota, or node-level issues." \
      "Review generated pod descriptions and logs; prioritize system namespaces and pods with repeated restarts or image pull failures." \
      "Automated CLI evaluation."
  else
    record_result "Platform" "Workloads" "Problem Pods" \
      "No problem pods were detected by the automated criteria." \
      "no_change" "raw/01-core/problem-pods.tsv" \
      "No immediate pod health risk was identified by this automated scan." \
      "Continue reviewing application-specific SLOs and alerts." \
      "Automated CLI evaluation."
  fi

  if [[ "$warning_events" -gt 10 ]]; then
    record_result "Platform" "Events" "Warning Events" \
      "Collected ${warning_events} warning event lines for review." \
      "changes_recommended" "raw/01-core/events-warning.txt" \
      "Repeated warning events can reveal systemic issues not visible in high-level status." \
      "Group warning events by reason and involved object; address recurring node, scheduling, image, storage, or certificate issues." \
      "Automated CLI evidence collection."
  else
    record_result "Platform" "Events" "Warning Events" \
      "Warning events are low or absent in the collected sample." \
      "no_change" "raw/01-core/events-warning.txt" \
      "No immediate event-driven risk was identified." \
      "Continue periodic event review." \
      "Automated CLI evidence collection."
  fi

  if [[ "$api_false" -gt 0 ]]; then
    record_result "Platform" "API Availability" "API Services" \
      "Detected ${api_false} APIService object(s) with Available=False." \
      "changes_required" "raw/01-core/apiservices.txt" \
      "Unavailable aggregated APIs can break operators, admission flows, or application integrations." \
      "Review the affected APIService backing service, endpoints, certificates, and operator ownership." \
      "Automated CLI evaluation."
  else
    record_result "Platform" "API Availability" "API Services" \
      "No APIService object reports Available=False." \
      "no_change" "raw/01-core/apiservices.txt" \
      "No aggregated API availability issue was identified." \
      "Continue normal platform API monitoring." \
      "Automated CLI evaluation."
  fi

  if [[ "$csr_pending" -gt 0 ]]; then
    record_result "Security" "Certificates" "Pending Certificate Signing Requests" \
      "Detected ${csr_pending} pending CSR(s)." \
      "changes_recommended" "raw/01-core/csr.txt" \
      "Pending CSRs can prevent node or component certificate rotation from completing." \
      "Review pending CSRs and approve only those that match expected node or component identities." \
      "Automated CLI evaluation."
  else
    record_result "Security" "Certificates" "Pending Certificate Signing Requests" \
      "No pending CSRs were detected." \
      "no_change" "raw/01-core/csr.txt" \
      "No immediate CSR backlog risk was identified." \
      "Continue certificate rotation monitoring." \
      "Automated CLI evaluation."
  fi
}

analyze_platform() {
  local automatic_subs kubeadmin image_registry_storage_empty uwm_enabled etcd_encryption quotas_count pdb_count hpa_count ingress_replicas default_catalogs
  automatic_subs=0
  if [[ "$HAVE_JQ" == "true" ]]; then
    sed '/^#/d; /^$/d' "${RAW_DIR}/04-platform/olm-subscriptions.txt" > "${TMP_DIR}/subs.yaml" 2>/dev/null || true
    automatic_subs=$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null | jq '[.items[] | select(.spec.installPlanApproval == "Automatic")] | length' 2>/dev/null || echo 0)
  fi
  kubeadmin=$(grep -c 'secret/kubeadmin' "${RAW_DIR}/04-platform/kubeadmin-secret-presence.txt" 2>/dev/null || echo 0)
  image_registry_storage_empty=$(grep -Ec 'emptyDir|managementState: Removed|storage: \{\}' "${RAW_DIR}/04-platform/image-registry-config.txt" 2>/dev/null || echo 0)
  uwm_enabled=$(grep -Ec 'enableUserWorkload|user-workload-monitoring-config' "${RAW_DIR}/05-monitoring-logging/monitoring-configmaps.txt" 2>/dev/null || echo 0)
  etcd_encryption=$(grep -Evc '^$|identity|^#' "${RAW_DIR}/04-platform/etcd-encryption.txt" 2>/dev/null || echo 0)
  quotas_count=$(oc get resourcequotas -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pdb_count=$(oc get pdb -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  hpa_count=$(oc get hpa -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ingress_replicas=$(oc -n openshift-ingress-operator get ingresscontroller default -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  [[ -z "$ingress_replicas" ]] && ingress_replicas="unknown"
  default_catalogs=$(oc get catalogsources.operators.coreos.com -n openshift-marketplace --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$automatic_subs" -gt 0 ]]; then
    record_result "Platform" "Lifecycle Management" "Operator Upgrade Approval" \
      "Detected ${automatic_subs} operator subscription(s) using automatic approval." \
      "changes_recommended" "raw/04-platform/olm-subscriptions.txt" \
      "Automatic operator upgrades can introduce unplanned version changes if not governed by release management." \
      "Review subscriptions and use manual approval where strict change control is required." \
      "Automated OLM evaluation."
  else
    record_result "Platform" "Lifecycle Management" "Operator Upgrade Approval" \
      "No automatic operator subscriptions were detected, or the check could not evaluate subscription approval mode." \
      "no_change" "raw/04-platform/olm-subscriptions.txt" \
      "No automatic operator upgrade risk was identified by this check." \
      "Continue governing operator lifecycle through release management." \
      "Automated OLM evaluation."
  fi

  if [[ "$kubeadmin" -gt 0 ]]; then
    record_result "Security" "Administration" "kubeadmin User" \
      "The kubeadmin secret exists." \
      "changes_recommended" "raw/04-platform/kubeadmin-secret-presence.txt" \
      "Leaving the initial administrative credential enabled can increase administrative access risk." \
      "Confirm identity provider readiness and remove the kubeadmin credential according to the approved operational process." \
      "Automated security posture check."
  else
    record_result "Security" "Administration" "kubeadmin User" \
      "The kubeadmin secret was not found." \
      "no_change" "raw/04-platform/kubeadmin-secret-presence.txt" \
      "No kubeadmin credential exposure was detected." \
      "Continue using governed identity provider and RBAC workflows." \
      "Automated security posture check."
  fi

  if [[ "$image_registry_storage_empty" -gt 0 ]]; then
    record_result "Platform" "Container Image Management" "OpenShift Internal Registry Storage" \
      "The internal image registry appears to be removed or configured without persistent storage." \
      "changes_recommended" "raw/04-platform/image-registry-config.txt" \
      "A registry without persistent storage can lose image data on pod restart if it is used for builds or application promotion." \
      "Configure supported persistent storage for the internal registry when the registry is required by workloads or build processes." \
      "Automated registry configuration check."
  else
    record_result "Platform" "Container Image Management" "OpenShift Internal Registry Storage" \
      "The internal image registry configuration did not show an obvious empty storage pattern." \
      "no_change" "raw/04-platform/image-registry-config.txt" \
      "No immediate registry storage risk was detected by this pattern check." \
      "Validate registry usage and retention policy with the platform team." \
      "Automated registry configuration check."
  fi

  if [[ "$uwm_enabled" -gt 0 ]]; then
    record_result "Platform" "Monitoring & Logging" "User Workload Monitoring" \
      "User workload monitoring configuration artifacts were found." \
      "no_change" "raw/05-monitoring-logging/monitoring-configmaps.txt" \
      "Application teams can use the platform monitoring stack when RBAC and project configuration are aligned." \
      "Continue validating application metrics, rules, and tenant access." \
      "Automated monitoring configuration check."
  else
    record_result "Platform" "Monitoring & Logging" "User Workload Monitoring" \
      "User workload monitoring was not confirmed by this collector." \
      "changes_recommended" "raw/05-monitoring-logging/monitoring-configmaps.txt" \
      "Without user workload monitoring, application teams may lack integrated observability." \
      "Enable and govern user workload monitoring if application metrics are required on the cluster." \
      "Automated monitoring configuration check."
  fi

  if [[ "$etcd_encryption" -gt 0 ]]; then
    record_result "Security" "Data Protection" "etcd Encryption" \
      "An encryption type appears to be configured for the API server." \
      "no_change" "raw/04-platform/etcd-encryption.txt" \
      "No immediate etcd encryption gap was identified by this check." \
      "Continue validating encryption status during security reviews." \
      "Automated platform security check."
  else
    record_result "Security" "Data Protection" "etcd Encryption" \
      "etcd encryption was not confirmed by this collector." \
      "changes_recommended" "raw/04-platform/etcd-encryption.txt" \
      "Unencrypted API data at rest can be a security gap depending on policy requirements." \
      "Review data-at-rest requirements and enable etcd encryption when required." \
      "Automated platform security check."
  fi

  if [[ "$quotas_count" -eq 0 ]]; then
    record_result "Platform" "Quotas & Limits" "ResourceQuotas Defined" \
      "No ResourceQuota objects were detected." \
      "changes_recommended" "raw/04-platform/resourcequotas.txt" \
      "Lack of quotas can allow a namespace to consume excessive shared capacity." \
      "Define ResourceQuota and LimitRange standards for tenant namespaces where appropriate." \
      "Automated tenancy governance check."
  else
    record_result "Platform" "Quotas & Limits" "ResourceQuotas Defined" \
      "Detected ${quotas_count} ResourceQuota object(s)." \
      "no_change" "raw/04-platform/resourcequotas.txt" \
      "Resource governance controls are present; adequacy still requires policy review." \
      "Validate quota standards against workload profiles." \
      "Automated tenancy governance check."
  fi

  if [[ "$pdb_count" -eq 0 ]]; then
    record_result "Application Development" "Availability" "Pod Disruption Budget Usage" \
      "No PodDisruptionBudget objects were detected." \
      "changes_recommended" "raw/04-platform/pdb.txt" \
      "Workloads without disruption budgets can be more exposed during voluntary disruptions." \
      "Define PDB standards for highly available applications and platform-managed workloads." \
      "Automated workload availability check."
  else
    record_result "Application Development" "Availability" "Pod Disruption Budget Usage" \
      "Detected ${pdb_count} PodDisruptionBudget object(s)." \
      "advisory" "raw/04-platform/pdb.txt" \
      "PDBs are present; coverage needs to be assessed against critical workloads." \
      "Review PDB coverage for business-critical namespaces." \
      "Automated workload availability check."
  fi

  if [[ "$hpa_count" -eq 0 ]]; then
    record_result "Application Development" "Scaling" "Horizontal Pod Autoscaler Usage" \
      "No HorizontalPodAutoscaler objects were detected." \
      "advisory" "raw/04-platform/hpa.txt" \
      "This may be acceptable, but it suggests applications might not be using automated horizontal scaling." \
      "Review autoscaling requirements for variable-load applications." \
      "Automated workload scaling check."
  else
    record_result "Application Development" "Scaling" "Horizontal Pod Autoscaler Usage" \
      "Detected ${hpa_count} HorizontalPodAutoscaler object(s)." \
      "no_change" "raw/04-platform/hpa.txt" \
      "Autoscaling objects are present; effectiveness depends on metrics and thresholds." \
      "Validate autoscaling behavior through load testing and SLO review." \
      "Automated workload scaling check."
  fi

  if [[ "$ingress_replicas" != "unknown" && "$ingress_replicas" -lt 2 ]]; then
    record_result "Infrastructure" "Network" "Ingress Controller Replica Count" \
      "Default ingress controller replica count is ${ingress_replicas}." \
      "changes_required" "raw/02-infrastructure/ingresscontrollers.txt" \
      "Low ingress replica count can reduce route availability during node or pod disruption." \
      "Increase ingress replicas and validate placement, disruption budgets, and capacity." \
      "Automated ingress availability check."
  else
    record_result "Infrastructure" "Network" "Ingress Controller Replica Count" \
      "Default ingress controller replica count is ${ingress_replicas}." \
      "no_change" "raw/02-infrastructure/ingresscontrollers.txt" \
      "No immediate ingress replica risk was identified by this check." \
      "Continue validating ingress capacity and placement." \
      "Automated ingress availability check."
  fi

  if [[ "$default_catalogs" -gt 0 ]]; then
    record_result "Platform" "Container Image Management" "OperatorHub Catalog Sources" \
      "Detected ${default_catalogs} catalog source(s) in the marketplace namespace." \
      "advisory" "raw/04-platform/olm-catalogsources.txt" \
      "Broad catalog availability can be acceptable, but regulated environments often require curated operator catalogs." \
      "Review whether catalog sources should be curated and governed according to platform standards." \
      "Automated OLM catalog evidence collection."
  fi
}

analyze_alerts() {
  local critical_alerts warning_alerts total_alerts
  critical_alerts=0
  warning_alerts=0
  total_alerts=0
  if [[ "$HAVE_JQ" == "true" && -s "${RAW_DIR}/05-monitoring-logging/alertmanager-alerts-json.txt" ]]; then
    sed '/^#/d; /^$/d' "${RAW_DIR}/05-monitoring-logging/alertmanager-alerts-json.txt" > "${TMP_DIR}/alerts.json" || true
    total_alerts=$(jq '[.[]?] | length' "${TMP_DIR}/alerts.json" 2>/dev/null || echo 0)
    critical_alerts=$(jq '[.[]? | select((.labels.severity // "") | test("critical|error"; "i"))] | length' "${TMP_DIR}/alerts.json" 2>/dev/null || echo 0)
    warning_alerts=$(jq '[.[]? | select((.labels.severity // "") | test("warning|warn"; "i"))] | length' "${TMP_DIR}/alerts.json" 2>/dev/null || echo 0)
    jq -r '.[]? | [.labels.alertname, (.labels.severity // "unknown"), (.labels.namespace // ""), (.annotations.summary // .annotations.message // "")] | @tsv' "${TMP_DIR}/alerts.json" > "${CER_DIR}/alerts-summary.tsv" 2>/dev/null || true
  fi

  if [[ "$critical_alerts" -gt 0 ]]; then
    record_result "Platform" "Monitoring & Logging" "Active OpenShift Alerts" \
      "Detected ${critical_alerts} critical/error alert(s), ${warning_alerts} warning alert(s), and ${total_alerts} total alert(s)." \
      "changes_required" "raw/05-monitoring-logging/alertmanager-alerts-json.txt" \
      "Critical alerts can indicate active risk to platform reliability, capacity, or availability." \
      "Review active alerts, confirm ownership, and remediate or explicitly silence only after validation." \
      "Automated Alertmanager API evaluation."
  elif [[ "$warning_alerts" -gt 0 || "$total_alerts" -gt 0 ]]; then
    record_result "Platform" "Monitoring & Logging" "Active OpenShift Alerts" \
      "Detected ${warning_alerts} warning alert(s) and ${total_alerts} total alert(s)." \
      "changes_recommended" "raw/05-monitoring-logging/alertmanager-alerts-json.txt" \
      "Warning alerts may indicate trends that require operational follow-up." \
      "Review active alerts and ensure they are routed, owned, and documented." \
      "Automated Alertmanager API evaluation."
  else
    record_result "Platform" "Monitoring & Logging" "Active OpenShift Alerts" \
      "No active alerts were parsed from Alertmanager, or the alert endpoint was unavailable to this user." \
      "advisory" "raw/05-monitoring-logging/alertmanager-alerts-json.txt" \
      "Absence of parsed alerts must be validated against console access and monitoring permissions." \
      "Confirm Alertmanager access and external alert notification routing through the operational process." \
      "Automated Alertmanager API evaluation."
  fi
}

analyze_storage_virtualization() {
  local odf_present vms_count failed_pvcs pending_pvcs va_count
  odf_present=$(grep -Eci 'storagecluster|data foundation|ocs|odf' "${RAW_DIR}/03-storage/storage-operators.txt" 2>/dev/null || echo 0)
  pending_pvcs=$(oc get pvc -A --no-headers 2>/dev/null | awk '$3 == "Pending" {print $1"/"$2}' | wc -l | tr -d ' ')
  failed_pvcs=$(oc get pvc -A --no-headers 2>/dev/null | awk '$3 == "Lost" {print $1"/"$2}' | wc -l | tr -d ' ')
  va_count=$(oc get volumeattachments --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$pending_pvcs" -gt 0 || "$failed_pvcs" -gt 0 ]]; then
    record_result "Infrastructure" "Storage" "Persistent Volume Claims" \
      "Detected ${pending_pvcs} pending and ${failed_pvcs} lost PVC(s)." \
      "changes_required" "raw/03-storage/persistentvolumeclaims.txt" \
      "Unbound or lost claims can block application scheduling and data availability." \
      "Review storage class, provisioner health, events, quotas, and affected namespaces." \
      "Automated storage status check."
  else
    record_result "Infrastructure" "Storage" "Persistent Volume Claims" \
      "No pending or lost PVCs were detected." \
      "no_change" "raw/03-storage/persistentvolumeclaims.txt" \
      "No immediate PVC binding risk was identified." \
      "Continue monitoring capacity, reclaim policies, and expansion workflows." \
      "Automated storage status check."
  fi

  if [[ "$odf_present" -gt 0 ]]; then
    record_result "Infrastructure" "Storage" "Red Hat OpenShift Data Foundation Component Check" \
      "Red Hat OpenShift Data Foundation-related resources appear to be present." \
      "advisory" "raw/03-storage/storage-operators.txt" \
      "Storage health requires component-specific validation beyond generic Kubernetes PVC status." \
      "Review Red Hat OpenShift Data Foundation health, capacity, recovery policies, and operator lifecycle settings." \
      "Automated storage operator discovery."
  else
    record_result "Infrastructure" "Storage" "Red Hat OpenShift Data Foundation Component Check" \
      "Red Hat OpenShift Data Foundation-related resources were not detected by this collector." \
      "not_applicable" "raw/03-storage/storage-operators.txt" \
      "This check is not applicable if Red Hat OpenShift Data Foundation is not used." \
      "Validate the actual storage provider and document its operational model." \
      "Automated storage operator discovery."
  fi

  if oc api-resources --verbs=list -o name 2>/dev/null | grep -qx "virtualmachines.kubevirt.io"; then
    vms_count=$(oc get virtualmachines.kubevirt.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    record_result "OpenShift Virtualization" "Adoption" "Determine if OpenShift Virtualization is in use" \
      "Detected ${vms_count} virtual machine object(s)." \
      "advisory" "raw/08-openshift-virtualization/virtualization-vms.txt" \
      "Virtualized workloads require validation of storage, networking, migration, backup, and resource governance." \
      "Review OpenShift Virtualization architecture, VM placement, data protection, and monitoring." \
      "Automated OpenShift Virtualization discovery."
  else
    record_result "OpenShift Virtualization" "Adoption" "Determine if OpenShift Virtualization is in use" \
      "OpenShift Virtualization API resources were not detected." \
      "not_applicable" "raw/08-openshift-virtualization/virtualization-vms.txt" \
      "This category is not applicable when OpenShift Virtualization is not installed." \
      "No action required unless OpenShift Virtualization is planned." \
      "Automated OpenShift Virtualization discovery."
  fi
}

add_manual_review_items() {
  record_result "Infrastructure" "Backup & Recovery" "External Backup and Restore Tests" \
    "Requires interview confirmation and evidence from restore-test records." \
    "tbe" "survey-open-items.md" \
    "Backup without periodic restore validation can create false confidence in recoverability." \
    "Document backup scope, frequency, retention, encryption, and restore-test cadence." \
    "Manual review item generated to complete CER coverage."

  record_result "Infrastructure" "Network" "Load Balancer and DNS Operational Model" \
    "Requires architecture review and interview confirmation." \
    "tbe" "survey-open-items.md" \
    "External network dependencies can become single points of failure if health checks and ownership are unclear." \
    "Document VIPs, health checks, failover model, ownership, and change process." \
    "Manual review item generated to complete CER coverage."

  record_result "Application Development" "CI/CD" "CI/CD Tooling and Deployment Process" \
    "Requires application team interview and repository/process review." \
    "tbe" "survey-open-items.md" \
    "Unclear delivery process can affect repeatability, auditability, and recovery." \
    "Document build, test, promotion, deployment, rollback, and approval workflows." \
    "Manual review item generated to complete CER coverage."

  record_result "Application Development" "Application Readiness" "Readiness and Liveness Probes" \
    "Requires workload manifest review and application owner validation." \
    "tbe" "survey-open-items.md" \
    "Missing probes can affect traffic routing, self-healing, and rollout quality." \
    "Establish standards for readiness, liveness, startup probes, and pipeline validation." \
    "Manual review item generated to complete CER coverage."

  record_result "Security" "Identity and Access" "Identity Provider and RBAC Governance" \
    "Requires interview confirmation and RBAC review." \
    "tbe" "survey-open-items.md" \
    "Weak identity or RBAC governance can increase privilege and audit risk." \
    "Document identity providers, group mapping, administrative roles, break-glass access, and review cadence." \
    "Manual review item generated to complete CER coverage."

  record_result "Organizational Readiness" "Operating Model" "Platform Team Skills and Responsibilities" \
    "Requires stakeholder interviews." \
    "tbe" "survey-open-items.md" \
    "Undefined ownership and skills gaps can slow incident response and platform adoption." \
    "Document RACI, escalation path, training plan, operating model, and success measures." \
    "Manual review item generated to complete CER coverage."
}

###############################################################################
# Output generation
###############################################################################
recommendation_label() {
  case "$1" in
    changes_required) echo "Changes Required" ;;
    changes_recommended) echo "Changes Recommended" ;;
    no_change) echo "No Change" ;;
    not_applicable) echo "N/A" ;;
    advisory) echo "Advisory" ;;
    tbe) echo "To Be Evaluated" ;;
    *) echo "$1" ;;
  esac
}

recommendation_class() {
  case "$1" in
    changes_required) echo "critical" ;;
    changes_recommended) echo "warning" ;;
    no_change) echo "ok" ;;
    not_applicable) echo "na" ;;
    advisory) echo "advisory" ;;
    tbe) echo "tbe" ;;
    *) echo "tbe" ;;
  esac
}

generate_survey() {
  cat > "${CER_DIR}/survey-open-items.md" <<'SURVEY'
# OpenShift Health Check - Manual Review and Interview Items

Use this file to complete checks that cannot be fully validated with CLI evidence.

## Infrastructure
- Describe backup scope, frequency, retention, encryption, and restore-test cadence.
- Describe disaster recovery objectives, last failover or restore exercise, and known constraints.
- Describe DNS, ingress, API endpoint, and load balancer ownership and health-check process.
- Confirm network segmentation, egress controls, firewall change process, and exception handling.
- Confirm storage provider ownership, support process, performance baseline, and capacity planning.

## Platform
- Describe OpenShift update process, operator lifecycle process, and release approval model.
- Confirm alert routing, on-call process, incident severity model, and post-incident review process.
- Confirm log forwarding requirements, retention, tenant access, and audit log handling.
- Confirm image source governance, internal registry usage, and image promotion process.
- Confirm namespace onboarding process, quotas, limits, labels, templates, and default policies.

## Application Development
- Describe CI/CD standards, deployment methods, rollback process, and environment promotion.
- Confirm probe standards, resource request standards, application metrics, and autoscaling criteria.
- Confirm application onboarding, route TLS ownership, and application log ownership.

## OpenShift Virtualization
- Confirm whether OpenShift Virtualization is in scope.
- Describe VM backup, live migration, VM networking, VM storage, VM monitoring, and performance tuning standards.

## Security
- Confirm identity provider configuration, group mapping, administrative access review, and break-glass process.
- Confirm security scanning, policy enforcement, secret management, and audit review cadence.

## Organizational Readiness
- Confirm platform RACI, service ownership, stakeholder sponsorship, roadmap, training plan, and success metrics.
SURVEY
}

generate_csv() {
  local csv="${CER_DIR}/findings.csv"
  echo 'Category,Subcategory,Item Evaluated,Observed Result,Recommendation,Evidence,Impact/Risk,Remediation,Comments' > "$csv"
  tail -n +2 "$RESULTS_TSV" | while IFS=$'\t' read -r category subcategory item observed recommendation evidence impact remediation comments; do
    {
      csv_escape "$category"; echo -n ','
      csv_escape "$subcategory"; echo -n ','
      csv_escape "$item"; echo -n ','
      csv_escape "$observed"; echo -n ','
      csv_escape "$(recommendation_label "$recommendation")"; echo -n ','
      csv_escape "$evidence"; echo -n ','
      csv_escape "$impact"; echo -n ','
      csv_escape "$remediation"; echo -n ','
      csv_escape "$comments"; echo
    } >> "$csv"
  done
}

generate_markdown() {
  local md="${RUN_DIR}/healthcheck-report.md"
  cat > "$md" <<MD
# ${ENGAGEMENT_NAME}

Generated: ${RUN_TS}  
Cluster hint: ${CLUSTER_NAME_HINT}  
OpenShift version: ${OCP_VERSION}  
Overall automated status: ${GLOBAL_STATUS}

## Executive Summary

This report contains automated evidence collected from a Red Hat OpenShift 4.18+ cluster and preliminary findings for CER completion. Items marked as **To Be Evaluated** require interview confirmation, architectural review, or manual evidence review before final delivery.

## Output Structure

- \\`raw/\\`: command evidence
- \\`logs/problem-pods/\\`: logs collected from problem pods
- \\`describes/problem-pods/\\`: pod descriptions for problem pods
- \\`cer/findings.csv\\`: CER-ready findings table
- \\`cer/healthcheck-items/*.item\\`: generated item files for CER-style workflows
- \\`cer/survey-open-items.md\\`: manual review questions

## Findings

| Category | Subcategory | Item Evaluated | Observed Result | Recommendation | Evidence |
|---|---|---|---|---|---|
MD
  tail -n +2 "$RESULTS_TSV" | while IFS=$'\t' read -r category subcategory item observed recommendation evidence impact remediation comments; do
    printf '| %s | %s | %s | %s | %s | %s |\n' \
      "$(printf '%s' "$category" | sed 's/|/\\|/g')" \
      "$(printf '%s' "$subcategory" | sed 's/|/\\|/g')" \
      "$(printf '%s' "$item" | sed 's/|/\\|/g')" \
      "$(printf '%s' "$observed" | sed 's/|/\\|/g')" \
      "$(recommendation_label "$recommendation")" \
      "${evidence}" >> "$md"
  done
}

generate_html() {
  local html="${RUN_DIR}/healthcheck-report.html"
  local counts_file="${TMP_DIR}/recommendation-counts.tsv"
  tail -n +2 "$RESULTS_TSV" | awk -F'\t' '{count[$5]++} END {for (r in count) print r"\t"count[r]}' > "$counts_file"
  cat > "$html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OpenShift Health Check Report</title>
<style>
body { font-family: Arial, sans-serif; margin: 32px; color: #222; }
h1, h2 { color: #151515; }
.badge { display:inline-block; padding: 6px 10px; border-radius: 4px; font-weight: bold; }
.HEALTHY { background:#d7f5dd; color:#0f5132; }
.WARNING { background:#fff3cd; color:#664d03; }
.CRITICAL { background:#f8d7da; color:#842029; }
table { border-collapse: collapse; width: 100%; margin: 16px 0; font-size: 13px; }
th, td { border: 1px solid #ddd; padding: 8px; vertical-align: top; }
th { background: #f2f2f2; text-align: left; }
.critical { background: #f8d7da; }
.warning { background: #fff3cd; }
.ok { background: #d7f5dd; }
.advisory { background: #dbeafe; }
.na { background: #e5e7eb; }
.tbe { background: #f3e8ff; }
.small { font-size: 12px; color: #555; }
code { background:#f6f6f6; padding:2px 4px; }
</style>
</head>
<body>
<h1>OpenShift Health Check Report</h1>
<p><span class="badge ${GLOBAL_STATUS}">${GLOBAL_STATUS}</span></p>
<table>
<tr><th>Field</th><th>Value</th></tr>
<tr><td>Engagement</td><td>$(printf '%s' "$ENGAGEMENT_NAME" | html_escape)</td></tr>
<tr><td>Cluster hint</td><td>$(printf '%s' "$CLUSTER_NAME_HINT" | html_escape)</td></tr>
<tr><td>Generated</td><td>${RUN_TS}</td></tr>
<tr><td>OpenShift version</td><td>$(printf '%s' "$OCP_VERSION" | html_escape)</td></tr>
<tr><td>Console URL</td><td>$(printf '%s' "$CONSOLE_URL" | html_escape)</td></tr>
<tr><td>Cluster ID</td><td>$(printf '%s' "$CLUSTER_ID" | html_escape)</td></tr>
<tr><td>Infrastructure name</td><td>$(printf '%s' "$INFRA_NAME" | html_escape)</td></tr>
</table>

<h2>Recommendation Summary</h2>
<table><tr><th>Recommendation</th><th>Count</th></tr>
HTML
  while IFS=$'\t' read -r rec count; do
    [[ -z "$rec" ]] && continue
    printf '<tr class="%s"><td>%s</td><td>%s</td></tr>\n' "$(recommendation_class "$rec")" "$(recommendation_label "$rec" | html_escape)" "$count" >> "$html"
  done < "$counts_file"
  cat >> "$html" <<HTML
</table>

<h2>Findings</h2>
<table>
<tr><th>Category</th><th>Subcategory</th><th>Item Evaluated</th><th>Observed Result</th><th>Recommendation</th><th>Evidence</th><th>Remediation</th></tr>
HTML
  tail -n +2 "$RESULTS_TSV" | while IFS=$'\t' read -r category subcategory item observed recommendation evidence impact remediation comments; do
    printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><strong>%s</strong></td><td><code>%s</code></td><td>%s</td></tr>\n' \
      "$(recommendation_class "$recommendation")" \
      "$(printf '%s' "$category" | html_escape)" \
      "$(printf '%s' "$subcategory" | html_escape)" \
      "$(printf '%s' "$item" | html_escape)" \
      "$(printf '%s' "$observed" | html_escape)" \
      "$(recommendation_label "$recommendation" | html_escape)" \
      "$(printf '%s' "$evidence" | html_escape)" \
      "$(printf '%s' "$remediation" | html_escape)" >> "$html"
  done
  cat >> "$html" <<HTML
</table>

<h2>Evidence Index</h2>
<p class="small">See <code>command-index.tsv</code> for the complete command-to-file mapping.</p>

<h2>Notes</h2>
<p class="small">This report is generated from read-only OpenShift CLI evidence. Validate all recommendations before customer delivery. Items marked To Be Evaluated require manual input.</p>
</body>
</html>
HTML
}

generate_items() {
  local idx=1000
  tail -n +2 "$RESULTS_TSV" | while IFS=$'\t' read -r category subcategory item observed recommendation evidence impact remediation comments; do
    write_item_file "$idx" "$category" "$subcategory" "$item" "$observed" "$recommendation" "$evidence" "$impact" "$remediation" "$comments"
    idx=$((idx + 10))
  done
}

generate_summary() {
  cat > "$SUMMARY_TXT" <<SUMMARY
OpenShift Health Check CER Collector Summary
===========================================
Run directory: ${RUN_DIR}
Cluster hint: ${CLUSTER_NAME_HINT}
OpenShift version: ${OCP_VERSION}
Overall status: ${GLOBAL_STATUS}
Critical findings: ${CRIT_COUNT}
Warning/advisory findings: ${WARN_COUNT}
Informational findings: ${INFO_COUNT}

Primary outputs:
- ${RUN_DIR}/healthcheck-report.html
- ${RUN_DIR}/healthcheck-report.md
- ${CER_DIR}/findings.csv
- ${CER_DIR}/healthcheck-items/
- ${CER_DIR}/survey-open-items.md
- ${COMMAND_INDEX}

Raw evidence and logs:
- ${RAW_DIR}
- ${LOG_DIR}
- ${DESC_DIR}
SUMMARY
}

copy_to_cer_repo() {
  [[ "$WRITE_CER_ITEMS_TO_REPO" != "true" ]] && return
  if [[ -z "$CER_REPO_ROOT" || ! -d "$CER_REPO_ROOT/content/healthcheck-items" ]]; then
    log "WARN: CER_REPO_ROOT is not valid or content/healthcheck-items does not exist. Skipping copy."
    return
  fi
  log "Copying generated item files into CER repo: ${CER_REPO_ROOT}/content/healthcheck-items"
  cp "${ITEM_DIR}"/*.item "${CER_REPO_ROOT}/content/healthcheck-items/" || log "WARN: failed to copy generated item files."
}

create_packages() {
  [[ "$CREATE_PACKAGES" != "true" ]] && return
  local base parent name
  parent="$(dirname "$RUN_DIR")"
  name="$(basename "$RUN_DIR")"
  (cd "$parent" && tar -czf "${name}-full-evidence.tar.gz" "$name") || true
  mkdir -p "${RUN_DIR}/delivery-package"
  cp "${RUN_DIR}/healthcheck-report.html" "${RUN_DIR}/delivery-package/" 2>/dev/null || true
  cp "${RUN_DIR}/healthcheck-report.md" "${RUN_DIR}/delivery-package/" 2>/dev/null || true
  cp "${SUMMARY_TXT}" "${RUN_DIR}/delivery-package/" 2>/dev/null || true
  cp "${CER_DIR}/findings.csv" "${RUN_DIR}/delivery-package/" 2>/dev/null || true
  cp "${CER_DIR}/survey-open-items.md" "${RUN_DIR}/delivery-package/" 2>/dev/null || true
  mkdir -p "${RUN_DIR}/delivery-package/healthcheck-items"
  cp "${ITEM_DIR}"/*.item "${RUN_DIR}/delivery-package/healthcheck-items/" 2>/dev/null || true
  (cd "${RUN_DIR}" && tar -czf "../${name}-delivery-report.tar.gz" delivery-package) || true
}

finalize_reports() {
  generate_survey
  generate_csv
  generate_items
  generate_markdown
  generate_html
  generate_summary
  copy_to_cer_repo
  create_packages
  log "Completed. Report: ${RUN_DIR}/healthcheck-report.html"
  log "Summary: ${SUMMARY_TXT}"
}

main() {
  init_dirs
  preflight
  collect_core
  collect_infrastructure
  collect_storage
  collect_platform
  collect_monitoring_logging
  collect_security
  collect_app_dev
  collect_virtualization
  collect_acm
  collect_deep
  collect_problem_pod_logs
  analyze_core
  analyze_platform
  analyze_alerts
  analyze_storage_virtualization
  add_manual_review_items
  collect_must_gather
  finalize_reports
}

main "$@"
