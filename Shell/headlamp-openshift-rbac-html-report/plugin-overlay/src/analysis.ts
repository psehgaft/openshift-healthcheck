import {
  Binding,
  GroupSummary,
  PermissionAssignment,
  PolicyRule,
  ReportAnalysis,
  ReportData,
  RiskResult,
  RoleLike,
  RoleSummary,
  SccSummary,
  SecurityContextConstraints,
  ServiceAccountSummary,
  serviceAccountUserName,
  Severity,
  Subject,
  subjectId,
  uniqueSorted,
  UserSummary,
} from './model';

const severityOrder: Record<Severity, number> = {
  None: 0,
  Low: 1,
  Medium: 2,
  High: 3,
  Critical: 4,
};

function maxSeverity(values: Severity[]): Severity {
  return values.reduce<Severity>(
    (current, value) => (severityOrder[value] > severityOrder[current] ? value : current),
    'None'
  );
}

function includesAny(values: string[], candidates: string[]): boolean {
  return values.some(value => candidates.includes(value));
}

function ruleArrays(rules: PolicyRule[]): {
  verbs: string[];
  apiGroups: string[];
  resources: string[];
  resourceNames: string[];
  nonResourceURLs: string[];
} {
  return {
    verbs: uniqueSorted(rules.flatMap(rule => rule.verbs || [])),
    apiGroups: uniqueSorted(rules.flatMap(rule => rule.apiGroups || [])),
    resources: uniqueSorted(rules.flatMap(rule => rule.resources || [])),
    resourceNames: uniqueSorted(rules.flatMap(rule => rule.resourceNames || [])),
    nonResourceURLs: uniqueSorted(rules.flatMap(rule => rule.nonResourceURLs || [])),
  };
}

function ruleMatches(
  rule: PolicyRule,
  apiGroup: string,
  resource: string,
  verbs: string[]
): boolean {
  const groups = rule.apiGroups || [''];
  const resources = rule.resources || [];
  const ruleVerbs = rule.verbs || [];
  return (
    (groups.includes(apiGroup) || groups.includes('*')) &&
    (resources.includes(resource) || resources.includes('*')) &&
    (ruleVerbs.includes('*') || ruleVerbs.some(verb => verbs.includes(verb)))
  );
}

