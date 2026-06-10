#!/usr/bin/env bash
set -o pipefail

SCRIPT_VERSION="1.0.0"
: "${CLUSTER_NAME_HINT:=ocp-cluster}"
: "${ENGAGEMENT_NAME:=OpenShift Health Check Deep Dive}"
: "${CLIENT_LABEL:=Client}"
: "${REPORT_OWNER:=Red Hat Consulting}"
: "${OUTPUT_BASE_DIR:=./ocp-deep-healthcheck-runs}"
: "${TIMEOUT_SECONDS:=180}"
: "${COLLECT_LOGS:=true}"
: "${LOG_TAIL_LINES:=500}"
: "${MAX_OBJECTS_PER_SECTION:=300}"
: "${SANITIZE_OUTPUT:=true}"
: "${REDACTION_PATTERNS_FILE:=./redaction-patterns.txt}"
: "${TARGET_NAMESPACES:=}"
: "${AI_NAMESPACE_REGEX:=ai|aiops|watson|model|ml|rhods|redhat-ods|open-data-hub|llm|inference|ray|odh}"
: "${NETWORK_NAMESPACE_REGEX:=openshift-ingress|openshift-dns|openshift-network|metallb|nmstate|sriov|ovn|multus}"
: "${STORAGE_NAMESPACE_REGEX:=openshift-storage|portworx|openshift-local-storage|openshift-monitoring|openshift-image-registry|openshift-cnv}"
: "${RESTART_THRESHOLD:=10}"
: "${EPHEMERAL_EVICTION_CRITICAL_THRESHOLD:=5}"
: "${UNAVAILABLE_DEPLOYMENT_CRITICAL_THRESHOLD:=3}"
: "${PVC_PENDING_CRITICAL_THRESHOLD:=1}"
: "${WARNING_EVENT_THRESHOLD:=20}"
: "${CERT_WARNING_DAYS:=30}"
: "${RUN_PROMETHEUS_QUERIES:=true}"
: "${COLLECT_NODE_DEBUG_COMMANDS:=false}"

usage_common() {
  cat <<USAGE
Common options:
  --env-file FILE           Load variable file before execution
  --cluster-name NAME       Set logical cluster name for reports
  --output DIR              Set output base directory or run directory
  --target-namespaces LIST  Comma-separated namespaces to focus on
  --no-sanitize             Disable regex-based redaction in generated files
  --help                    Show help
USAGE
}

load_env_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$f"; set +a
  else
    echo "ERROR: env file not found: $f" >&2
    exit 2
  fi
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file) load_env_file "$2"; shift 2;;
      --cluster-name) CLUSTER_NAME_HINT="$2"; shift 2;;
      --output) OUTPUT_BASE_DIR="$2"; shift 2;;
      --target-namespaces) TARGET_NAMESPACES="$2"; shift 2;;
      --no-sanitize) SANITIZE_OUTPUT="false"; shift;;
      --help|-h) usage_common; exit 0;;
      *) echo "ERROR: unknown argument: $1" >&2; usage_common; exit 2;;
    esac
  done
}

init_run_dir() {
  local prefix="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OUTPUT_BASE_DIR"
  RUN_DIR="$OUTPUT_BASE_DIR/${prefix}-${CLUSTER_NAME_HINT}-${ts}"
  RAW_DIR="$RUN_DIR/raw"
  LOG_DIR="$RUN_DIR/logs"
  DESC_DIR="$RUN_DIR/describes"
  CSV_DIR="$RUN_DIR/csv"
  REPORT_DIR="$RUN_DIR/report"
  mkdir -p "$RAW_DIR" "$LOG_DIR" "$DESC_DIR" "$CSV_DIR" "$REPORT_DIR"
  RUN_LOG="$RUN_DIR/run.log"
  MD_REPORT="$REPORT_DIR/report.md"
  HTML_REPORT="$REPORT_DIR/report.html"
  FINDINGS_CSV="$CSV_DIR/findings.csv"
  EVIDENCE_CSV="$CSV_DIR/evidence-index.csv"
  printf 'severity,category,finding,evidence,risk,recommendation\n' > "$FINDINGS_CSV"
  printf 'section,description,path\n' > "$EVIDENCE_CSV"
}

log() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$RUN_LOG" >&2; }

require_oc() {
  if ! command -v oc >/dev/null 2>&1; then
    echo "ERROR: oc CLI not found in PATH" >&2
    exit 3
  fi
  if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: oc is not logged in or the current user cannot reach the cluster" >&2
    exit 4
  fi
}

has_jq() { command -v jq >/dev/null 2>&1; }

safe_name() {
  echo "$*" | sed -E 's#[^A-Za-z0-9_.-]+#_#g; s#_+#_#g; s#^_+|_+$##g'
}

redact_file() {
  local f="$1"
  [[ "$SANITIZE_OUTPUT" == "true" ]] || return 0
  [[ -f "$f" ]] || return 0
  [[ -f "$REDACTION_PATTERNS_FILE" ]] || return 0
  local tmp="${f}.redacted"
  cp "$f" "$tmp"
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
    perl -0777 -pe "s/${pattern}/[REDACTED]/g" -i "$tmp" 2>/dev/null || true
  done < "$REDACTION_PATTERNS_FILE"
  mv "$tmp" "$f"
}

run_cmd() {
  local label="$1"; shift
  local outfile="$RAW_DIR/$(safe_name "$label").txt"
  log "Collecting: $label"
  {
    echo "# Label: $label"
    echo "# Command: $*"
    echo "# Started: $(date -Is)"
    echo
    timeout "${TIMEOUT_SECONDS}s" bash -lc "$*"
    rc=$?
    echo
    echo "# Finished: $(date -Is)"
    echo "# Return code: $rc"
    exit 0
  } > "$outfile" 2>&1
  redact_file "$outfile"
  printf '"%s","%s","%s"\n' "raw" "$label" "$outfile" >> "$EVIDENCE_CSV"
  echo "$outfile"
}

