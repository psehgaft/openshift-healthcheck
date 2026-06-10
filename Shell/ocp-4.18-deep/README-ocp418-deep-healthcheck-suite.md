# OpenShift 4.18+ Deep Health Check Suite

This suite extends the general OpenShift health check with targeted scripts for deeper analysis after the first report identifies errors, warnings, or workload symptoms.

The suite is read-only by default. It collects evidence using `oc` commands, limited pod logs, object descriptions, CSV annexes, Markdown reports, and HTML reports.

## Files

| File | Purpose |
| --- | --- |
| `ocp418-deep-error-followup.sh` | Deep follow-up for problematic pods, unavailable deployments, warning events, OLM/InstallPlans, CSRs, API services, services without endpoints, and workload resilience gaps. |
| `ocp418-network-deep-dive.sh` | Network, DNS, ingress, routes, services/endpoints, network policies, egress objects, MetalLB, NMState, SR-IOV, Multus/NAD, OVN-Kubernetes, and network warning events. |
| `ocp418-storage-deep-dive.sh` | StorageClasses, PV/PVC JSON validation, CSI drivers, VolumeAttachments, local storage, monitoring storage, registry storage, ODF if present, Portworx-like storage if present, and storage warning events. |
| `ocp418-ai-workloads-deep-dive.sh` | AI/AIOps/OpenShift AI-style workload analysis, GPU resources, model-serving resources, namespace workload health, ephemeral-storage evictions, probes, services/endpoints, PVCs, quotas, PDBs, HPAs, and warning events. |
| `ocp418-healthcheck-report-builder.py` | Offline builder that reads the original health-check output directory or `.txz` bundle and generates report-ready Markdown, HTML, and CSV annexes. |
| `ocp418-run-all-deep-dives.sh` | Convenience wrapper to run all live deep-dive scripts. |
| `ocp418-deep-suite.env.example` | Example variables. Copy and adjust before running. |
| `redaction-patterns.example.txt` | Optional regex redaction patterns for generated outputs. |

## Recommended workflow

1. Run the general health check.
2. Build report sections and annexes from the output bundle.
3. Run targeted deep-dive scripts based on the highest-priority findings.
4. Attach CSV annexes to the final report and copy the generated Markdown sections into the report body.

## Prepare environment

```bash
cp ocp418-deep-suite.env.example .ocp-deep.env
cp redaction-patterns.example.txt redaction-patterns.txt
vi .ocp-deep.env
vi redaction-patterns.txt

oc login https://api.<cluster>:6443
```

## Generate report sections from an existing health check bundle

This does not need cluster access.

```bash
./ocp418-healthcheck-report-builder.py \
  --input ./ocp418-health-non-prod-ocp-20260609-153827.txz \
  --output ./generated-report \
  --cluster-name non-prod-ocp \
  --client-label Client \
  --redaction-patterns ./redaction-patterns.txt
```

Generated output:

```text
generated-report/
├── report/
│   ├── healthcheck-report-generated.md
│   ├── healthcheck-report-generated.html
│   └── report-fill-sections.md
└── annex/
    ├── priority-findings.csv
    ├── problem-summary.csv
    ├── problematic-pods.csv
    ├── deployments-unavailable.csv
    ├── installplans-review.csv
    ├── warning-events.csv
    ├── pvc-inventory.csv
    └── pvc-not-bound.csv
```

## Run all live deep-dive scripts

```bash
./ocp418-run-all-deep-dives.sh \
  --env-file ./.ocp-deep.env \
  --cluster-name non-prod-ocp
```

## Run specific deep dives

### Error follow-up

```bash
./ocp418-deep-error-followup.sh \
  --env-file ./.ocp-deep.env \
  --cluster-name non-prod-ocp
```

Use this when the first report shows problematic pods, unavailable deployments, warning events, pending CSRs, OLM issues, services without endpoints, or rollout failures.

### Network

```bash
./ocp418-network-deep-dive.sh \
  --env-file ./.ocp-deep.env \
  --cluster-name non-prod-ocp
```

Use this for DNS, ingress, route, service endpoint, egress, proxy, NetworkPolicy, MetalLB, NMState, SR-IOV, Multus, or OVN-Kubernetes questions.

### Storage

```bash
./ocp418-storage-deep-dive.sh \
  --env-file ./.ocp-deep.env \
  --cluster-name non-prod-ocp
```

Use this for PVC/PV, CSI, VolumeAttachment, monitoring persistent storage, image registry storage, local storage, ODF, or storage warning event analysis. This script validates PVC phase through JSON to avoid false positives from text matching.

### AI workloads

```bash
./ocp418-ai-workloads-deep-dive.sh \
  --env-file ./.ocp-deep.env \
  --cluster-name non-prod-ocp \
  --target-namespaces apm0006923-non-prod
```

Use this for AI/AIOps/OpenShift AI workloads, model-serving workloads, GPU resources, namespace-specific eviction issues, and application service endpoint readiness.

## How to read the outputs

Each live script creates a timestamped directory under `OUTPUT_BASE_DIR`:

```text
<run-dir>/
├── raw/                 # command outputs
├── logs/                # selected pod logs
├── describes/           # selected pod describes
├── csv/                 # findings and annex tables
└── report/
    ├── report.md
    └── report.html
```

Read in this order:

1. Open `report/report.html` for a human-readable summary.
2. Review `csv/findings.csv` for prioritized findings.
3. Use `csv/evidence-index.csv` to map each finding to raw evidence.
4. Review `raw/` files for command outputs.
5. Review `logs/` and `describes/` only for selected failing pods.

## Suggested mapping to report sections

| Report section | Generated content source |
| --- | --- |
| 3.1 Executive Summary | `report/report-fill-sections.md` or `report/healthcheck-report-generated.md` |
| 4.4 Engagement Requirement Criteria | `report/healthcheck-report-generated.md` |
| 5.1 Journal | `report/healthcheck-report-generated.md` |
| 5.2 Knowledge Transfer | `report/healthcheck-report-generated.md` |
| 6 Review Findings and Recommendations | `annex/priority-findings.csv` and each live script `csv/findings.csv` |
| 7.1 Technical Next Steps | `report/healthcheck-report-generated.md` |
| Appendix / Annex | CSV files under `annex/` and `csv/` |

## Important notes

- The scripts do not modify cluster resources.
- Sanitization is enabled by default for generated reports. Raw command output files can still contain hostnames, namespaces, URLs, labels, image references, or other environment identifiers.
- Review all generated files before sharing externally.
- `jq` is strongly recommended. Scripts continue best-effort without it, but structured findings are richer when `jq` is available.
