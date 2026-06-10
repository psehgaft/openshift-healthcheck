#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ocp418-deep-lib.sh
source "$SCRIPT_DIR/ocp418-deep-lib.sh"
parse_common_args "$@"
require_oc
init_run_dir "ai-workloads-deep-dive"
start_md "OpenShift 4.18+ AI Workloads Deep Dive"

mapfile -t NS_LIST < <(collect_namespaces_matching "$AI_NAMESPACE_REGEX")
if [[ ${#NS_LIST[@]} -eq 0 ]]; then
  log "No AI-like namespaces matched regex: $AI_NAMESPACE_REGEX. Collecting OpenShift AI namespaces if present."
  mapfile -t NS_LIST < <(oc get ns --no-headers 2>/dev/null | awk '{print $1}' | grep -Ei 'redhat-ods|rhods|open-data-hub' || true)
fi
printf '%s\n' "${NS_LIST[@]:-}" > "$CSV_DIR/target-namespaces.txt"

run_cmd "ai_target_namespaces" "printf '%s\n' ${NS_LIST[*]:-}"
run_cmd "ai_related_operators" "oc get subscriptions,csv,installplans -A -o wide 2>/dev/null | grep -Ei '${AI_NAMESPACE_REGEX}|model|serving|odh|rhods|data-science|ray|gpu|nvidia|serverless' || true"
run_cmd "gpu_nodes_and_resources" "oc get nodes -L nvidia.com/gpu.present,node-role.kubernetes.io/gpu -o wide 2>/dev/null || oc get nodes -o wide; echo; oc describe nodes | grep -Ei 'Name:|nvidia.com/gpu|amd.com/gpu|habana.ai|Capacity:|Allocatable:' -A8 || true"
run_cmd "nvidia_gpu_operator" "oc get ns nvidia-gpu-operator >/dev/null 2>&1 && oc get all -n nvidia-gpu-operator -o wide || true; oc get clusterpolicy,nvidiadriver,nvidiagpudriver -A -o yaml 2>/dev/null || true"
run_cmd "serving_and_model_resources" "oc get servingruntime,inferenceservice,notebook,dataconnection,dscinitialization,datasciencecluster,raycluster -A -o wide 2>/dev/null || true"
run_cmd "ai_events_warning" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp | grep -Ei '${AI_NAMESPACE_REGEX}|gpu|model|serving|inference|ray|notebook|evicted|ephemeral|probe|endpoint|pvc|quota|limit' | tail -n ${MAX_OBJECTS_PER_SECTION} || true"

: > "$CSV_DIR/ai-pods.tsv"
: > "$CSV_DIR/ai-workloads.tsv"
: > "$CSV_DIR/ai-services-without-endpoints.tsv"
: > "$CSV_DIR/ai-pvc.tsv"
: > "$CSV_DIR/ai-quota-limits.tsv"
for ns in "${NS_LIST[@]}"; do
  [[ -z "$ns" ]] && continue
  run_cmd "ai_${ns}_pods" "oc -n '$ns' get pods -o wide; echo; oc -n '$ns' get pods -o json"
  run_cmd "ai_${ns}_workloads" "oc -n '$ns' get deploy,statefulset,daemonset,job,cronjob -o wide 2>/dev/null || true; echo; oc -n '$ns' get deploy,statefulset,daemonset,job,cronjob -o yaml 2>/dev/null || true"
  run_cmd "ai_${ns}_services_routes" "oc -n '$ns' get svc,route,endpoints,endpointslice -o wide 2>/dev/null || true"
  run_cmd "ai_${ns}_storage" "oc -n '$ns' get pvc,pv -o wide 2>/dev/null || true"
  run_cmd "ai_${ns}_quota_limits_pdb_hpa" "oc -n '$ns' get resourcequota,limitrange,pdb,hpa,vpa -o wide 2>/dev/null || true; echo; oc -n '$ns' get resourcequota,limitrange,pdb,hpa,vpa -o yaml 2>/dev/null || true"
  if has_jq; then
    oc -n "$ns" get pods -o json 2>/dev/null | jq -r --arg ns "$ns" '
      .items[] | [.metadata.namespace,.metadata.name,.status.phase,([.status.containerStatuses[]?.restartCount]|add//0),([.status.containerStatuses[]?.state.waiting.reason,.status.containerStatuses[]?.lastState.terminated.reason,.status.reason]|map(select(.!=null))|join("|")),(.status.message//""),(.spec.nodeName//""),([.spec.containers[]?.resources.requests["ephemeral-storage"]//""]|join("+")),([.spec.containers[]?.resources.limits["ephemeral-storage"]//""]|join("+"))] | @tsv' >> "$CSV_DIR/ai-pods.tsv" || true
    oc -n "$ns" get deploy,statefulset -o json 2>/dev/null | jq -r '.items[] | [.kind,.metadata.namespace,.metadata.name,(.spec.replicas//1),(.status.availableReplicas//0),([.spec.template.spec.containers[]?.readinessProbe?]|length),([.spec.template.spec.containers[]?.livenessProbe?]|length),((.spec.template.spec.topologySpreadConstraints//[])|length)] | @tsv' >> "$CSV_DIR/ai-workloads.tsv" || true
  fi
  oc -n "$ns" get svc -o name 2>/dev/null | while read -r svc; do
    name="${svc#service/}"
    ep="$(oc -n "$ns" get endpoints "$name" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    type="$(oc -n "$ns" get svc "$name" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
    [[ -z "$ep" && "$type" != "ExternalName" ]] && echo -e "$ns\t$name\t$type\tno_ready_endpoints" >> "$CSV_DIR/ai-services-without-endpoints.tsv"
  done
  oc -n "$ns" get pvc -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null >> "$CSV_DIR/ai-pvc.tsv" || true
  oc -n "$ns" get resourcequota,limitrange,pdb,hpa -o name 2>/dev/null | sed "s#^#${ns}\t#" >> "$CSV_DIR/ai-quota-limits.tsv" || true
done

# CSV headers
printf 'namespace,pod,phase,restarts,reasons,message,node,ephemeral_request,ephemeral_limit\n' > "$CSV_DIR/ai-pods.csv"
awk 'BEGIN{FS="\t"} {for(i=1;i<=9;i++){gsub(/"/,"""",$i); printf "\"%s\"%s",$i,(i==9?"\n":",")}}' "$CSV_DIR/ai-pods.tsv" >> "$CSV_DIR/ai-pods.csv" || true
printf 'kind,namespace,name,replicas,available,readiness_probe_count,liveness_probe_count,topology_spread_count\n' > "$CSV_DIR/ai-workloads.csv"
awk 'BEGIN{FS="\t"} {for(i=1;i<=8;i++){gsub(/"/,"""",$i); printf "\"%s\"%s",$i,(i==8?"\n":",")}}' "$CSV_DIR/ai-workloads.tsv" >> "$CSV_DIR/ai-workloads.csv" || true

if grep -Eiq 'Evicted|ephemeral local storage' "$CSV_DIR/ai-pods.tsv" "$RAW_DIR/ai_events_warning.txt" 2>/dev/null; then
  evictions=$(grep -Eic 'Evicted|ephemeral local storage' "$CSV_DIR/ai-pods.tsv" "$RAW_DIR/ai_events_warning.txt" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
  add_finding "Critical" "AI Workloads" "Detected AI workload evictions or ephemeral-storage pressure" "$CSV_DIR/ai-pods.csv" "AI workloads can fail or restart repeatedly when ephemeral-storage limits are undersized for model, cache, temporary, or batch processing data." "Increase or right-size ephemeral-storage requests and limits, move durable/intermediate data to PVC-backed paths, and define cleanup policies for cron jobs and batch workloads."
fi
if [[ -s "$CSV_DIR/ai-services-without-endpoints.tsv" ]]; then
  add_finding "Severe" "AI Workloads" "AI workload Services without ready endpoints detected" "$CSV_DIR/ai-services-without-endpoints.tsv" "Services without ready endpoints cause failed access paths and can be misdiagnosed as ingress or DNS issues." "Restore backing workloads, adjust selectors, or remove stale services; validate readiness probes and route-to-service mappings."
fi
if grep -Eiq '0$|0\t' "$CSV_DIR/ai-workloads.tsv" 2>/dev/null; then
  add_finding "Severe" "AI Workloads" "AI workload deployment availability gaps detected" "$CSV_DIR/ai-workloads.csv" "Unavailable AI components can degrade application workflow, inference, orchestration, or UI access." "Review rollout state, pod events, quota, probes, node placement, and storage mounts for unavailable workloads."
fi

append_md_section "Target Namespaces" "$CSV_DIR/target-namespaces.txt"
append_md_section "AI Related Operators" "$RAW_DIR/ai_related_operators.txt"
append_md_section "GPU Nodes and Resources" "$RAW_DIR/gpu_nodes_and_resources.txt"
append_md_section "Serving and Model Resources" "$RAW_DIR/serving_and_model_resources.txt"
append_md_section "AI Pods Summary" "$CSV_DIR/ai-pods.tsv"
append_md_section "AI Workloads Summary" "$CSV_DIR/ai-workloads.tsv"
append_md_section "AI Services without Ready Endpoints" "$CSV_DIR/ai-services-without-endpoints.tsv"
append_md_section "AI Storage" "$CSV_DIR/ai-pvc.tsv"
append_md_section "AI Warning Events" "$RAW_DIR/ai_events_warning.txt"
finish_md
generate_html_from_md
log "Done. Report: $HTML_REPORT"
echo "$RUN_DIR"
