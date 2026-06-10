#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ocp418-deep-lib.sh
source "$SCRIPT_DIR/ocp418-deep-lib.sh"
parse_common_args "$@"
require_oc
init_run_dir "error-followup"
start_md "OpenShift 4.18+ Error Follow-up Deep Dive"

run_cmd "cluster_version" "oc get clusterversion version -o wide && oc get clusterversion version -o yaml"
run_cmd "clusteroperators_wide" "oc get clusteroperators -o wide"
run_cmd "clusteroperators_json" "oc get clusteroperators -o json"
run_cmd "nodes_and_mcp" "oc get nodes -o wide; echo; oc get mcp -o wide"
run_cmd "problematic_pods_json" "oc get pods -A -o json"
run_cmd "problematic_pods_table" "oc get pods -A --field-selector=status.phase!=Running -o wide || true; echo; oc get pods -A --field-selector=status.phase=Running -o wide | awk 'NR==1 || \$5+0 >= ${RESTART_THRESHOLD}' || true"
run_cmd "deployments_unavailable" "oc get deploy -A -o jsonpath='{range .items[?(@.status.availableReplicas<@.spec.replicas)]}{.metadata.namespace}{\"\\t\"}{.metadata.name}{\"\\t\"}{.status.availableReplicas}{\"/\"}{.spec.replicas}{\"\\t\"}{.status.conditions[*].type}{\"\\t\"}{.status.conditions[*].message}{\"\\n\"}{end}' 2>/dev/null || true"
run_cmd "replicasets_current_failures" "oc get rs -A -o wide | awk 'NR==1 || \$3 != \$4 || \$4 != \$5' || true"
run_cmd "jobs_recent_failures" "oc get jobs -A -o jsonpath='{range .items[?(@.status.failed>0)]}{.metadata.namespace}{\"\\t\"}{.metadata.name}{\"\\tfailed=\"}{.status.failed}{\"\\tsucceeded=\"}{.status.succeeded}{\"\\tcompletions=\"}{.spec.completions}{\"\\n\"}{end}' 2>/dev/null || true"
run_cmd "events_warning_sorted" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -n ${MAX_OBJECTS_PER_SECTION} || true"
run_cmd "olm_installplans_subscriptions_csvs" "oc get subscriptions.operators.coreos.com,installplans.operators.coreos.com,csv -A -o wide 2>/dev/null || true"
run_cmd "cert_signing_requests" "oc get csr -o wide 2>/dev/null || true"
run_cmd "apiservices_not_available" "oc get apiservices -o jsonpath='{range .items[?(@.status.conditions[0].status!=\"True\")]}{.metadata.name}{\"\\t\"}{.status.conditions[*].type}{\"\\t\"}{.status.conditions[*].status}{\"\\t\"}{.status.conditions[*].message}{\"\\n\"}{end}' 2>/dev/null || true"
run_cmd "services_without_ready_endpoints" "for ns in \$(oc get ns --no-headers | awk '{print \$1}'); do oc -n \$ns get svc -o name 2>/dev/null | while read s; do name=\${s#service/}; ep=\$(oc -n \$ns get endpoints \$name -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true); type=\$(oc -n \$ns get svc \$name -o jsonpath='{.spec.type}' 2>/dev/null || true); [[ -z \"\$ep\" && \"\$type\" != \"ExternalName\" ]] && echo -e \"\$ns\\t\$name\\t\$type\\tno_ready_endpoints\"; done; done | sed -n '1,${MAX_OBJECTS_PER_SECTION}p'"
run_cmd "workload_resilience_gaps" "oc get deploy,statefulset -A -o json | jq -r '.items[] | [.kind,.metadata.namespace,.metadata.name,(.spec.replicas//1),((.spec.template.spec.containers[]?.readinessProbe? // empty)|tostring),((.spec.template.spec.topologySpreadConstraints//[])|length),((.spec.template.spec.affinity.podAntiAffinity//{})|tostring)] | @tsv' 2>/dev/null || true"

# Build focused pod owner and describe/log data for failing pods.
if has_jq; then
  oc get pods -A -o json | jq -r --argjson threshold "$RESTART_THRESHOLD" '
    .items[] |
    . as $p |
    ([.status.containerStatuses[]?.restartCount] | add // 0) as $restarts |
    ([.status.containerStatuses[]?.state.waiting.reason, .status.containerStatuses[]?.lastState.terminated.reason, .status.reason] | map(select(.!=null)) | join(",")) as $reasons |
    select(.status.phase != "Running" or $restarts >= $threshold or ($reasons|test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|Evicted"))) |
    [.metadata.namespace,.metadata.name,.status.phase,($restarts|tostring),$reasons, (.status.message//"")] | @tsv' | sed -n "1,${MAX_OBJECTS_PER_SECTION}p" > "$CSV_DIR/problematic-pods.tsv" || true
  printf 'namespace,pod,phase,restarts,reasons,message\n' > "$CSV_DIR/problematic-pods.csv"
  awk 'BEGIN{FS="\t"; OFS=","} {for(i=1;i<=6;i++){gsub(/"/,"""",$i); printf "\"%s\"%s",$i,(i==6?"\n":",")}}' "$CSV_DIR/problematic-pods.tsv" >> "$CSV_DIR/problematic-pods.csv"
  count=$(wc -l < "$CSV_DIR/problematic-pods.tsv" | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    add_finding "Critical" "Workload Health" "Detected ${count} problematic pod records" "$CSV_DIR/problematic-pods.csv" "Failed pods, high restarts, evictions or image errors can mask platform or application readiness issues and can degrade application reliability." "Review the pod records by namespace and owner, fix repeated evictions or restart loops first, then validate deployment rollout and service endpoint readiness."
  fi
  while IFS=$'\t' read -r ns pod phase restarts reasons message; do
    [[ -z "${ns:-}" || -z "${pod:-}" ]] && continue
    safe="$(safe_name "${ns}_${pod}")"
    oc -n "$ns" describe pod "$pod" > "$DESC_DIR/${safe}.txt" 2>&1 || true
    redact_file "$DESC_DIR/${safe}.txt"
    if [[ "$COLLECT_LOGS" == "true" ]]; then
      oc -n "$ns" logs "$pod" --all-containers --tail="$LOG_TAIL_LINES" > "$LOG_DIR/${safe}.log" 2>&1 || true
      redact_file "$LOG_DIR/${safe}.log"
    fi
  done < <(sed -n '1,30p' "$CSV_DIR/problematic-pods.tsv")
else
  log "jq not available; skipping structured pod follow-up."
fi

append_md_section "Cluster Version" "$RAW_DIR/cluster_version.txt"
append_md_section "ClusterOperators" "$RAW_DIR/clusteroperators_wide.txt"
append_md_section "Problematic Pods" "$CSV_DIR/problematic-pods.tsv"
append_md_section "Deployments with Unavailable Replicas" "$RAW_DIR/deployments_unavailable.txt"
append_md_section "Services without Ready Endpoints" "$RAW_DIR/services_without_ready_endpoints.txt"
append_md_section "Warning Events" "$RAW_DIR/events_warning_sorted.txt"
append_md_section "OLM State" "$RAW_DIR/olm_installplans_subscriptions_csvs.txt"
append_md_section "Certificate Signing Requests" "$RAW_DIR/cert_signing_requests.txt"
finish_md
generate_html_from_md
log "Done. Report: $HTML_REPORT"
echo "$RUN_DIR"
