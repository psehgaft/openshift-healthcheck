#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ocp418-deep-lib.sh
source "$SCRIPT_DIR/ocp418-deep-lib.sh"
parse_common_args "$@"
require_oc
init_run_dir "network-deep-dive"
start_md "OpenShift 4.18+ Network Deep Dive"

run_cmd "network_config" "oc get network.config.openshift.io cluster -o yaml"
run_cmd "network_operator" "oc get network.operator.openshift.io cluster -o yaml 2>/dev/null || true"
run_cmd "proxy_config" "oc get proxy/cluster -o yaml 2>/dev/null || true"
run_cmd "dns_config" "oc get dns.config.openshift.io cluster -o yaml 2>/dev/null || true; echo; oc get dns.operator.openshift.io default -o yaml 2>/dev/null || true"
run_cmd "ingresscontrollers" "oc get ingresscontrollers.operator.openshift.io -A -o wide; echo; oc get ingresscontrollers.operator.openshift.io -A -o yaml"
run_cmd "routes_openshift" "oc get route -A -o wide | sed -n '1,${MAX_OBJECTS_PER_SECTION}p'"
run_cmd "services_without_ready_endpoints" "for ns in \$(oc get ns --no-headers | awk '{print \$1}'); do oc -n \$ns get svc -o name 2>/dev/null | while read s; do name=\${s#service/}; ep=\$(oc -n \$ns get endpoints \$name -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true); type=\$(oc -n \$ns get svc \$name -o jsonpath='{.spec.type}' 2>/dev/null || true); [[ -z \"\$ep\" && \"\$type\" != \"ExternalName\" ]] && echo -e \"\$ns\\t\$name\\t\$type\\tno_ready_endpoints\"; done; done | sed -n '1,${MAX_OBJECTS_PER_SECTION}p'"
run_cmd "network_policies_summary" "for ns in \$(oc get ns --no-headers | awk '{print \$1}'); do count=\$(oc -n \$ns get networkpolicy --no-headers 2>/dev/null | wc -l | tr -d ' '); echo -e \"\$ns\\t\$count\"; done | sed -n '1,${MAX_OBJECTS_PER_SECTION}p'"
run_cmd "admin_network_policies" "oc get adminnetworkpolicy,baselineadminnetworkpolicy -A -o wide 2>/dev/null || true"
run_cmd "egress_objects" "oc get egressip,egressfirewall,egressrouter -A -o wide 2>/dev/null || true"
run_cmd "metallb_state" "oc get ns metallb-system >/dev/null 2>&1 && { oc get all -n metallb-system -o wide; echo; oc get ipaddresspools,l2advertisements,bgppeers,bgpadvertisements -A -o yaml 2>/dev/null || true; } || true"
run_cmd "nmstate_state" "oc get nmstate,nodenetworkstate,nodenetworkconfigurationpolicy -A -o wide 2>/dev/null || true"
run_cmd "sriov_state" "oc get sriovnetworknodestates.sriovnetwork.openshift.io,sriovnetworknodepolicies.sriovnetwork.openshift.io,sriovnetworks.sriovnetwork.openshift.io -A -o wide 2>/dev/null || true"
run_cmd "multus_nad" "oc get network-attachment-definitions.k8s.cni.cncf.io -A -o wide 2>/dev/null | sed -n '1,${MAX_OBJECTS_PER_SECTION}p' || true"
run_cmd "ovn_kubernetes_pods" "oc get pods -n openshift-ovn-kubernetes -o wide 2>/dev/null || true"
run_cmd "network_warnings" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp | grep -Ei 'network|dns|route|ingress|egress|multus|ovn|sriov|metallb|endpoint|probe|timeout|connection' | tail -n ${MAX_OBJECTS_PER_SECTION} || true"

if has_jq; then
  oc get network.config.openshift.io cluster -o json > "$RAW_DIR/network_config.json" 2>/dev/null || true
  mtu=$(jq -r '.status.clusterNetworkMTU // empty' "$RAW_DIR/network_config.json" 2>/dev/null || true)
  plugin=$(jq -r '.status.networkType // .spec.networkType // empty' "$RAW_DIR/network_config.json" 2>/dev/null || true)
  [[ -n "$plugin" ]] && add_finding "Info" "Network" "Cluster network plugin: ${plugin}" "$RAW_DIR/network_config.json" "The CNI plugin determines feature availability and troubleshooting path." "Document the selected network plugin, MTU, and operational support model."
  [[ -n "$mtu" ]] && add_finding "Info" "Network" "Cluster network MTU detected: ${mtu}" "$RAW_DIR/network_config.json" "MTU mismatch can cause intermittent application or route failures." "Validate the configured overlay MTU against the underlay network and load balancer path."
fi

svc_no_ep_count=$(grep -vc '^#' "$RAW_DIR/services_without_ready_endpoints.txt" 2>/dev/null || echo 0)
if [[ "$svc_no_ep_count" -gt 0 ]]; then
  add_finding "Severe" "Network" "Detected services without ready endpoints" "$RAW_DIR/services_without_ready_endpoints.txt" "Traffic to Services without ready endpoints can fail or create misleading application availability symptoms." "Have application owners either remove stale Services or restore the backing pods/endpoints; verify associated Routes and readiness probes."
fi
if grep -Eiq 'timeout|probe|connection|endpoint' "$RAW_DIR/network_warnings.txt" 2>/dev/null; then
  add_finding "Severe" "Network" "Detected network or probe-related warning events" "$RAW_DIR/network_warnings.txt" "Probe and traffic-path timeouts can affect perceived platform availability and can be caused by overloaded pods, blocked paths, or endpoint churn." "Correlate warning events with pod placement, services, endpoints, ingress, network policies, and recent changes."
fi

append_md_section "Network Config" "$RAW_DIR/network_config.txt"
append_md_section "Proxy Config" "$RAW_DIR/proxy_config.txt"
append_md_section "DNS Config" "$RAW_DIR/dns_config.txt"
append_md_section "Ingress Controllers" "$RAW_DIR/ingresscontrollers.txt"
append_md_section "Services without Ready Endpoints" "$RAW_DIR/services_without_ready_endpoints.txt"
append_md_section "Network Policies Summary" "$RAW_DIR/network_policies_summary.txt"
append_md_section "Egress Objects" "$RAW_DIR/egress_objects.txt"
append_md_section "MetalLB State" "$RAW_DIR/metallb_state.txt"
append_md_section "NMState State" "$RAW_DIR/nmstate_state.txt"
append_md_section "SR-IOV State" "$RAW_DIR/sriov_state.txt"
append_md_section "Network Warning Events" "$RAW_DIR/network_warnings.txt"
finish_md
generate_html_from_md
log "Done. Report: $HTML_REPORT"
echo "$RUN_DIR"
