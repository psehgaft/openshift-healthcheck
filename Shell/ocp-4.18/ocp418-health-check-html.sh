#!/usr/bin/env bash
# =============================================================================
# ocp418-health-check-html.sh
# Read-only OpenShift 4.18+ general health check script.
# Generates raw command logs, optional pod logs, Markdown summary, and compact HTML report.
# =============================================================================

set -uo pipefail

# =============================================================================
# CONFIGURABLE VARIABLES - EXAMPLE VALUES
# You can edit these directly or override them with environment variables.
# Recommended: copy ocp418-health-check.env.example to .ocp-health-check.env and edit it.
# =============================================================================

SCRIPT_VERSION="3.0.0"

# Human-friendly cluster hint used only for local output folder names and reports.
# Example: CLUSTER_NAME_HINT="prod-ocp-qro"
CLUSTER_NAME_HINT="${CLUSTER_NAME_HINT:-example-ocp418-cluster}"

# Minimum supported OpenShift minor version. This script is intended for OCP 4.18+.
OCP_MIN_MINOR="${OCP_MIN_MINOR:-18}"

# Base directory where the script creates the timestamped evidence folder.
# Example: OUTPUT_BASE_DIR="/tmp/ocp-health"
OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-./ocp-health-runs}"

# Full output directory. Leave empty to auto-generate from OUTPUT_BASE_DIR + timestamp.
# Example: OUT_DIR="/tmp/ocp-health-prod-20260609"
OUT_DIR="${OUT_DIR:-}"

# Command timeout in seconds. Increase in large clusters.
# Example: TIMEOUT_SECONDS="180"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"

# Guided execution. Set true to pause after each major step.
# Example: PAUSE="true"
PAUSE="${PAUSE:-false}"

# Deep mode collects additional describe/log information.
# Example: DEEP="true"
DEEP="${DEEP:-false}"

# Optional must-gather. This can take time and consume disk space.
# Example: RUN_MUST_GATHER="true"
RUN_MUST_GATHER="${RUN_MUST_GATHER:-false}"

# Collect logs for problematic pods detected by the script.
# Example: COLLECT_PROBLEM_POD_LOGS="true"
COLLECT_PROBLEM_POD_LOGS="${COLLECT_PROBLEM_POD_LOGS:-true}"

# Collect selected core operator logs when DEEP=true.
# Example: COLLECT_CORE_OPERATOR_LOGS="true"
COLLECT_CORE_OPERATOR_LOGS="${COLLECT_CORE_OPERATOR_LOGS:-true}"

# Tail lines to collect per pod/container log.
# Example: LOG_TAIL_LINES="500"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-250}"

# Maximum number of problematic pods for which logs/describe output are collected.
# Example: MAX_PROBLEM_PODS="40"
MAX_PROBLEM_PODS="${MAX_PROBLEM_PODS:-25}"

# Restart threshold above which a pod is flagged.
# Example: RESTART_THRESHOLD="5"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-10}"

# Query platform alerts through the Kubernetes API proxy to Prometheus.
# Example: RUN_PROMETHEUS_ALERTS="true"
RUN_PROMETHEUS_ALERTS="${RUN_PROMETHEUS_ALERTS:-true}"

# Collect recent Warning events across namespaces.
# Example: EVENT_LIMIT="300"
EVENT_LIMIT="${EVENT_LIMIT:-250}"

# Optional namespace list for additional core namespace snapshots.
# Space-separated list. Keep quotes.
CORE_NAMESPACES="${CORE_NAMESPACES:-openshift-kube-apiserver openshift-apiserver openshift-etcd openshift-authentication openshift-ingress openshift-ingress-operator openshift-dns openshift-network-operator openshift-monitoring openshift-console openshift-machine-config-operator openshift-operator-lifecycle-manager}"

# Report title.
REPORT_TITLE="${REPORT_TITLE:-OpenShift 4.18+ General Health Report}"

# =============================================================================
# END OF CONFIGURABLE VARIABLES
# =============================================================================

RAW_DIR=""
LOG_DIR=""
DESCRIBE_DIR=""
REPORT_HTML=""
REPORT_MD=""
SUMMARY_TXT=""
COMMAND_INDEX=""
SECTIONS_HTML=""
FINDINGS_HTML=""
FINDINGS_MD=""
RUN_LOG=""

OVERALL_STATUS="HEALTHY"
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0
START_TS="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<USAGE
${REPORT_TITLE} - v${SCRIPT_VERSION}

Usage:
  ./ocp418-health-check-html.sh [options]

Options:
  --env-file FILE              Source variables from FILE before execution.
  -o, --output DIR             Output directory. Default: auto-generated under OUTPUT_BASE_DIR.
  -t, --timeout SEC            Timeout per command. Default: ${TIMEOUT_SECONDS}
  --cluster-name NAME          Local label used in the report and default output folder.
  --pause                      Pause after each major step.
  --deep                       Collect extra describe output and selected core operator logs.
  --must-gather                Run 'oc adm must-gather' at the end.
  --no-problem-pod-logs        Do not collect logs for problematic pods.
  --restart-threshold N        Warning threshold for container restarts. Default: ${RESTART_THRESHOLD}
  --max-problem-pods N         Maximum problematic pods to describe/log. Default: ${MAX_PROBLEM_PODS}
  --log-tail-lines N           Tail lines per pod/operator log. Default: ${LOG_TAIL_LINES}
  --event-limit N              Number of recent Warning events to collect. Default: ${EVENT_LIMIT}
  --skip-alerts                Skip Prometheus alert query.
  -h, --help                   Show this help.

Examples:
  chmod +x ocp418-health-check-html.sh
  oc login https://api.<cluster>:6443
  ./ocp418-health-check-html.sh

  ./ocp418-health-check-html.sh --env-file ./.ocp-health-check.env --deep

  ./ocp418-health-check-html.sh \
    --cluster-name prod-ocp-qro \
    --output /tmp/ocp-health-prod-ocp-qro \
    --deep \
    --must-gather

