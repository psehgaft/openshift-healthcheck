# Headlamp OpenShift RBAC and SCC HTML Report Plugin

## 1. Purpose

This Headlamp plugin adds a **Cluster → RBAC Report** page that reads the current OpenShift cluster authorization configuration, resolves Role and binding relationships, displays graphical summaries, and exports a self-contained HTML report.

The report covers:

- `Role` and `ClusterRole` rules.
- `RoleBinding` and `ClusterRoleBinding` subjects.
- OpenShift `User` and `Group` objects.
- Group-inherited permissions for users whose group membership is represented in OpenShift.
- Kubernetes `ServiceAccount` objects and their bound roles.
- OpenShift `SecurityContextConstraints` (SCCs).
- Direct SCC `users` and `groups` assignments.
- RBAC rules that grant the `use` verb on SCCs.
- Verbs, API groups, resources, resource names, and non-resource URLs.
- Risk review candidates such as wildcards, `bind`, `escalate`, `impersonate`, Secrets, pod exec, node proxy, ServiceAccount token creation, certificate approval, and privileged SCC access.
- Charts for user/group/ServiceAccount counts, verb frequency, group membership, SCC assignments, identity providers, and permission risk.
- Standalone HTML export with no external JavaScript or chart dependencies.

> The plugin is read-only. It does not create or modify any OpenShift resource.

---

## 2. How it works

```text
Headlamp user or ServiceAccount
             |
             v
Headlamp RBAC Report plugin
             |
             +--> rbac.authorization.k8s.io
             |      Roles, ClusterRoles, bindings
             |
             +--> user.openshift.io
             |      Users and Groups
             |
             +--> core/v1
             |      ServiceAccounts and Namespaces
             |
             +--> security.openshift.io
             |      SecurityContextConstraints
             |
             +--> config.openshift.io
                    ClusterVersion
```

The plugin uses Headlamp's authenticated Kubernetes API proxy. Therefore, it can report only the objects that the current Headlamp identity is allowed to list.

API collections are paginated in batches of 500 objects. A denied or unavailable API does not stop the complete page: the plugin renders the information it could collect and records the failure under the **Warnings** tab and in the exported HTML.

---

## 3. Files in this toolkit

```text
headlamp-openshift-rbac-html-report/
├── README.md
├── package.json
├── tsconfig.json
├── src/
│   ├── headlamp-plugin.d.ts
│   ├── index.tsx
│   ├── api.ts
│   ├── analysis.ts
│   ├── html.ts
│   └── model.ts
├── plugin-overlay/
│   └── src/
├── manifests/
│   └── rbac-report-reader.yaml
└── scripts/
    ├── create-plugin-project.sh
    ├── install-macos-plugin.sh
    ├── install-rhel9-plugin.sh
    └── verify-report-reader.sh
```

The root folder is already a complete Headlamp plugin project. `plugin-overlay/src` is provided only for teams that prefer to scaffold a new project with the current Headlamp plugin CLI and then overlay the implementation.

---

# Part I — OpenShift authorization

## 4. Authenticate to OpenShift

Use an administrative workstation:

```bash
oc login https://api.<cluster-domain>:6443 --web

oc whoami
oc whoami --show-server
oc get clusterversion
```

The identity applying the reader role must be allowed to create ClusterRoles and ClusterRoleBindings:

```bash
oc auth can-i create clusterroles.rbac.authorization.k8s.io
oc auth can-i create clusterrolebindings.rbac.authorization.k8s.io
```

---

## 5. Select the Headlamp identity model

### Option A — Individual administrators

For Headlamp Desktop on macOS, the recommended model is:

```text
Enterprise user → OpenShift group → report reader ClusterRole
```

This preserves individual OpenShift audit attribution.

### Option B — Shared Headlamp server

For Headlamp on RHEL 9 using one audit kubeconfig:

```text
Headlamp ServiceAccount → report reader ClusterRole
```

All users of the shared Headlamp instance act against OpenShift as the same ServiceAccount. Protect the web service with HTTPS and authentication, and understand that OpenShift audit records will show the shared ServiceAccount rather than the individual browser user.

---

## 6. Configure the reader binding

Edit:

```text
manifests/rbac-report-reader.yaml
```

The supplied binding targets this OpenShift group:

```yaml
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: headlamp-rbac-report-readers
```

Replace the group name with the enterprise group that is permitted to view security metadata.

### Bind one user instead

```yaml
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: user@example.com
```

### Bind the existing Headlamp audit ServiceAccount instead

```yaml
subjects:
  - kind: ServiceAccount
    name: headlamp-rbac-auditor
    namespace: headlamp-audit
```

Apply the manifest:

```bash
oc apply -f manifests/rbac-report-reader.yaml
```

