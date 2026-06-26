# OpenShift Certificate Inventory and Expiration Audit

This project provides a read-only Ansible playbook for Red Hat OpenShift Container Platform 4.18. It inventories X.509 certificates, calculates expiration status, identifies cryptographically verified self-signed certificates, and produces CSV, JSON, and Markdown reports.

The implementation is designed for platform health checks and audit evidence collection. It does **not** export private keys, raw Secret objects, or certificate bodies.

## 1. Audit scope

The collector reviews the following sources:

- Every key in every Kubernetes `Secret` across all namespaces. PEM chains and kubeconfig-style embedded certificate data are parsed in memory.
- Certificate and CA bundle data in every `ConfigMap`.
- Certificates embedded directly in OpenShift `Route` TLS configuration.
- Issued certificates and pending states in Kubernetes `CertificateSigningRequest` resources.
- CA bundles in `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`, aggregated `APIService`, and CRD conversion webhook objects.
- Certificate data embedded in `MachineConfig` objects.
- Local kubeconfig `client-certificate-data`, `certificate-authority-data`, and referenced certificate files.
- Active certificate chains presented by the OpenShift API, web console, and OAuth endpoints.
- Optionally, active certificate chains presented by every admitted TLS Route.
- Node-local certificate files under selected read-only RHCOS paths, including:
  - `/etc/kubernetes`
  - `/var/lib/kubelet`
  - `/var/lib/etcd`
  - `/etc/pki/ca-trust`
  - `/etc/containers/certs.d`
- cert-manager `Certificate` ownership references when the cert-manager API is installed.
- OpenShift ownership hints for service-ca, default ingress, API server named certificates, and the cluster-wide proxy CA bundle.

## 2. What is reported for each certificate

Each occurrence contains:

- Status: `EXPIRED`, `NOT_YET_VALID`, `CRITICAL`, `WARNING`, `OK`, or `UNKNOWN`
- Remaining days
- `notBefore` and `notAfter` timestamps
- Subject and issuer
- SHA-256 fingerprint
- Serial number
- Subject Alternative Names
- CA flag
- Signature algorithm
- Public-key algorithm and key size
- Self-signed classification
- Kubernetes object, namespace, key, node path, or TLS endpoint where the certificate was found
- Management hint, such as service-ca, cert-manager, Ingress Operator, API named certificate, Route-managed, or unknown
- Whether a node path might belong to a retained historical static-pod revision

Two inventories are generated:

- `certificates-all.csv`: every occurrence, including duplicates.
- `certificates-unique.csv`: deduplicated by SHA-256 fingerprint, with all source locations retained.

## 3. Self-signed detection

The audit marks a certificate as `self_signed=yes` only when both conditions are true:

1. The normalized X.509 subject equals the issuer.
2. OpenSSL verifies the certificate signature using the certificate's own public key.

A certificate with matching subject and issuer whose signature cannot be verified is marked `self-issued-unverified`, not self-signed.

A self-signed result is a classification, not automatically a security defect. OpenShift uses internal self-signed infrastructure CAs by design. External application and platform endpoints should still be evaluated against the organization's PKI and trust requirements.

## 4. Requirements

Run the playbook from a Linux or macOS administration host with:

- Ansible Core 2.12 or later
- Python 3.9 or later
- OpenShift CLI `oc` compatible with the cluster
- OpenSSL
- Network access to the OpenShift API
- A logged-in identity with `cluster-admin` privileges for a complete inventory

Node scanning additionally requires permission to run `oc debug node/<node>`. The scan uses temporary debug pods and executes only read-only file discovery and OpenSSL metadata commands on the host.

Check the local tools:

```bash
ansible-playbook --version
python3 --version
oc version
openssl version
oc whoami
oc auth can-i get secrets --all-namespaces
oc auth can-i get nodes
```

## 5. Project structure

```text
ocp-certificate-audit/
├── README.md
├── audit-certificates.yml
├── inventory.ini
├── requirements.yml
├── vars.example.yml
└── files/
    ├── node_cert_scan.sh
    └── ocp_certificate_audit.py
```

No external Ansible collection is required; the playbook uses `ansible.builtin` modules only.

## 6. Basic execution

### 6.1 Authenticate to the cluster

```bash
oc login https://api.<cluster>.<base-domain>:6443
oc whoami
```

Alternatively, export an existing kubeconfig:

```bash
export KUBECONFIG="$HOME/.kube/config"
```

### 6.2 Run the standard audit

The standard mode inventories all API-stored certificates, scans nodes, and probes the API, console, and OAuth endpoints. It does not connect to every application Route by default.

```bash
cd ocp-certificate-audit
ansible-playbook -i inventory.ini audit-certificates.yml
```

The final Ansible task prints the generated report directory.

### 6.3 Run with an explicit kubeconfig

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e audit_kubeconfig=/secure/path/cluster-kubeconfig
```

### 6.4 Use a named kubeconfig context

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e audit_context=my-cluster-context
```

