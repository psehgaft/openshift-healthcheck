#!/usr/bin/env bash
# Unified OpenShift 4.18+ full and deep Health Check collector.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ocp-healthcheck-lib.sh
source "$SCRIPT_DIR/lib/ocp-healthcheck-lib.sh"
parse_common_args "$@"
require_oc
init_run_dir "healthcheck"

log "Starting unified OpenShift health check for ${CLUSTER_NAME_HINT}"

collect_baseline() {
  log "Collecting cluster baseline"
  run_cmd baseline "oc-whoami" "oc whoami && oc whoami --show-server"
  run_cmd baseline "version" "oc version -o yaml || oc version"
  run_json baseline "clusterversion" "oc get clusterversion version -o json"
  run_cmd baseline "clusterversion-wide" "oc get clusterversion version -o wide"
  run_json baseline "infrastructure" "oc get infrastructure cluster -o json"
  run_json baseline "clusteroperators" "oc get clusteroperators -o json"
  run_cmd baseline "clusteroperators-wide" "oc get co"
  run_json baseline "nodes" "oc get nodes -o json"
  run_cmd baseline "nodes-wide" "oc get nodes -o wide"
  run_cmd baseline "nodes-top" "oc adm top nodes || true"
  run_json baseline "machineconfigpools" "oc get mcp -o json"
  run_cmd baseline "machineconfigpools-wide" "oc get mcp"
  run_cmd baseline "csr" "oc get csr || true"
  run_json baseline "apiservices" "oc get apiservice -o json || true"
  run_json baseline "namespaces" "oc get ns -o json"
  run_cmd baseline "projects" "oc projects || true"
}

collect_core_components() {
  log "Collecting core component evidence"
  for ns in openshift-apiserver openshift-authentication openshift-authentication-operator openshift-console openshift-controller-manager openshift-etcd openshift-kube-apiserver openshift-kube-controller-manager openshift-kube-scheduler openshift-monitoring openshift-ingress openshift-ingress-operator openshift-dns openshift-network-operator openshift-ovn-kubernetes openshift-machine-config-operator openshift-cluster-version; do
    run_cmd core "pods-${ns}" "oc get pods -n ${ns} -o wide --ignore-not-found || true"
    run_json core "pods-${ns}-json" "oc get pods -n ${ns} -o json --ignore-not-found || true"
    run_cmd core "events-${ns}" "oc get events -n ${ns} --sort-by=.lastTimestamp --ignore-not-found | tail -200 || true"
  done
  run_json core "operators-config" "oc get configs.operator.openshift.io -o json || true"
  run_json core "proxies" "oc get proxy cluster -o json || true"
  run_json core "dns-config" "oc get dns.operator/default -o json || true"
  run_json core "networks-config" "oc get network.config/cluster -o json || true"
  run_json core "ingresscontrollers" "oc get ingresscontroller -n openshift-ingress-operator -o json || true"
}

collect_storage() {
  [[ "$COLLECT_STORAGE_DEEP" == "true" ]] || return 0
  log "Collecting storage evidence"
  run_json storage "storageclasses" "oc get storageclass -o json || true"
  run_json storage "persistentvolumes" "oc get pv -o json || true"
  run_json storage "persistentvolumeclaims-all" "oc get pvc -A -o json || true"
  run_json storage "volumeattachments" "oc get volumeattachments -o json || true"
  run_json storage "csidrivers" "oc get csidrivers -o json || true"
  run_json storage "csinodes" "oc get csinodes -o json || true"
  run_json storage "image-registry-config" "oc get configs.imageregistry.operator.openshift.io/cluster -o json || true"
  run_json storage "monitoring-configmap" "oc get cm cluster-monitoring-config -n openshift-monitoring -o json || true"
  run_cmd storage "openshift-storage-all" "oc get all -n openshift-storage -o wide --ignore-not-found || true"
  run_json storage "odf-subscriptions" "oc get sub -A -o json | jq '[.items[] | select(.metadata.namespace|test(\"openshift-storage|odf\"))]' 2>/dev/null || true"
  run_cmd storage "storage-events" "oc get events -A --sort-by=.lastTimestamp | egrep -i 'pvc|persistent|volume|mount|attach|detach|ceph|odf|storage|csi|no space|disk|ephemeral' | tail -${WARNING_EVENT_LIMIT} || true"
}

