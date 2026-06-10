#!/usr/bin/env bash
# ocp-general-health-check.sh
# Read-only OpenShift general health check script.
# Author: Generated for operational troubleshooting / support evidence collection.

set -uo pipefail

SCRIPT_VERSION="1.0.0"
OUT_DIR="ocp-health-$(date +%Y%m%d-%H%M%S)"
TIMEOUT_SECONDS=60
PAUSE=false
DEEP=false
RUN_MUST_GATHER=false
RAW_DIR=""
REPORT=""
SUMMARY=""
OVERALL_STATUS="HEALTHY"
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0

usage() {
  cat <<USAGE
OpenShift General Health Check - v${SCRIPT_VERSION}

Usage:
  ./ocp-general-health-check.sh [options]

Options:
  -o, --output DIR       Output directory. Default: ocp-health-YYYYMMDD-HHMMSS
  -t, --timeout SEC      Timeout per command. Default: 60
      --pause            Pause after every major step. Useful for step-by-step guided execution.
      --deep             Collect additional describe/log-tail information. Still read-only, but more verbose.
      --must-gather      Run 'oc adm must-gather' at the end. This can take several minutes and requires space.
  -h, --help             Show help.

Examples:
  ./ocp-general-health-check.sh
  ./ocp-general-health-check.sh --pause --deep
  ./ocp-general-health-check.sh -o /tmp/ocp-health --must-gather
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      OUT_DIR="$2"; shift 2 ;;
    -t|--timeout)
      TIMEOUT_SECONDS="$2"; shift 2 ;;
    --pause)
      PAUSE=true; shift ;;
    --deep)
      DEEP=true; shift ;;
    --must-gather)
      RUN_MUST_GATHER=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
RAW_DIR="$OUT_DIR/raw"
mkdir -p "$RAW_DIR"
REPORT="$OUT_DIR/health-report.md"
SUMMARY="$OUT_DIR/summary.txt"

if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"; RED="$(tput setaf 1)"; YELLOW="$(tput setaf 3)"; GREEN="$(tput setaf 2)"; BLUE="$(tput setaf 4)"
else
  BOLD=""; RESET=""; RED=""; YELLOW=""; GREEN=""; BLUE=""
fi

log() { echo -e "$*"; }

pause_if_needed() {
  if [[ "$PAUSE" == "true" ]]; then
    read -r -p "Press ENTER to continue..." _
  fi
}

set_status() {
  local severity="$1"
  local message="$2"
  case "$severity" in
    CRITICAL)
      CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
      OVERALL_STATUS="CRITICAL"
      echo "- **CRITICAL**: ${message}" >> "$REPORT"
      ;;
    WARNING)
      WARNING_COUNT=$((WARNING_COUNT + 1))
      if [[ "$OVERALL_STATUS" != "CRITICAL" ]]; then OVERALL_STATUS="WARNING"; fi
      echo "- **WARNING**: ${message}" >> "$REPORT"
      ;;
    INFO)
      INFO_COUNT=$((INFO_COUNT + 1))
      echo "- **INFO**: ${message}" >> "$REPORT"
      ;;
  esac
}

run_cmd() {
  local name="$1"
  local cmd="$2"
  local file="$RAW_DIR/${name}.txt"
  {
    echo "# Command"
    echo "$ ${cmd}"
    echo
    echo "# Output"
  } > "$file"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" bash -o pipefail -c "$cmd" >> "$file" 2>&1
  else
    bash -o pipefail -c "$cmd" >> "$file" 2>&1
  fi
  local rc=$?
  echo >> "$file"
  echo "# Return code: ${rc}" >> "$file"
  return "$rc"
}

run_step() {
  local step_id="$1"
  local title="$2"
  log "${BLUE}${BOLD}[${step_id}] ${title}${RESET}"
  echo "\n## ${step_id}. ${title}\n" >> "$REPORT"
}

print_file_tail() {
  local label="$1"
  local file="$2"
  local lines="${3:-20}"
  echo "\n### ${label}\n" >> "$REPORT"
  echo '```text' >> "$REPORT"
  tail -n "$lines" "$file" >> "$REPORT" 2>/dev/null || true
  echo '```' >> "$REPORT"
}

