# OpenShift Health Check Scripts - Usage Guide

This repository contains read-only Bash scripts to collect health information from Red Hat OpenShift clusters, generate local evidence, and produce human-readable reports. The recommended target is Red Hat OpenShift 4.18 or later.

The OpenShift Health Check workflow is aligned with three delivery activities: data collection, review and analysis, and results and recommendations. The CER-oriented collector produces outputs that help populate a Health Check Consulting Engagement Report, including findings tables and CER-style `.item` files.

## Repository structure

```text
.
├── ocp-4.18/
│   ├── README-ocp418-health-check.md
│   ├── README-ocp418-healthcheck-cer-collector.md
│   ├── ocp418-health-check-html.sh
│   ├── ocp418-health-check.env.example
│   ├── ocp418-healthcheck-cer-catalog.csv
│   ├── ocp418-healthcheck-cer-collector.sh
│   └── ocp418-healthcheck-cer.env.example
├── README-ocp-general-health-check.md
├── ocp-general-health-check.sh
└── redaction-patterns.example.txt
```

## Which script should I use?

| Use case | Recommended script | Location | Main output |
|---|---|---|---|
| Full OpenShift 4.18+ health check with CER-ready findings | `ocp418-healthcheck-cer-collector.sh` | `ocp-4.18/` | `healthcheck-report.html`, `healthcheck-report.md`, `cer/findings.csv`, `cer/healthcheck-items/*.item` |
| Technical health snapshot with compact HTML report | `ocp418-health-check-html.sh` | `ocp-4.18/` | `health-report.html`, `health-report.md`, `summary.txt`, `raw/`, `logs/` |
| Lightweight/general health check | `ocp-general-health-check.sh` | repository root | `health-report.md`, `summary.txt`, `raw/` |

Recommended default: use `ocp-4.18/ocp418-healthcheck-cer-collector.sh` when the result will be used as input for a formal OpenShift Health Check report.

## Prerequisites

Install or validate the following on the workstation, bastion, or jump host where you will run the scripts:

```bash
oc version --client
bash --version
command -v jq || echo "jq is optional but recommended"
command -v timeout || echo "timeout is optional but recommended"
```

Required access:

- A valid `oc login` session to the target cluster.
- Preferably `cluster-admin` for complete evidence collection.
- Enough local disk space under the selected output directory.
- Network access from your workstation to the OpenShift API.

Validate access before running any collector:

```bash
oc login https://api.<cluster-name>:6443
oc whoami
oc get clusterversion
oc get clusteroperators
```

## One-time setup

From the repository root:

```bash
chmod +x ocp-general-health-check.sh
chmod +x ocp-4.18/ocp418-health-check-html.sh
chmod +x ocp-4.18/ocp418-healthcheck-cer-collector.sh
```

Create local variable files from the examples:

```bash
cp ocp-4.18/ocp418-health-check.env.example .ocp-health-check.env
cp ocp-4.18/ocp418-healthcheck-cer.env.example .ocp-healthcheck.env
cp redaction-patterns.example.txt redaction-patterns.txt
```

Edit the values:

```bash
vi .ocp-health-check.env
vi .ocp-healthcheck.env
vi redaction-patterns.txt
```

At minimum, adjust these values:

```bash
CLUSTER_NAME_HINT="prod-ocp"
OUTPUT_BASE_DIR="/tmp/ocp-healthcheck-runs"
TIMEOUT_SECONDS="180"
DEEP="false"
RUN_MUST_GATHER="false"
SANITIZE_DELIVERY_OUTPUT="true"
REDACTION_PATTERNS_FILE="../redaction-patterns.txt"
```

When running a script from inside `ocp-4.18/`, use relative paths like `../.ocp-healthcheck.env` and `../redaction-patterns.txt`. When running from the repository root, use paths like `./.ocp-healthcheck.env` and `./redaction-patterns.txt`.

## File-by-file usage

### `ocp-4.18/ocp418-healthcheck-cer-collector.sh`

Purpose: full OpenShift 4.18+ collector for delivery-style reports. It collects raw command output, selected pod logs, describes, preliminary findings, a compact HTML report, a Markdown report, CSV/TSV findings, and CER-style `.item` files.

Basic execution:

```bash
cd ocp-4.18
./ocp418-healthcheck-cer-collector.sh \
  --env-file ../.ocp-healthcheck.env \
  --cluster-name prod-ocp \
  --deep
```

Execution with must-gather:

```bash
cd ocp-4.18
./ocp418-healthcheck-cer-collector.sh \
  --env-file ../.ocp-healthcheck.env \
  --cluster-name prod-ocp \
  --deep \
  --must-gather
```

Execution with CER repository integration:

```bash
cd ocp-4.18
./ocp418-healthcheck-cer-collector.sh \
  --env-file ../.ocp-healthcheck.env \
  --cluster-name prod-ocp \
  --deep \
  --cer-root /path/to/cer-root \
  --write-cer-items
```

Expected output structure:

```text
ocp-healthcheck-runs/
└── ocp-healthcheck-prod-ocp-YYYYMMDD-HHMMSS/
    ├── healthcheck-report.html
    ├── healthcheck-report.md
    ├── summary.txt
    ├── command-index.tsv
    ├── run.log
    ├── cer/
    │   ├── findings.csv
    │   ├── findings.tsv
    │   ├── survey-open-items.md
    │   └── healthcheck-items/
    ├── raw/
    ├── logs/
    ├── describes/
    └── delivery-package/
```

Use this script when you need the strongest output for a report deliverable.

### `ocp-4.18/ocp418-healthcheck-cer.env.example`

Purpose: example variable file for `ocp418-healthcheck-cer-collector.sh`.

Recommended workflow:

```bash
cp ocp-4.18/ocp418-healthcheck-cer.env.example .ocp-healthcheck.env
vi .ocp-healthcheck.env
```

Important variables:

| Variable | Description | Typical value |
|---|---|---|
| `CLUSTER_NAME_HINT` | Friendly local label for folder and report names | `prod-ocp` |
| `ENGAGEMENT_NAME` | Report title context | `OpenShift Health Check` |
| `OUTPUT_BASE_DIR` | Base folder for run outputs | `/tmp/ocp-healthcheck-runs` |
| `MIN_OCP_VERSION` | Expected minimum OpenShift version | `4.18` |
| `STOP_ON_VERSION_BELOW_MIN` | Stop if the cluster is below the required version | `true` |
| `TIMEOUT_SECONDS` | Timeout per command | `180` |
| `DEEP` | Collect additional evidence | `false` or `true` |
| `RUN_MUST_GATHER` | Collect `oc adm must-gather` | `false` by default |
| `COLLECT_PROBLEM_POD_LOGS` | Save logs for problematic pods | `true` |
| `LOG_TAIL_LINES` | Number of log lines per pod | `300` |
| `MAX_PROBLEM_PODS` | Maximum number of problem pods to inspect | `40` |
| `RUN_PROMETHEUS_ALERTS` | Query platform alerts through the API proxy | `true` |
| `SANITIZE_DELIVERY_OUTPUT` | Generate sanitized delivery output | `true` |
| `REDACTION_PATTERNS_FILE` | File with patterns to redact | `../redaction-patterns.txt` |
| `WRITE_CER_ITEMS_TO_REPO` | Copy generated `.item` files to a CER repo | `false` |
| `CER_REPO_ROOT` | Root path of the CER repo | `/path/to/cer-root` |

### `ocp-4.18/ocp418-healthcheck-cer-catalog.csv`

Purpose: catalog that maps report sections to evidence files. Use it to understand which command output supports each finding.

How to read it:

```bash
column -s, -t ocp-4.18/ocp418-healthcheck-cer-catalog.csv | less -S
```

Typical columns:

```text
Category,Subcategory,Item Evaluated,Source,Output/Evidence
```

Use this file when you need to trace a recommendation back to a raw evidence file under `raw/`.

### `ocp-4.18/README-ocp418-healthcheck-cer-collector.md`

Purpose: detailed README for the CER-oriented collector. Use this as the technical runbook for the full report workflow.

Read it with:

```bash
less ocp-4.18/README-ocp418-healthcheck-cer-collector.md
```

### `ocp-4.18/ocp418-health-check-html.sh`

Purpose: OpenShift 4.18+ health check script that generates a compact HTML report and Markdown report without the CER `.item` workflow.

Basic execution:

```bash
cd ocp-4.18
./ocp418-health-check-html.sh \
  --env-file ../.ocp-health-check.env \
  --cluster-name prod-ocp
```

Recommended troubleshooting execution:

```bash
cd ocp-4.18
./ocp418-health-check-html.sh \
  --env-file ../.ocp-health-check.env \
  --cluster-name prod-ocp \
  --deep
```

Execution with must-gather:

```bash
cd ocp-4.18
./ocp418-health-check-html.sh \
  --env-file ../.ocp-health-check.env \
  --cluster-name prod-ocp \
  --deep \
  --must-gather
```

Expected output structure:

```text
ocp-health-runs/
└── ocp418-health-prod-ocp-YYYYMMDD-HHMMSS/
    ├── health-report.html
    ├── health-report.md
    ├── summary.txt
    ├── command-index.tsv
    ├── run.log
    ├── raw/
    ├── logs/
    └── describes/
```

Use this script when you need a fast technical health report but do not need CER `.item` files.

### `ocp-4.18/ocp418-health-check.env.example`

Purpose: example variable file for `ocp418-health-check-html.sh`.

Recommended workflow:

```bash
cp ocp-4.18/ocp418-health-check.env.example .ocp-health-check.env
vi .ocp-health-check.env
```

Important variables:

| Variable | Description | Typical value |
|---|---|---|
| `CLUSTER_NAME_HINT` | Friendly local label | `prod-ocp` |
| `OCP_MIN_MINOR` | Minimum minor version | `18` |
| `OUTPUT_BASE_DIR` | Base output directory | `/tmp/ocp-health` |
| `OUT_DIR` | Fixed output directory, optional | empty |
| `TIMEOUT_SECONDS` | Timeout per command | `180` |
| `PAUSE` | Pause after major steps | `false` |
| `DEEP` | More detailed collection | `false` or `true` |
| `RUN_MUST_GATHER` | Run must-gather | `false` |
| `COLLECT_PROBLEM_POD_LOGS` | Collect logs from problem pods | `true` |
| `LOG_TAIL_LINES` | Log tail size | `250` |

### `ocp-4.18/README-ocp418-health-check.md`

Purpose: usage README for the compact HTML health check script.

Read it with:

```bash
less ocp-4.18/README-ocp418-health-check.md
```

### `ocp-general-health-check.sh`

Purpose: root-level general health check script. Use it for a quick read-only snapshot or when you want a simpler output.

Basic execution:

```bash
./ocp-general-health-check.sh
```

Step-by-step guided execution:

```bash
./ocp-general-health-check.sh --pause
```

Deeper evidence collection:

```bash
./ocp-general-health-check.sh --deep
```

Custom output directory:

```bash
./ocp-general-health-check.sh \
  --output /tmp/ocp-general-health-prod-ocp \
  --deep
```

Execution with must-gather:

```bash
./ocp-general-health-check.sh \
  --output /tmp/ocp-general-health-prod-ocp \
  --deep \
  --must-gather
```

Expected output structure:

```text
ocp-health-YYYYMMDD-HHMMSS/
├── health-report.md
├── summary.txt
└── raw/
```

### `README-ocp-general-health-check.md`

Purpose: README for the root-level general health check script.

Read it with:

```bash
less README-ocp-general-health-check.md
```

### `redaction-patterns.example.txt`

Purpose: example file for redaction patterns. Copy it and add sensitive names, host naming conventions, domains, and non-Red Hat vendor or product names that should not appear in delivery outputs.

Recommended workflow:

```bash
cp redaction-patterns.example.txt redaction-patterns.txt
vi redaction-patterns.txt
```

Example content:

```text
customer-name
customer.internal.domain
non-redhat-product-name
non-redhat-vendor-name
```

The collector can sanitize delivery-oriented outputs, but raw evidence may still contain cluster-specific values. Review `raw/`, `logs/`, and `describes/` before sharing them externally.

## How to read the final reports

### 1. Start with `summary.txt`

This is the fastest triage file. It tells you where the report is located and gives counts for critical, warning/advisory, and informational findings.

```bash
cat /path/to/run-dir/summary.txt
```

Read it first to answer:

- Did the collection finish successfully?
- What is the overall health status?
- How many critical or warning findings were detected?
- Which main files should be opened next?

### 2. Open the HTML report

For the CER collector:

```bash
xdg-open /path/to/run-dir/healthcheck-report.html
```

For the compact health check:

```bash
xdg-open /path/to/run-dir/health-report.html
```

On macOS, use:

```bash
open /path/to/run-dir/healthcheck-report.html
```

On Windows with WSL, copy the path or open it from the Windows file browser.

Use the HTML report for executive review, quick status interpretation, and initial recommendations.

### 3. Read the Markdown report

For the CER collector:

```bash
less /path/to/run-dir/healthcheck-report.md
```

For the compact health check:

```bash
less /path/to/run-dir/health-report.md
```

Use the Markdown report when you need content that can be copied into another report or reviewed in Git.

### 4. Review CER findings

For the CER collector:

```bash
column -s, -t /path/to/run-dir/cer/findings.csv | less -S
less /path/to/run-dir/cer/findings.tsv
```

Use `cer/findings.csv` for spreadsheet review. The key fields are:

| Field | Meaning |
|---|---|
| `category` | Report category such as Infrastructure, Platform, Security, or Application Development |
| `subcategory` | More specific area inside the category |
| `item` | Check or control being evaluated |
| `observed` | What the script detected or what must still be reviewed |
| `recommendation` | Preliminary status such as no change, advisory, changes recommended, or changes required |
| `evidence` | File path that supports the observation |
| `impact` | Risk or operational impact |
| `remediation` | Recommended action |
| `comments` | Additional notes |

### 5. Map findings back to command output

Use `command-index.tsv` to map each collection step to the command and output file:

```bash
column -t -s $'\t' /path/to/run-dir/command-index.tsv | less -S
```

