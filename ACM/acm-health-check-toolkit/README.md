# Red Hat Advanced Cluster Management health check and best-practice validation

**Reference profile:** Red Hat OpenShift Container Platform 4.18 and Red Hat Advanced Cluster Management for Kubernetes 2.15  
**Execution model:** Read-only audit first; configuration changes are separate, optional, and subject to change control  
**Primary output:** Markdown report, CSV findings, raw YAML/text evidence, and selected failing-pod logs

## 1. Objective

This runbook validates that an ACM hub is installed, operational, supportable, observable, recoverable, and managed with an appropriate security and governance baseline. It covers:

- OpenShift hub platform health.
- Operator Lifecycle Manager installation state for ACM and multicluster engine.
- `MultiClusterHub` and `MultiClusterEngine` reconciliation.
- ACM namespace, pod, controller, PVC, event, and resource-pressure checks.
- Managed-cluster registration, availability, add-ons, and `ManifestWork` delivery.
- Governance policy deployment and compliance visibility.
- Multicluster observability and its object-storage dependency.
- ACM backup and restore integration with OADP and Velero.
- RBAC, dangerous `cluster-admin` grants, insecure application channels, and TLS-certificate expiry.
- Availability mode, infrastructure-node placement, sizing, and operational automation.

The toolkit does not modify the hub during the primary audit. Optional YAML examples are deliberately separated under `examples/`.

## 2. Acceptance model

Use the following interpretation:

| Result | Meaning | Operational action |
|---|---|---|
| `PASS` | The observed state meets the automated check. | Preserve evidence and continue. |
| `WARN` | The condition can be valid, but requires architectural or operational review. | Record an exception, owner, due date, and decision. |
| `FAIL` | A prerequisite, availability condition, security control, or recovery dependency is unhealthy. | Do not declare ACM production-ready until resolved or formally accepted. |
| `INFO` | Inventory or architecture context without an automatic pass/fail judgment. | Compare with the approved design. |

The generated score is a triage indicator. It is not a Red Hat certification, support statement, or substitute for a tested recovery exercise.

## 3. Toolkit contents

```text
acm-health-check-toolkit/
├── acm-health-check.md
├── README.md
├── scripts/
│   ├── acm-health-check.sh
│   ├── acm-health-check-lite.sh
│   ├── acm-must-gather.sh
│   └── managed-cluster-deep-dive.sh
├── automation/
│   ├── acm-health-check-lite.sh
│   ├── cronjob.yaml
│   ├── kustomization.yaml
│   └── namespace-rbac.yaml
└── examples/
    ├── backup/
    │   ├── backup-schedule.yaml
    │   └── restore-all.template.yaml
    ├── governance/
    │   └── acm-agent-presence-policy.yaml
    ├── infra-placement/
    │   └── multiclusterhub-infra-example.yaml
    └── observability/
        ├── 00-namespace.yaml
        ├── 01-thanos-object-storage-secret.template.yaml
        └── 02-multiclusterobservability.yaml
```

## 4. Safety and handling requirements

1. Run the primary script from an administrative workstation, bastion, or controlled automation runner.
2. Use a dedicated audit identity where possible. Some checks require `cluster-admin`; the script tolerates unavailable optional permissions and records skipped checks.
3. Treat the output as sensitive. It can contain object metadata, topology, event messages, RBAC assignments, internal hostnames, and selected failing-pod logs.
4. The script does not intentionally export Secret values. The certificate check decodes TLS certificates temporarily and deletes the local temporary file.
5. Never commit real object-storage access keys, kubeconfigs, generated reports, or must-gather archives to Git.
6. Do not apply the restore template on the active hub.
7. Do not patch `MultiClusterHub`, `Subscription`, `MultiClusterEngine`, observability, or backup resources without capturing the current YAML and preparing a rollback.

Recommended local permissions:

```bash
umask 077
```

## 5. Prerequisites

### 5.1 Required tools

```bash
oc version --client
jq --version
openssl version
bash --version
```

The full audit requires `oc` and `jq`. `openssl` is optional but required for the TLS-expiry check.

### 5.2 Login and context verification

```bash
oc login https://api.<hub-domain>:6443
oc whoami
oc whoami --show-server
oc config current-context
```

Confirm that this is the ACM **hub** cluster, not a managed cluster:

```bash
oc get multiclusterhub -A
oc get multiclusterengine
```

Expected high-level state for ACM 2.15:

- One intended `MultiClusterHub` instance, normally in `open-cluster-management`.
- `MultiClusterHub` phase `Running`.
- One `MultiClusterEngine` instance created and managed by ACM.
- ACM and MCE current CSVs in `Succeeded` phase.
- OpenShift `ClusterVersion` available and not failing.

### 5.3 Permission preflight