## 7. Full Route endpoint validation

To connect to every admitted TLS Route and observe the certificate chain actually presented through the router or passthrough backend:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e scan_route_endpoints=true
```

This mode can take significantly longer on clusters with many Routes. It generates outbound TLS connections from the administration host but does not modify the Routes or workloads.

Limit the number of unique endpoints when validating the process in a large cluster:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e scan_route_endpoints=true \
  -e max_route_endpoints=100
```

`max_route_endpoints=0` means no collector-imposed limit.

## 8. Run without node debug pods

Use this mode when node-level permissions are unavailable or when only Kubernetes API objects and externally presented certificates are required:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e scan_nodes=false
```

The result is not a full host-level certificate inventory because kubelet, etcd, static-pod, and RHCOS trust-store files are not inspected.

## 9. Customize expiration thresholds

Default thresholds:

- Critical: 30 days or fewer
- Warning: 90 days or fewer

Example:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e critical_days=15 \
  -e warning_days=60
```

The critical threshold must not exceed the warning threshold.

## 10. Use the example variable file

Edit `vars.example.yml`, then execute:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e @vars.example.yml
```

## 11. Generated evidence

Each run creates a timestamped directory:

```text
output/certificate-audit-<cluster>-<UTC-timestamp>/
├── certificate-audit.md
├── certificate-audit.json
├── certificates-all.csv
├── certificates-unique.csv
├── endpoints.csv
├── execution.log
└── findings.csv
```

Permissions are set to `0700` for directories and `0600` for report files because subjects, SANs, node names, and internal hostnames can be sensitive infrastructure metadata.

### 11.1 View the Markdown report

```bash
less output/certificate-audit-*/certificate-audit.md
```

### 11.2 List expired and critical unique certificates with Python

```bash
python3 - <<'PY'
import csv
from pathlib import Path

report = sorted(Path("output").glob("certificate-audit-*/certificates-unique.csv"))[-1]
with report.open(newline="", encoding="utf-8") as handle:
    rows = csv.DictReader(handle)
    for row in rows:
        if row["status"] in {"EXPIRED", "CRITICAL"}:
            print(
                row["status"],
                row["days_remaining"],
                row["not_after"],
                row["self_signed"],
                row["subject"],
                row["source_id"],
                sep=" | ",
            )
PY
```

### 11.3 List all verified self-signed certificates

```bash
python3 - <<'PY'
import csv
from pathlib import Path

report = sorted(Path("output").glob("certificate-audit-*/certificates-unique.csv"))[-1]
with report.open(newline="", encoding="utf-8") as handle:
    for row in csv.DictReader(handle):
        if row["self_signed"] == "yes":
            print(
                row["status"],
                row["not_after"],
                row["is_ca"],
                row["subject"],
                row["management_hint"],
                sep=" | ",
            )
PY
```

### 11.4 Query the JSON report with `jq`

```bash
REPORT_JSON="$(find output -name certificate-audit.json -type f | sort | tail -1)"

jq '.summary' "$REPORT_JSON"

jq -r '
  .unique_certificates[]
  | select(.status == "EXPIRED" or .status == "CRITICAL")
  | [.status, .days_remaining, .not_after, .self_signed, .subject, .source_id]
  | @tsv
' "$REPORT_JSON"
```

## 12. Recommended interpretation and remediation workflow

### 12.1 Validate whether the occurrence is active

Prioritize in this order:

1. Certificates observed from active API, console, OAuth, or Route endpoints.
2. User-managed Secrets referenced by the API server, Ingress Controller, Routes, cert-manager, or applications.
3. Current node and static-pod certificate paths.
4. CA bundles and historical static-pod revisions.

An expired certificate in a retained static-pod revision or trust bundle does not necessarily mean that the active service is using it.

### 12.2 Determine the certificate owner

Use `management_hint`, `source_locations`, Secret annotations, owner references, and the consuming resource.

Useful checks:

```bash
oc get secret -n <namespace> <secret> -o yaml
oc get service -n <namespace> -o yaml
oc get ingresscontroller -n openshift-ingress-operator -o yaml
oc get apiserver cluster -o yaml
oc get certificate -A
oc get csr
```

Do not copy private-key values into tickets, chat systems, or audit reports.

### 12.3 User-managed ingress certificate

Identify the configured Secret:

```bash
oc get ingresscontroller default \
  -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}{"\n"}'
```

Renew the certificate through the organization's CA, validate that the private key matches the leaf certificate, include the required intermediate chain, update the referenced TLS Secret through the approved change process, and validate the console and application endpoints.

### 12.4 API server named certificate

Review configured names and Secret references:

```bash
oc get apiserver cluster -o yaml
```

A named certificate must cover the configured DNS names and be stored in the `openshift-config` namespace. Update the referenced Secret only after validating the key pair and certificate chain.

### 12.5 service-ca certificates

Service serving certificates are generated from a Service annotation and stored in the named Secret:

```bash
oc get service -A \
  -o jsonpath='{range .items[?(@.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name)]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}{"\n"}{end}'
