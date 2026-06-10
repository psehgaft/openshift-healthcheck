#!/usr/bin/env python3
"""
Builds customer-ready Markdown/HTML report sections and annex CSVs from an
OpenShift 4.18+ health check output directory or .tar/.txz/.tar.gz bundle.

The builder is offline: it does not require cluster access. It parses the output
from the health-check collector and generates:
  - report/healthcheck-report-generated.md
  - report/healthcheck-report-generated.html
  - report/report-fill-sections.md
  - annex/*.csv

Default behavior sanitizes customer names, emails, IPs, URLs, and common non-Red Hat
vendor/brand names from generated outputs. Raw evidence is not modified.
"""
from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Dict, Tuple

NON_REDHAT_BRAND_PATTERNS = [
    r"\bKPMG\b", r"\bIBM\b", r"\bWatson\b", r"\bWatsonx\b", r"\bAIOps\b",
    r"\bDynatrace\b", r"\bRubrik\b", r"\bPortworx\b", r"\bF5\b", r"\bCyberArk\b",
    r"\bCommvault\b", r"\bNexus\b", r"\bGitLab\b", r"\bJIRA\b", r"\bCheckmk\b",
]

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
URL_RE = re.compile(r"https?://[^\s)\]]+")
FQDN_RE = re.compile(r"\b[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+){2,}\b")


def read_text(path: Path, limit: int | None = None) -> str:
    try:
        data = path.read_text(errors="replace")
        return data if limit is None else data[:limit]
    except Exception:
        return ""


def extract_archive_if_needed(input_path: Path) -> Tuple[Path, tempfile.TemporaryDirectory | None]:
    if input_path.is_dir():
        return input_path, None
    tmp = tempfile.TemporaryDirectory(prefix="ocp-health-input-")
    dest = Path(tmp.name)
    if tarfile.is_tarfile(input_path):
        with tarfile.open(input_path) as tf:
            def is_safe(member: tarfile.TarInfo) -> bool:
                target = dest / member.name
                return str(target.resolve()).startswith(str(dest.resolve()))
            for m in tf.getmembers():
                if is_safe(m):
                    tf.extract(m, dest)
        dirs = [p for p in dest.iterdir() if p.is_dir()]
        if len(dirs) == 1:
            return dirs[0], tmp
        return dest, tmp
    raise SystemExit(f"Unsupported input: {input_path}")


def load_patterns(file: Path | None) -> List[re.Pattern]:
    patterns = []
    if file and file.exists():
        for line in file.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                patterns.append(re.compile(line, re.I))
            except re.error:
                pass
    return patterns


def sanitize(text: str, client_label: str, patterns: List[re.Pattern], enabled: bool = True) -> str:
    if not enabled:
        return text
    text = EMAIL_RE.sub("[REDACTED_EMAIL]", text)
    text = URL_RE.sub("[REDACTED_URL]", text)
    text = IP_RE.sub("[REDACTED_IP]", text)
    # Keep Red Hat and OpenShift names; redact customer/third-party names.
    for pat in NON_REDHAT_BRAND_PATTERNS:
        text = re.sub(pat, "third-party", text, flags=re.I)
    for pat in patterns:
        text = pat.sub("[REDACTED]", text)
    # FQDN redaction is intentionally not applied by default because Kubernetes object
    # versions and operator package names can look like dotted hostnames. Use
    # --redaction-patterns for environment-specific domains.
    return text.replace("Client Client", client_label)


def lines_without_command_wrapper(text: str) -> List[str]:
    lines = []
    in_output = False
    saw_wrapper = False
    for line in text.splitlines():
        if line.startswith("# Output"):
            saw_wrapper = True
            in_output = True
            continue
        if line.startswith("# Finished") or line.startswith("# Return code"):
            in_output = False
        elif in_output and not line.startswith("#"):
            if line.strip():
                lines.append(line.rstrip())
    if saw_wrapper:
        return lines
    return [l.rstrip() for l in text.splitlines() if l.strip() and not l.startswith("#")]