init_report() {
  cat > "$REPORT" <<EOF_REPORT
# OpenShift General Health Report

- **Generated:** $(date -u +"%Y-%m-%dT%H:%M:%S%z")
- **Script version:** ${SCRIPT_VERSION}
- **Output directory:** ${OUT_DIR}
- **Mode:** deep=${DEEP}, must_gather=${RUN_MUST_GATHER}, pause=${PAUSE}

> This report is generated using read-only OpenShift CLI queries, except when '--must-gather' is requested. Review the collected artifacts before sharing them externally because they can include cluster names, routes, node names, namespaces, events, IPs, and operational metadata.

## Executive findings

EOF_REPORT
}

requirement_checks() {
  run_step "01" "Validate local tools and OpenShift login"

  if ! command -v oc >/dev/null 2>&1; then
    set_status "CRITICAL" "The 'oc' CLI was not found in PATH. Install the OpenShift CLI and run the script again."
    log "${RED}CRITICAL: oc CLI not found.${RESET}"
    finalize_report
    exit 2
  fi

  run_cmd "01_oc_version" "oc version --client=true"
  run_cmd "01_oc_whoami" "oc whoami"
  if [[ $? -ne 0 ]]; then
    set_status "CRITICAL" "Unable to verify OpenShift login using 'oc whoami'. Run 'oc login' and execute the script again."
    log "${RED}CRITICAL: Not logged in or API is unreachable.${RESET}"
    finalize_report
    exit 2
  fi

  run_cmd "01_oc_project" "oc project"
  run_cmd "01_oc_config_current_context" "oc config current-context"
  run_cmd "01_oc_api_resources_probe" "oc api-resources --request-timeout=10s | head -n 20"

  print_file_tail "oc client version" "$RAW_DIR/01_oc_version.txt" 20
  print_file_tail "Current user" "$RAW_DIR/01_oc_whoami.txt" 10
  print_file_tail "Current context" "$RAW_DIR/01_oc_config_current_context.txt" 10
  set_status "INFO" "OpenShift CLI is available and the current session can reach the API."
  pause_if_needed
}

cluster_baseline() {
  run_step "02" "Collect cluster baseline and version status"

  run_cmd "02_clusterversion" "oc get clusterversion version -o wide"
  run_cmd "02_clusterversion_yaml" "oc get clusterversion version -o yaml"
  run_cmd "02_infrastructure" "oc get infrastructure cluster -o yaml"
  run_cmd "02_clusterid" "oc get clusterversion version -o jsonpath='{.spec.clusterID}{\"\\n\"}'"
  run_cmd "02_oc_get_projects" "oc get projects --no-headers | wc -l"

  local cv_file="$RAW_DIR/02_clusterversion.txt"
  print_file_tail "ClusterVersion" "$cv_file" 40

  local cv_problem
  cv_problem=$(oc get clusterversion version --no-headers 2>/dev/null | awk '$2!="True" || $3=="True" {print}' || true)
  if [[ -n "$cv_problem" ]]; then
    set_status "WARNING" "ClusterVersion is not fully Available or is Progressing. Review raw/02_clusterversion_yaml.txt."
  else
    set_status "INFO" "ClusterVersion reports Available=True and Progressing=False."
  fi
  pause_if_needed
}

cluster_operators() {
  run_step "03" "Validate ClusterOperators"

  run_cmd "03_clusteroperators" "oc get clusteroperators"
  run_cmd "03_clusteroperators_wide" "oc get clusteroperators -o wide"
  run_cmd "03_clusteroperators_yaml" "oc get clusteroperators -o yaml"

  print_file_tail "ClusterOperators" "$RAW_DIR/03_clusteroperators.txt" 80

  local degraded unavailable progressing
  degraded=$(oc get co --no-headers 2>/dev/null | awk '$5=="True" {print $1}' | paste -sd ',' - || true)
  unavailable=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" {print $1}' | paste -sd ',' - || true)
  progressing=$(oc get co --no-headers 2>/dev/null | awk '$4=="True" {print $1}' | paste -sd ',' - || true)

  [[ -n "$degraded" ]] && set_status "CRITICAL" "ClusterOperators degraded: ${degraded}."
  [[ -n "$unavailable" ]] && set_status "CRITICAL" "ClusterOperators unavailable: ${unavailable}."
  [[ -n "$progressing" ]] && set_status "WARNING" "ClusterOperators progressing: ${progressing}."
  [[ -z "$degraded$unavailable$progressing" ]] && set_status "INFO" "All ClusterOperators appear Available=True, Progressing=False, Degraded=False."

  if [[ "$DEEP" == "true" ]]; then
    run_cmd "03_describe_problem_clusteroperators" "for co in \$(oc get co --no-headers | awk '\$3!=\"True\" || \$4==\"True\" || \$5==\"True\" {print \$1}'); do echo '===== clusteroperator/'\$co '====='; oc describe clusteroperator \$co; done"
  fi
  pause_if_needed
}