csv_escape() {
  local s="$*"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

add_finding() {
  local severity="$1" category="$2" finding="$3" evidence="$4" risk="$5" recommendation="$6"
  {
    csv_escape "$severity"; printf ','
    csv_escape "$category"; printf ','
    csv_escape "$finding"; printf ','
    csv_escape "$evidence"; printf ','
    csv_escape "$risk"; printf ','
    csv_escape "$recommendation"; printf '\n'
  } >> "$FINDINGS_CSV"
}

start_md() {
  local title="$1"
  cat > "$MD_REPORT" <<MD
# $title

- Generated: $(date -Is)
- Script version: $SCRIPT_VERSION
- Cluster: $CLUSTER_NAME_HINT
- Engagement: $ENGAGEMENT_NAME
- Client label: $CLIENT_LABEL
- Owner: $REPORT_OWNER
- Output directory: $RUN_DIR

## Executive Summary

This report was generated through read-only OpenShift CLI collection. It is intended to provide technical evidence for Health Check analysis, findings, risk explanation, and remediation planning.

MD
}

append_md_section() {
  local heading="$1" file="$2"
  {
    echo
    echo "## $heading"
    echo
    if [[ -f "$file" ]]; then
      echo '```text'
      sed -n '1,250p' "$file"
      echo '```'
    else
      echo "No evidence file generated."
    fi
  } >> "$MD_REPORT"
}

finish_md() {
  {
    echo
    echo "## Findings Register"
    echo
    echo "The CSV finding register is available at: $FINDINGS_CSV"
    echo
    if command -v column >/dev/null 2>&1; then
      echo '```text'
      column -s, -t < "$FINDINGS_CSV" | sed -n '1,60p'
      echo '```'
    else
      echo '```text'
      sed -n '1,60p' "$FINDINGS_CSV"
      echo '```'
    fi
    echo
    echo "## Evidence Index"
    echo
    echo "Evidence index CSV: $EVIDENCE_CSV"
  } >> "$MD_REPORT"
  redact_file "$MD_REPORT"
}

html_escape_file() {
  python3 - "$1" <<'PY'
import html, sys
print(html.escape(open(sys.argv[1], errors='replace').read()))
PY
}

generate_html_from_md() {
  python3 - "$MD_REPORT" "$HTML_REPORT" <<'PY'
import html, re, sys
md_path, html_path = sys.argv[1], sys.argv[2]
text = open(md_path, errors='replace').read().splitlines()
out=[]; in_code=False; buf=[]
for line in text:
    if line.startswith('```'):
        if not in_code:
            in_code=True; buf=[]
        else:
            out.append('<pre><code>'+html.escape('\n'.join(buf))+'</code></pre>')
            in_code=False
        continue
    if in_code:
        buf.append(line); continue
    if line.startswith('# '): out.append(f'<h1>{html.escape(line[2:])}</h1>')
    elif line.startswith('## '): out.append(f'<h2>{html.escape(line[3:])}</h2>')
    elif line.startswith('### '): out.append(f'<h3>{html.escape(line[4:])}</h3>')
    elif line.startswith('- '): out.append(f'<li>{html.escape(line[2:])}</li>')
    elif line.strip() == '': out.append('')
    else: out.append(f'<p>{html.escape(line)}</p>')
css='''<style>body{font-family:Arial,Helvetica,sans-serif;margin:32px;line-height:1.45;color:#222}h1{border-bottom:3px solid #cc0000;padding-bottom:8px}h2{margin-top:28px;border-bottom:1px solid #ddd;padding-bottom:4px}pre{background:#f6f6f6;border:1px solid #ddd;padding:12px;overflow:auto;font-size:12px}code{font-family:Consolas,monospace}li{margin:4px 0}.meta{color:#555}</style>'''
open(html_path,'w').write('<!doctype html><html><head><meta charset="utf-8"><title>OpenShift Health Check Deep Dive</title>'+css+'</head><body>'+'\n'.join(out)+'</body></html>')
PY
  redact_file "$HTML_REPORT"
}

collect_namespace_list() {
  if [[ -n "$TARGET_NAMESPACES" ]]; then
    echo "$TARGET_NAMESPACES" | tr ',' '\n' | sed '/^$/d'
  else
    oc get ns --no-headers 2>/dev/null | awk '{print $1}' | sed -n "1,${MAX_OBJECTS_PER_SECTION}p"
  fi
}

collect_namespaces_matching() {
  local regex="$1"
  if [[ -n "$TARGET_NAMESPACES" ]]; then
    echo "$TARGET_NAMESPACES" | tr ',' '\n' | sed '/^$/d'
  else
    oc get ns --no-headers 2>/dev/null | awk '{print $1}' | grep -Ei "$regex" | sed -n "1,${MAX_OBJECTS_PER_SECTION}p" || true
  fi
}

prom_query() {
  local name="$1" query="$2"
  [[ "$RUN_PROMETHEUS_QUERIES" == "true" ]] || return 0
  local encoded
  encoded="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote('''$query'''))
PY
)"
  run_cmd "prometheus_${name}" "oc -n openshift-monitoring exec deploy/prometheus-adapter -- true >/dev/null 2>&1; oc get --raw '/api/v1/namespaces/openshift-monitoring/services/https:prometheus-k8s:9091/proxy/api/v1/query?query=${encoded}' 2>/dev/null || true"
}