def parse_summary(run_dir: Path) -> Dict[str, str | List[str]]:
    summary = read_text(run_dir / "summary.txt")
    result: Dict[str, str | List[str]] = {"findings": []}
    for line in summary.splitlines():
        if line.startswith("Overall status:"):
            result["overall_status"] = line.split(":", 1)[1].strip()
        elif line.startswith("Critical findings:"):
            result["critical_count"] = line.split(":", 1)[1].strip()
        elif line.startswith("Warning findings:"):
            result["warning_count"] = line.split(":", 1)[1].strip()
        elif line.startswith("Info findings:"):
            result["info_count"] = line.split(":", 1)[1].strip()
        elif line.startswith("Cluster name hint:"):
            result["cluster"] = line.split(":", 1)[1].strip()
        elif line.startswith("Generated:"):
            result["generated"] = line.split(":", 1)[1].strip()
        elif line.startswith("- **"):
            result["findings"].append(line.strip("- "))  # type: ignore
    return result


def parse_problematic_pods(run_dir: Path) -> List[Dict[str, str]]:
    p = run_dir / "raw" / "05_pods_problematic.tsv"
    rows = []
    if not p.exists():
        return rows
    for line in p.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        rows.append({
            "namespace": parts[0],
            "pod": parts[1],
            "phase": parts[2] if len(parts) > 2 else "",
            "restarts": parts[3] if len(parts) > 3 else "",
            "waiting_reason": parts[4] if len(parts) > 4 else "",
            "terminated_reason": parts[5] if len(parts) > 5 else "",
            "reason": parts[6] if len(parts) > 6 else "",
            "message": parts[7] if len(parts) > 7 else "",
        })
    return rows


def parse_deployments_unavailable(run_dir: Path) -> List[Dict[str, str]]:
    p = run_dir / "raw" / "05_deployments_not_available.txt"
    rows = []
    for line in lines_without_command_wrapper(read_text(p)):
        if line.startswith("NAMESPACE") or not line.strip():
            continue
        parts = re.split(r"\s+", line.strip(), maxsplit=5)
        if len(parts) >= 3:
            rows.append({"namespace": parts[0], "deployment": parts[1], "ready": parts[2], "raw": line})
    return rows


def parse_installplans(run_dir: Path) -> List[Dict[str, str]]:
    p = run_dir / "raw" / "09_installplans_not_complete.txt"
    rows = []
    for line in lines_without_command_wrapper(read_text(p)):
        parts = re.split(r"\s+", line.strip())
        if len(parts) >= 5 and parts[0] != "NAMESPACE":
            rows.append({"namespace": parts[0], "name": parts[1], "csv": parts[2], "approval": parts[-2], "approved": parts[-1]})
    return rows


def parse_csr_pending(run_dir: Path) -> List[str]:
    p = run_dir / "raw" / "11_cert_signing_requests_pending.txt"
    return [l for l in lines_without_command_wrapper(read_text(p)) if l.strip() and not l.startswith("NAME")]


def parse_warning_events(run_dir: Path) -> List[Dict[str, str]]:
    p = run_dir / "raw" / "10_warning_events.txt"
    events = []
    for line in lines_without_command_wrapper(read_text(p)):
        if line.startswith("NAMESPACE") or not line.strip():
            continue
        # oc get events -A usually: namespace, last seen, type, reason, object, message
        parts = re.split(r"\s+", line.strip(), maxsplit=5)
        if len(parts) >= 6:
            events.append({"namespace": parts[0], "last_seen": parts[1], "type": parts[2], "reason": parts[3], "object": parts[4], "message": parts[5]})
        else:
            events.append({"namespace": parts[0], "last_seen": "", "type": "", "reason": "", "object": "", "message": line.strip()})
    return events