```bash
oc auth can-i get clusterversion.config.openshift.io/version
oc auth can-i get multiclusterhubs.operator.open-cluster-management.io -A
oc auth can-i get multiclusterengines.multicluster.openshift.io
oc auth can-i get managedclusters.cluster.open-cluster-management.io
oc auth can-i get managedclusteraddons.addon.open-cluster-management.io -A
oc auth can-i get policies.policy.open-cluster-management.io -A
oc auth can-i get pods -A
oc auth can-i get secrets -A
```

Secret read access is not mandatory for the operational checks, but it is required for local TLS certificate-expiry inspection. Avoid granting it only for convenience; use the approved privileged audit role.

## 6. Run the complete read-only health check

From the toolkit directory:

```bash
chmod +x scripts/*.sh

./scripts/acm-health-check.sh
```

Specify an output directory:

```bash
./scripts/acm-health-check.sh acm-health-mgmtcnfs-$(date +%Y%m%d)
```

Useful environment variables:

```bash
export RESTART_WARN_THRESHOLD=5
export CERT_WARN_DAYS=30
export COLLECT_FAILING_POD_LOGS=true
export FAIL_ON_WARN=false

./scripts/acm-health-check.sh acm-health-$(date +%Y%m%d-%H%M%S)
```

Generated content:

```text
acm-health-check-<timestamp>/
├── report.md
├── results.csv
├── raw/
└── logs/
```

Exit codes:

| Code | Meaning |
|---:|---|
| `0` | No `FAIL` findings. Warnings can still exist. |
| `1` | Warnings exist and `FAIL_ON_WARN=true`. |
| `2` | One or more `FAIL` findings. |
| `3` | A required local command is missing. |
| `4` | OpenShift authentication failed. |

A CI example:

```bash
set +e
./scripts/acm-health-check.sh "artifacts/acm-health-${BUILD_ID:-manual}"
rc=$?
set -e

case "$rc" in
  0) echo "ACM operational checks passed" ;;
  1) echo "ACM checks completed with warnings" ;;
  2) echo "ACM health check failed"; exit 2 ;;
  *) echo "Health-check execution error: $rc"; exit "$rc" ;;
esac
```

## 7. Manual validation sequence

The script collects these resources automatically. The commands below provide an operator-friendly verification path and help validate any generated finding.

### 7.1 Validate OpenShift hub health first

```bash
oc get clusterversion version
oc get clusteroperators
oc get nodes -o wide
oc get machineconfigpools
oc get --raw='/readyz?verbose'
```

Target state:

- `ClusterVersion`: `AVAILABLE=True`, `FAILING=False`.
- Cluster operators: `AVAILABLE=True`, `DEGRADED=False`.
- Nodes: `Ready`.
- MachineConfigPools: updated and not degraded.
- API `/readyz`: all required checks pass.

Do not troubleshoot ACM in isolation when the API server, authentication, ingress, DNS, storage, monitoring, or nodes are degraded.

### 7.2 Validate ACM and MCE installation through OLM

```bash
oc get subscription.operators.coreos.com -A | \
  grep -E 'advanced-cluster-management|multicluster-engine'

oc get csv.operators.coreos.com -A | \
  grep -E 'advanced-cluster-management|multicluster-engine'

oc get installplan.operators.coreos.com -A
oc get catalogsource.operators.coreos.com -A
```

Inspect current subscriptions:

```bash
oc get subscription.operators.coreos.com -A -o json | jq -r '
  .items[]
  | select(
      (.metadata.name | test("advanced-cluster-management|multicluster-engine"; "i"))
      or ((.spec.name // "") | test("advanced-cluster-management|multicluster-engine"; "i"))
    )
  | [
      .metadata.namespace,
      .metadata.name,
      (.spec.channel // ""),
      (.spec.installPlanApproval // ""),
      (.status.currentCSV // "")
    ] | @tsv'
```

Validate the current CSV, not every historical/replaced CSV:

```bash
ACM_NS="$(oc get subscription -A -o json | jq -r '
  .items[]
  | select((.spec.name // "") | test("advanced-cluster-management"; "i"))
  | .metadata.namespace' | head -1)"

ACM_CSV="$(oc get subscription -n "$ACM_NS" -o json | jq -r '
  .items[]
  | select((.spec.name // "") | test("advanced-cluster-management"; "i"))
  | .status.currentCSV' | head -1)"

oc get csv -n "$ACM_NS" "$ACM_CSV" -o yaml
```

Review:

- Current CSV phase is `Succeeded`.
- Subscription channel matches the intended ACM minor release.
- Install plan policy matches enterprise change control. Manual approval is common in tightly controlled production environments, but it creates an operational obligation to review and approve errata promptly.
- Catalog sources are healthy and have recent registry polls.
- ACM 2.15 and MCE 2.10 remain paired as the supported product combination for that release.

### 7.3 Validate `MultiClusterHub`

```bash
oc get multiclusterhub -A
oc get multiclusterhub -A -o yaml
```

Focused status:

```bash
oc get multiclusterhub -A -o json | jq -r '
  .items[] |
  {
    namespace: .metadata.namespace,
    name: .metadata.name,
    phase: .status.phase,
    currentVersion: .status.currentVersion,
    desiredVersion: .status.desiredVersion,
    availabilityConfig: (.spec.availabilityConfig // "High (default)"),
    nodeSelector: (.spec.nodeSelector // {}),
    tolerations: (.spec.tolerations // [])
  }'
```

Inspect components and failure reasons:

```bash
oc get multiclusterhub -A -o json | jq '.items[].status'
oc get multiclusterhub -A -o yaml | grep -n -C3 'ProgressDeadlineExceeded'
```

Target state:

- Phase is `Running`.
- Current and desired versions are aligned after reconciliation.
- No component reports `ProgressDeadlineExceeded`.
- `availabilityConfig` is `High` by default for a production multi-node hub.
- Use `Basic` for a supported single-node topology where documented.
- Node placement matches the approved worker/infra-node design.

### 7.4 Validate `MultiClusterEngine`

```bash
oc get multiclusterengine
oc get multiclusterengine -o yaml
```

Focused status:

```bash
oc get multiclusterengine -o json | jq -r '
  .items[] |
  {
    name: .metadata.name,
    phase: .status.phase,
    currentVersion: .status.currentVersion,
    desiredVersion: .status.desiredVersion,
    availabilityConfig: (.spec.availabilityConfig // "default")
  }'
```

The MCE resource is created and managed as part of ACM. Avoid independently forcing incompatible MCE versions or replacing ACM-owned settings.

### 7.5 Validate ACM workloads

List the primary namespaces:

```bash
for ns in \
  open-cluster-management \
  multicluster-engine \
  open-cluster-management-hub \
  open-cluster-management-agent-addon \
  open-cluster-management-observability \
  open-cluster-management-backup
do
  oc get namespace "$ns" >/dev/null 2>&1 || continue
  echo "===== $ns ====="
  oc get pods -n "$ns" -o wide
  oc get deploy,sts,ds -n "$ns"
  oc get pvc -n "$ns"
done
```

Find abnormal pods:

```bash
oc get pods -A -o json | jq -r '
  .items[]
  | select(.metadata.namespace | test("open-cluster-management|multicluster-engine"))
  | select(
      (.status.phase != "Running" and .status.phase != "Succeeded")
      or any(.status.containerStatuses[]?;
        (.state.waiting.reason // "")
        | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError")
      )
    )
  | [
      .metadata.namespace,
      .metadata.name,
      .status.phase,
      ([.status.containerStatuses[]?.state.waiting.reason] | join(","))
    ] | @tsv'
```

Find high restart counts:

```bash
oc get pods -A -o json | jq -r '
  .items[]
  | select(.metadata.namespace | test("open-cluster-management|multicluster-engine"))
  | ([.status.containerStatuses[]?.restartCount] | add // 0) as $r
  | select($r >= 5)
  | [.metadata.namespace,.metadata.name,($r|tostring)] | @tsv'
```

For each affected pod:

```bash
NS=<namespace>
POD=<pod>

oc describe pod -n "$NS" "$POD"
oc logs -n "$NS" "$POD" --all-containers --tail=300 --prefix
oc logs -n "$NS" "$POD" --all-containers --previous --tail=300 --prefix
oc get events -n "$NS" --sort-by=.lastTimestamp | tail -100
```

Interpretation:

- `Pending`: inspect CPU/memory requests, taints, selectors, affinity, topology, PVCs, and quotas.
- `OOMKilled`: verify actual memory demand, limits, leaks, and fleet scale before changing operator-managed resources.
- Probe failures: inspect dependent services, certificates, DNS, and network policy.
- Image pull errors: validate pull secret, mirrored catalogs, ICSP/IDMS/ITMS, proxy, and registry trust.
- Repeated restarts during an upgrade can be transient; repeated restarts outside a change window require root-cause analysis.

### 7.6 Validate managed clusters

```bash
oc get managedclusters
```

Detailed condition table:

```bash
oc get managedclusters -o json | jq -r '
  .items[] |
  .metadata.name as $name |
  ([.status.conditions[]? | select(.type=="ManagedClusterJoined")][0].status // "Unknown") as $joined |
  ([.status.conditions[]? | select(.type=="ManagedClusterConditionAvailable")][0].status // "Unknown") as $available |
  [$name, (.spec.hubAcceptsClient|tostring), $joined, $available] | @tsv'
```

Expected for actively managed clusters:

- `hubAcceptsClient=true`.
- `ManagedClusterJoined=True`.
- `ManagedClusterConditionAvailable=True`.

Show the reason for a failed cluster:

```bash
CLUSTER=<managed-cluster-name>

oc get managedcluster "$CLUSTER" -o json | jq -r '
  .status.conditions[]?
  | [.type,.status,(.reason // ""),(.message // "")] | @tsv'
```

