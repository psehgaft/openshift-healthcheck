import { ReportAnalysis, ReportData, Severity } from './model';

function escapeHtml(value: unknown): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function join(values: string[]): string {
  return values.length > 0 ? values.map(escapeHtml).join(', ') : '—';
}

function severityClass(severity: Severity): string {
  return `severity-${severity.toLowerCase()}`;
}

function table(headers: string[], rows: string[][]): string {
  const head = headers.map(header => `<th>${escapeHtml(header)}</th>`).join('');
  const body = rows
    .map(row => `<tr>${row.map(cell => `<td>${cell}</td>`).join('')}</tr>`)
    .join('');
  return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}

function metricCards(metrics: Record<string, number>): string {
  return `<div class="metric-grid">${Object.entries(metrics)
    .map(([label, value]) => `<div class="metric"><div class="metric-value">${value}</div><div>${escapeHtml(label)}</div></div>`)
    .join('')}</div>`;
}

function barChart(title: string, values: Record<string, number>, limit = 15): string {
  const entries = Object.entries(values)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit);
  const max = Math.max(1, ...entries.map(([, value]) => value));
  return `<section class="chart"><h3>${escapeHtml(title)}</h3>${entries
    .map(
      ([label, value]) => `<div class="bar-row"><div class="bar-label" title="${escapeHtml(label)}">${escapeHtml(
        label
      )}</div><div class="bar-track"><div class="bar-fill" style="width:${Math.max(
        2,
        (value / max) * 100
      )}%"></div></div><div class="bar-value">${value}</div></div>`
    )
    .join('')}</section>`;
}

function donutChart(title: string, values: Record<string, number>): string {
  const entries = Object.entries(values).filter(([, value]) => value > 0);
  const total = entries.reduce((sum, [, value]) => sum + value, 0) || 1;
  const colors = ['#06c', '#5e40be', '#009596', '#f0ab00', '#c9190b', '#8a8d90'];
  let offset = 0;
  const segments = entries
    .map(([, value], index) => {
      const percentage = value / total;
      const dash = percentage * 100;
      const segment = `<circle class="donut-segment" cx="60" cy="60" r="48" pathLength="100" stroke="${colors[
        index % colors.length
      ]}" stroke-dasharray="${dash} ${100 - dash}" stroke-dashoffset="${-offset}" />`;
      offset += dash;
      return segment;
    })
    .join('');
  const legend = entries
    .map(
      ([label, value], index) => `<div class="legend-row"><span class="legend-color" style="background:${colors[
        index % colors.length
      ]}"></span><span>${escapeHtml(label)}</span><strong>${value}</strong></div>`
    )
    .join('');
  return `<section class="chart"><h3>${escapeHtml(title)}</h3><div class="donut-layout"><svg viewBox="0 0 120 120" class="donut"><circle class="donut-bg" cx="60" cy="60" r="48" />${segments}<text x="60" y="57" text-anchor="middle" class="donut-total">${total}</text><text x="60" y="72" text-anchor="middle" class="donut-caption">total</text></svg><div>${legend}</div></div></section>`;
}

function riskBadge(severity: Severity): string {
  return `<span class="severity ${severityClass(severity)}">${escapeHtml(severity)}</span>`;
}

function details(title: string, content: string, open = false): string {
  return `<details ${open ? 'open' : ''}><summary>${escapeHtml(title)}</summary>${content}</details>`;
}

