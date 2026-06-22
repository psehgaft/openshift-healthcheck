export interface ObjectMeta {
  name: string;
  namespace?: string;
  labels?: Record<string, string>;
  annotations?: Record<string, string>;
  creationTimestamp?: string;
}

export interface KubeList<T> {
  items: T[];
  metadata?: {
    continue?: string;
    resourceVersion?: string;
  };
}

export interface PolicyRule {
  apiGroups?: string[];
  resources?: string[];
  verbs?: string[];
  resourceNames?: string[];
  nonResourceURLs?: string[];
}

export interface RoleLike {
  apiVersion?: string;
  kind?: 'Role' | 'ClusterRole' | string;
  metadata: ObjectMeta;
  rules?: PolicyRule[];
  aggregationRule?: {
    clusterRoleSelectors?: unknown[];
  };
}

export interface Subject {
  apiGroup?: string;
  kind: 'User' | 'Group' | 'ServiceAccount' | string;
  name: string;
  namespace?: string;
}

export interface Binding {
  apiVersion?: string;
  kind?: 'RoleBinding' | 'ClusterRoleBinding' | string;
  metadata: ObjectMeta;
  roleRef: {
    apiGroup?: string;
    kind: 'Role' | 'ClusterRole' | string;
    name: string;
  };
  subjects?: Subject[];
}

export interface ServiceAccount {
  metadata: ObjectMeta;
  automountServiceAccountToken?: boolean;
  secrets?: Array<{ name?: string }>;
  imagePullSecrets?: Array<{ name?: string }>;
}

export interface OpenShiftUser {
  metadata: ObjectMeta;
  fullName?: string;
  identities?: string[];
}

export interface OpenShiftGroup {
  metadata: ObjectMeta;
  users?: string[];
}

export interface SecurityContextConstraints {
  metadata: ObjectMeta;
  priority?: number;
  allowPrivilegedContainer?: boolean;
  allowHostDirVolumePlugin?: boolean;
  allowHostNetwork?: boolean;
  allowHostPorts?: boolean;
  allowHostPID?: boolean;
  allowHostIPC?: boolean;
  readOnlyRootFilesystem?: boolean;
  defaultAddCapabilities?: string[];
  requiredDropCapabilities?: string[];
  allowedCapabilities?: string[];
  volumes?: string[];
  seccompProfiles?: string[];
  users?: string[];
  groups?: string[];
  runAsUser?: Record<string, unknown>;
  seLinuxContext?: Record<string, unknown>;
  fsGroup?: Record<string, unknown>;
  supplementalGroups?: Record<string, unknown>;
}

export interface ClusterVersion {
  metadata?: ObjectMeta;
  spec?: {
    clusterID?: string;
  };
  status?: {
    desired?: {
      version?: string;
      image?: string;
    };
  };
}

export interface ReportData {
  clusterRoles: RoleLike[];
  clusterRoleBindings: Binding[];
  roles: RoleLike[];
  roleBindings: Binding[];
  serviceAccounts: ServiceAccount[];
  users: OpenShiftUser[];
  groups: OpenShiftGroup[];
  sccs: SecurityContextConstraints[];
  namespaces: ObjectMeta[];
  clusterVersion?: ClusterVersion;
  collectionErrors: Record<string, string>;
  collectedAt: string;
}

export type Severity = 'Critical' | 'High' | 'Medium' | 'Low' | 'None';

export interface RiskResult {
  severity: Severity;
  reasons: string[];
}

export interface PermissionAssignment {
  scope: 'Cluster' | 'Namespace';
  namespace: string;
  bindingKind: string;
  bindingName: string;
  roleKind: string;
  roleName: string;
  subjectKind: string;
  subjectNamespace: string;
  subjectName: string;
  verbs: string[];
  apiGroups: string[];
  resources: string[];
  resourceNames: string[];
  nonResourceURLs: string[];
  risk: Severity;
  riskReasons: string[];
  unresolvedRole: boolean;
}

export interface RoleSummary {
  scope: 'Cluster' | 'Namespace';
  namespace: string;
  kind: string;
  name: string;
  verbs: string[];
  apiGroups: string[];
  resources: string[];
  resourceNames: string[];
  nonResourceURLs: string[];
  bindingCount: number;
  subjectCount: number;
  aggregated: boolean;
  risk: Severity;
  riskReasons: string[];
}

export interface ServiceAccountSummary {
  namespace: string;
  name: string;
  automountServiceAccountToken: string;
  bindingCount: number;
  roles: string[];
  verbs: string[];
  resources: string[];
  sccs: string[];
  risk: Severity;
  riskReasons: string[];
}

export interface UserSummary {
  name: string;
  fullName: string;
  identities: string[];
  groups: string[];
  directBindingCount: number;
  inheritedBindingCount: number;
  roles: string[];
  verbs: string[];
  resources: string[];
  sccs: string[];
  risk: Severity;
  riskReasons: string[];
}

export interface GroupSummary {
  name: string;
  memberCount: number;
  users: string[];
  bindingCount: number;
  roles: string[];
  verbs: string[];
  resources: string[];
  sccs: string[];
  risk: Severity;
  riskReasons: string[];
}

export interface SccSummary {
  name: string;
  priority: string;
  privileged: boolean;
  hostNetwork: boolean;
  hostPID: boolean;
  hostIPC: boolean;
  hostPorts: boolean;
  hostPath: boolean;
  readOnlyRootFilesystem: boolean;
  allowedCapabilities: string[];
  requiredDropCapabilities: string[];
  volumes: string[];
  directUsers: string[];
  directGroups: string[];
  rbacSubjects: string[];
  totalAssignments: number;
  risk: Severity;
  riskReasons: string[];
}

export interface ReportAnalysis {
  inventory: Record<string, number>;
  assignments: PermissionAssignment[];
  roles: RoleSummary[];
  serviceAccounts: ServiceAccountSummary[];
  users: UserSummary[];
  groups: GroupSummary[];
  sccs: SccSummary[];
  verbCounts: Record<string, number>;
  subjectCounts: Record<string, number>;
  bindingScopeCounts: Record<string, number>;
  groupMemberCounts: Record<string, number>;
  identityProviderCounts: Record<string, number>;
  sccAssignmentCounts: Record<string, number>;
  riskCounts: Record<string, number>;
}

export function uniqueSorted(values: Array<string | undefined | null>): string[] {
  return Array.from(new Set(values.filter((value): value is string => Boolean(value)))).sort((a, b) =>
    a.localeCompare(b)
  );
}

export function subjectId(subject: Subject): string {
  if (subject.kind === 'ServiceAccount') {
    return `ServiceAccount:${subject.namespace || ''}:${subject.name}`;
  }
  return `${subject.kind}:${subject.name}`;
}

export function serviceAccountUserName(namespace: string, name: string): string {
  return `system:serviceaccount:${namespace}:${name}`;
}