nodes_health() {
  run_step "04" "Validate nodes, capacity, and node pressure conditions"

  run_cmd "04_nodes" "oc get nodes -o wide"
  run_cmd "04_nodes_labels" "oc get nodes --show-labels"
  run_cmd "04_nodes_conditions" "oc get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\\.kubernetes\\.io/master,READY:.status.conditions[?(@.type==\"Ready\")].status,KERNEL:.status.nodeInfo.kernelVersion,KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage"
  run_cmd "04_node_pressure_conditions" "oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{range .status.conditions[*]}{.type}{\"=\"}{.status}{\" message=\"}{.message}{\"\\n\"}{end}{\"---\\n\"}{end}'"
  run_cmd "04_adm_top_nodes" "oc adm top nodes"

  print_file_tail "Nodes" "$RAW_DIR/04_nodes.txt" 80
  print_file_tail "Node pressure conditions" "$RAW_DIR/04_node_pressure_conditions.txt" 120
  print_file_tail "Node resource usage" "$RAW_DIR/04_adm_top_nodes.txt" 80

  local not_ready unsched pressure
  not_ready=$(oc get nodes --no-headers 2>/dev/null | awk '$2 ~ /NotReady|Unknown/ {print $1":"$2}' | paste -sd ',' - || true)
  unsched=$(oc get nodes --no-headers 2>/dev/null | awk '$2 ~ /SchedulingDisabled/ {print $1":"$2}' | paste -sd ',' - || true)
  pressure=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}{"\n"}{end}' 2>/dev/null | grep -E 'MemoryPressure|DiskPressure|PIDPressure|NetworkUnavailable' || true)

  [[ -n "$not_ready" ]] && set_status "CRITICAL" "Nodes not ready or unknown: ${not_ready}."
  [[ -n "$unsched" ]] && set_status "WARNING" "Nodes marked SchedulingDisabled: ${unsched}. Confirm whether they are intentionally cordoned."
  [[ -n "$pressure" ]] && set_status "CRITICAL" "One or more nodes report pressure or NetworkUnavailable conditions. Review raw/04_node_pressure_conditions.txt."
  [[ -z "$not_ready$unsched$pressure" ]] && set_status "INFO" "All nodes appear Ready with no detected pressure conditions."

  if [[ "$DEEP" == "true" ]]; then
    run_cmd "04_describe_nodes" "for n in \$(oc get nodes --no-headers | awk '{print \$1}'); do echo '===== node/'\$n '====='; oc describe node \$n; done"
  fi
  pause_if_needed
}

