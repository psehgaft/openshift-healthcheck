# OpenShift 4.18+ Health Check CER Collector

This package provides a read-only Bash collector for Red Hat OpenShift 4.18 or later. It collects command evidence, problem pod logs, a compact HTML report, a Markdown report, CSV findings, and CER-style `.item` files that can be reviewed and merged into a Health Check CER workflow.

The script is intentionally generic. It does not include customer names or non-Red Hat vendor/product names in the generated recommendation text. Raw evidence may still contain environment-specific values from the cluster, so review and sanitize delivery outputs before sharing.

## Files

| File | Purpose |
|---|---|
| `ocp418-healthcheck-cer-collector.sh` | Main collector script. |
| `ocp-general-health-check.sh` | Compatibility copy of the main collector. |
| `ocp418-health-check-html.sh` | Compatibility copy of the main collector. |
| `ocp418-healthcheck-cer.env.example` | Example variables file. |
| `redaction-patterns.example.txt` | Example redaction pattern file. |
| `ocp418-healthcheck-cer-catalog.csv` | Mapping of report sections to collected evidence. |
| `README-ocp418-healthcheck-cer-collector.md` | This guide. |

## Prerequisites

- `oc` CLI installed and logged in.
- Access to the target Red Hat OpenShift cluster.
- Cluster version 4.18 or later.
- `jq` is optional but strongly recommended for richer automated analysis.
- `timeout` is optional; if unavailable, commands run without timeout enforcement.

## Quick Start

```bash
chmod +x ocp418-healthcheck-cer-collector.sh
oc login https://api.<cluster>:6443
./ocp418-healthcheck-cer-collector.sh --cluster-name prod-ocp --deep
```

## Recommended Usage with Variables

```bash
cp ocp418-healthcheck-cer.env.example .ocp-healthcheck.env
cp redaction-patterns.example.txt redaction-patterns.txt
vi .ocp-healthcheck.env
vi redaction-patterns.txt

./ocp418-healthcheck-cer-collector.sh \
  --env-file ./.ocp-healthcheck.env \
  --deep
```

## Usage with must-gather

```bash
./ocp418-healthcheck-cer-collector.sh \
  --env-file ./.ocp-healthcheck.env \
  --must-gather
```

`must-gather` can take time and produce a large evidence bundle. Use it when the engagement requires diagnostic artifacts in addition to standard CLI evidence.

## Optional CER Repository Integration

By default, generated CER item files remain local under the run directory. To copy the generated `.item` files into a CER repository:

```bash
./ocp418-healthcheck-cer-collector.sh \
  --env-file ./.ocp-healthcheck.env \
  --cer-root /path/to/cer-root \
  --write-cer-items
```

The target directory must exist:

```text
/path/to/cer-root/content/healthcheck-items
```

Review all generated `.item` files before committing them.

## Variables

| Variable | Default | Description |
|---|---:|---|
| `CLUSTER_NAME_HINT` | `ocp-production` | Logical cluster name used in output directory names. |
| `ENGAGEMENT_NAME` | `OpenShift Health Check` | Name shown in generated reports. |
| `OUTPUT_BASE_DIR` | `./ocp-healthcheck-runs` | Base directory for run output. |
| `MIN_OCP_VERSION` | `4.18` | Minimum expected OpenShift version. |
| `STOP_ON_VERSION_BELOW_MIN` | `true` | Stop if the cluster is below the minimum version. |
| `TIMEOUT_SECONDS` | `180` | Timeout per collection command when `timeout` exists. |
| `DEEP` | `false` | Collect additional resource indexes. |
| `RUN_MUST_GATHER` | `false` | Run `oc adm must-gather`. |
| `COLLECT_PROBLEM_POD_LOGS` | `true` | Collect logs and pod descriptions for problem pods. |
| `LOG_TAIL_LINES` | `300` | Number of log lines per problem pod container. |
| `MAX_PROBLEM_PODS` | `40` | Maximum problem pods for log collection. |
| `RESTART_THRESHOLD` | `10` | Restart threshold used to classify problem pods. |
| `RUN_PROMETHEUS_ALERTS` | `true` | Query OpenShift monitoring APIs for active alerts when accessible. |
| `EVENT_LIMIT` | `500` | Maximum warning event lines retained. |
| `COLLECT_OPENSHIFT_VIRTUALIZATION` | `true` | Collect OpenShift Virtualization evidence when APIs exist. |
| `COLLECT_ODF` | `true` | Collect Red Hat OpenShift Data Foundation evidence when APIs exist. |
| `COLLECT_ACM` | `true` | Collect Red Hat Advanced Cluster Management evidence when APIs exist. |
| `COLLECT_ACS` | `true` | Collect Red Hat Advanced Cluster Security evidence when APIs exist. |
| `COLLECT_GITOPS_PIPELINES` | `true` | Collect GitOps and pipeline API evidence when APIs exist. |
| `COLLECT_NAMESPACED_WORKLOADS` | `true` | Collect application workload summaries. |
| `COLLECT_NODE_DEBUG` | `false` | Reserved for node debug workflows; default remains non-intrusive. |
| `WRITE_CER_ITEMS_TO_REPO` | `false` | Copy generated `.item` files to a CER repository. |
| `CER_REPO_ROOT` | empty | CER repository root when writing generated item files. |
| `SANITIZE_DELIVERY_OUTPUT` | `true` | Apply redaction patterns to generated report text. |
| `REDACTION_PATTERNS_FILE` | `./redaction-patterns.txt` | Regex file used to redact delivery outputs. |
| `CREATE_PACKAGES` | `true` | Create full and delivery-only `.tar.gz` packages. |