collect_network() {
  [[ "$COLLECT_NETWORK_DEEP" == "true" ]] || return 0
  log "Collecting network evidence"
  run_json network "network-config" "oc get network.config/cluster -o json || true"
  run_json network "dns-config" "oc get dns.operator/default -o json || true"
  run_json network "ingresscontrollers" "oc get ingresscontroller -n openshift-ingress-operator -o json || true"
  run_json network "routes-all" "oc get routes -A -o json || true"
  run_json network "services-all" "oc get svc -A -o json || true"
  run_json network "endpoints-all" "oc get endpoints -A -o json || true"
  run_json network "endpointslices-all" "oc get endpointslices -A -o json || true"
  run_json network "networkpolicies-all" "oc get networkpolicy -A -o json || true"
  run_json network "adminnetworkpolicies" "oc get adminnetworkpolicy -A -o json || true"
  run_json network "egressfirewalls" "oc get egressfirewall -A -o json || true"
  run_json network "egressips" "oc get egressip -A -o json || true"
  run_json network "nad-all" "oc get network-attachment-definitions -A -o json || true"
  run_json network "nmstate" "oc get nmstate,nodenetworkconfigurationpolicy,nodenetworkstate -A -o json || true"
  run_json network "sriov" "oc get sriovnetworknodestates,sriovnetworknodepolicies,sriovnetworks -A -o json || true"
  run_cmd network "network-events" "oc get events -A --sort-by=.lastTimestamp | egrep -i 'dns|route|ingress|endpoint|network|egress|timeout|connection|probe|unhealthy|ovn|multus|sriov|mtu' | tail -${WARNING_EVENT_LIMIT} || true"
}

collect_olm_security_ai() {
  log "Collecting OLM, security and AI evidence"
  run_json olm "subscriptions" "oc get subscriptions -A -o json || true"
  run_json olm "csvs" "oc get csv -A -o json || true"
  run_json olm "installplans" "oc get installplans -A -o json || true"
  run_json olm "catalogsources" "oc get catalogsources -A -o json || true"
  run_json security "oauth" "oc get oauth cluster -o json || true"
  run_json security "scc" "oc get scc -o json || true"
  run_json security "clusterrolebindings" "oc get clusterrolebindings -o json || true"
  run_json security "secrets-metadata-all" "oc get secrets -A -o json | jq 'del(.items[].data)' 2>/dev/null || oc get secrets -A -o json || true"
  run_json security "etcd-encryption" "oc get apiserver cluster -o json || true"
  if [[ "$COLLECT_AI_WORKLOADS" == "true" ]]; then
    run_cmd ai "candidate-namespaces" "oc get ns -o name | egrep -i '${AI_NAMESPACE_REGEX}' || true"
    run_json ai "accelerator-nodes" "oc get nodes -o json | jq '[.items[] | {name:.metadata.name, labels:.metadata.labels, allocatable:.status.allocatable, capacity:.status.capacity}]' 2>/dev/null || oc get nodes -o json"
    run_json ai "serving-resources" "oc get inferenceservice,servingruntime,notebook,data-science-cluster,dscinitialization,kfdef -A -o json || true"
    run_json ai "gpu-operators" "oc get csv,subscriptions -A -o json | jq '[.items[] | select((.metadata.name|test(\"gpu|nvidia|accelerator|rhods|odh|serving|kserve|model|ai\";\"i\")) or (.spec.displayName // \"\" | test(\"gpu|nvidia|accelerator|rhods|odh|serving|kserve|model|ai\";\"i\")))]' 2>/dev/null || true"
  fi
}

collect_all_api_resources() {
  [[ "$COLLECT_ALL_API_RESOURCES" == "true" ]] || return 0
  log "Collecting all listable API resources. This can take time on large clusters."
  local list="$TMP_DIR/api-resources.txt"
  oc api-resources --verbs=list -o name 2>/dev/null | sort -u > "$list" || true
  cp "$list" "$RAW_DIR/api-resources-list.txt"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "api-resources" "api-resources-list" "oc api-resources --verbs=list -o name" "$RAW_DIR/api-resources-list.txt" >> "$COMMAND_INDEX"
  local res count=0
  while IFS= read -r res; do
    [[ -z "$res" ]] && continue
    count=$((count+1))
    [[ "$count" -gt "$MAX_RESOURCE_LISTS" ]] && { log "MAX_RESOURCE_LISTS reached: $MAX_RESOURCE_LISTS"; break; }
    local out="$RAW_DIR/api-resource-$(safe_name "$res").txt"
    timeout "${TIMEOUT_SECONDS}s" bash -lc "oc get ${res} -A -o wide --ignore-not-found 2>&1 || oc get ${res} -o wide --ignore-not-found 2>&1 || true" > "$out" 2>&1 || true
    redact_file "$out"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "api-resource" "$res" "oc get $res -A -o wide" "$out" >> "$COMMAND_INDEX"
  done < "$list"
}