def parse_pvcs(run_dir: Path) -> List[Dict[str, str]]:
    p = run_dir / "raw" / "08_pvc_all.txt"
    rows = []
    for line in lines_without_command_wrapper(read_text(p)):
        if line.startswith("NAMESPACE") or not line.strip():
            continue
        parts = re.split(r"\s+", line.strip())
        if len(parts) >= 4:
            rows.append({"namespace": parts[0], "name": parts[1], "status": parts[2], "volume": parts[3], "raw": line})
    return rows


def write_csv(path: Path, rows: List[Dict[str, str]], headers: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=headers)
        w.writeheader()
        for r in rows:
            w.writerow({h: r.get(h, "") for h in headers})


def md_table(rows: List[Dict[str, str]], headers: List[str], max_rows: int = 20) -> str:
    if not rows:
        return "No records found.\n"
    h = "| " + " | ".join(headers) + " |"
    sep = "| " + " | ".join(["---"] * len(headers)) + " |"
    out = [h, sep]
    for r in rows[:max_rows]:
        out.append("| " + " | ".join(str(r.get(c, "")).replace("\n", " ")[:220] for c in headers) + " |")
    if len(rows) > max_rows:
        out.append(f"\n_Additional rows omitted in Markdown view: {len(rows)-max_rows}. See CSV annex._")
    return "\n".join(out) + "\n"


