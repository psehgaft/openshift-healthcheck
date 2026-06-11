#!/usr/bin/env bash
set -o pipefail

SCRIPT_VERSION="2.0.0"
: "${CLUSTER_NAME_HINT:=ocp-cluster}"
: "${CLIENT_LABEL:=Client}"
: "${ENGAGEMENT_NAME:=OpenShift Health Check}"
: "${OUTPUT_BASE_DIR:=./ocp-healthcheck-runs}"
: "${TIMEOUT_SECONDS:=180}"
: "${RUN_MUST_GATHER:=true}"
: "${MUST_GATHER_TIMEOUT_SECONDS:=7200}"
: "${COLLECT_ALL_API_RESOURCES:=true}"
: "${COLLECT_ALL_CRD_DEFINITIONS:=true}"
: "${COLLECT_ALL_CRD_INSTANCES:=true}"
: "${COLLECT_NAMESPACES_DEEP:=true}"
: "${COLLECT_PROBLEM_POD_LOGS:=true}"
: "${COLLECT_DESCRIBES:=true}"
: "${COLLECT_EVENTS:=true}"
: "${COLLECT_PROMETHEUS:=true}"
: "${COLLECT_AI_WORKLOADS:=true}"
: "${COLLECT_STORAGE_DEEP:=true}"
: "${COLLECT_NETWORK_DEEP:=true}"
: "${COLLECT_SECURITY_DEEP:=true}"
: "${TARGET_NAMESPACES:=}"
: "${EXCLUDE_NAMESPACES_REGEX:=^$}"
: "${INCLUDE_SYSTEM_NAMESPACES:=true}"
: "${LOG_TAIL_LINES:=500}"
: "${MAX_PROBLEM_PODS:=80}"
: "${RESTART_THRESHOLD:=10}"
: "${WARNING_EVENT_LIMIT:=1000}"
: "${MAX_RESOURCE_LISTS:=10000}"
: "${SANITIZE_OUTPUT:=true}"
: "${REDACTION_PATTERNS_FILE:=./redaction-patterns.txt}"
: "${AI_NAMESPACE_REGEX:=ai|aiops|watson|model|ml|rhods|redhat-ods|open-data-hub|llm|inference|ray|odh|kserve|serving}"
: "${EPHEMERAL_EVICTION_CRITICAL_THRESHOLD:=5}"
: "${UNAVAILABLE_DEPLOYMENT_CRITICAL_THRESHOLD:=1}"
: "${PENDING_PVC_CRITICAL_THRESHOLD:=1}"
: "${SERVICE_NO_ENDPOINT_WARNING_THRESHOLD:=1}"
: "${NAMESPACE_BACKLOG_LIMIT:=20000}"

usage_common() {
  cat <<USAGE
Common options:
  --env-file FILE              Load variable file before execution
  --cluster-name NAME          Logical cluster name used in report file names
  --client-label NAME          Client/report label
  --output DIR                 Output base directory
  --target-namespaces LIST     Comma-separated namespaces for namespace/app/AI deep review
  --must-gather                Force must-gather collection
  --no-must-gather             Disable must-gather collection
  --include-system-ns          Include openshift-*, kube-* and default namespaces in namespace analysis
  --exclude-ns-regex REGEX     Exclude namespaces matching REGEX from namespace analysis
  --no-sanitize                Disable redaction
  --help                       Show help
USAGE
}

load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: env file not found: $f" >&2; exit 2; }
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file) load_env_file "$2"; shift 2;;
      --cluster-name) CLUSTER_NAME_HINT="$2"; shift 2;;
      --client-label) CLIENT_LABEL="$2"; shift 2;;
      --output) OUTPUT_BASE_DIR="$2"; shift 2;;
      --target-namespaces) TARGET_NAMESPACES="$2"; shift 2;;
      --must-gather) RUN_MUST_GATHER="true"; shift;;
      --no-must-gather) RUN_MUST_GATHER="false"; shift;;
      --include-system-ns) INCLUDE_SYSTEM_NAMESPACES="true"; shift;;
      --exclude-ns-regex) EXCLUDE_NAMESPACES_REGEX="$2"; shift 2;;
      --no-sanitize) SANITIZE_OUTPUT="false"; shift;;
      --help|-h) usage_common; exit 0;;
      *) echo "ERROR: unknown argument: $1" >&2; usage_common; exit 2;;
    esac
  done
}

