# OpenShift 4.18+ General Health Check with HTML Report

This package provides a read-only Bash health-check script for OpenShift Container Platform 4.18 or later. It collects cluster evidence with `oc`, stores raw command logs, optionally collects selected pod/operator log tails, and generates a compact HTML report.

## Files

| File | Purpose |
|---|---|
| `ocp418-health-check-html.sh` | Main health-check script for OCP 4.18+. |
| `ocp-general-health-check.sh` | Compatibility copy using the same OCP 4.18+ logic. |
| `ocp418-health-check.env.example` | Example variables file. Copy it to `.ocp-health-check.env` and edit it. |
| `README-ocp418-health-check.md` | This README. |

## Requirements

Required:

- Bash 4 or later.
- OpenShift CLI `oc`.
- A valid `oc login` session.
- Recommended permissions: `cluster-admin` for complete results.

Recommended:

- `jq` for structured parsing of JSON output.
- `timeout` from GNU coreutils for per-command timeouts.

The script is read-only by default. It uses `oc get`, `oc describe`, `oc logs`, `oc adm top`, and optional `oc adm must-gather` only when explicitly enabled.

## Quick start

```bash
chmod +x ocp418-health-check-html.sh
oc login https://api.<cluster>:6443
./ocp418-health-check-html.sh --cluster-name prod-ocp-qro
```

## Recommended execution for troubleshooting

```bash
./ocp418-health-check-html.sh \
  --cluster-name prod-ocp-qro \
  --output /tmp/ocp-health-prod-ocp-qro \
  --deep
```

## Execution with variables file

Copy the example file:

```bash
cp ocp418-health-check.env.example .ocp-health-check.env
vi .ocp-health-check.env
```

Run:

```bash
./ocp418-health-check-html.sh --env-file ./.ocp-health-check.env
```

The script also auto-loads `./.ocp-health-check.env` when present.

## Optional must-gather

Enable only when preparing evidence for Red Hat Support or when a complete evidence bundle is required:

```bash
./ocp418-health-check-html.sh \
  --cluster-name prod-ocp-qro \
  --deep \
  --must-gather
```

`must-gather` can take several minutes and can consume significant disk space.

## Output structure

The script creates a timestamped directory unless `OUT_DIR` or `--output` is provided.

```text
ocp-health-runs/
└── ocp418-health-prod-ocp-qro-YYYYMMDD-HHMMSS/
    ├── health-report.html
    ├── health-report.md
    ├── summary.txt
    ├── command-index.tsv
    ├── run.log
    ├── raw/
    ├── logs/
    └── describes/
```

### Output files

| Path | Description |
|---|---|
| `health-report.html` | Compact executive report with status, findings, and selected evidence snippets. |
| `health-report.md` | Markdown equivalent of the report. |
| `summary.txt` | Plain-text summary with status counts and findings. |
| `command-index.tsv` | Command name, return code, start time, end time, and file path. |
| `run.log` | Runtime progress log. |
| `raw/*.txt` | Raw command output logs. Each file includes command, timestamp, output, and return code. |
| `logs/*.log` | Optional log tails from problematic pods and selected core operators. |
| `describes/*.txt` | Optional `oc describe pod` output for problematic pods. |

## Variables to fill or customize

You can set variables in either of these ways:

1. Edit the variable block at the top of `ocp418-health-check-html.sh`.
2. Recommended: copy `ocp418-health-check.env.example` to `.ocp-health-check.env` and edit it.
3. Override selected values using command-line flags.

| Variable | Example | Required | Description |
|---|---:|:---:|---|
| `CLUSTER_NAME_HINT` | `prod-ocp-qro` | Recommended | Friendly name used only for local folder/report labels. Does not change cluster resources. |
| `OCP_MIN_MINOR` | `18` | Yes | Minimum OpenShift minor version expected by the script. |
| `OUTPUT_BASE_DIR` | `/tmp/ocp-health` | Recommended | Base directory for timestamped output folders. |
| `OUT_DIR` | `/tmp/ocp-health-prod` | No | Fixed output directory. Leave empty to auto-generate. |
| `TIMEOUT_SECONDS` | `180` | Recommended | Per-command timeout. Increase for large clusters. |
| `PAUSE` | `false` | No | If `true`, the script pauses after every major section. |
| `DEEP` | `false` | No | If `true`, collects additional describe output and selected core operator logs. |
| `RUN_MUST_GATHER` | `false` | No | If `true`, runs `oc adm must-gather`. This is heavier. |
| `COLLECT_PROBLEM_POD_LOGS` | `true` | Recommended | Collects log tails for pods detected as problematic. |
| `COLLECT_CORE_OPERATOR_LOGS` | `true` | No | Collects selected core operator logs only when `DEEP=true`. |
| `LOG_TAIL_LINES` | `250` | Recommended | Number of log lines collected per pod/operator. |
| `MAX_PROBLEM_PODS` | `25` | Recommended | Maximum number of problematic pods for log/describe collection. |
| `RESTART_THRESHOLD` | `10` | Recommended | Container restart count above which a pod is flagged. |
| `RUN_PROMETHEUS_ALERTS` | `true` | Recommended | Queries active platform alerts through the Kubernetes API proxy. |
| `EVENT_LIMIT` | `250` | Recommended | Number of recent Warning events saved in the evidence bundle. |
| `CORE_NAMESPACES` | `openshift-etcd openshift-monitoring ...` | Recommended | Space-separated OpenShift namespaces to snapshot. |
| `REPORT_TITLE` | `OpenShift 4.18+ General Health Report` | No | HTML/Markdown report title. |

