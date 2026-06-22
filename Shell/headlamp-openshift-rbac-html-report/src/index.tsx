import { registerRoute, registerSidebarEntry } from '@kinvolk/headlamp-plugin/lib';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  FormControl,
  InputLabel,
  MenuItem,
  Paper,
  Select,
  Stack,
  Tab,
  Tabs,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import type { SelectChangeEvent } from '@mui/material/Select';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { analyzeReportData } from './analysis';
import { collectReportData } from './api';
import { downloadHtmlReport } from './html';
import { ReportAnalysis, ReportData, Severity } from './model';

const severityColors: Record<Severity, 'default' | 'success' | 'warning' | 'error' | 'info'> = {
  None: 'default',
  Low: 'success',
  Medium: 'info',
  High: 'warning',
  Critical: 'error',
};

function RiskChip({ severity, reasons }: { severity: Severity; reasons: string[] }) {
  return (
    <Tooltip title={reasons.join('; ') || 'No high-impact permission detected'}>
      <Chip size="small" label={severity} color={severityColors[severity]} />
    </Tooltip>
  );
}

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <Paper variant="outlined" sx={{ p: 2, minWidth: 130 }}>
      <Typography variant="h4" sx={{ fontWeight: 700 }}>
        {value}
      </Typography>
      <Typography variant="body2" color="text.secondary">
        {label}
      </Typography>
    </Paper>
  );
}

function BarChart({ title, values, limit = 12 }: { title: string; values: Record<string, number>; limit?: number }) {
  const entries = Object.entries(values)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit);
  const max = Math.max(1, ...entries.map(([, value]) => value));

  return (
    <Paper variant="outlined" sx={{ p: 2, minHeight: 260 }}>
      <Typography variant="h6" sx={{ mb: 1.5 }}>
        {title}
      </Typography>
      {entries.length === 0 ? (
        <Typography color="text.secondary">No data.</Typography>
      ) : (
        entries.map(([label, value]) => (
          <Box key={label} sx={{ display: 'grid', gridTemplateColumns: '130px 1fr 42px', gap: 1, mb: 1 }}>
            <Tooltip title={label}>
              <Typography noWrap variant="body2">
                {label}
              </Typography>
            </Tooltip>
            <Box sx={{ bgcolor: 'action.hover', borderRadius: 5, overflow: 'hidden', height: 14, mt: 0.4 }}>
              <Box sx={{ bgcolor: 'primary.main', width: `${Math.max(2, (value / max) * 100)}%`, height: '100%' }} />
            </Box>
            <Typography variant="body2" align="right">
              {value}
            </Typography>
          </Box>
        ))
      )}
    </Paper>
  );
}

function DonutChart({ title, values }: { title: string; values: Record<string, number> }) {
  const entries = Object.entries(values).filter(([, value]) => value > 0);
  const total = entries.reduce((sum, [, value]) => sum + value, 0) || 1;
  const colors = ['#0066cc', '#5e40be', '#009596', '#f0ab00', '#c9190b', '#8a8d90'];
  let offset = 0;

  return (
    <Paper variant="outlined" sx={{ p: 2, minHeight: 260 }}>
      <Typography variant="h6">{title}</Typography>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, mt: 1 }}>
        <svg width="150" height="150" viewBox="0 0 120 120" style={{ transform: 'rotate(-90deg)' }}>
          <circle cx="60" cy="60" r="48" fill="none" stroke="#e7e7e7" strokeWidth="16" />
          {entries.map(([label, value], index) => {
            const dash = (value / total) * 100;
            const element = (
              <circle
                key={label}
                cx="60"
                cy="60"
                r="48"
                pathLength="100"
                fill="none"
                stroke={colors[index % colors.length]}
                strokeWidth="16"
                strokeDasharray={`${dash} ${100 - dash}`}
                strokeDashoffset={-offset}
              />
            );
            offset += dash;
            return element;
          })}
          <text x="60" y="64" textAnchor="middle" fontSize="20" fontWeight="700" style={{ transform: 'rotate(90deg)', transformOrigin: '60px 60px' }}>
            {total}
          </text>
        </svg>
        <Box sx={{ flex: 1 }}>
          {entries.map(([label, value], index) => (
            <Box key={label} sx={{ display: 'grid', gridTemplateColumns: '12px 1fr 42px', gap: 1, mb: 0.7, alignItems: 'center' }}>
              <Box sx={{ width: 12, height: 12, bgcolor: colors[index % colors.length], borderRadius: 0.5 }} />
              <Typography variant="body2">{label}</Typography>
              <Typography variant="body2" align="right" fontWeight={700}>
                {value}
              </Typography>
            </Box>
          ))}
        </Box>
      </Box>
    </Paper>
  );
}