Run the packaged deep dive:

```bash
./scripts/managed-cluster-deep-dive.sh "$CLUSTER"
```

Include managed-cluster-side evidence when a secure kubeconfig is available:

```bash
./scripts/managed-cluster-deep-dive.sh \
  "$CLUSTER" \
  "/secure/kubeconfigs/${CLUSTER}.kubeconfig"
```

Common root causes:

- Managed-cluster DNS cannot resolve hub API or callback endpoints.
- Required outbound TCP access is blocked.
- Proxy/noProxy configuration excludes required cluster domains incorrectly.
- Hub or managed-cluster certificates changed or expired.
- Registration/work agent pods are unhealthy.
- Import secret was not generated or applied correctly.
- Time synchronization causes certificate validation failures.

### 7.7 Validate managed-cluster add-ons

```bash
oc get managedclusteraddons -A
```

Condition detail:

```bash
oc get managedclusteraddons -A -o json | jq -r '
  .items[] |
  .metadata.namespace as $cluster |
  .metadata.name as $addon |
  ([.status.conditions[]? | select(.type=="Available")][0].status // "Unknown") as $available |
  ([.status.conditions[]? | select(.type=="Degraded")][0].status // "False") as $degraded |
  [$cluster,$addon,$available,$degraded] | @tsv'
```

Required add-ons vary by enabled ACM features. An add-on resource that exists should normally report available and not degraded. Review at least:

- Governance policy framework.
- Configuration policy controller.
- Search collector.
- Work manager.
- Observability controller when observability is enabled.
- Cluster proxy, application manager, certificate policy, GitOps, or other optional add-ons when intentionally configured.

### 7.8 Validate work delivery

```bash
oc get manifestworks -A
```

Failed application status:

```bash
oc get manifestworks -A -o json | jq -r '
  .items[]
  | ([.status.conditions[]? | select(.type=="Applied")][0].status // "Unknown") as $applied
  | ([.status.conditions[]? | select(.type=="Available")][0].status // "Unknown") as $available
  | select($applied != "True" or $available == "False")
  | [.metadata.namespace,.metadata.name,$applied,$available] | @tsv'
```

For an affected work:

```bash
oc describe manifestwork -n "$CLUSTER" "$WORK_NAME"
oc get manifestwork -n "$CLUSTER" "$WORK_NAME" -o yaml
```

Correlate with `klusterlet-work-agent` logs on the managed cluster.

## 8. Observability validation

ACM installs the multicluster observability operator component by default, but the service is enabled by creating a `MultiClusterObservability` resource and supplying supported object storage.

### 8.1 Inventory

```bash
oc get multiclusterobservability
oc get multiclusterobservability observability -o yaml
oc get pods -n open-cluster-management-observability
oc get pvc -n open-cluster-management-observability
oc get managedclusteraddons -A | grep observability
```

### 8.2 Validate object-storage reference without displaying credentials

```bash
OBS_SECRET="$(oc get multiclusterobservability observability -o jsonpath='{.spec.storageConfig.metricObjectStorage.name}')"
OBS_KEY="$(oc get multiclusterobservability observability -o jsonpath='{.spec.storageConfig.metricObjectStorage.key}')"

echo "Secret: $OBS_SECRET"
echo "Key:    $OBS_KEY"
oc get secret -n open-cluster-management-observability "$OBS_SECRET" \
  -o custom-columns=NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp
```

Do not print `.data` or `.stringData` in shared logs.

### 8.3 Target state

- `MultiClusterObservability` reconciles without failing ready/available conditions.
- Object-storage endpoint uses TLS with correct CA trust.
- `insecure_skip_verify` is not used as a permanent production workaround.
- Thanos receiver, store, query, compactor, rule, and Grafana-related components meet desired availability.
- All observability PVCs are bound and use a supported StorageClass.
- Object storage has lifecycle, retention, capacity, encryption, and access-control policies.
- Metrics collection is disabled only for clusters with a documented reason.
- Capacity is reviewed against managed-cluster count, collected series, retention, and query demand.

### 8.4 Optional enablement templates

Review and edit:

```bash
cat examples/observability/01-thanos-object-storage-secret.template.yaml
cat examples/observability/02-multiclusterobservability.yaml
```

Create the namespace:

```bash
oc apply -f examples/observability/00-namespace.yaml
```

Create credentials through the approved secret-management workflow. A direct Secret template is supplied only to document the required structure.

Dry-run the MCO resource:

```bash
oc apply --dry-run=server \
  -f examples/observability/02-multiclusterobservability.yaml
```

Apply only after storage and credential validation:

```bash
oc apply -f examples/observability/02-multiclusterobservability.yaml
oc get multiclusterobservability observability -w
```

## 9. Backup, restore, and disaster-recovery validation