## Command-line flags

| Flag | Equivalent variable / behavior |
|---|---|
| `--env-file FILE` | Loads variables from a file. |
| `--cluster-name NAME` | Overrides `CLUSTER_NAME_HINT`. |
| `--output DIR` | Overrides `OUT_DIR`. |
| `--timeout SEC` | Overrides `TIMEOUT_SECONDS`. |
| `--pause` | Sets `PAUSE=true`. |
| `--deep` | Sets `DEEP=true`. |
| `--must-gather` | Sets `RUN_MUST_GATHER=true`. |
| `--no-problem-pod-logs` | Sets `COLLECT_PROBLEM_POD_LOGS=false`. |
| `--restart-threshold N` | Overrides `RESTART_THRESHOLD`. |
| `--max-problem-pods N` | Overrides `MAX_PROBLEM_PODS`. |
| `--log-tail-lines N` | Overrides `LOG_TAIL_LINES`. |
| `--event-limit N` | Overrides `EVENT_LIMIT`. |
| `--skip-alerts` | Sets `RUN_PROMETHEUS_ALERTS=false`. |

## Health areas collected

The script collects and evaluates:

1. Local tools and `oc` login.
2. OpenShift version and `ClusterVersion` conditions.
3. `ClusterOperators` status.
4. Nodes, node conditions, resource usage, MachineConfigPools, machines, and MachineSets.
5. Pods, restarts, image pull failures, CrashLoopBackOff, OOMKilled, and unavailable deployments.
6. Core OpenShift namespaces such as API server, etcd, authentication, ingress, DNS, monitoring, console, and MCO.
7. Network, ingress, DNS, proxy, route, image registry, and image config resources.
8. StorageClasses, PVs, PVCs, CSI drivers/nodes, and VolumeAttachments.
9. OLM resources: CSVs, Subscriptions, InstallPlans, OperatorGroups, CatalogSources.
10. Recent Warning events and active Prometheus alerts.
11. Authentication, OAuth, CSRs, APIService availability, and TLS/cert-related secret overview.
12. Optional `oc adm must-gather`.

## Status classification

The report classifies the cluster as:

| Status | Meaning |
|---|---|
| `HEALTHY` | No critical or warning findings were detected by this script. |
| `WARNING` | One or more warning conditions were detected. Review before maintenance or upgrades. |
| `CRITICAL` | One or more critical conditions were detected, such as degraded operators, NotReady/pressure nodes, or critical alerts. |

## Data handling note

Review the generated artifacts before sharing them externally. The evidence can include cluster names, namespaces, node names, routes, IP addresses, events, image references, and operational metadata.

## Example support workflow

```bash
oc login https://api.<cluster>:6443
cp ocp418-health-check.env.example .ocp-health-check.env
vi .ocp-health-check.env
./ocp418-health-check-html.sh --env-file ./.ocp-health-check.env --deep
firefox /tmp/ocp-health/ocp418-health-*/health-report.html
cat /tmp/ocp-health/ocp418-health-*/summary.txt
```

If the summary is `CRITICAL`, review in this order:

1. `health-report.html`
2. `summary.txt`
3. `raw/03_clusteroperators_problematic.tsv`
4. `raw/04_node_condition_problems.tsv`
5. `raw/04_mcp_problematic.tsv`
6. `raw/05_pods_problematic.tsv`
7. `raw/10_prometheus_alerts_firing.tsv`
8. `logs/` and `describes/`

## APA references

Red Hat. (2025). *Gathering data about your cluster*. Red Hat OpenShift Container Platform 4.18 Documentation.

Red Hat. (2025). *Working with nodes*. Red Hat OpenShift Container Platform 4.18 Documentation.

Red Hat. (2025). *Observability overview*. Red Hat OpenShift Container Platform 4.18 Documentation.

Red Hat. (2025). *Troubleshooting a cluster update*. Red Hat OpenShift Container Platform 4.18 Documentation.