interface Column<Row> {
  label: string;
  value: (row: Row) => React.ReactNode;
  text?: (row: Row) => string;
}

function DataTable<Row>({
  rows,
  columns,
  emptyMessage = 'No rows match the current filters.',
  maxRows = 1000,
}: {
  rows: Row[];
  columns: Array<Column<Row>>;
  emptyMessage?: string;
  maxRows?: number;
}) {
  const visibleRows = rows.slice(0, maxRows);
  return (
    <Box sx={{ overflow: 'auto', maxHeight: '68vh', border: 1, borderColor: 'divider' }}>
      <Box component="table" sx={{ borderCollapse: 'collapse', minWidth: '100%', fontSize: 12 }}>
        <Box component="thead" sx={{ position: 'sticky', top: 0, bgcolor: 'background.paper', zIndex: 1 }}>
          <Box component="tr">
            {columns.map(column => (
              <Box component="th" key={column.label} sx={{ textAlign: 'left', p: 1, borderBottom: 1, borderColor: 'divider', whiteSpace: 'nowrap' }}>
                {column.label}
              </Box>
            ))}
          </Box>
        </Box>
        <Box component="tbody">
          {visibleRows.map((row, rowIndex) => (
            <Box component="tr" key={rowIndex} sx={{ '&:nth-of-type(even)': { bgcolor: 'action.hover' } }}>
              {columns.map(column => (
                <Box component="td" key={column.label} sx={{ p: 1, borderBottom: 1, borderColor: 'divider', verticalAlign: 'top', maxWidth: 420 }}>
                  {column.value(row)}
                </Box>
              ))}
            </Box>
          ))}
        </Box>
      </Box>
      {visibleRows.length === 0 && (
        <Typography sx={{ p: 3 }} color="text.secondary">
          {emptyMessage}
        </Typography>
      )}
      {rows.length > maxRows && (
        <Alert severity="info">The UI is showing the first {maxRows} of {rows.length} rows. The HTML export contains all rows.</Alert>
      )}
    </Box>
  );
}

function csv(values: string[]): string {
  return values.join(', ') || '—';
}

function filterText(values: unknown[]): string {
  return values.flatMap(value => (Array.isArray(value) ? value : [value])).join(' ').toLowerCase();
}

function Overview({ analysis }: { analysis: ReportAnalysis }) {
  return (
    <>
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(130px,1fr))', gap: 1.5, mb: 2 }}>
        {Object.entries(analysis.inventory).map(([label, value]) => (
          <StatCard key={label} label={label} value={value} />
        ))}
      </Box>
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(340px,1fr))', gap: 2 }}>
        <DonutChart title="Unique bound subjects" values={analysis.subjectCounts} />
        <DonutChart title="Permission assignment risk" values={analysis.riskCounts} />
        <BarChart title="RBAC verbs" values={analysis.verbCounts} />
        <BarChart title="Users per OpenShift group" values={analysis.groupMemberCounts} />
        <BarChart title="Assignments per SCC" values={analysis.sccAssignmentCounts} />
        <BarChart title="Users by identity provider" values={analysis.identityProviderCounts} />
      </Box>
    </>
  );
}