Output:
  <output-dir>/health-report.html       Compact HTML report
  <output-dir>/health-report.md         Markdown report
  <output-dir>/summary.txt              Plain-text summary
  <output-dir>/raw/*.txt                Raw command output logs
  <output-dir>/logs/*.log               Optional pod/operator log tails
  <output-dir>/describes/*.txt          Optional pod describe output
  <output-dir>/command-index.tsv        Command execution index
USAGE
}

# First pass: allow env file before normal argument parsing.
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [[ "${ARGS[$i]}" == "--env-file" ]]; then
    env_file="${ARGS[$((i+1))]:-}"
    if [[ -z "$env_file" || ! -f "$env_file" ]]; then
      echo "ERROR: --env-file requires an existing file." >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    source "$env_file"
  fi
done

# Optional default env file next to execution directory.
if [[ -f "./.ocp-health-check.env" ]]; then
  # shellcheck source=/dev/null
  source "./.ocp-health-check.env"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      shift 2 ;;
    -o|--output)
      OUT_DIR="${2:-}"; shift 2 ;;
    -t|--timeout)
      TIMEOUT_SECONDS="${2:-120}"; shift 2 ;;
    --cluster-name)
      CLUSTER_NAME_HINT="${2:-example-ocp418-cluster}"; shift 2 ;;
    --pause)
      PAUSE="true"; shift ;;
    --deep)
      DEEP="true"; shift ;;
    --must-gather)
      RUN_MUST_GATHER="true"; shift ;;
    --no-problem-pod-logs)
      COLLECT_PROBLEM_POD_LOGS="false"; shift ;;
    --restart-threshold)
      RESTART_THRESHOLD="${2:-10}"; shift 2 ;;
    --max-problem-pods)
      MAX_PROBLEM_PODS="${2:-25}"; shift 2 ;;
    --log-tail-lines)
      LOG_TAIL_LINES="${2:-250}"; shift 2 ;;
    --event-limit)
      EVENT_LIMIT="${2:-250}"; shift 2 ;;
    --skip-alerts)
      RUN_PROMETHEUS_ALERTS="false"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

# Normalize booleans.
for bool_name in PAUSE DEEP RUN_MUST_GATHER COLLECT_PROBLEM_POD_LOGS COLLECT_CORE_OPERATOR_LOGS RUN_PROMETHEUS_ALERTS; do
  val="${!bool_name}"
  case "${val,,}" in
    true|yes|y|1) printf -v "$bool_name" 'true' ;;
    false|no|n|0) printf -v "$bool_name" 'false' ;;
    *) echo "ERROR: ${bool_name} must be true or false. Current value: ${val}" >&2; exit 1 ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  safe_cluster="$(printf '%s' "$CLUSTER_NAME_HINT" | sed -E 's#[^A-Za-z0-9_.-]+#-#g')"
  OUT_DIR="${OUTPUT_BASE_DIR}/ocp418-health-${safe_cluster}-${START_TS}"
fi

mkdir -p "$OUT_DIR"
RAW_DIR="$OUT_DIR/raw"
LOG_DIR="$OUT_DIR/logs"
DESCRIBE_DIR="$OUT_DIR/describes"
mkdir -p "$RAW_DIR" "$LOG_DIR" "$DESCRIBE_DIR"
REPORT_HTML="$OUT_DIR/health-report.html"
REPORT_MD="$OUT_DIR/health-report.md"
SUMMARY_TXT="$OUT_DIR/summary.txt"
COMMAND_INDEX="$OUT_DIR/command-index.tsv"
SECTIONS_HTML="$OUT_DIR/.sections.html"
FINDINGS_HTML="$OUT_DIR/.findings.html"
FINDINGS_MD="$OUT_DIR/.findings.md"
RUN_LOG="$OUT_DIR/run.log"
: > "$COMMAND_INDEX"
: > "$SECTIONS_HTML"
: > "$FINDINGS_HTML"
: > "$FINDINGS_MD"
: > "$RUN_LOG"

if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"; RED="$(tput setaf 1)"; YELLOW="$(tput setaf 3)"; GREEN="$(tput setaf 2)"; BLUE="$(tput setaf 4)"
else
  BOLD=""; RESET=""; RED=""; YELLOW=""; GREEN=""; BLUE=""
fi

log() {
  echo -e "$*" | tee -a "$RUN_LOG"
}

pause_if_needed() {
  if [[ "$PAUSE" == "true" ]]; then
    read -r -p "Press ENTER to continue..." _
  fi
}

html_escape_stream() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

html_escape_text() {
  printf '%s' "$1" | html_escape_stream
}

safe_name() {
  printf '%s' "$1" | sed -E 's#[^A-Za-z0-9_.-]+#_#g'
}

count_lines() {
  local file="$1"
  if [[ -s "$file" ]]; then wc -l < "$file" | tr -d ' '; else echo 0; fi
}

set_status() {
  local severity="$1"
  local message="$2"
  local class="info"

  case "$severity" in
    CRITICAL)
      CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
      OVERALL_STATUS="CRITICAL"
      class="critical"
      ;;
    WARNING)
      WARNING_COUNT=$((WARNING_COUNT + 1))
      if [[ "$OVERALL_STATUS" != "CRITICAL" ]]; then OVERALL_STATUS="WARNING"; fi
      class="warning"
      ;;
    INFO)
      INFO_COUNT=$((INFO_COUNT + 1))
      class="info"
      ;;
    *)
      severity="INFO"
      INFO_COUNT=$((INFO_COUNT + 1))
      class="info"
      ;;
  esac

  echo "- **${severity}**: ${message}" >> "$FINDINGS_MD"
  {
    printf '<li class="%s"><strong>%s:</strong> ' "$class" "$severity"
    html_escape_text "$message"
    printf '</li>\n'
  } >> "$FINDINGS_HTML"
}

run_cmd() {
  local name="$1"
  local cmd="$2"
  local file="$RAW_DIR/${name}.txt"
  local started ended rc
  started="$(date -Is)"

  {
    echo "# Command"
    echo "$ ${cmd}"
    echo
    echo "# Started"
    echo "$started"
    echo
    echo "# Output"
  } > "$file"

  log "  - running: ${name}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" bash -o pipefail -c "$cmd" >> "$file" 2>&1
  else
    bash -o pipefail -c "$cmd" >> "$file" 2>&1
  fi
  rc=$?
  ended="$(date -Is)"

  {
    echo
    echo "# Finished"
    echo "$ended"
    echo "# Return code: ${rc}"
  } >> "$file"

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$rc" "$started" "$ended" "$file" >> "$COMMAND_INDEX"
  return "$rc"
}

append_section_start() {
  local id="$1"
  local title="$2"
  log "${BLUE}${BOLD}[${id}] ${title}${RESET}"
  {
    printf '\n<section>\n<h2>%s. ' "$id"
    html_escape_text "$title"
    printf '</h2>\n'
  } >> "$SECTIONS_HTML"
  {
    echo
    echo "## ${id}. ${title}"
    echo
  } >> "$REPORT_MD"
}

append_section_end() {
  echo '</section>' >> "$SECTIONS_HTML"
}

append_paragraph() {
  local text="$1"
  {
    printf '<p>'
    html_escape_text "$text"
    printf '</p>\n'
  } >> "$SECTIONS_HTML"
  echo "$text" >> "$REPORT_MD"
  echo >> "$REPORT_MD"
}

append_pre_file() {
  local title="$1"
  local file="$2"
  local lines="${3:-50}"
  {
    printf '<h3>'
    html_escape_text "$title"
    printf '</h3>\n'
    printf '<p class="artifact">Artifact: <code>'
    html_escape_text "$file"
    printf '</code></p>\n'
    printf '<pre>'
    if [[ -s "$file" ]]; then
      tail -n "$lines" "$file" | html_escape_stream
    else
      printf 'No output captured or file is empty.' | html_escape_stream
    fi
    printf '</pre>\n'
  } >> "$SECTIONS_HTML"

  {
    echo "### ${title}"
    echo
    echo "Artifact: ${file}"
    echo
    echo '```text'
    if [[ -s "$file" ]]; then tail -n "$lines" "$file"; else echo "No output captured or file is empty."; fi
    echo '```'
    echo
  } >> "$REPORT_MD"
}

init_markdown() {
  cat > "$REPORT_MD" <<EOF_MD
# ${REPORT_TITLE}

- **Generated:** $(date -Is)
- **Script version:** ${SCRIPT_VERSION}
- **Cluster name hint:** ${CLUSTER_NAME_HINT}
- **Output directory:** ${OUT_DIR}
- **Mode:** deep=${DEEP}, must_gather=${RUN_MUST_GATHER}, problem_pod_logs=${COLLECT_PROBLEM_POD_LOGS}, alerts=${RUN_PROMETHEUS_ALERTS}
- **Restart threshold:** ${RESTART_THRESHOLD}

> This report is generated using read-only OpenShift CLI queries. Optional pod log collection uses tail limits. Optional \`oc adm must-gather\` can be heavier and must be explicitly requested.

## Executive findings

EOF_MD
}

validate_access() {
  append_section_start "01" "Validate local tools, OpenShift login, and OpenShift 4.18+ compatibility"

  if ! command -v oc >/dev/null 2>&1; then
    set_status "CRITICAL" "The 'oc' CLI was not found in PATH. Install the OpenShift CLI and run the script again."
    append_paragraph "The oc CLI was not found. The health check cannot continue."
    append_section_end
    finalize_reports
    exit 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    set_status "WARNING" "jq was not found. The script will continue, but structured JSON checks will use fallback logic."
  else
    set_status "INFO" "jq is available; structured JSON parsing will be used."
  fi

  run_cmd "01_oc_version" "oc version"
  run_cmd "01_oc_whoami" "oc whoami"
  local whoami_rc=$?
  run_cmd "01_oc_config_current_context" "oc config current-context"
  run_cmd "01_oc_project" "oc project"
  run_cmd "01_api_resources_probe" "oc api-resources --request-timeout=15s | head -n 80"

  append_pre_file "oc version" "$RAW_DIR/01_oc_version.txt" 40
  append_pre_file "Current user" "$RAW_DIR/01_oc_whoami.txt" 20
  append_pre_file "Current context" "$RAW_DIR/01_oc_config_current_context.txt" 20

  if [[ $whoami_rc -ne 0 ]]; then
    set_status "CRITICAL" "Unable to verify OpenShift login using 'oc whoami'. Run 'oc login' and execute the script again."
    append_section_end
    finalize_reports
    exit 2
  fi

  local desired minor
  desired="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
  if [[ "$desired" =~ ^4\.([0-9]+) ]]; then
    minor="${BASH_REMATCH[1]}"
    if (( minor < OCP_MIN_MINOR )); then
      set_status "WARNING" "Cluster desired version is ${desired}. This script is intended for OpenShift 4.${OCP_MIN_MINOR} or later. Collection will continue with best-effort compatibility."
    else
      set_status "INFO" "Cluster desired version is ${desired}; this matches the OpenShift 4.${OCP_MIN_MINOR}+ target."
    fi
  else
    set_status "WARNING" "Unable to parse ClusterVersion desired version. Raw ClusterVersion output will be collected in step 02."
  fi

  pause_if_needed
  append_section_end
}

cluster_baseline() {
  append_section_start "02" "Collect cluster baseline, ClusterVersion, and infrastructure status"

  run_cmd "02_clusterversion" "oc get clusterversion version -o wide"
  run_cmd "02_clusterversion_yaml" "oc get clusterversion version -o yaml"
  run_cmd "02_infrastructure" "oc get infrastructure cluster -o yaml"
  run_cmd "02_clusterid" "oc get clusterversion version -o jsonpath='{.spec.clusterID}{\"\\n\"}'"
  run_cmd "02_projects_count" "oc get projects --no-headers 2>/dev/null | wc -l"

  append_pre_file "ClusterVersion" "$RAW_DIR/02_clusterversion.txt" 60

  local cv_available cv_progressing cv_degraded
  cv_available="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  cv_progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
  cv_degraded="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)"

  if [[ "$cv_degraded" == "True" ]]; then
    set_status "CRITICAL" "ClusterVersion reports Degraded=True. Review raw/02_clusterversion_yaml.txt."
  fi
  if [[ "$cv_available" != "True" ]]; then
    set_status "CRITICAL" "ClusterVersion does not report Available=True. Current Available=${cv_available:-unknown}."
  fi
  if [[ "$cv_progressing" == "True" ]]; then
    set_status "WARNING" "ClusterVersion reports Progressing=True. The cluster might be upgrading or reconciling."
  fi
  if [[ "$cv_available" == "True" && "$cv_progressing" != "True" && "$cv_degraded" != "True" ]]; then
    set_status "INFO" "ClusterVersion reports Available=True, Progressing=False, and Degraded=False."
  fi

  pause_if_needed
  append_section_end
}

cluster_operators() {
  append_section_start "03" "Validate ClusterOperators"

  run_cmd "03_clusteroperators" "oc get clusteroperators"
  run_cmd "03_clusteroperators_wide" "oc get clusteroperators -o wide"
  run_cmd "03_clusteroperators_json" "oc get clusteroperators -o json"
  append_pre_file "ClusterOperators" "$RAW_DIR/03_clusteroperators.txt" 120

  if command -v jq >/dev/null 2>&1; then
    oc get clusteroperators -o json 2>/dev/null | jq -r '
      .items[] as $co |
      ($co.status.conditions[]? | select(.type=="Available") | .status) as $available |
      ($co.status.conditions[]? | select(.type=="Progressing") | .status) as $progressing |
      ($co.status.conditions[]? | select(.type=="Degraded") | .status) as $degraded |
      select(($available != "True") or ($progressing == "True") or ($degraded == "True")) |
      [$co.metadata.name, "Available=" + ($available // "unknown"), "Progressing=" + ($progressing // "unknown"), "Degraded=" + ($degraded // "unknown")] | @tsv
    ' > "$RAW_DIR/03_clusteroperators_problematic.tsv" || true
  else
    oc get clusteroperators --no-headers 2>/dev/null | awk '$3 != "True" || $4 == "True" || $5 == "True" {print}' > "$RAW_DIR/03_clusteroperators_problematic.tsv" || true
  fi

  if [[ -s "$RAW_DIR/03_clusteroperators_problematic.tsv" ]]; then
    set_status "CRITICAL" "One or more ClusterOperators are unavailable, progressing, or degraded. Review raw/03_clusteroperators_problematic.tsv."
    append_pre_file "Problematic ClusterOperators" "$RAW_DIR/03_clusteroperators_problematic.tsv" 80
  else
    set_status "INFO" "All parsed ClusterOperators are Available=True, Progressing=False, and Degraded=False."
  fi

  pause_if_needed
  append_section_end
}

nodes_and_mcp() {
  append_section_start "04" "Validate nodes, resource usage, MachineConfigPools, and machine API"

  run_cmd "04_nodes" "oc get nodes -o wide"
  run_cmd "04_nodes_json" "oc get nodes -o json"
  run_cmd "04_adm_top_nodes" "oc adm top nodes 2>/dev/null || true"
  run_cmd "04_mcp" "oc get machineconfigpools"
  run_cmd "04_mcp_json" "oc get machineconfigpools -o json"
  run_cmd "04_machines" "oc get machines -A -o wide 2>/dev/null || true"
  run_cmd "04_machinesets" "oc get machinesets -A -o wide 2>/dev/null || true"

  append_pre_file "Nodes" "$RAW_DIR/04_nodes.txt" 100
  append_pre_file "Node resource usage" "$RAW_DIR/04_adm_top_nodes.txt" 100
  append_pre_file "MachineConfigPools" "$RAW_DIR/04_mcp.txt" 100

  if command -v jq >/dev/null 2>&1; then
    oc get nodes -o json 2>/dev/null | jq -r '
      .items[] as $n |
      $n.status.conditions[]? |
      select((.type=="Ready" and .status!="True") or ((.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure" or .type=="NetworkUnavailable") and .status=="True")) |
      [$n.metadata.name, .type, .status, (.reason // ""), (.message // "")] | @tsv
    ' > "$RAW_DIR/04_node_condition_problems.tsv" || true
  else
    oc get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print}' > "$RAW_DIR/04_node_condition_problems.tsv" || true
  fi

  if [[ -s "$RAW_DIR/04_node_condition_problems.tsv" ]]; then
    set_status "CRITICAL" "One or more node conditions indicate NotReady, pressure, or network unavailability. Review raw/04_node_condition_problems.tsv."
    append_pre_file "Node condition problems" "$RAW_DIR/04_node_condition_problems.tsv" 80
  else
    set_status "INFO" "No NotReady, pressure, or NetworkUnavailable node condition was detected."
  fi

  if command -v jq >/dev/null 2>&1; then
    oc get machineconfigpools -o json 2>/dev/null | jq -r '
      .items[] as $mcp |
      ($mcp.status.conditions[]? | select(.type=="Updated") | .status) as $updated |
      ($mcp.status.conditions[]? | select(.type=="Updating") | .status) as $updating |
      ($mcp.status.conditions[]? | select(.type=="Degraded") | .status) as $degraded |
      select(($updated != "True") or ($updating == "True") or ($degraded == "True")) |
      [$mcp.metadata.name, "Updated=" + ($updated // "unknown"), "Updating=" + ($updating // "unknown"), "Degraded=" + ($degraded // "unknown")] | @tsv
    ' > "$RAW_DIR/04_mcp_problematic.tsv" || true
  else
    oc get mcp --no-headers 2>/dev/null | awk '$3 != "True" || $4 == "True" || $5 == "True" {print}' > "$RAW_DIR/04_mcp_problematic.tsv" || true
  fi

  if [[ -s "$RAW_DIR/04_mcp_problematic.tsv" ]]; then
    set_status "CRITICAL" "One or more MachineConfigPools are not updated, updating, or degraded. Review raw/04_mcp_problematic.tsv."
    append_pre_file "Problematic MachineConfigPools" "$RAW_DIR/04_mcp_problematic.tsv" 80
  else
    set_status "INFO" "MachineConfigPools are updated and not degraded."
  fi

  pause_if_needed
  append_section_end
}

workloads_and_pods() {
  append_section_start "05" "Validate pods, restarts, and workload symptoms"

  run_cmd "05_pods_all" "oc get pods -A -o wide"
  oc get pods -A -o json > "$RAW_DIR/05_pods_all.json" 2> "$RAW_DIR/05_pods_all_json.err" || true
  run_cmd "05_deployments_all" "oc get deployments -A -o wide 2>/dev/null || true"
  run_cmd "05_statefulsets_all" "oc get statefulsets -A -o wide 2>/dev/null || true"
  run_cmd "05_daemonsets_all" "oc get daemonsets -A -o wide 2>/dev/null || true"
  run_cmd "05_replicasets_all" "oc get replicasets -A -o wide 2>/dev/null || true"
  oc get deployments -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if (a[1] != a[2]) print}' > "$RAW_DIR/05_deployments_not_available.txt" || true

  if command -v jq >/dev/null 2>&1 && [[ -s "$RAW_DIR/05_pods_all.json" ]]; then
    jq -r --argjson threshold "$RESTART_THRESHOLD" '
      .items[] | . as $p |
      [
        $p.metadata.namespace,
        $p.metadata.name,
        ($p.status.phase // ""),
        ([$p.status.containerStatuses[]? | select((.restartCount // 0) > $threshold) | "\(.name):\(.restartCount)"] | join(",")),
        ([$p.status.containerStatuses[]? | select(.state.waiting.reason? and ((.state.waiting.reason == "CrashLoopBackOff") or (.state.waiting.reason == "ImagePullBackOff") or (.state.waiting.reason == "ErrImagePull") or (.state.waiting.reason == "CreateContainerConfigError") or (.state.waiting.reason == "CreateContainerError") or (.state.waiting.reason == "RunContainerError") or (.state.waiting.reason == "InvalidImageName"))) | "\(.name):\(.state.waiting.reason)"] | join(",")),
        ([$p.status.containerStatuses[]? | select(.lastState.terminated.reason? == "OOMKilled") | "\(.name):OOMKilled"] | join(",")),
        ($p.status.reason // ""),
        ($p.status.message // "")
      ] as $row |
      select(($row[2] != "Running" and $row[2] != "Succeeded") or ($row[3] != "") or ($row[4] != "") or ($row[5] != "")) |
      $row | @tsv
    ' "$RAW_DIR/05_pods_all.json" > "$RAW_DIR/05_pods_problematic.tsv" 2>/dev/null || true
  else
    oc get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print}' > "$RAW_DIR/05_pods_problematic.tsv" || true
  fi

  append_pre_file "All pods" "$RAW_DIR/05_pods_all.txt" 150
  append_pre_file "Problematic pods" "$RAW_DIR/05_pods_problematic.tsv" 120
  append_pre_file "Deployments with unavailable replicas" "$RAW_DIR/05_deployments_not_available.txt" 100

  local bad_count deploy_bad_count
  bad_count="$(count_lines "$RAW_DIR/05_pods_problematic.tsv")"
  deploy_bad_count="$(count_lines "$RAW_DIR/05_deployments_not_available.txt")"

  if (( bad_count > 0 )); then
    set_status "CRITICAL" "Detected ${bad_count} problematic pod entries: non-running phases, high restarts, image pull failures, CrashLoopBackOff, or OOMKilled. Review raw/05_pods_problematic.tsv."
  else
    set_status "INFO" "No problematic pods detected by phase/restart/waiting-state analysis."
  fi

  if (( deploy_bad_count > 0 )); then
    set_status "WARNING" "Detected deployments with unavailable replicas. Review raw/05_deployments_not_available.txt."
  fi

  if [[ "$COLLECT_PROBLEM_POD_LOGS" == "true" ]]; then
    collect_problem_pod_evidence
  fi

  pause_if_needed
  append_section_end
}

collect_problem_pod_evidence() {
  local processed=0 ns pod clean
  if [[ ! -s "$RAW_DIR/05_pods_problematic.tsv" ]]; then
    return 0
  fi

  append_paragraph "Collecting describe output and limited log tails for up to ${MAX_PROBLEM_PODS} problematic pods."
  while IFS=$'\t' read -r ns pod _rest; do
    [[ -z "${ns:-}" || -z "${pod:-}" ]] && continue
    processed=$((processed + 1))
    if (( processed > MAX_PROBLEM_PODS )); then
      break
    fi
    clean="$(safe_name "${ns}_${pod}")"
    run_cmd "describe_pod_${clean}" "oc -n '${ns}' describe pod '${pod}'" || true
    cp "$RAW_DIR/describe_pod_${clean}.txt" "$DESCRIBE_DIR/${clean}.txt" 2>/dev/null || true
    run_cmd "logs_pod_${clean}" "oc -n '${ns}' logs pod/'${pod}' --all-containers=true --tail=${LOG_TAIL_LINES} --prefix --timestamps 2>/dev/null || true" || true
    cp "$RAW_DIR/logs_pod_${clean}.txt" "$LOG_DIR/${clean}.log" 2>/dev/null || true
  done < "$RAW_DIR/05_pods_problematic.tsv"

  set_status "INFO" "Collected describe/log evidence for ${processed} problematic pod entries, capped at ${MAX_PROBLEM_PODS}."
}

core_namespaces() {
  append_section_start "06" "Collect selected core OpenShift namespace status"

  : > "$RAW_DIR/06_core_namespaces_pods.txt"
  local ns
  for ns in $CORE_NAMESPACES; do
    {
      echo "## ${ns}"
      oc -n "$ns" get pods -o wide 2>/dev/null || true
      echo
    } >> "$RAW_DIR/06_core_namespaces_pods.txt"
  done

  run_cmd "06_etcd_members" "POD=\$(oc -n openshift-etcd get pods -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); if [[ -n \"\$POD\" ]]; then oc -n openshift-etcd exec -c etcd \"\$POD\" -- etcdctl member list -w table 2>/dev/null; fi"
  run_cmd "06_kube_apiserver_pods" "oc -n openshift-kube-apiserver get pods -o wide 2>/dev/null || true"
  run_cmd "06_authentication_pods" "oc -n openshift-authentication get pods -o wide 2>/dev/null || true"
  run_cmd "06_ingress_pods" "oc -n openshift-ingress get pods -o wide 2>/dev/null || true"
  run_cmd "06_dns_pods" "oc -n openshift-dns get pods -o wide 2>/dev/null || true"
  run_cmd "06_monitoring_pods" "oc -n openshift-monitoring get pods -o wide 2>/dev/null || true"

  append_pre_file "Core namespace pods" "$RAW_DIR/06_core_namespaces_pods.txt" 220
  append_pre_file "etcd members" "$RAW_DIR/06_etcd_members.txt" 80

  if grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|Pending|Terminating|Unknown|Evicted' "$RAW_DIR/06_core_namespaces_pods.txt" >/dev/null 2>&1; then
    set_status "CRITICAL" "Selected core OpenShift namespaces contain pods in problematic states. Review raw/06_core_namespaces_pods.txt."
  else
    set_status "INFO" "No obvious problematic pod states found in the selected core OpenShift namespaces."
  fi

  if [[ "$DEEP" == "true" && "$COLLECT_CORE_OPERATOR_LOGS" == "true" ]]; then
    collect_core_operator_logs
  fi

  pause_if_needed
  append_section_end
}

collect_core_operator_logs() {
  append_paragraph "Deep mode enabled: collecting limited logs from selected core operator deployments when present."
  local refs=(
    "openshift-cluster-version:deployment/cluster-version-operator"
    "openshift-machine-config-operator:deployment/machine-config-operator"
    "openshift-ingress-operator:deployment/ingress-operator"
    "openshift-authentication-operator:deployment/authentication-operator"
    "openshift-dns-operator:deployment/dns-operator"
    "openshift-network-operator:deployment/network-operator"
    "openshift-monitoring:deployment/cluster-monitoring-operator"
    "openshift-console-operator:deployment/console-operator"
  )
  local item ns ref clean
  for item in "${refs[@]}"; do
    ns="${item%%:*}"
    ref="${item#*:}"
    clean="$(safe_name "${ns}_${ref}")"
    run_cmd "logs_core_${clean}" "oc -n '${ns}' logs '${ref}' --all-containers=true --tail=${LOG_TAIL_LINES} --prefix --timestamps 2>/dev/null || true" || true
    cp "$RAW_DIR/logs_core_${clean}.txt" "$LOG_DIR/${clean}.log" 2>/dev/null || true
  done
  set_status "INFO" "Deep mode collected limited logs from selected core operator deployments."
}

network_ingress_dns() {
  append_section_start "07" "Validate network, ingress, DNS, proxy, routes, and image registry configuration"

  run_cmd "07_network_config" "oc get network.config.openshift.io cluster -o yaml"
  run_cmd "07_network_operator" "oc get co network -o yaml"
  run_cmd "07_dns_operator" "oc get dns.operator.openshift.io default -o yaml 2>/dev/null || true"
  run_cmd "07_dns_config" "oc get dns.config.openshift.io cluster -o yaml 2>/dev/null || true"
  run_cmd "07_ingresscontrollers" "oc get ingresscontrollers.operator.openshift.io -A -o wide 2>/dev/null || true"
  run_cmd "07_ingresscontrollers_yaml" "oc get ingresscontrollers.operator.openshift.io -A -o yaml 2>/dev/null || true"
  run_cmd "07_routes_openshift" "oc get routes -A | egrep 'openshift|console|oauth|prometheus|alertmanager|grafana' || true"
  run_cmd "07_proxy_config" "oc get proxy.config.openshift.io cluster -o yaml 2>/dev/null || true"
  run_cmd "07_image_registry_config" "oc get configs.imageregistry.operator.openshift.io cluster -o yaml 2>/dev/null || true"
  run_cmd "07_image_config" "oc get image.config.openshift.io cluster -o yaml 2>/dev/null || true"

  append_pre_file "IngressControllers" "$RAW_DIR/07_ingresscontrollers.txt" 100
  append_pre_file "Selected OpenShift routes" "$RAW_DIR/07_routes_openshift.txt" 100
  append_pre_file "Proxy configuration" "$RAW_DIR/07_proxy_config.txt" 100

  if command -v jq >/dev/null 2>&1; then
    oc get ingresscontrollers.operator.openshift.io -A -o json 2>/dev/null | jq -r '
      .items[] as $ic |
      $ic.status.conditions[]? |
      select(.type == "Available" and .status != "True") |
      [$ic.metadata.namespace, $ic.metadata.name, .type, .status, (.reason // ""), (.message // "")] | @tsv
    ' > "$RAW_DIR/07_ingresscontrollers_unavailable.tsv" || true
    if [[ -s "$RAW_DIR/07_ingresscontrollers_unavailable.tsv" ]]; then
      set_status "WARNING" "One or more IngressControllers are not Available=True. Review raw/07_ingresscontrollers_unavailable.tsv."
      append_pre_file "Unavailable IngressControllers" "$RAW_DIR/07_ingresscontrollers_unavailable.tsv" 80
    else
      set_status "INFO" "No unavailable IngressController condition was detected through structured parsing."
    fi
  else
    set_status "INFO" "IngressController YAML was collected. Install jq for structured condition parsing."
  fi

  pause_if_needed
  append_section_end
}

storage_health() {
  append_section_start "08" "Validate storage classes, PVs, PVCs, CSI, and volume attachments"

  run_cmd "08_storageclasses" "oc get storageclass -o wide 2>/dev/null || true"
  run_cmd "08_pv" "oc get pv -o wide 2>/dev/null || true"
  run_cmd "08_pvc_all" "oc get pvc -A -o wide 2>/dev/null || true"
  run_cmd "08_csidrivers" "oc get csidrivers 2>/dev/null || true"
  run_cmd "08_csinodes" "oc get csinodes 2>/dev/null || true"
  run_cmd "08_volumeattachments" "oc get volumeattachments -o wide 2>/dev/null || true"
  run_cmd "08_storage_operator" "oc get co storage -o yaml 2>/dev/null || true"

  append_pre_file "StorageClasses" "$RAW_DIR/08_storageclasses.txt" 100
  append_pre_file "PersistentVolumes" "$RAW_DIR/08_pv.txt" 120
  append_pre_file "PersistentVolumeClaims" "$RAW_DIR/08_pvc_all.txt" 120
  append_pre_file "VolumeAttachments" "$RAW_DIR/08_volumeattachments.txt" 100

  local pvc_bad pv_bad va_bad
  pvc_bad="$(oc get pvc -A --no-headers 2>/dev/null | awk '$4 != "Bound" {print}' || true)"
  pv_bad="$(oc get pv --no-headers 2>/dev/null | awk '$5 != "Bound" && $5 != "Available" {print}' || true)"
  va_bad="$(oc get volumeattachments --no-headers 2>/dev/null | awk '$5 != "true" && $5 != "True" {print}' || true)"

  if [[ -n "$pvc_bad" ]]; then
    printf '%s\n' "$pvc_bad" > "$RAW_DIR/08_pvc_not_bound.txt"
    set_status "WARNING" "One or more PVCs are not Bound. Review raw/08_pvc_not_bound.txt."
    append_pre_file "PVCs not Bound" "$RAW_DIR/08_pvc_not_bound.txt" 100
  else
    set_status "INFO" "All listed PVCs are Bound, or no PVCs were found."
  fi

  if [[ -n "$pv_bad" ]]; then
    printf '%s\n' "$pv_bad" > "$RAW_DIR/08_pv_unusual_status.txt"
    set_status "WARNING" "One or more PVs are neither Bound nor Available. Review raw/08_pv_unusual_status.txt."
    append_pre_file "PVs in unusual status" "$RAW_DIR/08_pv_unusual_status.txt" 100
  fi

  if [[ -n "$va_bad" ]]; then
    printf '%s\n' "$va_bad" > "$RAW_DIR/08_volumeattachments_not_attached.txt"
    set_status "WARNING" "One or more VolumeAttachments are not attached. Review raw/08_volumeattachments_not_attached.txt."
    append_pre_file "VolumeAttachments not attached" "$RAW_DIR/08_volumeattachments_not_attached.txt" 100
  fi

  pause_if_needed
  append_section_end
}

olm_health() {
  append_section_start "09" "Validate OLM operators, CSVs, subscriptions, install plans, and catalog sources"

  run_cmd "09_csv_all" "oc get csv -A 2>/dev/null || true"
  run_cmd "09_subscriptions" "oc get subscriptions.operators.coreos.com -A -o wide 2>/dev/null || true"
  run_cmd "09_installplans" "oc get installplans.operators.coreos.com -A -o wide 2>/dev/null || true"
  run_cmd "09_operatorgroups" "oc get operatorgroups.operators.coreos.com -A -o wide 2>/dev/null || true"
  run_cmd "09_catalogsources" "oc get catalogsources.operators.coreos.com -A -o wide 2>/dev/null || true"
  run_cmd "09_olm_pods" "oc -n openshift-operator-lifecycle-manager get pods -o wide 2>/dev/null || true"

  append_pre_file "ClusterServiceVersions" "$RAW_DIR/09_csv_all.txt" 140
  append_pre_file "Subscriptions" "$RAW_DIR/09_subscriptions.txt" 140
  append_pre_file "InstallPlans" "$RAW_DIR/09_installplans.txt" 140
  append_pre_file "CatalogSources" "$RAW_DIR/09_catalogsources.txt" 140

  local csv_bad install_pending
  csv_bad="$(oc get csv -A --no-headers 2>/dev/null | awk '$NF != "Succeeded" {print}' || true)"
  install_pending="$(oc get installplans -A --no-headers 2>/dev/null | awk '$NF != "Complete" && $NF != "Completed" {print}' || true)"

  if [[ -n "$csv_bad" ]]; then
    printf '%s\n' "$csv_bad" > "$RAW_DIR/09_csv_not_succeeded.txt"
    set_status "WARNING" "One or more ClusterServiceVersions are not Succeeded. Review raw/09_csv_not_succeeded.txt."
    append_pre_file "CSVs not Succeeded" "$RAW_DIR/09_csv_not_succeeded.txt" 120
  else
    set_status "INFO" "All listed CSVs are Succeeded, or no CSVs were found."
  fi

  if [[ -n "$install_pending" ]]; then
    printf '%s\n' "$install_pending" > "$RAW_DIR/09_installplans_not_complete.txt"
    set_status "WARNING" "One or more InstallPlans are not Complete. Review raw/09_installplans_not_complete.txt."
    append_pre_file "InstallPlans not Complete" "$RAW_DIR/09_installplans_not_complete.txt" 120
  fi

  pause_if_needed
  append_section_end
}

events_and_alerts() {
  append_section_start "10" "Collect warning events and active platform alerts"

  run_cmd "10_warning_events" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n ${EVENT_LIMIT} || true"
  run_cmd "10_recent_events" "oc get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n ${EVENT_LIMIT} || true"
  append_pre_file "Recent Warning events" "$RAW_DIR/10_warning_events.txt" 180

  local warning_count
  warning_count="$(grep -v '^#' "$RAW_DIR/10_warning_events.txt" 2>/dev/null | grep -v '^$' | wc -l | tr -d ' ' || true)"
  if [[ "$warning_count" =~ ^[0-9]+$ ]] && (( warning_count > 5 )); then
    set_status "WARNING" "Recent Warning events were detected. Review raw/10_warning_events.txt."
  else
    set_status "INFO" "Warning events were collected; no large warning-event volume was detected by the simple threshold."
  fi

  if [[ "$RUN_PROMETHEUS_ALERTS" == "true" ]]; then
    run_cmd "10_prometheus_alerts_raw" "oc get --raw '/api/v1/namespaces/openshift-monitoring/services/https:prometheus-k8s:9091/proxy/api/v1/alerts' 2>/dev/null || true"
    if command -v jq >/dev/null 2>&1; then
      sed -n '/^{/,$p' "$RAW_DIR/10_prometheus_alerts_raw.txt" | jq -r '
        .data.alerts[]? |
        select(.state == "firing") |
        [(.labels.severity // "none"), (.labels.alertname // "unknown"), (.labels.namespace // ""), (.labels.pod // ""), (.annotations.summary // .annotations.message // "")] | @tsv
      ' > "$RAW_DIR/10_prometheus_alerts_firing.tsv" 2>/dev/null || true
      append_pre_file "Firing Prometheus alerts" "$RAW_DIR/10_prometheus_alerts_firing.tsv" 140
      local critical_alerts warning_alerts total_alerts
      critical_alerts="$(awk -F '\t' '$1 == "critical" {c++} END{print c+0}' "$RAW_DIR/10_prometheus_alerts_firing.tsv" 2>/dev/null || echo 0)"
      warning_alerts="$(awk -F '\t' '$1 == "warning" {c++} END{print c+0}' "$RAW_DIR/10_prometheus_alerts_firing.tsv" 2>/dev/null || echo 0)"
      total_alerts="$(count_lines "$RAW_DIR/10_prometheus_alerts_firing.tsv")"
      if (( critical_alerts > 0 )); then
        set_status "CRITICAL" "Detected ${critical_alerts} firing critical Prometheus alerts. Review raw/10_prometheus_alerts_firing.tsv."
      elif (( warning_alerts > 0 )); then
        set_status "WARNING" "Detected ${warning_alerts} firing warning Prometheus alerts. Review raw/10_prometheus_alerts_firing.tsv."
      elif (( total_alerts > 0 )); then
        set_status "WARNING" "Detected ${total_alerts} firing Prometheus alerts without critical/warning severity. Review raw/10_prometheus_alerts_firing.tsv."
      else
        set_status "INFO" "No firing Prometheus alerts were parsed through the API proxy."
      fi
    else
      set_status "INFO" "Prometheus alerts raw collection was attempted. Install jq or inspect raw/10_prometheus_alerts_raw.txt for details."
    fi
  else
    set_status "INFO" "Prometheus alert query was skipped by configuration."
  fi

  pause_if_needed
  append_section_end
}

auth_cert_api_health() {
  append_section_start "11" "Validate authentication, CSRs, APIService availability, and certificate overview"

  run_cmd "11_co_auth_related" "oc get co authentication kube-apiserver openshift-apiserver oauth-apiserver 2>/dev/null || true"
  run_cmd "11_oauth_config" "oc get oauth cluster -o yaml 2>/dev/null || true"
  run_cmd "11_csr" "oc get csr 2>/dev/null || true"
  run_cmd "11_apiservices" "oc get apiservices 2>/dev/null || true"
  run_cmd "11_apiservices_json" "oc get apiservices -o json 2>/dev/null || true"
  run_cmd "11_cert_signing_requests_pending" "oc get csr --no-headers 2>/dev/null | awk '\$6 == \"Pending\" || \$NF == \"Pending\" {print}' || true"
  run_cmd "11_config_secrets_tls_overview" "oc -n openshift-config get secrets 2>/dev/null | egrep 'tls|cert|ca|router|proxy|pull-secret' || true"

  append_pre_file "Auth-related ClusterOperators" "$RAW_DIR/11_co_auth_related.txt" 100
  append_pre_file "CertificateSigningRequests" "$RAW_DIR/11_csr.txt" 100
  append_pre_file "APIService availability" "$RAW_DIR/11_apiservices.txt" 140
  append_pre_file "TLS/cert-related secrets overview" "$RAW_DIR/11_config_secrets_tls_overview.txt" 100

  local csr_pending
  csr_pending="$(count_lines "$RAW_DIR/11_cert_signing_requests_pending.txt")"
  if [[ "$csr_pending" =~ ^[0-9]+$ ]] && (( csr_pending > 0 )); then
    set_status "WARNING" "Detected ${csr_pending} pending CSRs. Review raw/11_cert_signing_requests_pending.txt."
  else
    set_status "INFO" "No pending CSRs were detected through the fallback parser."
  fi

  if command -v jq >/dev/null 2>&1; then
    oc get apiservices -o json 2>/dev/null | jq -r '
      .items[] as $api |
      $api.status.conditions[]? |
      select(.type == "Available" and .status != "True") |
      [$api.metadata.name, .status, (.reason // ""), (.message // "")] | @tsv
    ' > "$RAW_DIR/11_apiservices_unavailable.tsv" 2>/dev/null || true
    if [[ -s "$RAW_DIR/11_apiservices_unavailable.tsv" ]]; then
      set_status "WARNING" "One or more APIService objects are not Available=True. Review raw/11_apiservices_unavailable.tsv."
      append_pre_file "Unavailable APIService objects" "$RAW_DIR/11_apiservices_unavailable.tsv" 100
    else
      set_status "INFO" "All parsed APIService objects report Available=True."
    fi
  else
    set_status "INFO" "APIService JSON was collected. Install jq for structured APIService parsing."
  fi

  pause_if_needed
  append_section_end
}

optional_must_gather() {
  append_section_start "12" "Optional must-gather"
  if [[ "$RUN_MUST_GATHER" == "true" ]]; then
    append_paragraph "Running oc adm must-gather because RUN_MUST_GATHER=true or --must-gather was requested."
    run_cmd "12_must_gather" "cd '${OUT_DIR}' && oc adm must-gather --dest-dir=must-gather.local"
    local rc=$?
    append_pre_file "must-gather command output" "$RAW_DIR/12_must_gather.txt" 100
    if [[ $rc -eq 0 ]]; then
      set_status "INFO" "must-gather completed under ${OUT_DIR}/must-gather.local."
    else
      set_status "WARNING" "must-gather did not complete successfully. Review raw/12_must_gather.txt."
    fi
  else
    append_paragraph "must-gather was skipped. Re-run with --must-gather when preparing a Red Hat Support case or when full evidence is required."
    set_status "INFO" "must-gather skipped by configuration."
  fi
  pause_if_needed
  append_section_end
}

finalize_reports() {
  local generated status_class tmp_md
  generated="$(date -Is)"
  status_class="healthy"
  case "$OVERALL_STATUS" in
    CRITICAL) status_class="critical" ;;
    WARNING) status_class="warning" ;;
    *) status_class="healthy" ;;
  esac

  {
    echo "# OpenShift 4.18+ Health Check Summary"
    echo "Generated: ${generated}"
    echo "Script version: ${SCRIPT_VERSION}"
    echo "Cluster name hint: ${CLUSTER_NAME_HINT}"
    echo "Output directory: ${OUT_DIR}"
    echo "Overall status: ${OVERALL_STATUS}"
    echo "Critical findings: ${CRITICAL_COUNT}"
    echo "Warning findings: ${WARNING_COUNT}"
    echo "Info findings: ${INFO_COUNT}"
    echo
    echo "Main report: health-report.html"
    echo "Markdown report: health-report.md"
    echo "Raw command logs: raw/"
    echo "Pod/operator logs: logs/"
    echo "Pod describes: describes/"
    echo "Command index: command-index.tsv"
    echo
    echo "Findings:"
    cat "$FINDINGS_MD" 2>/dev/null || true
  } > "$SUMMARY_TXT"

  tmp_md="$OUT_DIR/.health-report.tmp.md"
  awk -v findings_file="$FINDINGS_MD" '
    {print}
    /^## Executive findings$/ {print ""; while ((getline line < findings_file) > 0) print line}
  ' "$REPORT_MD" > "$tmp_md" 2>/dev/null || cp "$REPORT_MD" "$tmp_md"
  mv "$tmp_md" "$REPORT_MD"

  cat > "$REPORT_HTML" <<EOF_HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${REPORT_TITLE}</title>
<style>
  :root { --bg:#f6f8fa; --card:#ffffff; --text:#24292f; --muted:#57606a; --border:#d0d7de; --ok:#1a7f37; --warn:#9a6700; --crit:#cf222e; --info:#0969da; }
  body { margin:0; padding:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif; background:var(--bg); color:var(--text); }
  header { background:#151515; color:#fff; padding:24px 32px; }
  header h1 { margin:0 0 8px 0; font-size:28px; }
  header p { margin:0; color:#d8d8d8; }
  main { max-width:1180px; margin:24px auto; padding:0 20px 40px 20px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:12px; margin-bottom:18px; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:16px; box-shadow:0 1px 2px rgba(0,0,0,.04); }
  .card .label { color:var(--muted); font-size:13px; margin-bottom:6px; }
  .card .value { font-size:26px; font-weight:700; }
  .status { display:inline-block; padding:6px 10px; border-radius:999px; font-weight:700; color:#fff; }
  .status.healthy { background:var(--ok); }
  .status.warning { background:var(--warn); }
  .status.critical { background:var(--crit); }
  section { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:18px; margin:16px 0; box-shadow:0 1px 2px rgba(0,0,0,.04); }
  h2 { margin-top:0; border-bottom:1px solid var(--border); padding-bottom:8px; }
  h3 { margin-bottom:6px; }
  pre { background:#0d1117; color:#e6edf3; padding:14px; border-radius:8px; overflow:auto; max-height:460px; font-size:12px; line-height:1.45; }
  code { background:#eff1f3; padding:2px 4px; border-radius:4px; }
  .artifact { color:var(--muted); font-size:13px; }
  ul.findings { padding-left:22px; }
  ul.findings li { margin:8px 0; }
  li.critical strong { color:var(--crit); }
  li.warning strong { color:var(--warn); }
  li.info strong { color:var(--info); }
  .note { color:var(--muted); font-size:14px; }
  table { width:100%; border-collapse:collapse; }
  th, td { border:1px solid var(--border); padding:6px 8px; text-align:left; font-size:13px; }
  th { background:#f0f3f6; }
</style>
</head>
<body>
<header>
  <h1>${REPORT_TITLE}</h1>
  <p>Generated: ${generated} | Script version: ${SCRIPT_VERSION} | Cluster hint: ${CLUSTER_NAME_HINT}</p>
</header>
<main>
  <div class="cards">
    <div class="card"><div class="label">Overall status</div><div class="value"><span class="status ${status_class}">${OVERALL_STATUS}</span></div></div>
    <div class="card"><div class="label">Critical findings</div><div class="value">${CRITICAL_COUNT}</div></div>
    <div class="card"><div class="label">Warning findings</div><div class="value">${WARNING_COUNT}</div></div>
    <div class="card"><div class="label">Information findings</div><div class="value">${INFO_COUNT}</div></div>
  </div>

  <section>
    <h2>Executive findings</h2>
    <ul class="findings">
EOF_HTML

  if [[ -s "$FINDINGS_HTML" ]]; then
    cat "$FINDINGS_HTML" >> "$REPORT_HTML"
  else
    echo '<li class="info"><strong>INFO:</strong> No findings were recorded.</li>' >> "$REPORT_HTML"
  fi

  cat >> "$REPORT_HTML" <<EOF_HTML
    </ul>
    <p class="note">Review raw evidence before external sharing. Artifacts can include cluster names, routes, IP addresses, namespaces, node names, events, and operational metadata.</p>
  </section>
EOF_HTML

  cat "$SECTIONS_HTML" >> "$REPORT_HTML"

  cat >> "$REPORT_HTML" <<EOF_HTML
  <section>
    <h2>Artifacts</h2>
    <table>
      <tr><th>Path</th><th>Description</th></tr>
      <tr><td><code>summary.txt</code></td><td>Plain-text summary with status counts.</td></tr>
      <tr><td><code>health-report.html</code></td><td>Compact HTML report.</td></tr>
      <tr><td><code>health-report.md</code></td><td>Markdown report with key snippets.</td></tr>
      <tr><td><code>raw/</code></td><td>Raw command output logs for each validation step.</td></tr>
      <tr><td><code>logs/</code></td><td>Optional problematic pod and core operator log tails.</td></tr>
      <tr><td><code>describes/</code></td><td>Optional pod describe outputs.</td></tr>
      <tr><td><code>command-index.tsv</code></td><td>Command execution index with return codes and timestamps.</td></tr>
      <tr><td><code>run.log</code></td><td>Script runtime progress log.</td></tr>
    </table>
  </section>
</main>
</body>
</html>
EOF_HTML

  rm -f "$SECTIONS_HTML" "$FINDINGS_HTML" "$FINDINGS_MD" 2>/dev/null || true

  log ""
  case "$OVERALL_STATUS" in
    HEALTHY) log "${GREEN}${BOLD}Overall status: ${OVERALL_STATUS}${RESET}" ;;
    WARNING) log "${YELLOW}${BOLD}Overall status: ${OVERALL_STATUS}${RESET}" ;;
    CRITICAL) log "${RED}${BOLD}Overall status: ${OVERALL_STATUS}${RESET}" ;;
  esac
  log "HTML report: ${REPORT_HTML}"
  log "Summary: ${SUMMARY_TXT}"
  log "Raw command logs: ${RAW_DIR}"
  log "Pod/operator logs: ${LOG_DIR}"
}

main() {
  init_markdown
  validate_access
  cluster_baseline
  cluster_operators
  nodes_and_mcp
  workloads_and_pods
  core_namespaces
  network_ingress_dns
  storage_health
  olm_health
  events_and_alerts
  auth_cert_api_health
  optional_must_gather
  finalize_reports
}

main "$@"