Inspect it:

```bash
oc describe clusterrole headlamp-rbac-report-reader
oc describe clusterrolebinding headlamp-rbac-report-readers
```

The role intentionally does **not** grant access to Secrets, workload exec, impersonation, or RBAC modification.

---

## 7. Verify the permissions

For the default group binding:

```bash
SUBJECT_KIND=Group \
SUBJECT_NAME=headlamp-rbac-report-readers \
  ./scripts/verify-report-reader.sh
```

For one user:

```bash
SUBJECT_KIND=User \
SUBJECT_NAME=user@example.com \
  ./scripts/verify-report-reader.sh
```

For a ServiceAccount, provide the canonical username:

```bash
SUBJECT_KIND=ServiceAccount \
SUBJECT_NAME=system:serviceaccount:headlamp-audit:headlamp-rbac-auditor \
  ./scripts/verify-report-reader.sh
```

The following report APIs should return `yes`:

```text
ClusterRoles
ClusterRoleBindings
Roles
RoleBindings
ServiceAccounts
OpenShift Users
OpenShift Groups
SecurityContextConstraints
```

Sensitive checks such as reading Secrets, patching ClusterRoles, creating ClusterRoleBindings, and impersonating users should return `no`.

---

# Part II — Build the plugin

## 8. Build requirements

The current Headlamp plugin development documentation requires:

```text
Node.js 22 or later
npm 11 or later
Headlamp Desktop or a running Headlamp server
```

Validate:

```bash
node --version
npm --version
```

On macOS with Homebrew:

```bash
brew install node
sudo npm install --global npm@11
```

On RHEL 9, use an approved Node.js 22 installation or build the plugin on a controlled macOS/Linux workstation and transfer only the packaged archive to RHEL.

---

## 9. Build the ready project

From this toolkit directory:

```bash
npm install
npm run tsc
npm run lint
npm run build
npm run package
```

The package command creates an archive similar to:

```text
openshift-rbac-html-report-0.1.0.tar.gz
```

List it:

```bash
find . -maxdepth 1 -name '*.tar.gz' -ls
```

### Alternative: create a fresh scaffold

The included helper creates a new plugin project with the current Headlamp CLI, overlays the source, builds it, and packages it:

```bash
chmod +x scripts/create-plugin-project.sh

./scripts/create-plugin-project.sh \
  "${HOME}/projects/openshift-rbac-report"
```

---

# Part III — Install on Headlamp Desktop for macOS

## 10. Confirm Headlamp Desktop and kubeconfig

Validate that the user can access the cluster:

```bash
oc whoami
oc get namespaces
```

The Headlamp Desktop application should use the same personal kubeconfig, for example:

```bash
KUBECONFIG="${HOME}/.kube/openshift-production.yaml" \
  /Applications/Headlamp.app/Contents/MacOS/Headlamp
```

---

## 11. Install the packaged plugin

```bash
chmod +x scripts/install-macos-plugin.sh

./scripts/install-macos-plugin.sh \
  ./openshift-rbac-html-report-0.1.0.tar.gz
```

The archive is extracted into:

```text
$HOME/.config/Headlamp/plugins
```

Quit Headlamp completely and reopen it.

### Manual installation

```bash
mkdir -p "${HOME}/.config/Headlamp/plugins"

tar xzf openshift-rbac-html-report-0.1.0.tar.gz \
  -C "${HOME}/.config/Headlamp/plugins"
```

---

# Part IV — Install on a RHEL 9 Headlamp server

## 12. Copy the archive to RHEL

From the build workstation:

```bash
scp openshift-rbac-html-report-0.1.0.tar.gz \
  <rhel-user>@<headlamp-server>:/tmp/
```

On RHEL:

```bash
cd /tmp
sudo /path/to/scripts/install-rhel9-plugin.sh \
  ./openshift-rbac-html-report-0.1.0.tar.gz
```

The default installation directory is:

```text
/opt/headlamp/plugins
```

---

## 13. Configure the Podman Quadlet

Edit:

```text
/etc/containers/systemd/headlamp.container
```

Under `[Container]`, include the plugin volume:

```ini
Volume=/opt/headlamp/plugins:/headlamp/plugins:ro,Z
```

Ensure the existing Headlamp command includes:

```text
--plugins-dir=/headlamp/plugins
```

Example command fragment:

```ini
Exec=--kubeconfig=/home/headlamp/.kube/config \
  --listen-addr=0.0.0.0 \
  --port=4466 \
  --plugins-dir=/headlamp/plugins
```

Keep any other arguments already required by the deployment.

Reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart headlamp.service
sudo systemctl status headlamp.service --no-pager
sudo journalctl -u headlamp.service -n 100 --no-pager
```

Confirm that the plugin is visible inside the container:

```bash
sudo podman exec headlamp \
  find /headlamp/plugins -maxdepth 3 -type f -print
```

---

# Part V — Use the report

## 14. Open the report page

1. Open Headlamp.
2. Select the OpenShift cluster.
3. Open **Cluster → RBAC Report**.
4. Wait for collection to finish.
5. Review any yellow partial-collection warning.

The page contains these tabs:

```text
Overview
Assignments
Roles
ServiceAccounts
SCC
Users
Groups
Warnings
```

---

## 15. Use the filters

The page supports:

- Free-text search across names, roles, verbs, resources, groups, and risk reasons.
- Namespace filtering.
- Risk filtering:
  - Critical
  - High
  - Medium
  - Low
  - None

The UI displays at most 1,000 rows per table to protect browser responsiveness. The exported HTML contains the complete collected dataset.

---

## 16. Understand the charts

### Unique bound subjects

Counts distinct subjects referenced by RoleBindings and ClusterRoleBindings:

```text
User
Group
ServiceAccount
```

### Permission assignment risk

Counts binding-to-subject assignments by the highest detected risk in the referenced role.

### RBAC verbs

Counts how often verbs appear in Role and ClusterRole rules, including:

```text
get
list
watch
create
update
patch
delete
use
bind
escalate
impersonate
*
```

### Users per OpenShift group

Shows the groups with the largest membership represented in `user.openshift.io/v1` Group objects.

### Assignments per SCC

Counts direct SCC users/groups plus subjects that receive SCC `use` through RBAC.

### Users by identity provider

Uses the prefix of OpenShift User identity references, for example:

```text
ldap:user1     → ldap
htpasswd:user2 → htpasswd
```

---

## 17. Export the HTML report

Click:

```text
Export HTML
```

The browser downloads a file similar to:

```text
openshift-rbac-report-2026-06-22T18-30-00-000Z.html
```

The exported report is self-contained and includes:

- Inline CSS.
- Inline SVG charts.
- Inventory counters.
- Users and group-inherited roles.
- ServiceAccounts and bound permissions.
- Role and ClusterRole rule details.
- Every binding expanded by subject.
- SCC characteristics and assignments.
- Collection warnings.
- Risk classifications and reasons.
- Print-specific formatting.

No external chart service, JavaScript library, or network connection is required to open the generated HTML.

---

# Part VI — Report interpretation

## 18. User permissions

For each OpenShift User, the report combines:

```text
Direct User subjects in bindings
+
Group subjects where the OpenShift Group object lists the user
```

It reports:

- Direct binding count.
- Group-inherited binding count.
- Referenced Roles and ClusterRoles.
- Unique verbs and resources.
- SCC access.
- Risk level and reasons.

### Identity-provider limitation

If an external LDAP/OIDC group is referenced in RBAC but its membership is not synchronized into OpenShift Group objects, the plugin can show the group binding but cannot determine which external users inherit it.

---

## 19. ServiceAccount permissions

For each ServiceAccount, the report displays:

- Namespace and name.
- `automountServiceAccountToken` setting.
- Number of bindings.
- Roles.
- Verbs.
- Resources.
- SCCs.
- Risk level.

The plugin does not read ServiceAccount token Secrets.

---

## 20. SCC analysis

The SCC table includes:

- Privileged container permission.
- Host network, PID, IPC, ports, and hostPath.
- Read-only root filesystem requirement.
- Allowed and required-dropped Linux capabilities.
- Allowed volume types.
- Direct users and groups configured inside the SCC.
- RBAC subjects that can `use` the SCC.

Both SCC access mechanisms are considered:

```text
SCC.users / SCC.groups
+
RBAC verb use on securitycontextconstraints
```

---

## 21. Risk classification

### Critical examples

- `cluster-admin`.
- Wildcard API groups, resources, and verbs.
- `bind`, `escalate`, or `impersonate`.
- RBAC binding modification.
- ServiceAccount token creation.
- Node proxy access.
- Privileged/high-impact SCC use.

### High examples

- Secret access.
- Pod exec, attach, or port-forward.
- Certificate approval/signing.
- General SCC use.
- Partial wildcard permissions.

### Medium examples

- Resource mutation through `create`, `update`, `patch`, or `delete` without a higher-risk condition.

### Low examples

- Read-only rules using verbs such as `get`, `list`, and `watch`.

A risk candidate is not automatically a vulnerability. Evaluate business purpose, scope, resource names, namespace restrictions, ownership, and compensating controls.

---

# Part VII — Effective authorization validation

## 22. Validate one user

```bash
oc auth can-i --list \
  --as=user@example.com \
  -n <namespace>