export function buildStandaloneHtml(data: ReportData, analysis: ReportAnalysis): string {
  const clusterVersion = data.clusterVersion?.status?.desired?.version || 'Unknown';
  const clusterId = data.clusterVersion?.spec?.clusterID || 'Unknown';

  const warningRows = Object.entries(data.collectionErrors).map(([resource, message]) => [
    escapeHtml(resource),
    escapeHtml(message),
  ]);

  const userRows = analysis.users.map(user => [
    escapeHtml(user.name),
    escapeHtml(user.fullName || '—'),
    join(user.groups),
    String(user.directBindingCount),
    String(user.inheritedBindingCount),
    join(user.roles),
    join(user.verbs),
    join(user.resources),
    join(user.sccs),
    riskBadge(user.risk),
    join(user.riskReasons),
  ]);

  const serviceAccountRows = analysis.serviceAccounts.map(serviceAccount => [
    escapeHtml(serviceAccount.namespace),
    escapeHtml(serviceAccount.name),
    escapeHtml(serviceAccount.automountServiceAccountToken),
    String(serviceAccount.bindingCount),
    join(serviceAccount.roles),
    join(serviceAccount.verbs),
    join(serviceAccount.resources),
    join(serviceAccount.sccs),
    riskBadge(serviceAccount.risk),
    join(serviceAccount.riskReasons),
  ]);

  const assignmentRows = analysis.assignments.map(assignment => [
    escapeHtml(assignment.scope),
    escapeHtml(assignment.namespace || '—'),
    escapeHtml(`${assignment.bindingKind}/${assignment.bindingName}`),
    escapeHtml(`${assignment.roleKind}/${assignment.roleName}`),
    escapeHtml(assignment.subjectKind),
    escapeHtml(assignment.subjectNamespace || '—'),
    escapeHtml(assignment.subjectName),
    join(assignment.verbs),
    join(assignment.apiGroups),
    join(assignment.resources),
    join(assignment.resourceNames),
    join(assignment.nonResourceURLs),
    assignment.unresolvedRole ? '<strong>Yes</strong>' : 'No',
    riskBadge(assignment.risk),
    join(assignment.riskReasons),
  ]);

  const roleRows = analysis.roles.map(role => [
    escapeHtml(role.scope),
    escapeHtml(role.namespace || '—'),
    escapeHtml(role.kind),
    escapeHtml(role.name),
    String(role.bindingCount),
    String(role.subjectCount),
    role.aggregated ? 'Yes' : 'No',
    join(role.verbs),
    join(role.apiGroups),
    join(role.resources),
    join(role.resourceNames),
    join(role.nonResourceURLs),
    riskBadge(role.risk),
    join(role.riskReasons),
  ]);

  const sccRows = analysis.sccs.map(scc => [
    escapeHtml(scc.name),
    escapeHtml(scc.priority || '—'),
    scc.privileged ? 'Yes' : 'No',
    scc.hostNetwork ? 'Yes' : 'No',
    scc.hostPID ? 'Yes' : 'No',
    scc.hostIPC ? 'Yes' : 'No',
    scc.hostPorts ? 'Yes' : 'No',
    scc.hostPath ? 'Yes' : 'No',
    scc.readOnlyRootFilesystem ? 'Yes' : 'No',
    join(scc.allowedCapabilities),
    join(scc.requiredDropCapabilities),
    join(scc.volumes),
    join(scc.directUsers),
    join(scc.directGroups),
    join(scc.rbacSubjects),
    String(scc.totalAssignments),
    riskBadge(scc.risk),
    join(scc.riskReasons),
  ]);

  const groupRows = analysis.groups.map(group => [
    escapeHtml(group.name),
    String(group.memberCount),
    join(group.users),
    String(group.bindingCount),
    join(group.roles),
    join(group.verbs),
    join(group.resources),
    join(group.sccs),
    riskBadge(group.risk),
    join(group.riskReasons),
  ]);

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>OpenShift RBAC and SCC Report</title>
<style>
:root{font-family:RedHatText,Arial,sans-serif;color:#151515;background:#f5f5f5;line-height:1.4}
body{margin:0}.page{max-width:1800px;margin:0 auto;padding:24px}.header{background:#151515;color:#fff;padding:28px;border-radius:8px;margin-bottom:20px}.header h1{margin:0 0 8px}.meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px;margin-top:16px;font-size:14px}.metric-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:12px;margin:16px 0}.metric{background:#fff;border:1px solid #d2d2d2;border-radius:6px;padding:16px;box-shadow:0 1px 2px #0001}.metric-value{font-size:30px;font-weight:700;color:#06c}.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:16px;margin:20px 0}.chart{background:#fff;border:1px solid #d2d2d2;border-radius:6px;padding:16px}.chart h3{margin-top:0}.bar-row{display:grid;grid-template-columns:minmax(100px,180px) 1fr 48px;gap:8px;align-items:center;margin:8px 0}.bar-label{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.bar-track{height:14px;background:#e7e7e7;border-radius:7px;overflow:hidden}.bar-fill{height:100%;background:#06c}.bar-value{text-align:right;font-variant-numeric:tabular-nums}.donut-layout{display:flex;align-items:center;gap:24px}.donut{width:180px;height:180px;transform:rotate(-90deg)}.donut-bg{fill:none;stroke:#e7e7e7;stroke-width:16}.donut-segment{fill:none;stroke-width:16}.donut-total,.donut-caption{transform:rotate(90deg);transform-origin:60px 60px;fill:#151515}.donut-total{font-size:20px;font-weight:700}.donut-caption{font-size:9px}.legend-row{display:grid;grid-template-columns:12px 1fr 40px;gap:8px;align-items:center;margin:7px 0}.legend-color{width:12px;height:12px;border-radius:2px}.table-wrap{overflow:auto;max-height:720px;border:1px solid #d2d2d2;background:#fff}table{border-collapse:collapse;width:100%;font-size:12px}th,td{padding:8px;border-bottom:1px solid #e7e7e7;vertical-align:top;text-align:left}th{position:sticky;top:0;background:#f0f0f0;z-index:1;white-space:nowrap}tr:nth-child(even){background:#fafafa}.severity{display:inline-block;border-radius:12px;padding:2px 8px;font-weight:700}.severity-critical{background:#c9190b;color:#fff}.severity-high{background:#f4c145;color:#151515}.severity-medium{background:#bee1f4;color:#151515}.severity-low{background:#bde2b9;color:#151515}.severity-none{background:#e7e7e7;color:#151515}details{background:#fff;border:1px solid #d2d2d2;border-radius:6px;margin:16px 0}summary{cursor:pointer;font-size:18px;font-weight:700;padding:16px}details>.table-wrap,details>p{border-left:0;border-right:0;border-bottom:0}.warning{background:#fff4cc;border-left:5px solid #f0ab00;padding:14px;margin:12px 0}.footer{font-size:12px;color:#6a6e73;margin-top:24px}@media print{body{background:#fff}.page{max-width:none;padding:0}.table-wrap{max-height:none;overflow:visible}th{position:static}.charts{grid-template-columns:1fr 1fr}details{break-inside:avoid}details:not([open])>*:not(summary){display:block}summary{display:none}}
</style>
</head>
<body>
<div class="page">
<header class="header"><h1>OpenShift RBAC and SCC Report</h1><div>Generated from the current Headlamp cluster context.</div><div class="meta"><div><strong>Collected:</strong> ${escapeHtml(
    data.collectedAt
  )}</div><div><strong>OpenShift:</strong> ${escapeHtml(clusterVersion)}</div><div><strong>Cluster ID:</strong> ${escapeHtml(
    clusterId
  )}</div><div><strong>Headlamp URL:</strong> ${escapeHtml(window.location.href)}</div></div></header>
<section><h2>Inventory</h2>${metricCards(analysis.inventory)}</section>
<div class="charts">${donutChart('Unique bound subjects', analysis.subjectCounts)}${donutChart(
    'Permission assignment risk',
    analysis.riskCounts
  )}${barChart('RBAC verbs', analysis.verbCounts)}${barChart(
    'OpenShift group members',
    analysis.groupMemberCounts
  )}${barChart('SCC assignments', analysis.sccAssignmentCounts)}${barChart(
    'Identity providers',
    analysis.identityProviderCounts
  )}</div>
${
  warningRows.length > 0
    ? `<div class="warning"><strong>Partial collection:</strong> One or more APIs were not readable. Review the collection warnings section.</div>`
    : ''
}
${details(
  `Users and effective declared access (${userRows.length})`,
  table(
    ['User','Full name','Groups','Direct bindings','Inherited bindings','Roles','Verbs','Resources','SCCs','Risk','Reasons'],
    userRows
  ),
  true
)}
${details(
  `ServiceAccounts (${serviceAccountRows.length})`,
  table(
    ['Namespace','ServiceAccount','Automount token','Bindings','Roles','Verbs','Resources','SCCs','Risk','Reasons'],
    serviceAccountRows
  )
)}
${details(
  `Permission assignments (${assignmentRows.length})`,
  table(
    ['Scope','Namespace','Binding','Role','Subject kind','Subject namespace','Subject','Verbs','API groups','Resources','Resource names','Non-resource URLs','Unresolved role','Risk','Reasons'],
    assignmentRows
  )
)}
${details(
  `Roles and ClusterRoles (${roleRows.length})`,
  table(
    ['Scope','Namespace','Kind','Role','Bindings','Subjects','Aggregated','Verbs','API groups','Resources','Resource names','Non-resource URLs','Risk','Reasons'],
    roleRows
  )
)}
${details(
  `SecurityContextConstraints (${sccRows.length})`,
  table(
    ['SCC','Priority','Privileged','Host network','Host PID','Host IPC','Host ports','Host path','Read-only rootfs','Allowed capabilities','Required dropped capabilities','Volumes','Direct users','Direct groups','RBAC subjects','Assignments','Risk','Reasons'],
    sccRows
  )
)}
${details(
  `Groups (${groupRows.length})`,
  table(
    ['Group','Members','Users','Bindings','Roles','Verbs','Resources','SCCs','Risk','Reasons'],
    groupRows
  )
)}
${details('Collection warnings', warningRows.length > 0 ? table(['API/resource', 'Error'], warningRows) : '<p>No collection errors.</p>')}
<section class="footer"><p><strong>Interpretation limits:</strong> This report resolves RoleBinding and ClusterRoleBinding references, direct OpenShift group membership, ServiceAccount subjects, direct SCC users/groups, and RBAC SCC-use rules. External identity-provider membership that is not synchronized into OpenShift cannot be inferred. Admission policies can deny actions that RBAC allows. Aggregated ClusterRoles can change as labeled ClusterRoles are added or removed.</p><p>The exported file contains authorization and identity metadata. Store it as sensitive security evidence.</p></section>
</div>
</body>
</html>`;
}

export function downloadHtmlReport(data: ReportData, analysis: ReportAnalysis): void {
  const html = buildStandaloneHtml(data, analysis);
  const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  link.href = url;
  link.download = `openshift-rbac-report-${timestamp}.html`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}