def build_findings(summary, pods, deployments, installplans, events, pvcs, csr_pending) -> List[Dict[str, str]]:
    findings = []
    pod_count = len(pods)
    eviction_count = sum(1 for p in pods if "Evicted" in (p.get("reason", "") + p.get("message", "") + p.get("terminated_reason", "")) or "ephemeral" in p.get("message", "").lower())
    high_restart_count = sum(1 for p in pods if re.search(r":(\d+)", p.get("restarts", "")) and any(int(x) >= 10 for x in re.findall(r":(\d+)", p.get("restarts", ""))))
    ai_pod_count = sum(1 for p in pods if re.search(r"ai|aiops|model|ml|watson|zen|ir-core", p.get("namespace", "") + " " + p.get("pod", ""), re.I))
    if pod_count:
        findings.append({
            "priority": "1",
            "issue_name": "Workload Health and Ephemeral Storage Evictions",
            "severity": "Critical" if eviction_count >= 5 else "Severe",
            "likelihood": "Somewhat Likely",
            "complexity": "Standard",
            "category": "Application / AI Workloads",
            "description": f"The collected health output reported {pod_count} problematic pod records. {eviction_count} records indicate evictions or ephemeral-storage pressure, and {high_restart_count} records indicate high restart counts. {ai_pod_count} records appear related to AI or automation workloads.",
            "evidence": "raw/05_pods_problematic.tsv; logs/; describes/",
            "risk": "Failed pods, repeated evictions, and restart loops can cause service instability, delayed jobs, stale endpoints, and misleading platform symptoms when the root cause is workload resource sizing or application configuration.",
            "recommendation": "Group the problematic pods by namespace and owner. Remediate ephemeral-storage evictions first by increasing requests/limits or moving temporary data to PVC-backed paths. Then address restart loops, probes, and rollout errors. Re-run the deep workload script after changes."
        })
    if deployments:
        findings.append({
            "priority": "2",
            "issue_name": "Deployment Rollout Readiness",
            "severity": "Severe" if len(deployments) <= 3 else "Critical",
            "likelihood": "Somewhat Likely",
            "complexity": "Standard",
            "category": "Application / Platform Readiness",
            "description": f"The health output detected {len(deployments)} deployments with unavailable replicas.",
            "evidence": "raw/05_deployments_not_available.txt",
            "risk": "Unavailable deployments can leave Services without endpoints and can be misinterpreted as ingress, DNS, or platform instability.",
            "recommendation": "For each deployment, validate image references, quota errors, scheduling constraints, probes, rollout history, and backing service endpoints. Add remediation tickets for owners and confirm successful rollout."
        })
    protect_events = [e for e in events if re.search(r"ProtectionSet|backup|restore|snapshot|SLA", e.get("reason", "") + e.get("object", "") + e.get("message", ""), re.I)]
    if protect_events:
        findings.append({
            "priority": "3",
            "issue_name": "Backup and Protection Evidence",
            "severity": "Severe",
            "likelihood": "Possible",
            "complexity": "Somewhat Complex",
            "category": "Backup / Recovery",
            "description": f"The warning event set includes {len(protect_events)} backup/protection-related warning events. This indicates that backup or protection integration evidence needs validation.",
            "evidence": "raw/10_warning_events.txt",
            "risk": "Backup integrations that are failing, unauthenticated, or not evidenced can fail audit, recovery, and operational handoff expectations.",
            "recommendation": "Validate backup integration credentials and scope. Capture recent successful backup and restore evidence for representative namespaces, PVCs, and the OpenShift control plane recovery path. Document restore drills."
        })
    probe_events = [e for e in events if re.search(r"probe|timeout|endpoint|readiness|liveness|connection", e.get("reason", "") + e.get("message", ""), re.I)]
    if probe_events:
        findings.append({
            "priority": "4",
            "issue_name": "Network, Probe, and Traffic Path Readiness",
            "severity": "Severe",
            "likelihood": "Possible",
            "complexity": "Standard",
            "category": "Network / Application Traffic",
            "description": f"The warning event set includes {len(probe_events)} probe, timeout, endpoint, or connection related events.",
            "evidence": "raw/10_warning_events.txt; raw/07_network_config.txt",
            "risk": "Probe or traffic path failures can interrupt application access and may hide workload, service, network policy, or endpoint problems.",
            "recommendation": "Run the network deep-dive script. Correlate warnings with Services, Endpoints, Routes, IngressController status, NetworkPolicy, DNS, and pod placement. Resolve stale Services and failing probes."
        })
    unapproved = [p for p in installplans if p.get("approved", "").lower() == "false"]
    if unapproved or len(installplans) > 20:
        findings.append({
            "priority": "5",
            "issue_name": "Operator Lifecycle and InstallPlan Governance",
            "severity": "Major",
            "likelihood": "Possible",
            "complexity": "Standard",
            "category": "Platform / OLM",
            "description": f"The health output contains {len(installplans)} InstallPlan records listed for review, including {len(unapproved)} unapproved manual InstallPlans.",
            "evidence": "raw/09_installplans_not_complete.txt; raw/09_subscriptions.txt; raw/09_csv_all.txt",
            "risk": "Unreviewed or stale operator upgrade plans can cause inconsistent operator lifecycle state and unclear upgrade governance.",
            "recommendation": "Review all manual InstallPlans, confirm whether pending plans are intentional, remove obsolete plans where appropriate, and document operator upgrade ownership and approval workflow."
        })
    not_bound = [p for p in pvcs if p.get("status") and p.get("status") != "Bound"]
    if not_bound:
        findings.append({
            "priority": "6",
            "issue_name": "PVC Binding and Storage Provisioning",
            "severity": "Critical",
            "likelihood": "Possible",
            "complexity": "Standard",
            "category": "Storage",
            "description": f"The parsed PVC inventory shows {len(not_bound)} PVCs not in Bound state.",
            "evidence": "raw/08_pvc_all.txt",
            "risk": "Unbound PVCs can block scheduling, rollout, data recovery, and application startup.",
            "recommendation": "Run the storage deep-dive script. Validate the storage class, CSI driver health, quota, capacity, events, and VolumeAttachment state for each unbound claim."
        })
    else:
        findings.append({
            "priority": "6",
            "issue_name": "Storage Evidence Validation",
            "severity": "Advisory",
            "likelihood": "Possible",
            "complexity": "Standard",
            "category": "Storage",
            "description": "The original health summary reported PVC binding warnings, but parsed PVC inventory rows from the available evidence appear Bound. This needs stricter JSON-based validation to avoid false positives.",
            "evidence": "raw/08_pvc_all.txt; raw/08_pvc_not_bound.txt",
            "risk": "False positives reduce trust in the report and can distract the team from true storage issues.",
            "recommendation": "Use the updated storage deep-dive script, which validates PVC phase from JSON instead of loose text matching."
        })
    if csr_pending:
        findings.append({
            "priority": "7",
            "issue_name": "Certificate Signing Request Review",
            "severity": "Major",
            "likelihood": "Possible",
            "complexity": "Standard",
            "category": "Security / Certificates",
            "description": f"The health evidence includes {len(csr_pending)} candidate pending CSR rows.",
            "evidence": "raw/11_cert_signing_requests_pending.txt; raw/11_csr.txt",
            "risk": "Pending CSRs can indicate node or component certificate lifecycle issues if they are legitimate and unresolved.",
            "recommendation": "Verify CSR status with the full CSR table, approve only expected node/client requests, and investigate unexpected or stale requests."
        })
    cluster_status = summary.get("overall_status", "UNKNOWN")
    if cluster_status:
        findings.append({
            "priority": "7",
            "issue_name": "Platform Baseline Health and Upgrade Readiness",
            "severity": "No Change" if str(cluster_status).upper() != "CRITICAL" else "Advisory",
            "likelihood": "Possible",
            "complexity": "Standard",
            "category": "Platform",
            "description": f"The health summary reports overall status {cluster_status}. ClusterVersion, ClusterOperators, nodes, and MachineConfigPools should be kept as upgrade gates.",
            "evidence": "summary.txt; raw/02_clusterversion.txt; raw/03_clusteroperators.txt; raw/04_nodes.txt; raw/04_mcp.txt",
            "risk": "Upgrades attempted without clear health gates can turn routine maintenance into extended troubleshooting.",
            "recommendation": "Before any upgrade window, confirm ClusterVersion Available=True, all ClusterOperators healthy, nodes Ready, MCPs updated, no critical workload blockers, and certificate status reviewed."
        })
    return findings