ACM hub backup does not replace the OpenShift control-plane/etcd backup. Maintain both:

1. OpenShift etcd/control-plane backup for the hub cluster.
2. ACM backup and restore for managed-cluster registration data, policies, applications, credentials, and ACM resources.

### 9.1 Validate ACM backup dependencies

```bash
oc get csv -A | grep -Ei 'oadp|backup'
oc get dataprotectionapplication -A
oc get backupstoragelocation -A
oc get backupschedule -A
oc get schedules.velero.io -A | grep acm
oc get backups.velero.io -A | grep '^.*acm-'
```

Expected:

- OADP operator is installed and healthy.
- `DataProtectionApplication` reconciles successfully.
- At least one intended `BackupStorageLocation` is `Available`.
- ACM `BackupSchedule` phase is `Enabled` or the current-version equivalent.
- The schedule is not unintentionally paused.
- There is no `BackupCollision` state.
- Recent `acm-*` Velero backups complete successfully.
- Backup retention and frequency meet the business RPO.
- Backup data is stored outside the failure domain of the active hub.

### 9.2 Inspect the schedule

```bash
oc get backupschedule -A -o json | jq -r '
  .items[] |
  {
    namespace: .metadata.namespace,
    name: .metadata.name,
    phase: .status.phase,
    schedule: .spec.veleroSchedule,
    ttl: .spec.veleroTtl,
    paused: (.spec.paused // false),
    managedServiceAccount: (.spec.useManagedServiceAccount // false)
  }'
```

### 9.3 Create a schedule after OADP is ready

Review the example:

```bash
cat examples/backup/backup-schedule.yaml
oc apply --dry-run=server -f examples/backup/backup-schedule.yaml
```

Apply:

```bash
oc apply -f examples/backup/backup-schedule.yaml
oc get backupschedule -n open-cluster-management-backup -w
```

The example uses a six-hour schedule and 30-day TTL. Those values are examples, not universal Red Hat recommendations. Derive them from RPO/RTO, recovery-test duration, fleet scale, object-storage cost, and compliance retention.

### 9.4 Detect backup collision

```bash
oc get backupschedule -A
oc get backupschedule -A -o yaml | grep -n -C4 BackupCollision
```

Only the active primary hub should write to a shared ACM backup location. Before switching primary hubs, pause or remove the schedule on the old primary according to the documented recovery sequence.

### 9.5 Restore test

A backup is not considered proven until restored.

Minimum quarterly or release-change exercise:

1. Provision a compatible isolated recovery hub.
2. Install the same supported OpenShift/ACM/OADP combination required by the restore procedure.
3. Configure read/write access to the approved backup location.
4. Verify that the original active hub is not writing conflicting backups.
5. Restore passive resources first if using an active/passive design.
6. Validate policies, applications, secrets, credentials, placements, and managed-cluster inventory.
7. Activate managed-cluster resources only at the approved cutover point.
8. Confirm cluster reimport/registration behavior.
9. Record actual RTO, errors, manual actions, and recovery gaps.
10. Revert or destroy the test hub securely.

The file `examples/backup/restore-all.template.yaml` is a documentation template, not a routine apply file.

### 9.6 OpenShift etcd backup

Follow the OpenShift 4.18 control-plane backup procedure and store the backup securely outside the cluster failure domain. The etcd snapshot must match the OpenShift z-stream requirements documented by Red Hat.

## 10. Governance validation

### 10.1 Inventory and compliance

```bash
oc get policies -A
oc get placementbindings -A
oc get placements.cluster.open-cluster-management.io -A
oc get placementdecisions.cluster.open-cluster-management.io -A
```

Noncompliant policies:

```bash
oc get policies -A -o json | jq -r '
  .items[]
  | select((.status.compliant // "Unknown") == "NonCompliant")
  | [.metadata.namespace,.metadata.name,(.spec.remediationAction // "")] | @tsv'
```

Best-practice operating model:

1. Start new controls with `remediationAction: inform`.
2. Validate impact on representative non-production clusters.
3. Define severity, control owner, exception process, and remediation SLA.
4. Promote only approved controls to enforcement.
5. Use `Placement` and `ManagedClusterSetBinding` to target explicit cluster sets.
6. Keep policy manifests in Git and use pull requests, review, and signed commits according to enterprise policy.
7. Alert on high-severity noncompliance and governance-controller degradation.
8. Avoid policies that mutate operator-managed ACM or OpenShift resources without product-specific validation.

### 10.2 Optional ACM agent-presence policy

The supplied policy checks for the ACM agent namespaces and `Klusterlet` resource on clusters in the built-in global cluster set.

Server-side validation:

```bash
oc apply --dry-run=server \
  -f examples/governance/acm-agent-presence-policy.yaml
```

Apply in inform mode:

```bash
oc apply -f examples/governance/acm-agent-presence-policy.yaml
oc get policy -n open-cluster-management-global-set acm-agent-presence -w
```