```

Group-aware test:

```bash
oc auth can-i get secrets \
  --as=user@example.com \
  --as-group=<group> \
  -n <namespace>
```

## 23. Validate one ServiceAccount

```bash
oc auth can-i --list \
  --as=system:serviceaccount:<namespace>:<service-account> \
  -n <namespace>
```

## 24. Find subjects that can perform an action

```bash
oc adm policy who-can get secrets \
  -n <namespace>

oc adm policy who-can create pods/exec \
  -n <namespace>

oc adm policy who-can use scc privileged
```

Also inspect direct SCC assignments:

```bash
oc describe scc privileged
```

The static report does not replace API-server authorization checks.

---

# Part VIII — Troubleshooting

## 25. The sidebar entry is missing

Check that the plugin files exist.

### macOS

```bash
find "${HOME}/.config/Headlamp/plugins" \
  -maxdepth 3 \
  -type f \
  -print
```

### RHEL

```bash
sudo podman exec headlamp \
  find /headlamp/plugins \
  -maxdepth 3 \
  -type f \
  -print
```

Restart Headlamp after installation.

---

## 26. The page shows collection warnings

Open the **Warnings** tab. A typical message is an HTTP `403 Forbidden` for a missing list permission.

Validate with the exact Headlamp identity:

```bash
oc auth can-i list clusterrolebindings.rbac.authorization.k8s.io \
  --as=<user-or-service-account>

oc auth can-i list users.user.openshift.io \
  --as=<user-or-service-account>

oc auth can-i list securitycontextconstraints.security.openshift.io \
  --as=<user-or-service-account>
```

For group-based access, include:

```bash
--as-group=<group-name>
```

---

## 27. Users or groups are empty

Check the API directly:

```bash
oc get users.user.openshift.io
oc get groups.user.openshift.io
```

Possible reasons:

- The current identity cannot list the resources.
- Users have not yet been materialized by login.
- External groups have not been synchronized into OpenShift.
- The identity provider does not maintain OpenShift Group objects.

---

## 28. A binding shows an unresolved role

The binding references a Role or ClusterRole that the current Headlamp identity cannot read, or the reference is stale.

Check:

```bash
oc get clusterrole <role-name>

oc get role <role-name> \
  -n <namespace>
```

---

## 29. The exported HTML is large

Large clusters can produce large reports because every binding subject and role rule is included. The file is intentionally standalone.

Operational recommendations:

- Store the HTML in a restricted security-evidence repository.
- Compress it for transport.
- Avoid attaching it to unencrypted email.
- Generate reports during low-activity audit windows for consistent snapshots.

---

# Part IX — Security controls

## 30. Required controls

- Use individual OpenShift identities where possible.
- Do not grant the report role permission to read Secrets.
- Do not grant `cluster-admin` merely to make the report work.
- Protect exported HTML as sensitive authorization and identity metadata.
- Keep the plugin source and package under code review.
- Pin and approve the Headlamp plugin SDK version used for production builds.
- Retain OpenShift audit logs.
- Revalidate the reader ClusterRole after platform upgrades.
- Treat third-party Headlamp plugins as trusted code because they execute in the Headlamp browser context.

---

# References

1. Headlamp — Plugin development overview  
   https://headlamp.dev/docs/latest/development/plugins/

2. Headlamp — Getting started with plugin development  
   https://headlamp.dev/docs/latest/development/plugins/getting-started/

3. Headlamp — Building and shipping plugins  
   https://headlamp.dev/docs/latest/development/plugins/building/

4. Headlamp API — `registerRoute`  
   https://headlamp.dev/docs/latest/development/api/plugin/registry/functions/registerroute/

5. Headlamp API — `registerSidebarEntry`  
   https://headlamp.dev/docs/latest/development/api/plugin/registry/functions/registersidebarentry/

6. Headlamp API — Kubernetes proxy `request`  
   https://headlamp.dev/docs/latest/development/api/lib/k8s/api/v1/clusterrequests/functions/request/

7. Kubernetes — Using RBAC authorization  
   https://kubernetes.io/docs/reference/access-authn-authz/rbac/

8. Kubernetes — RBAC good practices  
   https://kubernetes.io/docs/concepts/security/rbac-good-practices/

9. Kubernetes — ServiceAccounts  
   https://kubernetes.io/docs/concepts/security/service-accounts/

10. Red Hat OpenShift Container Platform 4.18 — Managing Security Context Constraints  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/managing-pod-security-policies

11. Red Hat OpenShift Container Platform 4.18 — SCC API  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_apis/securitycontextconstraints-security-openshift-io-v1

12. Red Hat OpenShift Container Platform 4.18 — User and group preparation  
    https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/postinstallation_configuration/post-install-preparing-for-users