def html_from_md(md: str) -> str:
    out = []
    in_code = False
    buf = []
    for line in md.splitlines():
        if line.startswith("```"):
            if not in_code:
                in_code = True; buf = []
            else:
                out.append("<pre><code>" + html.escape("\n".join(buf)) + "</code></pre>")
                in_code = False
            continue
        if in_code:
            buf.append(line); continue
        if line.startswith("# "):
            out.append(f"<h1>{html.escape(line[2:])}</h1>")
        elif line.startswith("## "):
            out.append(f"<h2>{html.escape(line[3:])}</h2>")
        elif line.startswith("### "):
            out.append(f"<h3>{html.escape(line[4:])}</h3>")
        elif line.startswith("| "):
            # Simplistic table handling: group is not implemented; render as pre for stability.
            out.append(f"<pre>{html.escape(line)}</pre>")
        elif line.startswith("- "):
            out.append(f"<li>{html.escape(line[2:])}</li>")
        elif line.strip() == "":
            out.append("")
        else:
            out.append(f"<p>{html.escape(line)}</p>")
    css = """
<style>
body{font-family:Arial,Helvetica,sans-serif;margin:32px;line-height:1.45;color:#222;max-width:1280px}
h1{border-bottom:4px solid #cc0000;padding-bottom:8px}h2{margin-top:28px;border-bottom:1px solid #ddd;padding-bottom:4px}h3{margin-top:20px}.callout{border-left:5px solid #cc0000;background:#fff5f5;padding:12px;margin:16px 0}pre{background:#f7f7f7;border:1px solid #ddd;padding:10px;overflow:auto;font-size:12px}li{margin:4px 0}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:6px}
</style>
"""
    return "<!doctype html><html><head><meta charset='utf-8'><title>OpenShift Health Check Generated Report</title>" + css + "</head><body>" + "\n".join(out) + "</body></html>"


