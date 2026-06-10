#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ocp418-deep-lib.sh
source "$SCRIPT_DIR/ocp418-deep-lib.sh"
parse_common_args "$@"
require_oc
init_run_dir "storage-deep-dive"
start_md "OpenShift 4.18+ Storage Deep Dive"

run_cmd "storageclasses" "oc get storageclass -o wide; echo; oc get storageclass -o yaml"
run_cmd "pv_all" "oc get pv -o wide | sed -n '1,${MAX_OBJECTS_PER_SECTION}p'; echo; oc get pv -o json"
run_cmd "pvc_all" "oc get pvc -A -o wide | sed -n '1,${MAX_OBJECTS_PER_SECTION}p'; echo; oc get pvc -A -o json"
run_cmd "pvc_not_bound_strict" "oc get pvc -A -o jsonpath='{range .items[?(@.status.phase!=\"Bound\")]}{.metadata.namespace}{\"\\t\"}{.metadata.name}{\"\\t\"}{.status.phase}{\"\\t\"}{.spec.storageClassName}{\"\\t\"}{.status.conditions[*].type}{\"\\t\"}{.status.conditions[*].message}{\"\\n\"}{end}' 2>/dev/null || true"
run_cmd "volumeattachments" "oc get volumeattachments.storage.k8s.io -o wide 2>/dev/null || true; echo; oc get volumeattachments.storage.k8s.io -o json 2>/dev/null || true"
run_cmd "csidrivers_csinodes" "oc get csidrivers.storage.k8s.io,csinodes.storage.k8s.io -o wide 2>/dev/null || true"
run_cmd "storage_operator" "oc get clusteroperator storage -o yaml 2>/dev/null || true"
run_cmd "local_storage" "oc get ns openshift-local-storage >/dev/null 2>&1 && { oc get all -n openshift-local-storage -o wide; oc get localvolumes,localvolumesets,localvolumediscoveries -A -o yaml 2>/dev/null || true; } || true"
run_cmd "monitoring_persistent_storage" "oc -n openshift-monitoring get pvc,pod -o wide 2>/dev/null || true"
run_cmd "image_registry_storage" "oc get configs.imageregistry.operator.openshift.io cluster -o yaml 2>/dev/null || true; echo; oc -n openshift-image-registry get pvc,pod -o wide 2>/dev/null || true"
run_cmd "odf_state" "oc get ns openshift-storage >/dev/null 2>&1 && { oc get csv,pod,pvc -n openshift-storage -o wide; echo; oc get storagecluster,cephcluster,cephblockpool,cephfilesystem,noobaa,backingstore,bucketclass -A -o yaml 2>/dev/null || true; } || true"
run_cmd "portworx_state" "oc get ns portworx >/dev/null 2>&1 && { oc get all,pvc -n portworx -o wide; echo; oc get storagecluster,stork,volumeplacementstrategy -A -o yaml 2>/dev/null || true; } || true"
run_cmd "storage_warnings" "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp | grep -Ei 'storage|volume|pvc|pv|mount|attach|detach|filesystem|ephemeral|evicted|disk|ceph|odf|csi|portworx' | tail -n ${MAX_OBJECTS_PER_SECTION} || true"

prom_query "pvc_usage_bytes" 'topk(50, kubelet_volume_stats_used_bytes)'
prom_query "pvc_available_bytes" 'topk(50, kubelet_volume_stats_available_bytes)'
prom_query "pvc_usage_percent" 'topk(50, (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100)'
prom_query "container_fs_usage" 'topk(50, container_fs_usage_bytes{container!="",pod!=""})'

if has_jq; then
  oc get pvc -A -o json > "$RAW_DIR/pvc_all.json" 2>/dev/null || true
  jq -r '.items[] | select(.status.phase != "Bound") | [.metadata.namespace,.metadata.name,.status.phase,(.spec.storageClassName//""),(.status.conditions//[]|map(.type+":"+(.message//""))|join(";"))] | @csv' "$RAW_DIR/pvc_all.json" > "$CSV_DIR/pvc-not-bound.csv" 2>/dev/null || true
  pending_count=$(wc -l < "$CSV_DIR/pvc-not-bound.csv" | tr -d ' ')
  if [[ "$pending_count" -ge "$PVC_PENDING_CRITICAL_THRESHOLD" ]]; then
    add_finding "Critical" "Storage" "Detected ${pending_count} PVCs not in Bound state" "$CSV_DIR/pvc-not-bound.csv" "Unbound PVCs can block workload scheduling, rollouts, or restore operations." "Review each claim event, storage class, provisioner status, quota, and volume attachment state; correct provisioning or capacity issues before scaling dependent workloads."
  fi
  jq -r '.items[] | [.metadata.namespace,.metadata.name,.status.phase,(.spec.storageClassName//""),(.spec.resources.requests.storage//""),(.spec.accessModes//[]|join("+")),(.metadata.creationTimestamp//"")] | @csv' "$RAW_DIR/pvc_all.json" > "$CSV_DIR/pvc-inventory.csv" 2>/dev/null || true
  oc get pv -o json > "$RAW_DIR/pv_all.json" 2>/dev/null || true
  jq -r '.items[] | [.metadata.name,.status.phase,(.spec.storageClassName//""),(.spec.capacity.storage//""),(.spec.accessModes//[]|join("+")),(.spec.claimRef.namespace//""),(.spec.claimRef.name//""),(.metadata.creationTimestamp//"")] | @csv' "$RAW_DIR/pv_all.json" > "$CSV_DIR/pv-inventory.csv" 2>/dev/null || true
fi

if grep -Eiq 'evicted|ephemeral local storage|disk pressure|mount|attach|detach|filesystem' "$RAW_DIR/storage_warnings.txt" 2>/dev/null; then
  add_finding "Severe" "Storage" "Storage-related warning events detected" "$RAW_DIR/storage_warnings.txt" "Volume, mount, attach, or eviction warnings can cause failed workloads and delayed recovery." "Group events by namespace and storage class, then validate CSI controller/node plugin health, quota, ephemeral-storage limits, PV attachment state, and backend capacity."
fi

append_md_section "StorageClasses" "$RAW_DIR/storageclasses.txt"
append_md_section "PVCs not Bound" "$RAW_DIR/pvc_not_bound_strict.txt"
append_md_section "VolumeAttachments" "$RAW_DIR/volumeattachments.txt"
append_md_section "CSI Drivers and Nodes" "$RAW_DIR/csidrivers_csinodes.txt"
append_md_section "Image Registry Storage" "$RAW_DIR/image_registry_storage.txt"
append_md_section "Monitoring Persistent Storage" "$RAW_DIR/monitoring_persistent_storage.txt"
append_md_section "ODF State" "$RAW_DIR/odf_state.txt"
append_md_section "Portworx State" "$RAW_DIR/portworx_state.txt"
append_md_section "Storage Warning Events" "$RAW_DIR/storage_warnings.txt"
finish_md
generate_html_from_md
log "Done. Report: $HTML_REPORT"
echo "$RUN_DIR"
