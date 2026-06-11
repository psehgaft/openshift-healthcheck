#!/usr/bin/env python3
"""Render OpenShift Health Check CSV evidence into enriched HTML/Markdown/CER sections."""
from __future__ import annotations
import argparse, csv, html, os, pathlib, datetime

SEV_RANK = {"Critical": 1, "Severe": 2, "Major": 3, "Advisory": 4, "Minor": 5, "Info": 6, "": 99}
SEV_COLOR = {"Critical":"#c9190b","Severe":"#f04b37","Major":"#f0ab00","Advisory":"#73bcf7","Minor":"#bee1f4","Info":"#d2d2d2"}

def read_csv(path: pathlib.Path):
    if not path.exists(): return []
    with path.open(newline='', encoding='utf-8', errors='replace') as f:
        return list(csv.DictReader(f))

def write_csv(path: pathlib.Path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', newline='', encoding='utf-8') as f:
        w=csv.DictWriter(f, fieldnames=fields)
        w.writeheader(); w.writerows(rows)

def esc(x): return html.escape(str(x or ""))

def table(rows, fields=None, limit=None):
    if not rows: return "<p><em>No records found.</em></p>"
    rows = rows[:limit] if limit else rows
    fields = fields or list(rows[0].keys())
    out=["<table><thead><tr>"]
    out += [f"<th>{esc(f)}</th>" for f in fields]
    out.append("</tr></thead><tbody>")
    for r in rows:
        sev=r.get('severity') or r.get('Severity') or r.get('recommendation') or ''
        cls=''
        if sev in SEV_COLOR: cls=f' class="sev-{sev.lower()}"'
        out.append(f"<tr{cls}>")
        for f in fields:
            out.append(f"<td>{esc(r.get(f,''))}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return ''.join(out)

def md_table(rows, fields=None, limit=None):
    if not rows: return "No records found.\n"
    rows = rows[:limit] if limit else rows
    fields = fields or list(rows[0].keys())
    lines=["| " + " | ".join(fields) + " |", "| " + " | ".join(["---"]*len(fields)) + " |"]
    for r in rows:
        vals=[str(r.get(f,'' )).replace('|','\\|').replace('\n',' ') for f in fields]
        lines.append("| " + " | ".join(vals) + " |")
    return "\n".join(lines)+"\n"

def sev_counts(rows):
    counts={}
    for r in rows:
        s=r.get('severity','') or 'Unclassified'
        counts[s]=counts.get(s,0)+1
    return counts

def infer_recommendation_key(sev):
    return {"Critical":"Changes Required","Severe":"Changes Required","Major":"Changes Recommended","Advisory":"Advisory","Minor":"Advisory","Info":"No Change"}.get(sev,"To Be Evaluated")

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--run-dir', required=True)
    ap.add_argument('--cluster-name', required=True)
    ap.add_argument('--client-label', default='Client')
    args=ap.parse_args()
    run=pathlib.Path(args.run_dir)
    csvd=run/'csv'; rep=run/'report'; rep.mkdir(exist_ok=True)
    findings=read_csv(csvd/'findings.csv')
    backlog=read_csv(csvd/'backlog.csv')
    errors=read_csv(csvd/'errors-criticality.csv')
    ns=read_csv(csvd/'namespace-review.csv')
    workloads=read_csv(csvd/'workload-review.csv')
    evidence=read_csv(csvd/'evidence-index.csv')
    findings.sort(key=lambda r: SEV_RANK.get(r.get('severity',''), 99))
    errors.sort(key=lambda r: SEV_RANK.get(r.get('severity',''), 99))
    backlog.sort(key=lambda r: (r.get('priority','P9'), SEV_RANK.get(r.get('severity',''), 99)))
    counts=sev_counts(findings)
    now=datetime.datetime.now().isoformat(timespec='seconds')
    summary_lines=[
        f"OpenShift Health Check Summary",
        f"Generated: {now}",
        f"Cluster: {args.cluster_name}",
        f"Client label: {args.client_label}",
        f"Critical findings: {counts.get('Critical',0)}",
        f"Severe findings: {counts.get('Severe',0)}",
        f"Major findings: {counts.get('Major',0)}",
        f"Backlog items: {len(backlog)}",
        f"Namespaces reviewed: {len(ns)}",
        f"Workloads reviewed: {len(workloads)}",
        f"Evidence items: {len(evidence)}",
    ]
    (rep/'summary.txt').write_text('\n'.join(summary_lines)+'\n', encoding='utf-8')

    md=[]
    md += [f"# OpenShift Health Check Report - {args.cluster_name}", "", f"Generated: {now}", f"Client: {args.client_label}", ""]
    md += ["## Executive Summary", ""]
    if findings:
        top=findings[0]
        md.append(f"The automated Health Check identified {len(findings)} technical findings and {len(backlog)} remediation backlog actions across platform health, workload readiness, networking, storage, security and namespace governance. The highest priority finding is **{top.get('finding','')}** with severity **{top.get('severity','')}**.")
    else:
        md.append("The automated Health Check did not generate critical findings from the collected evidence. Manual review is still required for architecture, operational process, and customer-specific requirements.")
    md += ["", "## Recommendation Key", "", md_table([{"Severity":"Critical","Recommendation":"Changes Required","Meaning":"Immediate remediation or explicit risk acceptance required."},{"Severity":"Severe","Recommendation":"Changes Required","Meaning":"High risk; remediate before upgrades or production expansion."},{"Severity":"Major","Recommendation":"Changes Recommended","Meaning":"Improve resilience, governance, consistency or operability."},{"Severity":"Advisory","Recommendation":"Advisory","Meaning":"Informational or optimization recommendation."}], ["Severity","Recommendation","Meaning"])]
    md += ["", "## Summary of Findings", "", md_table(findings, ["severity","category","finding","risk","recommendation"], 100)]
    md += ["", "## Criticality Explanation", "", md_table(errors, ["severity","category","namespace","object","symptom","explanation","remediation"], 200)]
    md += ["", "## Namespace Review", "", md_table(ns, ["namespace","quotas","limitranges","networkpolicies","secrets","configmaps","deployments","pods","services","routes","recommendations"], 200)]
    md += ["", "## Workload Review", "", md_table(workloads, ["namespace","kind","name","replicas","ready","has_requests","has_limits","has_probes","has_pdb","has_hpa","recommendations"], 200)]
    md += ["", "## Remediation Backlog", "", md_table(backlog, ["priority","severity","category","namespace","object","action","rationale","remediation","owner","status"], 300)]
    md += ["", "## Evidence Index", "", f"Command index: `{run/'command-index.tsv'}`", "", f"Raw evidence directory: `{run/'raw'}`", "", f"Logs directory: `{run/'logs'}`", "", f"Describes directory: `{run/'describes'}`", "", f"Must-gather directory: `{run/'must-gather'}`", ""]
    (rep/f"report-{args.cluster_name}.md").write_text('\n'.join(md), encoding='utf-8')

    cer=[]
    cer += [f"# CER Fill Sections - {args.cluster_name}", ""]
    cer += ["## 3.1 Executive Summary", ""]
    cer += [f"Red Hat Consulting was engaged by {args.client_label} to perform an OpenShift Health Check for cluster `{args.cluster_name}`. The assessment collected read-only evidence from cluster APIs, workload objects, events, logs, describes, CRDs and must-gather output. The review identified prioritized findings across platform health, namespace governance, workload readiness, networking, storage, security and operational readiness.", ""]
    if findings:
        cer += ["The highest priority findings are:", ""]
        for i,r in enumerate(findings[:10],1):
            cer.append(f"{i}. **{r.get('finding','')}** ({r.get('severity','')}) - {r.get('recommendation','')}")
        cer.append("")
    cer += ["## 4.4 Engagement Requirement Criteria", "", md_table([{"Requirement":"OpenShift platform health","Details":"Validate ClusterVersion, ClusterOperators, nodes, MachineConfigPools, APIs, authentication, ingress, DNS, monitoring and upgrade readiness."},{"Requirement":"Network readiness","Details":"Review services, endpoints, routes, ingress, DNS, NetworkPolicy, EgressIP/EgressFirewall, Multus/NAD, NMState and SR-IOV when present."},{"Requirement":"Storage readiness","Details":"Review StorageClasses, PV/PVC, CSI, VolumeAttachments, registry storage, monitoring storage and ODF-related resources when present."},{"Requirement":"Namespace and workload governance","Details":"Review secrets, ConfigMaps, deployments, workload health, probes, resource requests/limits, quotas, LimitRanges, PDB, HPA and NetworkPolicy coverage."},{"Requirement":"AI/AIOps workloads","Details":"Review AI candidate namespaces, model-serving resources, GPU/accelerator capacity, storage and workload readiness."}], ["Requirement","Details"])]
    cer += ["", "## 5.1 Journal", "", md_table([{"Date":now.split('T')[0],"Activities":"Collected OpenShift health evidence, deep-dive namespace/workload data, CRD resources, logs, describes, and must-gather.","Blockers":"None identified by the collection script. Manual review may identify access gaps or incomplete external-system evidence."}], ["Date","Activities","Blockers"])]
    cer += ["", "## 5.2 Knowledge Transfer", "", "Recommended knowledge-transfer topics include: review of findings and backlog, namespace governance standards, resource request/limit policy, probe/PDB/HPA patterns, storage evidence, network traffic path review, AI/AIOps workload readiness, must-gather handoff, and backlog ownership model.", ""]
    cer += ["## 6.2 Summary", "", md_table(findings, ["severity","category","finding","risk","recommendation"], 100)]
    cer += ["", "## 7.1 Technical Next Steps", ""]
    for i,r in enumerate(backlog[:20],1):
        cer.append(f"{i}. **{r.get('action','')}** - {r.get('remediation','')} Owner: {r.get('owner','TBD')}. Priority: {r.get('priority','')}. Severity: {r.get('severity','')}.")
    cer.append("")
    cer += ["## Appendix: Critical Findings and Remediation Annex", "", md_table(backlog, ["priority","severity","category","namespace","object","action","rationale","remediation"], 500)]
    (rep/'cer-fill-sections.md').write_text('\n'.join(cer), encoding='utf-8')

    css='''<style>
body{font-family:Inter,Arial,sans-serif;margin:32px;color:#151515;background:#fff} h1,h2{color:#151515} .meta{color:#666}.cards{display:flex;gap:12px;flex-wrap:wrap}.card{border:1px solid #d2d2d2;border-radius:8px;padding:12px;min-width:140px;background:#f7f7f7}.num{font-size:28px;font-weight:700} table{border-collapse:collapse;width:100%;font-size:13px;margin:12px 0} th{background:#e0e0e0;text-align:left} th,td{border:1px solid #d2d2d2;padding:6px;vertical-align:top}.sev-critical td{background:#ffe6e2}.sev-severe td{background:#fff0ef}.sev-major td{background:#fff4ce}.sev-advisory td{background:#e7f1fa}.pill{display:inline-block;padding:3px 8px;border-radius:12px;background:#eee}.section{margin-top:28px}.small{font-size:12px;color:#6a6e73}
</style>'''
    cards=''.join([f"<div class='card'><div class='small'>{esc(k)}</div><div class='num'>{v}</div></div>" for k,v in [("Critical",counts.get('Critical',0)),("Severe",counts.get('Severe',0)),("Major",counts.get('Major',0)),("Backlog",len(backlog)),("Namespaces",len(ns)),("Workloads",len(workloads))]])
    html_doc=f"""<!doctype html><html><head><meta charset='utf-8'><title>OpenShift Health Check - {esc(args.cluster_name)}</title>{css}</head><body>
<h1>OpenShift Health Check Report - {esc(args.cluster_name)}</h1><p class='meta'>Generated {esc(now)} | Client: {esc(args.client_label)}</p><div class='cards'>{cards}</div>
<div class='section'><h2>Executive Summary</h2><p>The automated Health Check collected read-only evidence from the OpenShift API, CRDs, logs, describes, namespace resources and must-gather output. Findings below require consultant review before customer delivery.</p></div>
<div class='section'><h2>Priority Findings</h2>{table(findings,["severity","category","finding","risk","recommendation"],100)}</div>
<div class='section'><h2>Namespace Governance Review</h2>{table(ns,["namespace","quotas","limitranges","networkpolicies","secrets","configmaps","deployments","pods","services","routes","recommendations"],200)}</div>
<div class='section'><h2>Workload / 12-Factor Review</h2><p>Automated checks focus on config externalization, disposability, resource management, logs/events evidence, concurrency/scaling and operational parity indicators.</p>{table(workloads,["namespace","kind","name","replicas","ready","has_requests","has_limits","has_probes","has_pdb","has_hpa","recommendations"],300)}</div>
<div class='section'><h2>Remediation Backlog</h2>{table(backlog,["priority","severity","category","namespace","object","action","rationale","remediation","owner","status"],500)}</div>
<div class='section'><h2>Evidence</h2><p>See command-index.tsv, raw/, logs/, describes/ and must-gather/ in the run directory.</p></div>
</body></html>"""
    (rep/f"report-{args.cluster_name}.html").write_text(html_doc, encoding='utf-8')

    err_html=f"""<!doctype html><html><head><meta charset='utf-8'><title>OpenShift Criticality Explanation - {esc(args.cluster_name)}</title>{css}</head><body>
<h1>Errors, Criticality and Remediation - {esc(args.cluster_name)}</h1><p class='meta'>Generated {esc(now)}</p>
<p>This report explains the automated criticality assigned to detected symptoms. Criticality should be confirmed by a consultant with environment context, business impact and application ownership.</p>
<h2>Criticality Model</h2>{table([{"Level":"Critical","Why":"Platform or workload condition can cause outage, block upgrade, or cause repeated service interruption.","Typical Action":"Immediate remediation or explicit risk acceptance."},{"Level":"Severe","Why":"High operational risk, degraded readiness, failed rollout, or unsupported/fragile state.","Typical Action":"Remediate before expansion or upgrade."},{"Level":"Major","Why":"Governance, resilience or best-practice gap likely to cause drift, delays or increased support cost.","Typical Action":"Plan remediation in backlog."},{"Level":"Advisory","Why":"Optimization or evidence gap with low immediate impact.","Typical Action":"Document or improve when planned."}], ["Level","Why","Typical Action"])}
<h2>Detected Errors and Explanations</h2>{table(errors,["severity","criticality_reason","category","namespace","object","symptom","explanation","remediation","evidence"],1000)}
</body></html>"""
    (rep/f"errors-{args.cluster_name}.html").write_text(err_html, encoding='utf-8')

    # delivery copies in /report
    for src_name in ['findings.csv','backlog.csv','errors-criticality.csv','namespace-review.csv','workload-review.csv','evidence-index.csv']:
        p=csvd/src_name
        if p.exists(): (rep/src_name).write_text(p.read_text(encoding='utf-8', errors='replace'), encoding='utf-8')

if __name__ == '__main__': main()