## Output Structure

A run creates a directory like:

```text
ocp-healthcheck-runs/
└── ocp418-cer-healthcheck-prod-ocp-YYYYMMDD-HHMMSS/
    ├── healthcheck-report.html
    ├── healthcheck-report.md
    ├── summary.txt
    ├── command-index.tsv
    ├── run.log
    ├── raw/
    ├── logs/problem-pods/
    ├── describes/problem-pods/
    └── cer/
        ├── findings.csv
        ├── findings.tsv
        ├── survey-open-items.md
        └── healthcheck-items/
```

When `CREATE_PACKAGES=true`, the parent output directory also contains:

```text
ocp418-cer-healthcheck-<cluster>-<timestamp>-full-evidence.tar.gz
ocp418-cer-healthcheck-<cluster>-<timestamp>-delivery-report.tar.gz
```

Use the delivery package for stakeholder review after sanitization. Keep the full evidence package for technical analysis.

## What the Collector Covers

The collector gathers evidence for the following report areas:

- Infrastructure: nodes, network, ingress, DNS, proxy, storage, MachineConfig, and optional Red Hat OpenShift Data Foundation evidence.
- Platform: ClusterVersion, ClusterOperators, MachineConfigPools, OLM, image registry, monitoring, alerting, quotas, limits, and platform APIs.
- Application Development: workloads, routes, services, probes, build resources, autoscaling, disruption budgets, and optional pipeline/GitOps resources.
- OpenShift Virtualization: Red Hat OpenShift Virtualization resources when installed.
- Security: kubeadmin presence, OAuth configuration, RBAC evidence, SCCs, CSRs, secret type counts, and optional Red Hat security resources.
- Organizational Readiness: generated interview questions for operating model, responsibilities, skills, and adoption maturity.

## Recommendation Statuses

Generated `.item` files use CER-style status keys:

| Key | Meaning |
|---|---|
| `changes_required` | Required for stability, compliance, or urgent risk reduction. |
| `changes_recommended` | Recommended to align with operational practices, but not necessarily urgent. |
| `advisory` | No mandatory change, but the finding should be reviewed. |
| `no_change` | No change required based on automated evidence. |
| `not_applicable` | The item is not applicable to the cluster. |
| `tbe` | To Be Evaluated; manual/interview input required. |

## Sanitization Guidance

The generated report text avoids customer names and non-Red Hat vendor/product names. However, raw command outputs can contain hostnames, domains, namespaces, labels, routes, image references, user names, and other environment-specific values.

Before sharing reports externally:

1. Add customer-specific and non-Red Hat names to `redaction-patterns.txt`.
2. Run the collector with `SANITIZE_DELIVERY_OUTPUT=true`.
3. Review `healthcheck-report.html`, `healthcheck-report.md`, `cer/findings.csv`, and generated `.item` files.
4. Share the delivery package, not the full evidence package, unless raw technical evidence is explicitly required.

## Validation

The script was syntax-checked with:

```bash
bash -n ocp418-healthcheck-cer-collector.sh
```

## Notes

- The collector is read-only against the cluster.
- It does not collect Kubernetes Secret data; it only collects secret type counts or object names where needed for posture checks.
- It generates preliminary findings. A consultant or architect must validate the final recommendation status and wording before delivery.