Inspect placement decisions:

```bash
oc get placementdecision -n open-cluster-management-global-set \
  -l cluster.open-cluster-management.io/placement=acm-agent-presence \
  -o yaml
```

## 11. Security and RBAC validation

### 11.1 Privileged access inventory

```bash
oc get clusterrolebindings -o json | jq -r '
  .items[]
  | select(.roleRef.name=="cluster-admin")
  | .metadata.name as $binding
  | .subjects[]?
  | [$binding,.kind,.name,(.namespace // "")] | @tsv'
```

Critical anti-pattern check:

```bash
oc get clusterrolebindings -o json | jq -r '
  .items[]
  | select(.roleRef.name=="cluster-admin")
  | select(any(.subjects[]?;
      .kind=="Group" and
      (.name=="system:authenticated" or
       .name=="system:unauthenticated" or
       .name=="system:anonymous")))
  | .metadata.name'
```

Any result from the second command is critical.

Operational requirements:

- Grant roles to enterprise groups rather than individual users where possible.
- Separate cluster-set administration, policy administration, application administration, and read-only access.
- Maintain a controlled break-glass process.
- Review service-account permissions and token use.
- Recertify privileged access periodically.
- Avoid sharing admin kubeconfigs.

### 11.2 Application channel TLS

```bash
oc get channels.apps.open-cluster-management.io -A -o json | jq -r '
  .items[]
  | select(.spec.insecureSkipVerify==true)
  | [.metadata.namespace,.metadata.name,(.spec.pathname // "")] | @tsv'
```

Replace permanent TLS bypasses with correct CA trust and endpoint certificates.

### 11.3 TLS certificate expiry

The full script checks `kubernetes.io/tls` secrets in known ACM namespaces without storing private keys or certificate content in the report.

Manual example:

```bash
NS=open-cluster-management
SECRET=<tls-secret>

oc get secret -n "$NS" "$SECRET" -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | \
  openssl x509 -noout -subject -issuer -dates
```

Classify each certificate as operator-managed or customer-managed before rotation. Manual replacement of operator-managed certificates can cause service disruption.

### 11.4 Secret management

- Do not store S3 credentials or import kubeconfigs in plain Git.
- Use supported secret-management integration.
- Rotate object-storage credentials and validate MCO/Velero reconnection.
- Scope object-storage permissions to required buckets and operations.
- Encrypt object storage and backups at rest and in transit.
- Audit access to ACM backup credentials because they can contain cluster-management material.

## 12. Availability, capacity, and infrastructure-node design

### 12.1 Availability configuration

```bash
oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.availabilityConfig}{"\n"}{end}'
```

For a normal multi-node production hub, `High` is the default and gives relevant hub components two replicas. `Basic` reduces replicas and resource consumption. Use the topology documented for your platform and ACM release.

### 12.2 Infrastructure nodes

Inventory:

```bash
oc get nodes -l node-role.kubernetes.io/infra -o wide
oc get pods -A -o wide | grep -E 'open-cluster-management|multicluster-engine'
```

A supported ACM infra-node pattern uses:

```yaml
metadata:
  labels:
    node-role.kubernetes.io/infra: ""
spec:
  taints:
  - key: node-role.kubernetes.io/infra
    effect: NoSchedule
```

The ACM operator subscription and `MultiClusterHub` must be configured consistently. If ODF or another CSI provider supplies storage to components placed on infra nodes, confirm that required CSI pods can also run according to the storage product documentation.

Review the example without applying it as a replacement resource:

```bash
cat examples/infra-placement/multiclusterhub-infra-example.yaml
```

Capture the live object before patching:

```bash
oc get multiclusterhub -A -o yaml > multiclusterhub-before.yaml
```

Example patch after design approval:

```bash
MCH_NS="$(oc get multiclusterhub -A -o jsonpath='{.items[0].metadata.namespace}')"
MCH_NAME="$(oc get multiclusterhub -A -o jsonpath='{.items[0].metadata.name}')"

oc patch multiclusterhub -n "$MCH_NS" "$MCH_NAME" \
  --type=merge \
  -p '{
    "spec": {
      "availabilityConfig": "High",
      "nodeSelector": {
        "node-role.kubernetes.io/infra": ""
      },
      "tolerations": [
        {
          "key": "node-role.kubernetes.io/infra",
          "operator": "Exists",
          "effect": "NoSchedule"
        }
      ]
    }
  }'
```

Important: customizing `spec.tolerations` replaces the default list. Preserve every required toleration from the approved design.

### 12.3 Resource demand

```bash
oc adm top nodes
oc adm top pods -A --containers | \
  grep -E 'open-cluster-management|multicluster-engine'
```

Requests and limits:

```bash
oc get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory' | \
  grep -E 'open-cluster-management|multicluster-engine'
```

Review:

- Sustained CPU throttling.
- Memory working set near limits.
- `OOMKilled` events.
- Pending pods caused by insufficient resources.
- Uneven topology or single-node concentration.
- PVC growth and object-storage growth.
- Hub etcd latency and object churn from fleet scale.
- Observability cardinality and retention.
- Backup duration relative to schedule frequency.

Do not arbitrarily edit resources on operator-managed Deployments. Use supported product configuration and sizing guidance.

## 13. Automated weekly lightweight check

The automation deploys:

- Namespace `acm-health-check`.
- Service account bound to the built-in `cluster-reader` role.
- ConfigMap-generated lightweight script.
- Weekly CronJob using the OpenShift 4.18 CLI image.

Review rendered objects:

```bash
oc kustomize automation/
```

Server-side dry run:

```bash
oc apply --dry-run=server -k automation/
```

Deploy:

```bash
oc apply -k automation/
```

Run immediately:

```bash
oc create job -n acm-health-check \
  --from=cronjob/acm-health-check \
  acm-health-check-manual-$(date +%s)
```

Read logs:

```bash
oc get jobs,pods -n acm-health-check
POD="$(oc get pods -n acm-health-check -l job-name \
  -o jsonpath='{.items[-1:].metadata.name}')"
oc logs -n acm-health-check "$POD"
```

The in-cluster check is intentionally lightweight and uses no Secret access. Continue running the full external audit for evidence collection, RBAC analysis, TLS checks, and detailed troubleshooting.

Remove automation:

```bash
oc delete -k automation/
```

## 14. Official must-gather

For ACM 2.15, Red Hat documents the following image pattern:

```bash
registry.redhat.io/rhacm2/acm-must-gather-rhel9:v2.15
```

The packaged script discovers the installed ACM minor version and builds the image reference:

```bash
./scripts/acm-must-gather.sh
```

Specify destination:

```bash
./scripts/acm-must-gather.sh acm-must-gather-mgmtcnfs-$(date +%Y%m%d)
```

Disconnected registry override:

```bash
export MUST_GATHER_IMAGE='mirror.example.com/rhacm2/acm-must-gather-rhel9:v2.15'
./scripts/acm-must-gather.sh
```

Run must-gather when:

- `MultiClusterHub` remains installing or pending.
- Status components report `ProgressDeadlineExceeded`.
- A managed cluster remains offline after normal diagnosis.
- Add-ons or ManifestWorks fail without a clear cause.
- Observability or backup remains stuck.
- A Red Hat support case will be opened.

Protect and securely transfer the generated archive.

## 15. Remediation matrix

| Symptom | Primary evidence | Likely domain | Recommended first action |
|---|---|---|---|
| MCH not `Running` | MCH status/components, namespace events | Capacity, OLM, scheduling | Resolve pending/unavailable component and inspect operator logs. |
| Current CSV not `Succeeded` | Subscription, CSV, InstallPlan, CatalogSource | OLM/catalog | Correct catalog connectivity, approval, dependency, or CSV error. |
| Pods `Pending` | Pod describe/events | CPU, memory, taints, PVC | Compare requests to allocatable resources and placement rules. |
| Pods `OOMKilled` | Previous logs, pod status | Memory pressure/limits | Correlate actual usage and supported sizing before changes. |
| Managed cluster offline | ManagedCluster conditions | DNS/network/certificates | Run deep dive on hub and managed cluster; test resolution/connectivity. |
| Add-on unavailable | ManagedClusterAddOn and ManifestWork | Agent/add-on/work delivery | Inspect add-on conditions and agent-addon/work-agent logs. |
| ManifestWork not applied | ManifestWork conditions | API/schema/RBAC/agent | Review resource error and managed-cluster work-agent. |
| MCO stuck | MCO conditions, obs pods/PVC/events | Object storage, PVC, CA | Validate secret reference, endpoint TLS, storage, and credentials. |
| BackupSchedule unhealthy | BackupSchedule/Velero/DPA/BSL | OADP/object storage | Fix BSL/DPA/credentials and confirm no backup collision. |
| Policy noncompliant | Policy status/events | Configuration drift | Validate severity, placement, exception, and remediation mode. |
| Certificate near expiry | TLS inventory | PKI | Identify ownership and rotate through supported workflow. |
| ClusterOperator degraded | OpenShift CO status | Hub platform | Restore OpenShift health before declaring ACM healthy. |

## 16. Production-readiness checklist

Declare ACM healthy only when all applicable items are met:

### Hub platform

- [ ] Supported OpenShift and ACM version combination verified against the current support matrix.
- [ ] `ClusterVersion` is available and not failing.
- [ ] All required ClusterOperators are available and not degraded.
- [ ] Nodes and MachineConfigPools are healthy.
- [ ] Hub etcd backup is current and stored outside the cluster failure domain.

### ACM/MCE installation