function assessRules(roleName: string, rules: PolicyRule[]): RiskResult {
  const reasons = new Set<string>();
  let severity: Severity = 'Low';

  if (roleName === 'cluster-admin') {
    severity = 'Critical';
    reasons.add('References the cluster-admin role');
  }

  for (const rule of rules) {
    const verbs = rule.verbs || [];
    const resources = rule.resources || [];
    const apiGroups = rule.apiGroups || [''];
    const resourceNames = rule.resourceNames || [];

    if (verbs.includes('*') && resources.includes('*') && apiGroups.includes('*')) {
      severity = maxSeverity([severity, 'Critical']);
      reasons.add('Wildcard API groups, resources, and verbs');
    } else if (verbs.includes('*') || resources.includes('*') || apiGroups.includes('*')) {
      severity = maxSeverity([severity, 'High']);
      reasons.add('Contains wildcard permissions');
    }

    if (includesAny(verbs, ['bind', 'escalate', 'impersonate'])) {
      severity = maxSeverity([severity, 'Critical']);
      reasons.add('Can bind, escalate, or impersonate');
    }

    if (ruleMatches(rule, '', 'secrets', ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete'])) {
      severity = maxSeverity([severity, 'High']);
      reasons.add('Can access or modify Secrets');
    }

    if (
      ruleMatches(rule, '', 'pods/exec', ['create']) ||
      ruleMatches(rule, '', 'pods/attach', ['create']) ||
      ruleMatches(rule, '', 'pods/portforward', ['create'])
    ) {
      severity = maxSeverity([severity, 'High']);
      reasons.add('Can exec, attach, or port-forward to Pods');
    }

    if (ruleMatches(rule, '', 'nodes/proxy', ['get', 'create', '*'])) {
      severity = maxSeverity([severity, 'Critical']);
      reasons.add('Can access the node proxy API');
    }

    if (ruleMatches(rule, '', 'serviceaccounts/token', ['create'])) {
      severity = maxSeverity([severity, 'Critical']);
      reasons.add('Can create ServiceAccount tokens');
    }

    if (
      ruleMatches(rule, 'rbac.authorization.k8s.io', 'clusterrolebindings', [
        'create',
        'update',
        'patch',
        'delete',
      ]) ||
      ruleMatches(rule, 'rbac.authorization.k8s.io', 'rolebindings', [
        'create',
        'update',
        'patch',
        'delete',
      ])
    ) {
      severity = maxSeverity([severity, 'Critical']);
      reasons.add('Can modify RBAC bindings');
    }

    if (
      ruleMatches(rule, 'certificates.k8s.io', 'certificatesigningrequests/approval', [
        'approve',
        'update',
        'patch',
      ]) ||
      includesAny(verbs, ['approve', 'sign'])
    ) {
      severity = maxSeverity([severity, 'High']);
      reasons.add('Can approve or sign certificate requests');
    }

    if (ruleMatches(rule, 'security.openshift.io', 'securitycontextconstraints', ['use'])) {
      const powerfulSccs = resourceNames.filter(name =>
        ['privileged', 'anyuid', 'hostaccess', 'hostmount-anyuid', 'hostnetwork'].includes(name)
      );
      severity = maxSeverity([severity, powerfulSccs.length > 0 || resourceNames.length === 0 ? 'Critical' : 'High']);
      reasons.add(
        powerfulSccs.length > 0
          ? `Can use high-impact SCCs: ${powerfulSccs.join(', ')}`
          : 'Can use SecurityContextConstraints'
      );
    }

    if (includesAny(verbs, ['create', 'update', 'patch', 'delete', 'deletecollection'])) {
      severity = maxSeverity([severity, 'Medium']);
      reasons.add('Contains resource mutation permissions');
    }
  }

  if (rules.length === 0) {
    severity = 'None';
    reasons.add('No resolved policy rules');
  }

  return { severity, reasons: Array.from(reasons).sort() };
}

function resolveBindingRole(
  binding: Binding,
  clusterRoleMap: Map<string, RoleLike>,
  roleMap: Map<string, RoleLike>
): RoleLike | undefined {
  if (binding.roleRef.kind === 'ClusterRole') {
    return clusterRoleMap.get(binding.roleRef.name);
  }
  return roleMap.get(`${binding.metadata.namespace || ''}/${binding.roleRef.name}`);
}

function createAssignments(data: ReportData): PermissionAssignment[] {
  const clusterRoleMap = new Map(data.clusterRoles.map(role => [role.metadata.name, role]));
  const roleMap = new Map(
    data.roles.map(role => [`${role.metadata.namespace || ''}/${role.metadata.name}`, role])
  );

  const bindings = [...data.clusterRoleBindings, ...data.roleBindings];
  const assignments: PermissionAssignment[] = [];

  for (const binding of bindings) {
    const role = resolveBindingRole(binding, clusterRoleMap, roleMap);
    const rules = role?.rules || [];
    const arrays = ruleArrays(rules);
    const risk = assessRules(binding.roleRef.name, rules);
    const isCluster = binding.kind === 'ClusterRoleBinding' || !binding.metadata.namespace;

    for (const subject of binding.subjects || []) {
      assignments.push({
        scope: isCluster ? 'Cluster' : 'Namespace',
        namespace: binding.metadata.namespace || '',
        bindingKind: binding.kind || (isCluster ? 'ClusterRoleBinding' : 'RoleBinding'),
        bindingName: binding.metadata.name,
        roleKind: binding.roleRef.kind,
        roleName: binding.roleRef.name,
        subjectKind: subject.kind,
        subjectNamespace: subject.namespace || '',
        subjectName: subject.name,
        ...arrays,
        risk: risk.severity,
        riskReasons: risk.reasons,
        unresolvedRole: !role,
      });
    }
  }

  return assignments.sort((a, b) => {
    const riskDifference = severityOrder[b.risk] - severityOrder[a.risk];
    if (riskDifference !== 0) return riskDifference;
    return `${a.subjectKind}:${a.subjectNamespace}:${a.subjectName}`.localeCompare(
      `${b.subjectKind}:${b.subjectNamespace}:${b.subjectName}`
    );
  });
}

function createRoleSummaries(data: ReportData, assignments: PermissionAssignment[]): RoleSummary[] {
  const allRoles = [
    ...data.clusterRoles.map(role => ({ role, scope: 'Cluster' as const })),
    ...data.roles.map(role => ({ role, scope: 'Namespace' as const })),
  ];

  return allRoles
    .map(({ role, scope }) => {
      const namespace = role.metadata.namespace || '';
      const relatedAssignments = assignments.filter(
        assignment =>
          assignment.roleKind === (role.kind || (scope === 'Cluster' ? 'ClusterRole' : 'Role')) &&
          assignment.roleName === role.metadata.name &&
          (assignment.roleKind === 'ClusterRole' || assignment.namespace === namespace)
      );
      const rules = role.rules || [];
      const arrays = ruleArrays(rules);
      const risk = assessRules(role.metadata.name, rules);

      return {
        scope,
        namespace,
        kind: role.kind || (scope === 'Cluster' ? 'ClusterRole' : 'Role'),
        name: role.metadata.name,
        ...arrays,
        bindingCount: new Set(relatedAssignments.map(item => `${item.bindingKind}:${item.namespace}:${item.bindingName}`))
          .size,
        subjectCount: new Set(
          relatedAssignments.map(item => `${item.subjectKind}:${item.subjectNamespace}:${item.subjectName}`)
        ).size,
        aggregated: Boolean(role.aggregationRule),
        risk: risk.severity,
        riskReasons: risk.reasons,
      };
    })
    .sort((a, b) => {
      const riskDifference = severityOrder[b.risk] - severityOrder[a.risk];
      return riskDifference || `${a.namespace}/${a.name}`.localeCompare(`${b.namespace}/${b.name}`);
    });
}

interface SccAccessMap {
  bySubject: Map<string, Set<string>>;
  byScc: Map<string, Set<string>>;
}

function buildSccAccess(data: ReportData, assignments: PermissionAssignment[]): SccAccessMap {
  const sccNames = data.sccs.map(scc => scc.metadata.name);
  const bySubject = new Map<string, Set<string>>();
  const byScc = new Map<string, Set<string>>();

  const add = (subject: string, sccName: string) => {
    if (!bySubject.has(subject)) bySubject.set(subject, new Set());
    if (!byScc.has(sccName)) byScc.set(sccName, new Set());
    bySubject.get(subject)?.add(sccName);
    byScc.get(sccName)?.add(subject);
  };

  for (const scc of data.sccs) {
    for (const user of scc.users || []) add(`User:${user}`, scc.metadata.name);
    for (const group of scc.groups || []) add(`Group:${group}`, scc.metadata.name);
  }

  for (const assignment of assignments) {
    const relevantRole =
      assignment.roleKind === 'ClusterRole'
        ? data.clusterRoles.find(role => role.metadata.name === assignment.roleName)
        : data.roles.find(
            role =>
              role.metadata.namespace === assignment.namespace && role.metadata.name === assignment.roleName
          );

    for (const rule of relevantRole?.rules || []) {
      if (!ruleMatches(rule, 'security.openshift.io', 'securitycontextconstraints', ['use'])) continue;
      const targetSccs = rule.resourceNames?.length ? rule.resourceNames : sccNames;
      const id =
        assignment.subjectKind === 'ServiceAccount'
          ? `ServiceAccount:${assignment.subjectNamespace}:${assignment.subjectName}`
          : `${assignment.subjectKind}:${assignment.subjectName}`;
      for (const sccName of targetSccs) add(id, sccName);
    }
  }

  return { bySubject, byScc };
}

function riskFromAssignments(assignments: PermissionAssignment[]): RiskResult {
  if (assignments.length === 0) return { severity: 'None', reasons: [] };
  return {
    severity: maxSeverity(assignments.map(item => item.risk)),
    reasons: uniqueSorted(assignments.flatMap(item => item.riskReasons)),
  };
}

function createServiceAccountSummaries(
  data: ReportData,
  assignments: PermissionAssignment[],
  sccAccess: SccAccessMap
): ServiceAccountSummary[] {
  return data.serviceAccounts
    .map(serviceAccount => {
      const namespace = serviceAccount.metadata.namespace || '';
      const name = serviceAccount.metadata.name;
      const related = assignments.filter(
        assignment =>
          assignment.subjectKind === 'ServiceAccount' &&
          assignment.subjectNamespace === namespace &&
          assignment.subjectName === name
      );
      const risk = riskFromAssignments(related);
      const sccs = uniqueSorted([
        ...Array.from(sccAccess.bySubject.get(`ServiceAccount:${namespace}:${name}`) || []),
        ...Array.from(sccAccess.bySubject.get(`User:${serviceAccountUserName(namespace, name)}`) || []),
      ]);
      let severity = risk.severity;
      const reasons = new Set(risk.reasons);
      if (sccs.some(scc => ['privileged', 'anyuid', 'hostaccess', 'hostmount-anyuid', 'hostnetwork'].includes(scc))) {
        severity = maxSeverity([severity, 'Critical']);
        reasons.add(`Can use high-impact SCCs: ${sccs.join(', ')}`);
      }

      return {
        namespace,
        name,
        automountServiceAccountToken:
          serviceAccount.automountServiceAccountToken === undefined
            ? 'Default'
            : String(serviceAccount.automountServiceAccountToken),
        bindingCount: new Set(related.map(item => `${item.bindingKind}:${item.namespace}:${item.bindingName}`)).size,
        roles: uniqueSorted(related.map(item => `${item.roleKind}/${item.roleName}`)),
        verbs: uniqueSorted(related.flatMap(item => item.verbs)),
        resources: uniqueSorted(related.flatMap(item => item.resources)),
        sccs,
        risk: severity,
        riskReasons: Array.from(reasons).sort(),
      };
    })
    .sort((a, b) => {
      const riskDifference = severityOrder[b.risk] - severityOrder[a.risk];
      return riskDifference || `${a.namespace}/${a.name}`.localeCompare(`${b.namespace}/${b.name}`);
    });
}

function createUserSummaries(
  data: ReportData,
  assignments: PermissionAssignment[],
  sccAccess: SccAccessMap
): UserSummary[] {
  const groupsByUser = new Map<string, string[]>();
  for (const group of data.groups) {
    for (const user of group.users || []) {
      const current = groupsByUser.get(user) || [];
      current.push(group.metadata.name);
      groupsByUser.set(user, current);
    }
  }

  return data.users
    .map(user => {
      const name = user.metadata.name;
      const groups = uniqueSorted(groupsByUser.get(name) || []);
      const direct = assignments.filter(item => item.subjectKind === 'User' && item.subjectName === name);
      const inherited = assignments.filter(
        item => item.subjectKind === 'Group' && groups.includes(item.subjectName)
      );
      const all = [...direct, ...inherited];
      const risk = riskFromAssignments(all);
      const sccs = uniqueSorted([
        ...Array.from(sccAccess.bySubject.get(`User:${name}`) || []),
        ...groups.flatMap(group => Array.from(sccAccess.bySubject.get(`Group:${group}`) || [])),
      ]);
      let severity = risk.severity;
      const reasons = new Set(risk.reasons);
      if (sccs.some(scc => ['privileged', 'anyuid', 'hostaccess', 'hostmount-anyuid', 'hostnetwork'].includes(scc))) {
        severity = maxSeverity([severity, 'Critical']);
        reasons.add(`Can use high-impact SCCs: ${sccs.join(', ')}`);
      }

      return {
        name,
        fullName: user.fullName || '',
        identities: uniqueSorted(user.identities || []),
        groups,
        directBindingCount: new Set(direct.map(item => `${item.bindingKind}:${item.namespace}:${item.bindingName}`))
          .size,
        inheritedBindingCount: new Set(
          inherited.map(item => `${item.bindingKind}:${item.namespace}:${item.bindingName}`)
        ).size,
        roles: uniqueSorted(all.map(item => `${item.roleKind}/${item.roleName}`)),
        verbs: uniqueSorted(all.flatMap(item => item.verbs)),
        resources: uniqueSorted(all.flatMap(item => item.resources)),
        sccs,
        risk: severity,
        riskReasons: Array.from(reasons).sort(),
      };
    })
    .sort((a, b) => {
      const riskDifference = severityOrder[b.risk] - severityOrder[a.risk];
      return riskDifference || a.name.localeCompare(b.name);
    });
}

function createGroupSummaries(
  data: ReportData,
  assignments: PermissionAssignment[],
  sccAccess: SccAccessMap
): GroupSummary[] {
  return data.groups
    .map(group => {
      const name = group.metadata.name;
      const related = assignments.filter(item => item.subjectKind === 'Group' && item.subjectName === name);
      const risk = riskFromAssignments(related);
      const sccs = uniqueSorted(Array.from(sccAccess.bySubject.get(`Group:${name}`) || []));
      let severity = risk.severity;
      const reasons = new Set(risk.reasons);
      if (sccs.some(scc => ['privileged', 'anyuid', 'hostaccess', 'hostmount-anyuid', 'hostnetwork'].includes(scc))) {
        severity = maxSeverity([severity, 'Critical']);
        reasons.add(`Can use high-impact SCCs: ${sccs.join(', ')}`);
      }

      return {
        name,
        memberCount: group.users?.length || 0,
        users: uniqueSorted(group.users || []),
        bindingCount: new Set(related.map(item => `${item.bindingKind}:${item.namespace}:${item.bindingName}`)).size,
        roles: uniqueSorted(related.map(item => `${item.roleKind}/${item.roleName}`)),
        verbs: uniqueSorted(related.flatMap(item => item.verbs)),
        resources: uniqueSorted(related.flatMap(item => item.resources)),
        sccs,
        risk: severity,
        riskReasons: Array.from(reasons).sort(),
      };
    })
    .sort((a, b) => {
      const riskDifference = severityOrder[b.risk] - severityOrder[a.risk];
      return riskDifference || b.memberCount - a.memberCount || a.name.localeCompare(b.name);
    });
}

function sccRisk(scc: SecurityContextConstraints): RiskResult {
  const reasons = new Set<string>();
  let severity: Severity = 'Low';

  if (scc.allowPrivilegedContainer || scc.metadata.name === 'privileged') {
    severity = 'Critical';
    reasons.add('Allows privileged containers');
  }
  if (scc.allowHostNetwork || scc.allowHostPID || scc.allowHostIPC || scc.allowHostPorts) {
    severity = maxSeverity([severity, 'High']);
    reasons.add('Allows host namespace or host port access');
  }
  if (scc.allowHostDirVolumePlugin || (scc.volumes || []).includes('hostPath') || (scc.volumes || []).includes('*')) {
    severity = maxSeverity([severity, 'High']);
    reasons.add('Allows hostPath or all volume types');
  }
  if ((scc.allowedCapabilities || []).includes('*')) {
    severity = maxSeverity([severity, 'Critical']);
    reasons.add('Allows all Linux capabilities');
  } else if ((scc.allowedCapabilities || []).length > 0) {
    severity = maxSeverity([severity, 'Medium']);
    reasons.add('Allows additional Linux capabilities');
  }

  return { severity, reasons: Array.from(reasons).sort() };
}

function createSccSummaries(data: ReportData, sccAccess: SccAccessMap): SccSummary[] {
  return data.sccs
    .map(scc => {
      const risk = sccRisk(scc);
      const directUsers = uniqueSorted(scc.users || []);
      const directGroups = uniqueSorted(scc.groups || []);
      const rbacSubjects = uniqueSorted(Array.from(sccAccess.byScc.get(scc.metadata.name) || [])).filter(
        subject =>
          !directUsers.some(user => subject === `User:${user}`) &&
          !directGroups.some(group => subject === `Group:${group}`)
      );

      return {
        name: scc.metadata.name,
        priority: scc.priority === undefined ? '' : String(scc.priority),
        privileged: Boolean(scc.allowPrivilegedContainer),
        hostNetwork: Boolean(scc.allowHostNetwork),
        hostPID: Boolean(scc.allowHostPID),
        hostIPC: Boolean(scc.allowHostIPC),
        hostPorts: Boolean(scc.allowHostPorts),
        hostPath: Boolean(scc.allowHostDirVolumePlugin || (scc.volumes || []).includes('hostPath')),
        readOnlyRootFilesystem: Boolean(scc.readOnlyRootFilesystem),
        allowedCapabilities: uniqueSorted(scc.allowedCapabilities || []),
        requiredDropCapabilities: uniqueSorted(scc.requiredDropCapabilities || []),
        volumes: uniqueSorted(scc.volumes || []),
        directUsers,
        directGroups,
        rbacSubjects,
        totalAssignments: directUsers.length + directGroups.length + rbacSubjects.length,
        risk: risk.severity,
        riskReasons: risk.reasons,
      };
    })
    .sort((a, b) => {
      const riskDifference = severityOrder[b.risk] - severityOrder[a.risk];
      return riskDifference || b.totalAssignments - a.totalAssignments || a.name.localeCompare(b.name);
    });
}

function countValues(values: string[]): Record<string, number> {
  return values.reduce<Record<string, number>>((accumulator, value) => {
    accumulator[value] = (accumulator[value] || 0) + 1;
    return accumulator;
  }, {});
}

export function analyzeReportData(data: ReportData): ReportAnalysis {
  const assignments = createAssignments(data);
  const roles = createRoleSummaries(data, assignments);
  const sccAccess = buildSccAccess(data, assignments);
  const serviceAccounts = createServiceAccountSummaries(data, assignments, sccAccess);
  const users = createUserSummaries(data, assignments, sccAccess);
  const groups = createGroupSummaries(data, assignments, sccAccess);
  const sccs = createSccSummaries(data, sccAccess);

  const verbCounts = countValues(
    [...data.clusterRoles, ...data.roles].flatMap(role => role.rules || []).flatMap(rule => rule.verbs || [])
  );

  const uniqueSubjects = new Map<string, Subject>();
  for (const binding of [...data.clusterRoleBindings, ...data.roleBindings]) {
    for (const subject of binding.subjects || []) uniqueSubjects.set(subjectId(subject), subject);
  }

  const subjectCounts = countValues(Array.from(uniqueSubjects.values()).map(subject => subject.kind));
  const bindingScopeCounts = {
    ClusterRoleBindings: data.clusterRoleBindings.length,
    RoleBindings: data.roleBindings.length,
  };
  const groupMemberCounts = Object.fromEntries(groups.map(group => [group.name, group.memberCount]));
  const identityProviderCounts = countValues(
    data.users.flatMap(user => user.identities || []).map(identity => identity.split(':')[0] || 'unknown')
  );
  const sccAssignmentCounts = Object.fromEntries(sccs.map(scc => [scc.name, scc.totalAssignments]));
  const riskCounts = countValues(assignments.map(assignment => assignment.risk));

  return {
    inventory: {
      Users: data.users.length,
      Groups: data.groups.length,
      ServiceAccounts: data.serviceAccounts.length,
      ClusterRoles: data.clusterRoles.length,
      Roles: data.roles.length,
      ClusterRoleBindings: data.clusterRoleBindings.length,
      RoleBindings: data.roleBindings.length,
      SCCs: data.sccs.length,
      Namespaces: data.namespaces.length,
    },
    assignments,
    roles,
    serviceAccounts,
    users,
    groups,
    sccs,
    verbCounts,
    subjectCounts,
    bindingScopeCounts,
    groupMemberCounts,
    identityProviderCounts,
    sccAssignmentCounts,
    riskCounts,
  };
}
