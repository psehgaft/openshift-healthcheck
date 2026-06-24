#!/usr/bin/env bash
# Lightweight in-cluster ACM check. Requires only oc and read access.
set -u

OC="${OC:-oc}"
FAIL=0
WARN=0

result() {
  printf '%-5s | %-24s | %s\n' "$1" "$2" "$3"
  case "$1" in
    FAIL) FAIL=$((FAIL + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
  esac
}

printf 'ACM lightweight health check - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '--------------------------------------------------------------------------'

if ! "${OC}" get --raw=/readyz 2>/dev/null | grep -q '^ok'; then
  result FAIL "API readiness" "/readyz is not ok"
else
  result PASS "API readiness" "ok"
fi

CV_CONDITIONS="$("${OC}" get clusterversion version \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || true)"
CV_AVAILABLE="$(printf '%s\n' "${CV_CONDITIONS}" | awk -F= '$1=="Available" {print $2; exit}')"
CV_FAILING="$(printf '%s\n' "${CV_CONDITIONS}" | awk -F= '$1=="Failing" {print $2; exit}')"
CV_PROGRESSING="$(printf '%s\n' "${CV_CONDITIONS}" | awk -F= '$1=="Progressing" {print $2; exit}')"
if [ "${CV_AVAILABLE}" = "True" ] && [ "${CV_FAILING:-False}" = "False" ]; then
  if [ "${CV_PROGRESSING:-False}" = "True" ]; then
    result WARN "ClusterVersion" "Available=True, Failing=False, Progressing=True"
  else
    result PASS "ClusterVersion" "Available=True, Failing=False, Progressing=False"
  fi
else
  result FAIL "ClusterVersion" "Available=${CV_AVAILABLE:-unknown}, Failing=${CV_FAILING:-unknown}, Progressing=${CV_PROGRESSING:-unknown}"
  "${OC}" get clusterversion version 2>/dev/null || true
fi

BAD_CO="$("${OC}" get clusteroperators --no-headers 2>/dev/null | awk '$2!="True" || $4=="True" {print $1}' | paste -sd, -)"
if [ -z "${BAD_CO}" ]; then
  result PASS "ClusterOperators" "No unavailable/degraded operator"
else
  result FAIL "ClusterOperators" "${BAD_CO}"
fi

MCH_LINE="$("${OC}" get multiclusterhub -A --no-headers 2>/dev/null | head -1 || true)"
if [ -z "${MCH_LINE}" ]; then
  result FAIL "MultiClusterHub" "No instance found"
elif printf '%s' "${MCH_LINE}" | grep -q 'Running'; then
  result PASS "MultiClusterHub" "Running"
else
  result FAIL "MultiClusterHub" "${MCH_LINE}"
fi

MCE_LINE="$("${OC}" get multiclusterengine --no-headers 2>/dev/null | head -1 || true)"
if [ -z "${MCE_LINE}" ]; then
  result FAIL "MultiClusterEngine" "No instance found"
elif printf '%s' "${MCE_LINE}" | grep -Eq 'Available|Running'; then
  result PASS "MultiClusterEngine" "Available/Running"
else
  result FAIL "MultiClusterEngine" "${MCE_LINE}"
fi

BAD_MC="$("${OC}" get managedclusters --no-headers 2>/dev/null | awk '$4!="True" || $5!="True" {print $1}' | paste -sd, -)"
MC_COUNT="$("${OC}" get managedclusters --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${MC_COUNT}" -eq 0 ]; then
  result WARN "ManagedClusters" "No managed clusters found"
elif [ -z "${BAD_MC}" ]; then
  result PASS "ManagedClusters" "${MC_COUNT} joined and available"
else
  result FAIL "ManagedClusters" "Unavailable/not joined: ${BAD_MC}"
fi

BAD_ADDONS="$("${OC}" get managedclusteraddons -A --no-headers 2>/dev/null | awk '$3!="True" {print $1"/"$2}' | paste -sd, -)"
if [ -z "${BAD_ADDONS}" ]; then
  result PASS "ManagedClusterAddOns" "No unavailable add-on in tabular output"
else
  result FAIL "ManagedClusterAddOns" "${BAD_ADDONS}"
fi

BAD_PODS="$("${OC}" get pods -A --no-headers 2>/dev/null | grep -E 'open-cluster-management|multicluster-engine' | awk '$4!="Running" && $4!="Completed" {print $1"/"$2":"$4}' | paste -sd, -)"
if [ -z "${BAD_PODS}" ]; then
  result PASS "ACM pods" "All discovered ACM pods Running/Completed"
else
  result FAIL "ACM pods" "${BAD_PODS}"
fi

BS_LINE="$("${OC}" get backupschedule -A --no-headers 2>/dev/null | head -1 || true)"
if [ -z "${BS_LINE}" ]; then
  result WARN "BackupSchedule" "Not configured or not authorized"
elif printf '%s' "${BS_LINE}" | grep -Eq 'Enabled|Running'; then
  result PASS "BackupSchedule" "Enabled/Running"
else
  result FAIL "BackupSchedule" "${BS_LINE}"
fi

MCO_LINE="$("${OC}" get multiclusterobservability --no-headers 2>/dev/null | head -1 || true)"
if [ -z "${MCO_LINE}" ]; then
  result WARN "Observability" "Not enabled or not authorized"
else
  result PASS "Observability" "MultiClusterObservability exists"
fi

printf '%s\n' '--------------------------------------------------------------------------'
printf 'Summary: FAIL=%s WARN=%s\n' "${FAIL}" "${WARN}"
[ "${FAIL}" -eq 0 ] || exit 2