machine_config_pools() {
  run_step "05" "Validate MachineConfigPools and node configuration rollout"

  run_cmd "05_mcp" "oc get machineconfigpool"
  run_cmd "05_mcp_wide" "oc get machineconfigpool -o wide"
  run_cmd "05_mcp_yaml" "oc get machineconfigpool -o yaml"
  run_cmd "05_machinesets" "oc get machinesets -A -o wide"
  run_cmd "05_machines" "oc get machines -A -o wide"

  print_file_tail "MachineConfigPools" "$RAW_DIR/05_mcp.txt" 80

  local degraded updating not_updated
  degraded=$(oc get mcp --no-headers 2>/dev/null | awk '$5=="True" {print $1}' | paste -sd ',' - || true)
  updating=$(oc get mcp --no-headers 2>/dev/null | awk '$4=="True" {print $1}' | paste -sd ',' - || true)
  not_updated=$(oc get mcp --no-headers 2>/dev/null | awk '$3!="True" {print $1}' | paste -sd ',' - || true)

  [[ -n "$degraded" ]] && set_status "CRITICAL" "MachineConfigPools degraded: ${degraded}."
  [[ -n "$updating" ]] && set_status "WARNING" "MachineConfigPools updating: ${updating}."
  [[ -n "$not_updated" ]] && set_status "WARNING" "MachineConfigPools not fully updated: ${not_updated}."
  [[ -z "$degraded$updating$not_updated" ]] && set_status "INFO" "MachineConfigPools appear updated and not degraded."

  if [[ "$DEEP" == "true" ]]; then
    run_cmd "05_describe_problem_mcp" "for mcp in \$(oc get mcp --no-headers | awk '\$3!=\"True\" || \$4==\"True\" || \$5==\"True\" {print \$1}'); do echo '===== mcp/'\$mcp '====='; oc describe mcp \$mcp; done"
  fi
  pause_if_needed
}