- [ ] ACM and MCE subscriptions are present in approved channels.
- [ ] Current CSVs are `Succeeded`.
- [ ] `MultiClusterHub` is `Running`.
- [ ] `MultiClusterEngine` is available/running.
- [ ] No `ProgressDeadlineExceeded` condition exists.
- [ ] Availability mode matches the topology.
- [ ] Worker/infra-node placement matches the approved architecture.

### Runtime

- [ ] ACM/MCE pods are running or successfully completed.
- [ ] Deployments, StatefulSets, and DaemonSets meet desired availability.
- [ ] No unexplained restart trend, OOM kill, or probe-failure pattern exists.
- [ ] ACM PVCs are bound and capacity is monitored.
- [ ] CPU, memory, storage, and node headroom meet expected fleet growth.

### Managed clusters

- [ ] Intended clusters are accepted, joined, and available.
- [ ] Required add-ons are available and not degraded.
- [ ] ManifestWorks apply successfully.
- [ ] Import, DNS, proxy, network, and certificate requirements are documented.
- [ ] Decommissioned clusters and stale namespaces are removed through supported procedures.

### Observability

- [ ] MCO is enabled where required.
- [ ] Object storage is durable, encrypted, trusted, and capacity-managed.
- [ ] Observability pods and PVCs are healthy.
- [ ] Metrics retention and cardinality are controlled.
- [ ] Alert routing is tested.

### Business continuity

- [ ] OADP and ACM backup component are healthy.
- [ ] BackupStorageLocation is available.
- [ ] BackupSchedule meets approved RPO and retention.
- [ ] Recent ACM backups complete successfully.
- [ ] No backup collision exists.
- [ ] Restore procedure is tested and measured.
- [ ] Active/passive hub ownership and activation process are documented.

### Governance and security

- [ ] Governance policies are version-controlled and placed explicitly.
- [ ] High-severity noncompliance is owned and tracked.
- [ ] Enforcement changes are tested before production.
- [ ] No public/system-wide `cluster-admin` binding exists.
- [ ] Privileged access is recertified.
- [ ] No permanent insecure TLS bypass exists.
- [ ] Customer-managed certificates have adequate remaining validity.
- [ ] Secrets and kubeconfigs are protected and rotated.

### Operations

- [ ] Weekly lightweight and periodic full checks are scheduled.
- [ ] Reports are retained according to security policy.
- [ ] Upgrade runbook, rollback strategy, and maintenance windows exist.
- [ ] Current ACM must-gather procedure is documented.
- [ ] Escalation contacts and Red Hat support process are defined.

## 17. Recommended cadence

| Activity | Suggested cadence |
|---|---|
| Lightweight ACM operational check | Weekly and after significant changes |
| Full toolkit audit | Monthly, before/after upgrades, and after incidents |
| Privileged RBAC review | Monthly or quarterly according to policy |
| Backup completion review | Daily through alerting; manual weekly review |
| Restore exercise | Quarterly and after major architecture changes |
| Capacity and observability review | Monthly and before fleet expansion |
| Support-matrix and lifecycle review | Before every OpenShift/ACM upgrade plan |
| Certificate-expiry review | Continuous alerting plus monthly verification |

## 18. Official references

1. Red Hat Advanced Cluster Management 2.15 — Install:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/install/index
2. Red Hat Advanced Cluster Management 2.15 — Troubleshooting:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/troubleshooting/index
3. Red Hat Advanced Cluster Management 2.15 — Clusters and multicluster engine:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/clusters/index
4. Red Hat Advanced Cluster Management 2.15 — Observability:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/observability/index
5. Red Hat Advanced Cluster Management 2.15 — Business continuity:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/business_continuity/index
6. Red Hat Advanced Cluster Management 2.15 — Governance:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/governance/index
7. Red Hat Advanced Cluster Management 2.15 — Secure clusters:  
   https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html-single/secure_clusters/index
8. Red Hat Advanced Cluster Management support matrix:  
   https://access.redhat.com/articles/7133095
9. Multicluster engine 2.10 support information:  
   https://access.redhat.com/articles/7133096
10. OpenShift Container Platform 4.18 — Monitoring:  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/monitoring/index
11. OpenShift Container Platform 4.18 — Support and gathering cluster data:  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/support/index
12. OpenShift Container Platform 4.18 — Control-plane backup and restore:  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/backup_and_restore/control-plane-backup-and-restore
13. OpenShift Container Platform 4.18 — Nodes and infrastructure nodes:  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/nodes/index

## 19. Change record template

Use this for each remediation resulting from the report:

```text
Finding ID:
Date detected:
Environment:
Affected hub/managed clusters:
Severity:
Evidence path:
Technical root cause:
Business impact:
Proposed remediation:
Red Hat documentation/reference:
Change owner:
Approver:
Maintenance window:
Pre-change backup:
Rollback plan:
Validation commands:
Post-change result:
Exception and expiry date, if accepted:
```
