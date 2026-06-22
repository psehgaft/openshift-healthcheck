#!/usr/bin/env bash
set -euo pipefail

SUBJECT_KIND="${SUBJECT_KIND:-Group}"
SUBJECT_NAME="${SUBJECT_NAME:-headlamp-rbac-report-readers}"

case "${SUBJECT_KIND}" in
  User)
    AS_ARGS=(--as="${SUBJECT_NAME}")
    ;;
  Group)
    AS_ARGS=(--as=rbac-report-verifier --as-group="${SUBJECT_NAME}")
    ;;
  ServiceAccount)
    AS_ARGS=(--as="${SUBJECT_NAME}")
    ;;
  *)
    echo "ERROR: SUBJECT_KIND must be User, Group, or ServiceAccount." >&2
    exit 1
    ;;
esac

check() {
  description="$1"
  shift
  result="$(oc auth can-i "$@" "${AS_ARGS[@]}")"
  printf '%-72s %s\n' "${description}" "${result}"
}

echo "Validating Headlamp RBAC report reader: ${SUBJECT_KIND}/${SUBJECT_NAME}"
check "List ClusterRoles" list clusterroles.rbac.authorization.k8s.io
check "List ClusterRoleBindings" list clusterrolebindings.rbac.authorization.k8s.io
check "List Roles across namespaces" list roles.rbac.authorization.k8s.io --all-namespaces
check "List RoleBindings across namespaces" list rolebindings.rbac.authorization.k8s.io --all-namespaces
check "List ServiceAccounts across namespaces" list serviceaccounts --all-namespaces
check "List OpenShift users" list users.user.openshift.io
check "List OpenShift groups" list groups.user.openshift.io
check "List SCCs" list securitycontextconstraints.security.openshift.io

echo
echo "The following sensitive permissions should be no:"
check "Read Secrets across namespaces" get secrets --all-namespaces
check "Patch ClusterRoles" patch clusterroles.rbac.authorization.k8s.io
check "Create ClusterRoleBindings" create clusterrolebindings.rbac.authorization.k8s.io
check "Impersonate users" impersonate users