pod_health() {
  run_step "06" "Validate pod health across all namespaces"

  run_cmd "06_pods_all" "oc get pods -A -o wide"
  run_cmd "06_pods_not_running" "oc get pods -A --no-headers | awk '\$4 != \"Running\" && \$4 != \"Completed\" {print}'"
  run_cmd "06_pods_high_restarts" "oc get pods -A --no-headers | awk '\$5+0 >= 5 {print}'"
  run_cmd "06_pods_openshift_namespaces_summary" "for ns in \$(oc get ns --no-headers | awk '{print \$1}' | grep '^openshift-' | sort); do echo '===== namespace/'\$ns '====='; oc get pods -n \$ns --no-headers 2>/dev/null | awk '\$4 != \"Running\" && \$4 != \"Completed\" {print}' || true; done"

  print_file_tail "Pods not Running/Completed" "$RAW_DIR/06_pods_not_running.txt" 120
  print_file_tail "Pods with five or more restarts" "$RAW_DIR/06_pods_high_restarts.txt" 120

  local bad_count restart_count critical_pattern
  bad_count=$(grep -v '^#' "$RAW_DIR/06_pods_not_running.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)
  restart_count=$(grep -v '^#' "$RAW_DIR/06_pods_high_restarts.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)
  critical_pattern=$(grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|RunContainerError|Init:CrashLoopBackOff|ContainerCreating|Terminating|Unknown|Evicted|OOMKilled' "$RAW_DIR/06_pods_not_running.txt" || true)

  if [[ "$bad_count" -gt 0 ]]; then
    if [[ -n "$critical_pattern" ]]; then
      set_status "CRITICAL" "Found ${bad_count} pods not Running/Completed, including severe container states. Review raw/06_pods_not_running.txt."
    else
      set_status "WARNING" "Found ${bad_count} pods not Running/Completed. Review raw/06_pods_not_running.txt."
    fi
  else
    set_status "INFO" "No pods outside Running/Completed were detected using the table view."
  fi

  if [[ "$restart_count" -gt 0 ]]; then
    set_status "WARNING" "Found ${restart_count} pods with five or more restarts. Review raw/06_pods_high_restarts.txt."
  fi

  if [[ "$DEEP" == "true" ]]; then
    run_cmd "06_describe_problem_pods" "oc get pods -A --no-headers | awk '\$4 != \"Running\" && \$4 != \"Completed\" {print \$1,\$2}' | while read ns pod; do echo '===== pod/'\$ns'/'\$pod '====='; oc describe pod -n \$ns \$pod; done"
    run_cmd "06_logs_problem_pods_tail" "oc get pods -A --no-headers | awk '\$4 != \"Running\" && \$4 != \"Completed\" {print \$1,\$2}' | head -n 30 | while read ns pod; do echo '===== logs/'\$ns'/'\$pod '====='; oc logs -n \$ns \$pod --all-containers --tail=80 --ignore-errors=true; done"
  fi
  pause_if_needed
}

control_plane_core() {
  run_step "07" "Validate control plane and core OpenShift namespaces"

  run_cmd "07_core_clusteroperators" "oc get co kube-apiserver openshift-apiserver etcd authentication ingress dns network console monitoring image-registry -o wide"
  run_cmd "07_kube_apiserver_pods" "oc get pods -n openshift-kube-apiserver -o wide"
  run_cmd "07_etcd_pods" "oc get pods -n openshift-etcd -o wide"
  run_cmd "07_authentication_pods" "oc get pods -n openshift-authentication -o wide"
  run_cmd "07_ingress_pods" "oc get pods -n openshift-ingress -o wide"
  run_cmd "07_dns_pods" "oc get pods -n openshift-dns -o wide"
  run_cmd "07_network_pods" "oc get pods -n openshift-ovn-kubernetes -o wide || oc get pods -n openshift-sdn -o wide || true"
  run_cmd "07_monitoring_pods" "oc get pods -n openshift-monitoring -o wide"
  run_cmd "07_console_route" "oc get route -n openshift-console console -o wide"
  run_cmd "07_csr" "oc get csr"

  print_file_tail "Core ClusterOperators" "$RAW_DIR/07_core_clusteroperators.txt" 80
  print_file_tail "etcd pods" "$RAW_DIR/07_etcd_pods.txt" 80
  print_file_tail "kube-apiserver pods" "$RAW_DIR/07_kube_apiserver_pods.txt" 80
  print_file_tail "CSRs" "$RAW_DIR/07_csr.txt" 80

  local core_bad csr_pending
  core_bad=$(oc get co kube-apiserver openshift-apiserver etcd authentication ingress dns network console monitoring image-registry --no-headers 2>/dev/null | awk '$3!="True" || $4=="True" || $5=="True" {print $1}' | paste -sd ',' - || true)
  csr_pending=$(oc get csr --no-headers 2>/dev/null | grep -E 'Pending|<none>' || true)

  [[ -n "$core_bad" ]] && set_status "CRITICAL" "Core ClusterOperators with non-healthy status: ${core_bad}."
  [[ -n "$csr_pending" ]] && set_status "WARNING" "Pending or unapproved CSRs detected. Review raw/07_csr.txt."
  [[ -z "$core_bad$csr_pending" ]] && set_status "INFO" "Core control plane operators and CSRs did not show obvious issues."
  pause_if_needed
}

network_ingress_health() {
  run_step "08" "Validate network, ingress, DNS, routes, and proxies"

  run_cmd "08_network_config" "oc get network.operator.openshift.io cluster -o yaml"
  run_cmd "08_dns_config" "oc get dns.operator.openshift.io default -o yaml || oc get dns cluster -o yaml"
  run_cmd "08_ingresscontrollers" "oc get ingresscontrollers.operator.openshift.io -n openshift-ingress-operator -o wide"
  run_cmd "08_ingresscontrollers_yaml" "oc get ingresscontrollers.operator.openshift.io -n openshift-ingress-operator -o yaml"
  run_cmd "08_proxy" "oc get proxy cluster -o yaml"
  run_cmd "08_routes_all_summary" "oc get routes -A --no-headers | wc -l"
  run_cmd "08_console_route" "oc get route -n openshift-console console -o yaml"

  print_file_tail "IngressControllers" "$RAW_DIR/08_ingresscontrollers.txt" 80
  print_file_tail "Proxy config" "$RAW_DIR/08_proxy.txt" 120

  local ingress_bad
  ingress_bad=$(oc get ingresscontrollers.operator.openshift.io -n openshift-ingress-operator --no-headers 2>/dev/null | awk '$3!="True" || $4=="True" {print $1}' | paste -sd ',' - || true)
  [[ -n "$ingress_bad" ]] && set_status "CRITICAL" "IngressController not healthy or progressing: ${ingress_bad}."
  [[ -z "$ingress_bad" ]] && set_status "INFO" "IngressControllers do not show obvious degraded state in table output."
  pause_if_needed
}

storage_health() {
  run_step "09" "Validate storage objects, CSI resources, PVs, and PVCs"

  run_cmd "09_storageclasses" "oc get storageclass"
  run_cmd "09_pv" "oc get pv -o wide"
  run_cmd "09_pvc_all" "oc get pvc -A -o wide"
  run_cmd "09_pvc_not_bound" "oc get pvc -A --no-headers | awk '\$3 != \"Bound\" {print}'"
  run_cmd "09_pv_problem" "oc get pv --no-headers | awk '\$5 != \"Bound\" && \$5 != \"Available\" {print}'"
  run_cmd "09_csinodes" "oc get csinodes -o wide"
  run_cmd "09_csidrivers" "oc get csidrivers -o wide"
  run_cmd "09_volumeattachments" "oc get volumeattachments -o wide"

  print_file_tail "StorageClasses" "$RAW_DIR/09_storageclasses.txt" 80
  print_file_tail "PVCs not Bound" "$RAW_DIR/09_pvc_not_bound.txt" 120
  print_file_tail "PV problems" "$RAW_DIR/09_pv_problem.txt" 120

  local pvc_bad pv_bad
  pvc_bad=$(grep -v '^#' "$RAW_DIR/09_pvc_not_bound.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)
  pv_bad=$(grep -v '^#' "$RAW_DIR/09_pv_problem.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)

  [[ "$pvc_bad" -gt 0 ]] && set_status "WARNING" "Found ${pvc_bad} PVCs not Bound. Review raw/09_pvc_not_bound.txt."
  [[ "$pv_bad" -gt 0 ]] && set_status "WARNING" "Found ${pv_bad} PVs in states other than Bound/Available. Review raw/09_pv_problem.txt."
  [[ "$pvc_bad" -eq 0 && "$pv_bad" -eq 0 ]] && set_status "INFO" "No obvious PV/PVC binding issues were detected."
  pause_if_needed
}

olm_health() {
  run_step "10" "Validate OLM, installed operators, subscriptions, and install plans"

  run_cmd "10_csv" "oc get csv -A"
  run_cmd "10_csv_not_succeeded" "oc get csv -A --no-headers | awk '\$NF != \"Succeeded\" {print}'"
  run_cmd "10_subscriptions" "oc get subscriptions -A -o wide"
  run_cmd "10_installplans" "oc get installplans -A -o wide"
  run_cmd "10_operatorgroups" "oc get operatorgroups -A -o wide"
  run_cmd "10_catalogsources" "oc get catalogsources -n openshift-marketplace -o wide"
  run_cmd "10_marketplace_pods" "oc get pods -n openshift-marketplace -o wide"

  print_file_tail "CSV not Succeeded" "$RAW_DIR/10_csv_not_succeeded.txt" 120
  print_file_tail "Subscriptions" "$RAW_DIR/10_subscriptions.txt" 120
  print_file_tail "CatalogSources" "$RAW_DIR/10_catalogsources.txt" 120

  local csv_bad install_pending catalog_bad
  csv_bad=$(grep -v '^#' "$RAW_DIR/10_csv_not_succeeded.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)
  install_pending=$(oc get installplans -A --no-headers 2>/dev/null | awk '$NF=="false" || $NF=="False" {print}' || true)
  catalog_bad=$(oc get catalogsources -n openshift-marketplace --no-headers 2>/dev/null | awk '$NF!="READY" && $NF!="" {print}' || true)

  [[ "$csv_bad" -gt 0 ]] && set_status "WARNING" "Found ${csv_bad} ClusterServiceVersions not in Succeeded phase."
  [[ -n "$install_pending" ]] && set_status "WARNING" "InstallPlans appear not approved or not complete. Review raw/10_installplans.txt."
  [[ -n "$catalog_bad" ]] && set_status "WARNING" "Some CatalogSources may not be ready. Review raw/10_catalogsources.txt."
  [[ "$csv_bad" -eq 0 && -z "$install_pending$catalog_bad" ]] && set_status "INFO" "OLM resources did not show obvious failures."
  pause_if_needed
}

events_and_alerts() {
  run_step "11" "Collect recent events and active monitoring alerts"

  run_cmd "11_events_all_sorted" "oc get events -A --sort-by=.lastTimestamp"
  run_cmd "11_events_warning" "oc get events -A --sort-by=.lastTimestamp | grep -i Warning || true"
  run_cmd "11_events_recent_tail" "oc get events -A --sort-by=.lastTimestamp | tail -n 200"

  # Prometheus alerts through Kubernetes API proxy. This might fail depending on RBAC or monitoring availability.
  run_cmd "11_prometheus_alerts_json" "oc get --raw '/api/v1/namespaces/openshift-monitoring/services/https:prometheus-k8s:9091/proxy/api/v1/alerts'"

  if command -v jq >/dev/null 2>&1 && grep -q '"status"' "$RAW_DIR/11_prometheus_alerts_json.txt"; then
    awk '/^# Output/{flag=1; next} /^# Return code/{flag=0} flag{print}' "$RAW_DIR/11_prometheus_alerts_json.txt" > "$RAW_DIR/11_prometheus_alerts.clean.json" || true
    jq -r '.data.alerts[]? | select(.state=="firing") | [.labels.severity, .labels.alertname, .labels.namespace, .annotations.summary] | @tsv' "$RAW_DIR/11_prometheus_alerts.clean.json" > "$RAW_DIR/11_prometheus_alerts_firing.tsv" 2>/dev/null || true
    jq -r '[.data.alerts[]? | select(.state=="firing" and .labels.severity=="critical")] | length' "$RAW_DIR/11_prometheus_alerts.clean.json" > "$RAW_DIR/11_prometheus_alerts_critical.count" 2>/dev/null || echo 0 > "$RAW_DIR/11_prometheus_alerts_critical.count"
    jq -r '[.data.alerts[]? | select(.state=="firing" and .labels.severity=="warning")] | length' "$RAW_DIR/11_prometheus_alerts.clean.json" > "$RAW_DIR/11_prometheus_alerts_warning.count" 2>/dev/null || echo 0 > "$RAW_DIR/11_prometheus_alerts_warning.count"
  fi

  print_file_tail "Recent Warning events" "$RAW_DIR/11_events_warning.txt" 120
  [[ -f "$RAW_DIR/11_prometheus_alerts_firing.tsv" ]] && print_file_tail "Firing Prometheus alerts" "$RAW_DIR/11_prometheus_alerts_firing.tsv" 120

  local warning_events alert_critical alert_warning
  warning_events=$(grep -v '^#' "$RAW_DIR/11_events_warning.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)
  alert_critical=0
  alert_warning=0
  [[ -f "$RAW_DIR/11_prometheus_alerts_critical.count" ]] && alert_critical=$(cat "$RAW_DIR/11_prometheus_alerts_critical.count" 2>/dev/null || echo 0)
  [[ -f "$RAW_DIR/11_prometheus_alerts_warning.count" ]] && alert_warning=$(cat "$RAW_DIR/11_prometheus_alerts_warning.count" 2>/dev/null || echo 0)

  [[ "$warning_events" -gt 0 ]] && set_status "WARNING" "Found ${warning_events} Warning events in the event stream. Review raw/11_events_warning.txt."
  [[ "$alert_critical" -gt 0 ]] && set_status "CRITICAL" "Found ${alert_critical} firing critical Prometheus alerts. Review raw/11_prometheus_alerts_firing.tsv."
  [[ "$alert_warning" -gt 0 ]] && set_status "WARNING" "Found ${alert_warning} firing warning Prometheus alerts. Review raw/11_prometheus_alerts_firing.tsv."
  [[ "$warning_events" -eq 0 && "$alert_critical" -eq 0 && "$alert_warning" -eq 0 ]] && set_status "INFO" "No Warning events or firing Prometheus alerts were detected by the available queries."
  pause_if_needed
}

security_and_access() {
  run_step "12" "Validate authentication, OAuth, certificates, and API access signals"

  run_cmd "12_authentication_operator" "oc get co authentication oauth-apiserver kube-apiserver -o wide"
  run_cmd "12_oauth_pods" "oc get pods -n openshift-authentication -o wide"
  run_cmd "12_oauth_config" "oc get oauth cluster -o yaml"
  run_cmd "12_apiserver_config" "oc get apiserver cluster -o yaml"
  run_cmd "12_certificate_signing_requests" "oc get csr -o wide"
  run_cmd "12_apiservices_unavailable" "oc get apiservices | awk '\$2 != \"True\" {print}'"

  print_file_tail "Authentication operators" "$RAW_DIR/12_authentication_operator.txt" 80
  print_file_tail "Unavailable API services" "$RAW_DIR/12_apiservices_unavailable.txt" 120

  local api_bad
  api_bad=$(grep -v '^#' "$RAW_DIR/12_apiservices_unavailable.txt" | grep -v '^$' | grep -v '^\$ ' | grep -vc '^# Return code' || true)
  [[ "$api_bad" -gt 0 ]] && set_status "WARNING" "Found ${api_bad} APIService entries not Available=True. Review raw/12_apiservices_unavailable.txt."
  [[ "$api_bad" -eq 0 ]] && set_status "INFO" "APIService availability table did not show obvious unavailable entries."
  pause_if_needed
}

optional_must_gather() {
  if [[ "$RUN_MUST_GATHER" != "true" ]]; then
    return 0
  fi

  run_step "13" "Run optional must-gather"
  mkdir -p "$OUT_DIR/must-gather"
  run_cmd "13_must_gather" "cd '$OUT_DIR/must-gather' && oc adm must-gather"
  print_file_tail "must-gather command result" "$RAW_DIR/13_must_gather.txt" 80
  set_status "INFO" "must-gather was requested. Review ${OUT_DIR}/must-gather for collected support data."
  pause_if_needed
}

finalize_report() {
  {
    echo
    echo "## Final classification"
    echo
    echo "- **Overall status:** ${OVERALL_STATUS}"
    echo "- **Critical findings:** ${CRITICAL_COUNT}"
    echo "- **Warning findings:** ${WARNING_COUNT}"
    echo "- **Informational findings:** ${INFO_COUNT}"
    echo
    echo "## Recommended next actions"
    echo
    if [[ "$OVERALL_STATUS" == "CRITICAL" ]]; then
      echo "1. Prioritize ClusterOperators, nodes, MachineConfigPools, and firing critical alerts."
      echo "2. Review files referenced in the executive findings."
      echo "3. If opening a support case, attach this directory and a must-gather if policy allows it."
    elif [[ "$OVERALL_STATUS" == "WARNING" ]]; then
      echo "1. Review warnings before planned maintenance or upgrades."
      echo "2. Confirm whether cordoned nodes, progressing operators, or pending PVCs are expected."
      echo "3. Consider rerunning with '--deep' for additional pod and node details."
    else
      echo "1. No obvious general health issue was detected by this read-only check."
      echo "2. For application-specific issues, run namespace-focused checks and inspect app logs/events."
    fi
    echo
    echo "## Artifact index"
    echo
    echo "- Raw command outputs: \`raw/\`"
    echo "- Main report: \`health-report.md\`"
    echo "- Summary: \`summary.txt\`"
    [[ "$RUN_MUST_GATHER" == "true" ]] && echo "- must-gather output: \`must-gather/\`"
  } >> "$REPORT"

  cat > "$SUMMARY" <<EOF_SUMMARY
OpenShift General Health Check
Generated: $(date -u +"%Y-%m-%dT%H:%M:%S%z")
Overall status: ${OVERALL_STATUS}
Critical findings: ${CRITICAL_COUNT}
Warning findings: ${WARNING_COUNT}
Informational findings: ${INFO_COUNT}
Report: ${REPORT}
Raw outputs: ${RAW_DIR}
EOF_SUMMARY
}

main() {
  init_report
  log "${BOLD}OpenShift General Health Check v${SCRIPT_VERSION}${RESET}"
  log "Output directory: ${OUT_DIR}"
  log "Mode: deep=${DEEP}, must_gather=${RUN_MUST_GATHER}, pause=${PAUSE}"
  echo

  requirement_checks
  cluster_baseline
  cluster_operators
  nodes_health
  machine_config_pools
  pod_health
  control_plane_core
  network_ingress_health
  storage_health
  olm_health
  events_and_alerts
  security_and_access
  optional_must_gather
  finalize_report

  echo
  case "$OVERALL_STATUS" in
    HEALTHY) log "${GREEN}${BOLD}Overall status: ${OVERALL_STATUS}${RESET}" ;;
    WARNING) log "${YELLOW}${BOLD}Overall status: ${OVERALL_STATUS}${RESET}" ;;
    CRITICAL) log "${RED}${BOLD}Overall status: ${OVERALL_STATUS}${RESET}" ;;
  esac
  log "Report: ${REPORT}"
  log "Summary: ${SUMMARY}"
  log "Raw outputs: ${RAW_DIR}"
}

main "$@"