collect_crds() {
  [[ "$COLLECT_ALL_CRD_DEFINITIONS" == "true" ]] && run_json crd "customresourcedefinitions" "oc get crd -o json || true"
  [[ "$COLLECT_ALL_CRD_INSTANCES" == "true" ]] || return 0
  log "Collecting CRD instances"
  local crds="$TMP_DIR/crd-names.txt"
  oc get crd -o jsonpath='{range .items[*]}{.spec.names.plural}{"."}{.spec.group}{"\n"}{end}' 2>/dev/null | sort -u > "$crds" || true
  local crd
  while IFS= read -r crd; do
    [[ -z "$crd" ]] && continue
    local out="$RAW_DIR/crd-instances-$(safe_name "$crd").txt"
    timeout "${TIMEOUT_SECONDS}s" bash -lc "oc get ${crd} -A -o wide --ignore-not-found 2>&1 || oc get ${crd} -o wide --ignore-not-found 2>&1 || true" > "$out" 2>&1 || true
    redact_file "$out"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "crd-instance" "$crd" "oc get $crd -A -o wide" "$out" >> "$COMMAND_INDEX"
  done < "$crds"
}

collect_problem_pods() {
  log "Collecting problem pods, logs and describes"
  local pods_json="$TMP_DIR/pods-all.json"
  oc get pods -A -o json > "$pods_json" 2>/dev/null || echo '{"items":[]}' > "$pods_json"
  cp "$pods_json" "$RAW_DIR/pods-all.json"; redact_file "$RAW_DIR/pods-all.json"
  if has_jq; then
    jq -r '.items[] | select((.status.phase != "Running" and .status.phase != "Succeeded") or ([.status.containerStatuses[]?.restartCount] | add // 0) >= (env.RESTART_THRESHOLD|tonumber) or ([.status.containerStatuses[]?.state.waiting.reason,.status.containerStatuses[]?.lastState.terminated.reason] | map(select(.!=null)) | join(",") | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|Error|CreateContainerConfigError|RunContainerError"))) | [.metadata.namespace,.metadata.name,.status.phase,([.status.containerStatuses[]?.restartCount] | add // 0),([.status.containerStatuses[]?.state.waiting.reason,.status.containerStatuses[]?.lastState.terminated.reason] | map(select(.!=null)) | join(";"))] | @tsv' "$pods_json" > "$CSV_DIR/problem-pods.tsv" || true
  else
    oc get pods -A --field-selector=status.phase!=Running > "$CSV_DIR/problem-pods.tsv" || true
  fi
  local n=0 ns pod phase rest reason
  while IFS=$'\t' read -r ns pod phase rest reason; do
    [[ -z "$ns" || -z "$pod" ]] && continue
    n=$((n+1)); [[ "$n" -gt "$MAX_PROBLEM_PODS" ]] && break
    [[ "$COLLECT_DESCRIBES" == "true" ]] && oc describe pod "$pod" -n "$ns" > "$DESC_DIR/pod-${ns}-${pod}.txt" 2>&1 || true
    if [[ "$COLLECT_PROBLEM_POD_LOGS" == "true" ]]; then
      oc logs "$pod" -n "$ns" --all-containers --tail="$LOG_TAIL_LINES" > "$LOG_DIR/pod-${ns}-${pod}.log" 2>&1 || true
      oc logs "$pod" -n "$ns" --all-containers --previous --tail="$LOG_TAIL_LINES" > "$LOG_DIR/pod-${ns}-${pod}-previous.log" 2>&1 || true
    fi
    add_error "Severe" "Pod is not healthy or has high restarts" "Workload Health" "$ns" "pod/$pod" "phase=${phase}; restarts=${rest}; reason=${reason}" "Pods in failed/waiting states or with repeated restarts can indicate image, dependency, resource, probe or application failures." "Review pod describe, events and logs; fix image pulls, probes, resource limits or application errors; add requests/limits and rollout validation." "$CSV_DIR/problem-pods.tsv"
    add_backlog "P2" "Severe" "Somewhat Likely" "Standard" "Workload Health" "$ns" "pod/$pod" "Remediate unhealthy pod" "Pod is not healthy or repeatedly restarting" "Use describe/log evidence to correct image, probes, resources, secrets/config or application startup." "Application/Platform owner" "Open" "$CSV_DIR/problem-pods.tsv"
  done < "$CSV_DIR/problem-pods.tsv"
}