function ReportPage() {
  const [data, setData] = useState<ReportData | null>(null);
  const [loading, setLoading] = useState(true);
  const [fatalError, setFatalError] = useState('');
  const [tab, setTab] = useState(0);
  const [search, setSearch] = useState('');
  const [namespace, setNamespace] = useState('*');
  const [risk, setRisk] = useState('*');

  const refresh = useCallback(async () => {
    setLoading(true);
    setFatalError('');
    try {
      setData(await collectReportData());
    } catch (error) {
      setFatalError(error instanceof Error ? error.message : String(error));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const analysis = useMemo(() => (data ? analyzeReportData(data) : null), [data]);
  const namespaces = useMemo(() => {
    if (!data) return [];
    return Array.from(
      new Set([
        ...data.namespaces.map(item => item.name),
        ...data.roles.map(item => item.metadata.namespace || ''),
        ...data.roleBindings.map(item => item.metadata.namespace || ''),
        ...data.serviceAccounts.map(item => item.metadata.namespace || ''),
      ].filter(Boolean))
    ).sort();
  }, [data]);

  const matches = useCallback(
    (values: unknown[], rowNamespace = '', rowRisk = '') => {
      const searchMatches = !search || filterText(values).includes(search.toLowerCase());
      const namespaceMatches = namespace === '*' || rowNamespace === namespace;
      const riskMatches = risk === '*' || rowRisk === risk;
      return searchMatches && namespaceMatches && riskMatches;
    },
    [search, namespace, risk]
  );

  if (loading) {
    return (
      <Stack alignItems="center" justifyContent="center" sx={{ minHeight: 420 }} spacing={2}>
        <CircularProgress />
        <Typography>Collecting OpenShift RBAC, identity, ServiceAccount, and SCC resources…</Typography>
      </Stack>
    );
  }

  if (fatalError || !data || !analysis) {
    return <Alert severity="error">Unable to generate the RBAC report: {fatalError || 'Unknown error'}</Alert>;
  }

  const filteredAssignments = analysis.assignments.filter(item =>
    matches(
      [item.scope, item.namespace, item.bindingName, item.roleName, item.subjectKind, item.subjectNamespace, item.subjectName, item.verbs, item.resources, item.riskReasons],
      item.namespace,
      item.risk
    )
  );
  const filteredRoles = analysis.roles.filter(item =>
    matches([item.scope, item.namespace, item.kind, item.name, item.verbs, item.resources, item.riskReasons], item.namespace, item.risk)
  );
  const filteredServiceAccounts = analysis.serviceAccounts.filter(item =>
    matches([item.namespace, item.name, item.roles, item.verbs, item.resources, item.sccs, item.riskReasons], item.namespace, item.risk)
  );
  const filteredSccs = analysis.sccs.filter(item =>
    matches([item.name, item.allowedCapabilities, item.volumes, item.directUsers, item.directGroups, item.rbacSubjects, item.riskReasons], '', item.risk)
  );
  const filteredUsers = analysis.users.filter(item =>
    matches([item.name, item.fullName, item.identities, item.groups, item.roles, item.verbs, item.resources, item.sccs, item.riskReasons], '', item.risk)
  );
  const filteredGroups = analysis.groups.filter(item =>
    matches([item.name, item.users, item.roles, item.verbs, item.resources, item.sccs, item.riskReasons], '', item.risk)
  );

  return (
    <Box sx={{ p: 2 }}>
      <Stack direction={{ xs: 'column', md: 'row' }} justifyContent="space-between" alignItems={{ md: 'center' }} spacing={2} sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h4">OpenShift RBAC & SCC Report</Typography>
          <Typography color="text.secondary">
            Declared permissions resolved from Roles, bindings, OpenShift users/groups, ServiceAccounts, and SCC assignments.
          </Typography>
          <Typography variant="caption" color="text.secondary">
            Collected {new Date(data.collectedAt).toLocaleString()} · OpenShift {data.clusterVersion?.status?.desired?.version || 'unknown'}
          </Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Button variant="outlined" onClick={() => void refresh()}>
            Refresh
          </Button>
          <Button variant="contained" onClick={() => downloadHtmlReport(data, analysis)}>
            Export HTML
          </Button>
        </Stack>
      </Stack>

      {Object.keys(data.collectionErrors).length > 0 && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          The report is partial because {Object.keys(data.collectionErrors).length} API collection(s) were denied or unavailable. Review the Warnings tab.
        </Alert>
      )}

      <Paper variant="outlined" sx={{ mb: 2, p: 1.5 }}>
        <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', md: 'minmax(260px,1fr) 240px 180px' }, gap: 1.5 }}>
          <TextField size="small" label="Search report" value={search} onChange={(event: React.ChangeEvent<HTMLInputElement>) => setSearch(event.target.value)} />
          <FormControl size="small">
            <InputLabel>Namespace</InputLabel>
            <Select value={namespace} label="Namespace" onChange={(event: SelectChangeEvent) => setNamespace(event.target.value)}>
              <MenuItem value="*">All namespaces</MenuItem>
              {namespaces.map(item => (
                <MenuItem key={item} value={item}>
                  {item}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <FormControl size="small">
            <InputLabel>Risk</InputLabel>
            <Select value={risk} label="Risk" onChange={(event: SelectChangeEvent) => setRisk(event.target.value)}>
              <MenuItem value="*">All risks</MenuItem>
              {['Critical', 'High', 'Medium', 'Low', 'None'].map(item => (
                <MenuItem key={item} value={item}>
                  {item}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
        </Box>
      </Paper>

      <Tabs value={tab} onChange={(_event: React.SyntheticEvent, value: number) => setTab(value)} variant="scrollable" scrollButtons="auto" sx={{ mb: 2 }}>
        <Tab label="Overview" />
        <Tab label={`Assignments (${filteredAssignments.length})`} />
        <Tab label={`Roles (${filteredRoles.length})`} />
        <Tab label={`ServiceAccounts (${filteredServiceAccounts.length})`} />
        <Tab label={`SCC (${filteredSccs.length})`} />
        <Tab label={`Users (${filteredUsers.length})`} />
        <Tab label={`Groups (${filteredGroups.length})`} />
        <Tab label={`Warnings (${Object.keys(data.collectionErrors).length})`} />
      </Tabs>

      {tab === 0 && <Overview analysis={analysis} />}
      {tab === 1 && (
        <DataTable
          rows={filteredAssignments}
          columns={[
            { label: 'Scope', value: row => row.scope },
            { label: 'Namespace', value: row => row.namespace || '—' },
            { label: 'Binding', value: row => `${row.bindingKind}/${row.bindingName}` },
            { label: 'Role', value: row => `${row.roleKind}/${row.roleName}` },
            { label: 'Subject', value: row => `${row.subjectKind}:${row.subjectNamespace ? `${row.subjectNamespace}:` : ''}${row.subjectName}` },
            { label: 'Verbs', value: row => csv(row.verbs) },
            { label: 'API groups', value: row => csv(row.apiGroups) },
            { label: 'Resources', value: row => csv(row.resources) },
            { label: 'Resource names', value: row => csv(row.resourceNames) },
            { label: 'Risk', value: row => <RiskChip severity={row.risk} reasons={row.riskReasons} /> },
            { label: 'Reasons', value: row => csv(row.riskReasons) },
          ]}
        />
      )}
      {tab === 2 && (
        <DataTable
          rows={filteredRoles}
          columns={[
            { label: 'Scope', value: row => row.scope },
            { label: 'Namespace', value: row => row.namespace || '—' },
            { label: 'Role', value: row => `${row.kind}/${row.name}` },
            { label: 'Bindings', value: row => row.bindingCount },
            { label: 'Subjects', value: row => row.subjectCount },
            { label: 'Aggregated', value: row => (row.aggregated ? 'Yes' : 'No') },
            { label: 'Verbs', value: row => csv(row.verbs) },
            { label: 'API groups', value: row => csv(row.apiGroups) },
            { label: 'Resources', value: row => csv(row.resources) },
            { label: 'Resource names', value: row => csv(row.resourceNames) },
            { label: 'Risk', value: row => <RiskChip severity={row.risk} reasons={row.riskReasons} /> },
            { label: 'Reasons', value: row => csv(row.riskReasons) },
          ]}
        />
      )}
      {tab === 3 && (
        <DataTable
          rows={filteredServiceAccounts}
          columns={[
            { label: 'Namespace', value: row => row.namespace },
            { label: 'ServiceAccount', value: row => row.name },
            { label: 'Automount token', value: row => row.automountServiceAccountToken },
            { label: 'Bindings', value: row => row.bindingCount },
            { label: 'Roles', value: row => csv(row.roles) },
            { label: 'Verbs', value: row => csv(row.verbs) },
            { label: 'Resources', value: row => csv(row.resources) },
            { label: 'SCCs', value: row => csv(row.sccs) },
            { label: 'Risk', value: row => <RiskChip severity={row.risk} reasons={row.riskReasons} /> },
            { label: 'Reasons', value: row => csv(row.riskReasons) },
          ]}
        />
      )}
      {tab === 4 && (
        <DataTable
          rows={filteredSccs}
          columns={[
            { label: 'SCC', value: row => row.name },
            { label: 'Priority', value: row => row.priority || '—' },
            { label: 'Privileged', value: row => (row.privileged ? 'Yes' : 'No') },
            { label: 'Host network', value: row => (row.hostNetwork ? 'Yes' : 'No') },
            { label: 'Host PID/IPC', value: row => `${row.hostPID ? 'PID ' : ''}${row.hostIPC ? 'IPC' : ''}` || 'No' },
            { label: 'Host ports/path', value: row => `${row.hostPorts ? 'Ports ' : ''}${row.hostPath ? 'Path' : ''}` || 'No' },
            { label: 'Capabilities', value: row => csv(row.allowedCapabilities) },
            { label: 'Volumes', value: row => csv(row.volumes) },
            { label: 'Direct users', value: row => csv(row.directUsers) },
            { label: 'Direct groups', value: row => csv(row.directGroups) },
            { label: 'RBAC subjects', value: row => csv(row.rbacSubjects) },
            { label: 'Assignments', value: row => row.totalAssignments },
            { label: 'Risk', value: row => <RiskChip severity={row.risk} reasons={row.riskReasons} /> },
            { label: 'Reasons', value: row => csv(row.riskReasons) },
          ]}
        />
      )}
      {tab === 5 && (
        <DataTable
          rows={filteredUsers}
          columns={[
            { label: 'User', value: row => row.name },
            { label: 'Full name', value: row => row.fullName || '—' },
            { label: 'Identities', value: row => csv(row.identities) },
            { label: 'Groups', value: row => csv(row.groups) },
            { label: 'Direct bindings', value: row => row.directBindingCount },
            { label: 'Inherited bindings', value: row => row.inheritedBindingCount },
            { label: 'Roles', value: row => csv(row.roles) },
            { label: 'Verbs', value: row => csv(row.verbs) },
            { label: 'Resources', value: row => csv(row.resources) },
            { label: 'SCCs', value: row => csv(row.sccs) },
            { label: 'Risk', value: row => <RiskChip severity={row.risk} reasons={row.riskReasons} /> },
            { label: 'Reasons', value: row => csv(row.riskReasons) },
          ]}
        />
      )}
      {tab === 6 && (
        <DataTable
          rows={filteredGroups}
          columns={[
            { label: 'Group', value: row => row.name },
            { label: 'Members', value: row => row.memberCount },
            { label: 'Users', value: row => csv(row.users) },
            { label: 'Bindings', value: row => row.bindingCount },
            { label: 'Roles', value: row => csv(row.roles) },
            { label: 'Verbs', value: row => csv(row.verbs) },
            { label: 'Resources', value: row => csv(row.resources) },
            { label: 'SCCs', value: row => csv(row.sccs) },
            { label: 'Risk', value: row => <RiskChip severity={row.risk} reasons={row.riskReasons} /> },
            { label: 'Reasons', value: row => csv(row.riskReasons) },
          ]}
        />
      )}
      {tab === 7 && (
        <DataTable
          rows={Object.entries(data.collectionErrors).map(([resource, message]) => ({ resource, message }))}
          columns={[
            { label: 'API/resource', value: row => row.resource },
            { label: 'Error', value: row => row.message },
          ]}
          emptyMessage="All requested APIs were collected successfully."
        />
      )}

      <Alert severity="info" sx={{ mt: 2 }}>
        This page reports declared RBAC and SCC access. External group membership that is not synchronized into OpenShift, admission controls, and authorization webhook decisions cannot be fully inferred from these objects.
      </Alert>
    </Box>
  );
}

registerSidebarEntry({
  parent: 'cluster',
  name: 'openshift-rbac-report',
  label: 'RBAC Report',
  url: '/openshift-rbac-report',
});

registerRoute({
  path: '/openshift-rbac-report',
  sidebar: 'openshift-rbac-report',
  component: ReportPage,
  exact: true,
});