def build_report(run_dir: Path, output: Path, client_label: str, cluster_name: str | None, patterns: List[re.Pattern], sanitize_enabled: bool) -> None:
    report_dir = output / "report"
    annex_dir = output / "annex"
    report_dir.mkdir(parents=True, exist_ok=True)
    annex_dir.mkdir(parents=True, exist_ok=True)
    summary = parse_summary(run_dir)
    if cluster_name:
        summary["cluster"] = cluster_name
    pods = parse_problematic_pods(run_dir)
    deployments = parse_deployments_unavailable(run_dir)
    installplans = parse_installplans(run_dir)
    events = parse_warning_events(run_dir)
    pvcs = parse_pvcs(run_dir)
    csr_pending = parse_csr_pending(run_dir)
    findings = build_findings(summary, pods, deployments, installplans, events, pvcs, csr_pending)

    # Annex CSVs
    write_csv(annex_dir / "priority-findings.csv", findings, ["priority","issue_name","severity","likelihood","complexity","category","description","evidence","risk","recommendation"])
    write_csv(annex_dir / "problematic-pods.csv", pods, ["namespace","pod","phase","restarts","waiting_reason","terminated_reason","reason","message"])
    write_csv(annex_dir / "deployments-unavailable.csv", deployments, ["namespace","deployment","ready","raw"])
    write_csv(annex_dir / "installplans-review.csv", installplans, ["namespace","name","csv","approval","approved"])
    write_csv(annex_dir / "warning-events.csv", events, ["namespace","last_seen","type","reason","object","message"])
    write_csv(annex_dir / "pvc-inventory.csv", pvcs, ["namespace","name","status","volume","raw"])
    not_bound = [p for p in pvcs if p.get("status") and p.get("status") != "Bound"]
    write_csv(annex_dir / "pvc-not-bound.csv", not_bound, ["namespace","name","status","volume","raw"])

    reason_counts = Counter()
    ns_counts = Counter()
    for p in pods:
        reason = p.get("reason") or p.get("terminated_reason") or p.get("waiting_reason") or p.get("phase")
        if "ephemeral" in p.get("message", "").lower():
            reason = "Evicted: ephemeral local storage"
        reason_counts[reason] += 1
        ns_counts[p.get("namespace", "unknown")] += 1
    summary_rows = [{"dimension":"pod_reason","value":k,"count":str(v)} for k,v in reason_counts.most_common()]
    summary_rows += [{"dimension":"pod_namespace","value":k,"count":str(v)} for k,v in ns_counts.most_common()]
    write_csv(annex_dir / "problem-summary.csv", summary_rows, ["dimension","value","count"])

    # Report sections
    generated = datetime.now().isoformat(timespec="seconds")
    cluster = str(summary.get("cluster") or "OpenShift cluster")
    overall = str(summary.get("overall_status") or "UNKNOWN")
    critical = str(summary.get("critical_count") or "0")
    warning = str(summary.get("warning_count") or "0")

    md = f"""# OpenShift Health Check Generated Report Content

- Generated: {generated}
- Client label: {client_label}
- Cluster: {cluster}
- Source health run: {run_dir}
- Overall health status from source report: {overall}
- Critical findings from source report: {critical}
- Warning findings from source report: {warning}

## 3.1 Executive Summary

Red Hat Consulting was engaged to perform an OpenShift Health Check and targeted technical analysis for the in-scope OpenShift cluster. The assessment reviewed cluster health, workload readiness, operator lifecycle state, storage evidence, network and traffic-path signals, warning events, and AI/application workload symptoms identified in the collected evidence.

The collected health report indicates that the core OpenShift platform baseline is generally stable: ClusterVersion, ClusterOperators, nodes, and MachineConfigPools do not show the primary failure pattern in the available evidence. However, the overall report status is {overall} because workload-level issues were detected, including problematic pods, evictions or restart loops, unavailable deployments, warning events, and operator lifecycle items requiring review.

The most important remediation focus is to separate platform health from application/workload health. Platform upgrade gates should remain strict, but immediate technical attention should prioritize workload eviction/restart causes, deployment rollout blockers, backup/protection evidence, traffic-path readiness, and operator lifecycle governance.

## 4.4 Engagement Requirement Criteria

| Requirement | Details |
| --- | --- |
| OpenShift platform health | Validate OpenShift 4.18+ cluster baseline, ClusterVersion, ClusterOperators, node readiness, MachineConfigPools, and API availability. |
| AI/application workload stability | Identify failing, evicted, restarting, or unavailable AI/application workloads and capture owner-facing evidence. |
| Network and traffic-path readiness | Validate Services, Endpoints, Routes, IngressControllers, DNS, proxy/noProxy, NetworkPolicy, and network warning events. |
| Storage readiness | Validate PVC/PV binding, StorageClasses, VolumeAttachments, monitoring storage, registry storage, CSI drivers, and storage warning events. |
| Operator lifecycle governance | Review Subscriptions, CSVs, InstallPlans, approval state, and stale or unapproved operator upgrade plans. |
| Remediation evidence | Produce Markdown, HTML, and CSV annexes containing prioritized findings, risk, remediation guidance, and evidence pointers. |

## 5.1 Journal

| Date | Activities | Blockers |
| --- | --- | --- |
| {generated[:10]} | Collected and analyzed OpenShift health evidence; reviewed cluster baseline, workload symptoms, storage indicators, network indicators, OLM state, and warning events. | Some items require deeper live-cluster follow-up to confirm ownership, runtime metrics, and current post-remediation state. |

## 5.2 Knowledge Transfer

The recommended working sessions should be structured around evidence-based remediation. Each session should review the relevant annex, validate ownership, confirm impact, and agree on remediation evidence to collect after changes.

| Session | Purpose / Attendees | Outputs |
| --- | --- | --- |
| Workload Health and AI/Application Stability | Review problematic pods, evictions, restart loops, unavailable deployments, probes, PDBs, and service endpoints with platform and application owners. | Owner list, remediation backlog, pod/deployment fixes, post-change validation evidence. |
| Storage and Backup Evidence | Review PVC/PV state, storage classes, CSI evidence, backup/protection warnings, and restore evidence requirements. | Storage issue register, backup evidence checklist, restore validation plan. |
| Network and Traffic Path | Review DNS, ingress, services without endpoints, proxy/noProxy, network policies, and timeout/probe warnings. | Traffic-path diagram inputs, stale service list, network remediation backlog. |
| Operator Lifecycle and Upgrade Governance | Review InstallPlans, Subscriptions, CSVs, approval modes, and upgrade ownership. | Operator lifecycle decision log and upgrade approval process. |

## 6.2 Summary of Findings

{md_table(findings, ["priority","issue_name","severity","likelihood","complexity","category"], max_rows=20)}

## 7.1 Technical Next Steps

1. Run the deeper live-cluster scripts included with the deep-dive suite: error follow-up, network, storage, and AI workloads.
2. Assign owners for each priority finding in `annex/priority-findings.csv`.
3. For each Critical or Severe item, capture before/after evidence: affected object, root cause, remediation action, validation command, and result.
4. Re-run the health check after the first remediation cycle and compare `problem-summary.csv` deltas.
5. Convert recurring manual remediation into declarative configuration or controlled automation using Red Hat-supported platform capabilities where appropriate.

## Appendix F: Critical Findings and Remediation Annex

The detailed annex files generated with this report are:

- `annex/priority-findings.csv`
- `annex/problematic-pods.csv`
- `annex/problem-summary.csv`
- `annex/deployments-unavailable.csv`
- `annex/installplans-review.csv`
- `annex/warning-events.csv`
- `annex/pvc-inventory.csv`
- `annex/pvc-not-bound.csv`

### Priority Findings Detail

{md_table(findings, ["priority","issue_name","severity","description","risk","recommendation"], max_rows=12)}

### Problematic Pod Summary

{md_table(summary_rows, ["dimension","value","count"], max_rows=25)}

### Deployments with Unavailable Replicas

{md_table(deployments, ["namespace","deployment","ready"], max_rows=25)}

### InstallPlans Requiring Review

{md_table(installplans, ["namespace","name","csv","approval","approved"], max_rows=25)}
"""
    md = sanitize(md, client_label, patterns, sanitize_enabled)
    md_path = report_dir / "healthcheck-report-generated.md"
    md_path.write_text(md, encoding="utf-8")
    html_path = report_dir / "healthcheck-report-generated.html"
    html_path.write_text(html_from_md(md), encoding="utf-8")

    fill_md = f"""# Report TODO Fill Sections

Use this file to copy/paste into the Health Check report sections that currently contain TODO values.

## Section 3.1 Executive Summary

{sanitize('Red Hat Consulting was engaged to perform an OpenShift Health Check and targeted technical analysis for the in-scope OpenShift cluster. The assessment reviewed cluster baseline health, AI/application workload stability, storage readiness, network and traffic-path signals, operator lifecycle governance, and warning events. The current evidence shows a stable core OpenShift platform baseline, but the report should prioritize workload health, eviction/restart causes, unavailable deployments, backup/protection evidence, and operator lifecycle review.', client_label, patterns, sanitize_enabled)}

## Section 4.4 Engagement Requirement Criteria

See the table in `report/healthcheck-report-generated.md`.

## Section 5.1 Journal

Use the generated Journal table in `report/healthcheck-report-generated.md`.

## Section 5.2 Knowledge Transfer

Use the working session table in `report/healthcheck-report-generated.md`.

## Section 7.1 Technical Next Steps

Use the five technical next steps in `report/healthcheck-report-generated.md`.

## Appendix F Annexes

Attach the CSV files under `annex/` or convert them to spreadsheet tabs.
"""
    (report_dir / "report-fill-sections.md").write_text(fill_md, encoding="utf-8")

    # Sanitize CSV outputs too.
    if sanitize_enabled:
        for csv_path in annex_dir.glob("*.csv"):
            text = csv_path.read_text(errors="replace")
            csv_path.write_text(sanitize(text, client_label, patterns, sanitize_enabled), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description="Build generated report sections and annex CSVs from an OpenShift health check run.")
    ap.add_argument("--input", required=True, help="Health check run directory or tar/txz/tar.gz bundle")
    ap.add_argument("--output", default="./ocp-healthcheck-generated-report", help="Output directory")
    ap.add_argument("--client-label", default="Client", help="Client-neutral label for sanitized output")
    ap.add_argument("--cluster-name", default=None, help="Override cluster name in generated report")
    ap.add_argument("--redaction-patterns", default=None, help="Optional regex redaction file")
    ap.add_argument("--no-sanitize", action="store_true", help="Disable generated-output sanitization")
    args = ap.parse_args()

    input_path = Path(args.input).expanduser().resolve()
    run_dir, tmp = extract_archive_if_needed(input_path)
    output = Path(args.output).expanduser().resolve()
    if output.exists():
        shutil.rmtree(output)
    patterns = load_patterns(Path(args.redaction_patterns) if args.redaction_patterns else None)
    build_report(run_dir, output, args.client_label, args.cluster_name, patterns, not args.no_sanitize)
    print(output)
    if tmp:
        # Keep temp alive until here only.
        tmp.cleanup()


if __name__ == "__main__":
    main()