collect_events_and_mustgather() {
  [[ "$COLLECT_EVENTS" == "true" ]] && run_cmd events "warning-events" "oc get events -A --sort-by=.lastTimestamp | tail -${WARNING_EVENT_LIMIT} || true"
  if [[ "$RUN_MUST_GATHER" == "true" ]]; then
    log "Running must-gather. This can take several minutes."
    timeout "${MUST_GATHER_TIMEOUT_SECONDS}s" oc adm must-gather --dest-dir="$MUST_GATHER_DIR" > "$RUN_DIR/must-gather.log" 2>&1 || true
    redact_file "$RUN_DIR/must-gather.log"
  fi
}

analyze_namespaces() {
  [[ "$COLLECT_NAMESPACES_DEEP" == "true" ]] || return 0
  log "Analyzing namespaces and workloads"
  local ns
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    mkdir -p "$RAW_DIR/namespaces/$ns" "$DESC_DIR/namespaces/$ns"
    for res in resourcequota limitrange networkpolicy secret configmap deployment statefulset daemonset pod service route ingress hpa pdb role rolebinding serviceaccount cronjob job; do
      if [[ "$res" == "secret" ]]; then
        oc get secret -n "$ns" -o json 2>/dev/null | jq 'del(.items[].data)' > "$RAW_DIR/namespaces/$ns/secrets-metadata.json" 2>/dev/null || oc get secret -n "$ns" -o name > "$RAW_DIR/namespaces/$ns/secrets.txt" 2>&1 || true
      elif [[ "$res" == "configmap" ]]; then
        oc get configmap -n "$ns" -o json 2>/dev/null | jq '.items[]? |= (.data = ((.data // {}) | keys))' > "$RAW_DIR/namespaces/$ns/configmaps-keys.json" 2>/dev/null || oc get configmap -n "$ns" -o name > "$RAW_DIR/namespaces/$ns/configmaps.txt" 2>&1 || true
      else
        oc get "$res" -n "$ns" -o wide --ignore-not-found > "$RAW_DIR/namespaces/$ns/${res}.txt" 2>&1 || true
      fi
    done
    local quotas limits nps secrets cms deps sts ds pods svcs routes recs=""
    quotas=$(oc get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    limits=$(oc get limitrange -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    nps=$(oc get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    secrets=$(oc get secret -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    cms=$(oc get configmap -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    deps=$(oc get deploy -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    sts=$(oc get sts -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ds=$(oc get ds -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods=$(oc get pod -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    svcs=$(oc get svc -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    routes=$(oc get route -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [[ "$quotas" -eq 0 ]] && recs+="Add ResourceQuota baseline; " && add_backlog "P3" "Major" "Highly Likely" "Standard" "Namespace Governance" "$ns" "namespace/$ns" "Define ResourceQuota" "No ResourceQuota detected" "Set CPU, memory, object-count and storage quotas appropriate to the namespace type." "Platform owner" "Open" "$RAW_DIR/namespaces/$ns/resourcequota.txt"
    [[ "$limits" -eq 0 ]] && recs+="Add LimitRange baseline; " && add_backlog "P3" "Major" "Highly Likely" "Standard" "Namespace Governance" "$ns" "namespace/$ns" "Define LimitRange" "No LimitRange detected" "Set default and max CPU/memory/ephemeral-storage requests and limits." "Platform owner" "Open" "$RAW_DIR/namespaces/$ns/limitrange.txt"
    [[ "$nps" -eq 0 && "$pods" -gt 0 ]] && recs+="Add default NetworkPolicies; " && add_backlog "P3" "Major" "Highly Likely" "Standard" "Network Security" "$ns" "namespace/$ns" "Define baseline NetworkPolicy" "Pods exist but no NetworkPolicy detected" "Add default deny and required allow policies for ingress/egress paths." "Platform/Security owner" "Open" "$RAW_DIR/namespaces/$ns/networkpolicy.txt"
    csv_row "$ns" "Collected" "$(oc get ns "$ns" --show-labels --no-headers 2>/dev/null | awk '{print $NF}')" "$quotas" "$limits" "$nps" "$secrets" "$cms" "$deps" "$sts" "$ds" "$pods" "$svcs" "$routes" "$recs" >> "$NAMESPACE_REVIEW_CSV"

    if has_jq; then
      local wjson="$TMP_DIR/workloads-${ns}.json"
      oc get deploy,statefulset,daemonset -n "$ns" -o json > "$wjson" 2>/dev/null || echo '{"items":[]}' > "$wjson"
      jq -r '.items[] | [.kind,.metadata.name,(.spec.replicas // 1),(.status.readyReplicas // 0),([.spec.template.spec.containers[].name] | join(";")),(any(.spec.template.spec.containers[]?; (.resources.requests // {}) != {})),(any(.spec.template.spec.containers[]?; (.resources.limits // {}) != {})),(any(.spec.template.spec.containers[]?; has("readinessProbe") or has("livenessProbe") or has("startupProbe")))] | @tsv' "$wjson" 2>/dev/null | while IFS=$'\t' read -r kind name replicas ready containers has_req has_lim has_probe; do
        local pdb hpa services routes2 wrecs=""
        pdb=$(oc get pdb -n "$ns" --no-headers 2>/dev/null | grep -c "${name}" || true)
        hpa=$(oc get hpa -n "$ns" --no-headers 2>/dev/null | grep -c "${name}" || true)
        services=$(oc get svc -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        routes2=$(oc get route -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [[ "$has_req" != "true" ]] && wrecs+="Add CPU/memory/ephemeral-storage requests; " && add_backlog "P2" "Severe" "Highly Likely" "Standard" "12-Factor/Resource Management" "$ns" "$kind/$name" "Add resource requests" "Workload has no explicit requests" "Define requests based on observed usage; include ephemeral-storage for workloads writing temporary data." "App owner" "Open" "$RAW_DIR/namespaces/$ns/deployment.txt"
        [[ "$has_lim" != "true" ]] && wrecs+="Add resource limits where appropriate; " && add_backlog "P3" "Major" "Highly Likely" "Standard" "Resource Management" "$ns" "$kind/$name" "Add resource limits" "Workload has no explicit limits" "Set memory and ephemeral-storage limits; evaluate CPU limits based on latency/throttling tolerance." "App owner" "Open" "$RAW_DIR/namespaces/$ns/deployment.txt"
        [[ "$has_probe" != "true" ]] && wrecs+="Add readiness/liveness/startup probes; " && add_backlog "P2" "Severe" "Somewhat Likely" "Standard" "12-Factor/Disposability" "$ns" "$kind/$name" "Add probes" "No probe detected" "Add readiness for traffic gating, liveness for recovery, and startup probe for slow starters." "App owner" "Open" "$RAW_DIR/namespaces/$ns/deployment.txt"
        if [[ "$kind" != "DaemonSet" && "$replicas" -gt 1 && "$pdb" -eq 0 ]]; then
          wrecs+="Add PodDisruptionBudget; "
          add_backlog "P3" "Major" "Somewhat Likely" "Standard" "Resilience" "$ns" "$kind/$name" "Add PodDisruptionBudget" "Multi-replica workload without PDB" "Define minAvailable/maxUnavailable aligned to maintenance and availability expectations." "App owner" "Open" "$RAW_DIR/namespaces/$ns/pdb.txt"
        fi
        csv_row "$ns" "$kind" "$name" "$replicas" "$ready" "$containers" "$has_req" "$has_lim" "$has_probe" "$pdb" "$hpa" "$services" "$routes2" "$wrecs" >> "$WORKLOAD_REVIEW_CSV"
      done
    fi
  done < <(get_namespaces)
}

basic_analysis() {
  log "Running basic analysis"
  local co_degraded nodes_notready mcp_bad pending_pvc svc_no_ep evicted unavailable_deployments
  co_degraded=$(oc get co --no-headers 2>/dev/null | awk '$3!="False" || $4!="False" || $5!="True" {c++} END{print c+0}')
  nodes_notready=$(oc get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/ || $2 ~ /NotReady/ {c++} END{print c+0}')
  mcp_bad=$(oc get mcp --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False" {c++} END{print c+0}')
  pending_pvc=$(oc get pvc -A --no-headers 2>/dev/null | awk '$4!="Bound" {c++} END{print c+0}')
  svc_no_ep=$(oc get endpoints -A --no-headers 2>/dev/null | awk '$3=="<none>" {c++} END{print c+0}')
  evicted=$(grep -i "Evicted\|ephemeral-storage" "$CSV_DIR/problem-pods.tsv" 2>/dev/null | wc -l | tr -d ' ')
  unavailable_deployments=$(oc get deploy -A -o json 2>/dev/null | jq '[.items[] | select((.status.availableReplicas // 0) < (.spec.replicas // 1))] | length' 2>/dev/null || echo 0)
  [[ "$co_degraded" -gt 0 ]] && add_finding "Critical" "Platform Health" "One or more ClusterOperators are degraded, unavailable or progressing" "raw/baseline-clusteroperators-wide.txt" "Cluster operators represent platform control-plane health; unhealthy operators can block upgrades or affect core services." "Restore all ClusterOperators to healthy before upgrades or major changes."
  [[ "$nodes_notready" -gt 0 ]] && add_finding "Critical" "Node Health" "One or more nodes are not Ready" "raw/baseline-nodes-wide.txt" "Node unavailability reduces capacity and can disrupt workloads." "Investigate node conditions, kubelet, CRI-O, networking, storage pressure and MachineConfig state."
  [[ "$mcp_bad" -gt 0 ]] && add_finding "Severe" "MachineConfig" "One or more MachineConfigPools are not healthy" "raw/baseline-machineconfigpools-wide.txt" "MCP degradation can block node updates and cluster upgrades." "Review MCO logs and node rendered configs; remediate degraded nodes before proceeding."
  [[ "$pending_pvc" -ge "$PENDING_PVC_CRITICAL_THRESHOLD" ]] && add_finding "Severe" "Storage" "PVCs are not Bound" "raw/storage-persistentvolumeclaims-all.json" "Unbound storage can block workload scheduling and recovery." "Validate StorageClass, provisioner, quota, backend capacity, topology and CSI health."
  [[ "$svc_no_ep" -ge "$SERVICE_NO_ENDPOINT_WARNING_THRESHOLD" ]] && add_finding "Major" "Network/Traffic Path" "Services without endpoints detected" "raw/network-endpoints-all.json" "Services without endpoints can indicate failed rollouts, selector mismatch or traffic blackholes." "Review selectors, pod readiness, route targets and deployment health."
  [[ "$evicted" -ge "$EPHEMERAL_EVICTION_CRITICAL_THRESHOLD" ]] && add_finding "Critical" "Workload Health" "Multiple pods show Evicted or ephemeral-storage pressure symptoms" "csv/problem-pods.tsv" "Ephemeral storage pressure can cause repeated workload eviction and service instability." "Set ephemeral-storage requests/limits, reduce temp writes, move data to PVC/object storage and review node disk pressure."
  [[ "$unavailable_deployments" -ge "$UNAVAILABLE_DEPLOYMENT_CRITICAL_THRESHOLD" ]] && add_finding "Severe" "Deployment Readiness" "Deployments with unavailable replicas detected" "raw/api-resource-deployments.apps.txt" "Unavailable replicas can indicate app or platform readiness issues." "Review rollout status, pod logs, probes, images, secrets/configmaps and resource constraints."
  add_backlog "P1" "Critical" "Somewhat Likely" "Standard" "Health Check Follow-up" "cluster" "cluster/${CLUSTER_NAME_HINT}" "Review priority findings" "The automated findings register contains items requiring technical review." "Triage findings.csv and errors-criticality.csv; assign owners and remediation dates." "Platform owner" "Open" "$FINDINGS_CSV"
}

render_reports() {
  log "Rendering reports"
  write_basic_summary
  if has_python3; then
    python3 "$SCRIPT_DIR/reports/ocp-report-renderer.py" --run-dir "$RUN_DIR" --cluster-name "$CLUSTER_NAME_HINT" --client-label "$CLIENT_LABEL" || true
  fi
  [[ -f "$REPORT_DIR/report-${CLUSTER_NAME_HINT}.html" ]] && cp "$REPORT_DIR/report-${CLUSTER_NAME_HINT}.html" "$HEALTH_HTML"
  [[ -f "$REPORT_DIR/report-${CLUSTER_NAME_HINT}.md" ]] && cp "$REPORT_DIR/report-${CLUSTER_NAME_HINT}.md" "$HEALTH_MD"
  [[ -f "$REPORT_DIR/summary.txt" ]] && cp "$REPORT_DIR/summary.txt" "$SUMMARY_TXT"
  log "Report generated: $RUN_DIR"
}

collect_baseline
collect_core_components
collect_storage
collect_network
collect_olm_security_ai
collect_all_api_resources
collect_crds
collect_problem_pods
analyze_namespaces
collect_events_and_mustgather
basic_analysis
render_reports

echo "$RUN_DIR"
