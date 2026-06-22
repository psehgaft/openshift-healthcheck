import { ApiProxy } from '@kinvolk/headlamp-plugin/lib';
import {
  Binding,
  ClusterVersion,
  KubeList,
  ObjectMeta,
  OpenShiftGroup,
  OpenShiftUser,
  ReportData,
  RoleLike,
  SecurityContextConstraints,
  ServiceAccount,
} from './model';

interface ResourceDefinition<T> {
  key: keyof Omit<ReportData, 'collectionErrors' | 'collectedAt' | 'clusterVersion'>;
  label: string;
  path: string;
  normalize: (value: unknown) => T[];
}

function listItems<T>(value: unknown): T[] {
  const list = value as KubeList<T> | undefined;
  return Array.isArray(list?.items) ? list.items : [];
}

const resources: Array<ResourceDefinition<unknown>> = [
  {
    key: 'clusterRoles',
    label: 'ClusterRoles',
    path: '/apis/rbac.authorization.k8s.io/v1/clusterroles',
    normalize: value => listItems<RoleLike>(value),
  },
  {
    key: 'clusterRoleBindings',
    label: 'ClusterRoleBindings',
    path: '/apis/rbac.authorization.k8s.io/v1/clusterrolebindings',
    normalize: value => listItems<Binding>(value),
  },
  {
    key: 'roles',
    label: 'Roles',
    path: '/apis/rbac.authorization.k8s.io/v1/roles',
    normalize: value => listItems<RoleLike>(value),
  },
  {
    key: 'roleBindings',
    label: 'RoleBindings',
    path: '/apis/rbac.authorization.k8s.io/v1/rolebindings',
    normalize: value => listItems<Binding>(value),
  },
  {
    key: 'serviceAccounts',
    label: 'ServiceAccounts',
    path: '/api/v1/serviceaccounts',
    normalize: value => listItems<ServiceAccount>(value),
  },
  {
    key: 'users',
    label: 'OpenShift Users',
    path: '/apis/user.openshift.io/v1/users',
    normalize: value => listItems<OpenShiftUser>(value),
  },
  {
    key: 'groups',
    label: 'OpenShift Groups',
    path: '/apis/user.openshift.io/v1/groups',
    normalize: value => listItems<OpenShiftGroup>(value),
  },
  {
    key: 'sccs',
    label: 'SecurityContextConstraints',
    path: '/apis/security.openshift.io/v1/securitycontextconstraints',
    normalize: value => listItems<SecurityContextConstraints>(value),
  },
  {
    key: 'namespaces',
    label: 'Namespaces',
    path: '/api/v1/namespaces',
    normalize: value => listItems<{ metadata: ObjectMeta }>(value).map(item => item.metadata),
  },
];


async function requestAllPages(path: string): Promise<KubeList<unknown>> {
  const items: unknown[] = [];
  let continueToken = '';

  do {
    const queryParams: { limit: number; continue?: string } = { limit: 500 };
    if (continueToken) queryParams.continue = continueToken;

    const page = (await ApiProxy.request(path, {}, false, true, queryParams)) as KubeList<unknown>;
    if (Array.isArray(page?.items)) items.push(...page.items);
    continueToken = page?.metadata?.continue || '';
  } while (continueToken);

  return { items };
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === 'string') {
    return error;
  }
  try {
    return JSON.stringify(error);
  } catch {
    return 'Unknown API error';
  }
}

export async function collectReportData(): Promise<ReportData> {
  const initial: ReportData = {
    clusterRoles: [],
    clusterRoleBindings: [],
    roles: [],
    roleBindings: [],
    serviceAccounts: [],
    users: [],
    groups: [],
    sccs: [],
    namespaces: [],
    collectionErrors: {},
    collectedAt: new Date().toISOString(),
  };

  await Promise.all(
    resources.map(async resource => {
      try {
        // autoLogoutOnAuthError=false allows the report to render partial data when one API is forbidden.
        const response = await requestAllPages(resource.path);
        (initial[resource.key] as unknown[]) = resource.normalize(response);
      } catch (error) {
        initial.collectionErrors[resource.label] = errorMessage(error);
      }
    })
  );

  try {
    initial.clusterVersion = (await ApiProxy.request(
      '/apis/config.openshift.io/v1/clusterversions/version',
      {},
      false
    )) as ClusterVersion;
  } catch (error) {
    initial.collectionErrors.ClusterVersion = errorMessage(error);
  }

  return initial;
}