Use this file when a reviewer asks: “Which command produced this finding?”

### 6. Inspect raw evidence

Raw evidence is under `raw/`:

```bash
find /path/to/run-dir/raw -type f | sort
less /path/to/run-dir/raw/01-core/clusteroperators.txt
less /path/to/run-dir/raw/01-core/nodes-wide.txt
```

Use `raw/` for technical validation. Do not send raw evidence externally before reviewing and sanitizing it.

### 7. Inspect pod logs and describes

Problem pod logs and descriptions are useful for troubleshooting:

```bash
find /path/to/run-dir/logs -type f | sort
find /path/to/run-dir/describes -type f | sort
```

Typical review flow:

```bash
less /path/to/run-dir/logs/problem-pods/<namespace>__<pod>.log
less /path/to/run-dir/describes/problem-pods/<namespace>__<pod>.describe.txt
```

### 8. Review CER `.item` files

For the CER collector:

```bash
find /path/to/run-dir/cer/healthcheck-items -name '*.item' | sort
less /path/to/run-dir/cer/healthcheck-items/<item-name>.item
```

These `.item` files are preliminary and should be reviewed before copying into a CER repository. If you used `--write-cer-items`, validate the target CER repo after execution:

```bash
cd /path/to/cer-root
git status
ls content/healthcheck-items
```

## Recommendation status interpretation

| Status | Meaning |
|---|---|
| `changes_required` | Requires action for stability, compliance, operability, or critical risk reduction |
| `changes_recommended` | Recommended improvement, not necessarily urgent |
| `advisory` | Informational concern or item to review with the platform team |
| `no_change` | No change identified from collected evidence |
| `not_applicable` | Not applicable to this cluster or not detected |
| `tbe` | To be evaluated; requires interview, architecture review, or manual validation |

Treat automated results as preliminary. The final recommendation should be confirmed by an OpenShift architect or platform owner before delivery.

## How to remove literal backslash-n from existing Markdown reports

The updated root-level script avoids generating literal `\n` before Markdown headings. If you already generated a report that contains text like this:

```text
\n### Subscriptions\n
```

Fix it with:

```bash
perl -0pi -e 's/\\n(#{1,6}[[:space:]])/\n$1/g; s/(#{1,6}[^\n]*)\\n/$1\n/g' /path/to/run-dir/health-report.md
```

Validate that the issue is gone:

```bash
grep -n -F '\n###' /path/to/run-dir/health-report.md || echo "OK: no literal backslash-n headings found"
```

If you want to check all Markdown files in a run directory:

```bash
find /path/to/run-dir -name '*.md' -type f -print0 | \
  xargs -0 grep -n -F '\n###' || echo "OK: no literal backslash-n headings found"
```

## Recommended end-to-end execution

Use this flow for a complete OpenShift 4.18+ Health Check deliverable:

```bash
# 1. Validate access
oc login https://api.<cluster-name>:6443
oc whoami
oc get clusterversion

# 2. Prepare variables
cp ocp-4.18/ocp418-healthcheck-cer.env.example .ocp-healthcheck.env
cp redaction-patterns.example.txt redaction-patterns.txt
vi .ocp-healthcheck.env
vi redaction-patterns.txt

# 3. Run collector
cd ocp-4.18
chmod +x ocp418-healthcheck-cer-collector.sh
./ocp418-healthcheck-cer-collector.sh \
  --env-file ../.ocp-healthcheck.env \
  --cluster-name prod-ocp \
  --deep

# 4. Locate final run directory
find ../ocp-healthcheck-runs -maxdepth 1 -type d | sort

# 5. Review outputs
cat /path/to/run-dir/summary.txt
xdg-open /path/to/run-dir/healthcheck-report.html
column -s, -t /path/to/run-dir/cer/findings.csv | less -S
```

## Recommended execution for a fast technical health check

```bash
oc login https://api.<cluster-name>:6443
cp ocp-4.18/ocp418-health-check.env.example .ocp-health-check.env
vi .ocp-health-check.env

cd ocp-4.18
chmod +x ocp418-health-check-html.sh
./ocp418-health-check-html.sh \
  --env-file ../.ocp-health-check.env \
  --cluster-name prod-ocp \
  --deep
```

Review:

```bash
cat /path/to/run-dir/summary.txt
xdg-open /path/to/run-dir/health-report.html
less /path/to/run-dir/health-report.md
```

## Notes for delivery

- The scripts are read-only unless `--must-gather` is enabled, which still collects data but can be heavy.
- Review and sanitize all delivery outputs before sharing.
- Do not share raw evidence externally unless it has been reviewed.
- Prefer the CER collector for formal delivery because it creates findings tables and `.item` files.
- Keep the `raw/` directory as supporting evidence for technical reviewers.
- Keep `command-index.tsv` with the report package to preserve traceability.