safe_name() { echo "$*" | sed -E 's#[^A-Za-z0-9_.-]+#_#g; s#_+#_#g; s#^_+|_+$##g'; }
now_ts() { date +%Y%m%d-%H%M%S; }
log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${RUN_LOG:-/dev/null}" >&2; }
has_jq() { command -v jq >/dev/null 2>&1; }
has_python3() { command -v python3 >/dev/null 2>&1; }

csv_escape() {
  local s="$*"
  s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

csv_row() {
  local first=true field
  for field in "$@"; do
    [[ "$first" == true ]] || printf ','
    csv_escape "$field"
    first=false
  done
  printf '\n'
}

redact_file() {
  local f="$1"
  [[ "${SANITIZE_OUTPUT}" == "true" ]] || return 0
  [[ -f "$f" ]] || return 0
  [[ -f "${REDACTION_PATTERNS_FILE}" ]] || return 0
  local tmp="${f}.redacted"
  cp "$f" "$tmp" || return 0
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
    perl -0777 -pe "s/${pattern}/[REDACTED]/g" -i "$tmp" 2>/dev/null || true
  done < "${REDACTION_PATTERNS_FILE}"
  mv "$tmp" "$f"
}

require_oc() {
  command -v oc >/dev/null 2>&1 || { echo "ERROR: oc CLI not found" >&2; exit 3; }
  oc whoami >/dev/null 2>&1 || { echo "ERROR: oc is not logged in or cannot reach the cluster" >&2; exit 4; }
}

init_run_dir() {
  local prefix="${1:-full-healthcheck}"
  local ts="$(now_ts)"
  mkdir -p "$OUTPUT_BASE_DIR"
  RUN_DIR="$OUTPUT_BASE_DIR/${prefix}-${CLUSTER_NAME_HINT}-${ts}"
  RAW_DIR="$RUN_DIR/raw"
  LOG_DIR="$RUN_DIR/logs"
  DESC_DIR="$RUN_DIR/describes"
  REPORT_DIR="$RUN_DIR/report"
  CSV_DIR="$RUN_DIR/csv"
  MUST_GATHER_DIR="$RUN_DIR/must-gather"
  TMP_DIR="$RUN_DIR/tmp"
  mkdir -p "$RAW_DIR" "$LOG_DIR" "$DESC_DIR" "$REPORT_DIR" "$CSV_DIR" "$MUST_GATHER_DIR" "$TMP_DIR"
  RUN_LOG="$RUN_DIR/run.log"
  COMMAND_INDEX="$RUN_DIR/command-index.tsv"
  SUMMARY_TXT="$RUN_DIR/summary.txt"
  HEALTH_MD="$RUN_DIR/health-report.md"
  HEALTH_HTML="$RUN_DIR/health-report.html"
  FINDINGS_CSV="$CSV_DIR/findings.csv"
  BACKLOG_CSV="$CSV_DIR/backlog.csv"
  ERRORS_CSV="$CSV_DIR/errors-criticality.csv"
  NAMESPACE_REVIEW_CSV="$CSV_DIR/namespace-review.csv"
  WORKLOAD_REVIEW_CSV="$CSV_DIR/workload-review.csv"
  EVIDENCE_CSV="$CSV_DIR/evidence-index.csv"
  printf 'timestamp\tsection\tdescription\tcommand\tpath\n' > "$COMMAND_INDEX"
  csv_row severity category finding evidence risk recommendation > "$FINDINGS_CSV"
  csv_row priority severity likelihood complexity category namespace object action rationale remediation owner status evidence > "$BACKLOG_CSV"
  csv_row severity criticality_reason category namespace object symptom explanation remediation evidence > "$ERRORS_CSV"
  csv_row namespace status labels quotas limitranges networkpolicies secrets configmaps deployments statefulsets daemonsets pods services routes recommendations > "$NAMESPACE_REVIEW_CSV"
  csv_row namespace kind name replicas ready containers has_requests has_limits has_probes has_pdb has_hpa services routes recommendations > "$WORKLOAD_REVIEW_CSV"
  csv_row section description path > "$EVIDENCE_CSV"
  echo "Run directory: $RUN_DIR" > "$RUN_LOG"
}

run_cmd() {
  local section="$1" label="$2"; shift 2
  local cmd="$*"
  local outfile="$RAW_DIR/$(safe_name "$section-$label").txt"
  log "Collecting [$section] $label"
  {
    echo "# Section: $section"
    echo "# Label: $label"
    echo "# Command: $cmd"
    echo "# Started: $(date -Is)"
    echo
    timeout "${TIMEOUT_SECONDS}s" bash -lc "$cmd"
    rc=$?
    echo
    echo "# Finished: $(date -Is)"
    echo "# Return code: $rc"
  } > "$outfile" 2>&1 || true
  redact_file "$outfile"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$section" "$label" "$cmd" "$outfile" >> "$COMMAND_INDEX"
  csv_row "$section" "$label" "$outfile" >> "$EVIDENCE_CSV"
  echo "$outfile"
}

run_json() {
  local section="$1" label="$2"; shift 2
  local cmd="$*"
  local outfile="$RAW_DIR/$(safe_name "$section-$label").json"
  log "Collecting JSON [$section] $label"
  timeout "${TIMEOUT_SECONDS}s" bash -lc "$cmd" > "$outfile" 2>"${outfile}.err" || true
  redact_file "$outfile"; redact_file "${outfile}.err"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$section" "$label" "$cmd" "$outfile" >> "$COMMAND_INDEX"
  csv_row "$section" "$label" "$outfile" >> "$EVIDENCE_CSV"
  echo "$outfile"
}

add_finding() { csv_row "$@" >> "$FINDINGS_CSV"; }
add_error() { csv_row "$@" >> "$ERRORS_CSV"; }
add_backlog() { csv_row "$@" >> "$BACKLOG_CSV"; }

get_namespaces() {
  if [[ -n "$TARGET_NAMESPACES" ]]; then
    echo "$TARGET_NAMESPACES" | tr ',' '\n' | sed '/^$/d'
    return 0
  fi
  oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | while read -r ns; do
    [[ -z "$ns" ]] && continue
    if [[ "$INCLUDE_SYSTEM_NAMESPACES" != "true" && "$ns" =~ ^(openshift|kube)-|^default$ ]]; then continue; fi
    if [[ -n "$EXCLUDE_NAMESPACES_REGEX" && ! "$EXCLUDE_NAMESPACES_REGEX" == "^$" && "$ns" =~ $EXCLUDE_NAMESPACES_REGEX ]]; then continue; fi
    echo "$ns"
  done
}

write_basic_summary() {
  {
    echo "OpenShift Health Check Summary"
    echo "Generated: $(date -Is)"
    echo "Cluster: $CLUSTER_NAME_HINT"
    echo "Client label: $CLIENT_LABEL"
    echo "Run directory: $RUN_DIR"
    echo
    echo "Main outputs:"
    echo "- health-report.html"
    echo "- health-report.md"
    echo "- report/report-${CLUSTER_NAME_HINT}.html"
    echo "- report/errors-${CLUSTER_NAME_HINT}.html"
    echo "- report/cer-fill-sections.md"
    echo "- csv/findings.csv"
    echo "- csv/backlog.csv"
    echo "- csv/errors-criticality.csv"
    echo "- command-index.tsv"
    echo "- run.log"
    echo "- raw/"
    echo "- logs/"
    echo "- describes/"
    echo "- must-gather/"
  } > "$SUMMARY_TXT"
}