```

OpenShift rotates the service CA automatically. Do not manually replace service-ca-managed certificate data with an unrelated certificate. If regeneration is required, first confirm the Service annotation, application behavior, and Red Hat procedure; deleting a generated serving-certificate Secret causes the controller to recreate it.

### 12.6 kubelet and CSR issues

Review pending and recently issued CSRs:

```bash
oc get csr
oc describe csr <csr-name>
```

Approve only CSRs whose requester, signer, node identity, and SANs are expected. Do not bulk-approve unknown CSRs.

### 12.7 cert-manager certificates

```bash
oc get certificate,certificaterequest,issuer,clusterissuer -A
oc describe certificate -n <namespace> <name>
oc logs -n cert-manager deploy/cert-manager
```

Confirm issuer readiness, renewal time, DNS or ACME challenge status, and the Secret referenced by `spec.secretName`.

## 13. Operational and security characteristics

- The Kubernetes API retrieval is read-only.
- Secret objects are held only in process memory and are not saved as raw JSON.
- Private-key fields are ignored because only certificate blocks and certificate-like binary objects are parsed.
- Temporary local certificate files are created with restrictive permissions and removed at process exit.
- Node scans create temporary `oc debug` pods and temporary files under `/run` or `/tmp` inside the host chroot. These files are removed by a shell trap.
- Node commands use `find`, `awk`, `base64`, and `openssl`; they do not modify cluster or host configuration.
- Endpoint probing performs TLS handshakes only.
- The collector continues when an optional API type, such as cert-manager, is not installed.

## 14. Known limitations

No generic Kubernetes audit can guarantee discovery of every certificate inside every application container or external appliance. The following require separate application-owner procedures:

- Password-protected PKCS#12, PFX, JKS, or proprietary keystores
- Certificates generated only in container memory
- Certificates stored in external vaults, HSMs, cloud certificate managers, load balancers, WAFs, or appliances not reachable through the audited endpoint
- Certificates inside application databases or encrypted configuration values
- External endpoints that are unreachable from the administration host
- Historical objects already removed from the Kubernetes API and node filesystem

For a complete enterprise PKI assessment, correlate this report with load-balancer, DNS, vault, HSM, service mesh, external registry, LDAP, database, and application-team inventories.

## 15. Troubleshooting

### `oc` permission failure

```bash
oc whoami
oc auth can-i get secrets --all-namespaces
oc auth can-i create pods -n default
oc auth can-i get nodes
```

Use a `cluster-admin` identity for the complete run. To permit partial evidence collection instead of failing the playbook:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e require_complete_permissions=false
```

The report will contain an RBAC warning and can be incomplete.

### Node scan timeout

Increase the per-node timeout:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e node_scan_timeout=900
```

Or disable node scanning and run it separately during a maintenance or diagnostic window:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e scan_nodes=false
```

### Route endpoint timeout

Increase the TLS timeout or restrict the endpoint count:

```bash
ansible-playbook -i inventory.ini audit-certificates.yml \
  -e scan_route_endpoints=true \
  -e endpoint_timeout=20 \
  -e max_route_endpoints=100
```

### Large report size

Clusters contain many duplicated injected CA bundles. Use `certificates-unique.csv` for primary analysis and `certificates-all.csv` only when tracing every occurrence.

## 16. OpenShift 4.18 reference behavior

Red Hat documents the following relevant behaviors:

- The default ingress certificate is issued by an internal OpenShift CA, and internal infrastructure CA certificates are self-signed.
- The default ingress certificate should be replaced with an appropriately trusted certificate for production external access.
- User-provided API and ingress certificates are managed by the user.
- The service CA is valid for 26 months and automatically rotates when less than 13 months remain.
- Ingress Operator metrics, signing, and generated default certificates normally have two-year validity.
- OpenShift 4.18 extended the kube-apiserver self-signed loopback certificate validity from one year to three years.

These expected lifecycles help interpret results, but the report uses the actual `notAfter` value of every discovered certificate rather than assuming a product default.

## 17. Official references

- [OpenShift Container Platform 4.18 — Configuring certificates](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/configuring-certificates)
- [OpenShift Container Platform 4.18 — Certificate types and descriptions](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/certificate-types-and-descriptions)
- [OpenShift Container Platform 4.18 — Working with nodes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-nodes)
- [OpenShift Container Platform 4.18 — Gathering cluster data](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/support/gathering-cluster-data)
- [OpenShift Container Platform 4.18 — cert-manager Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift)
- [OpenShift Container Platform 4.18 — Release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/release_notes/ocp-4-18-release-notes)
