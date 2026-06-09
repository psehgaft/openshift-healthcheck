# OpenShift General Health Check Script

This package contains a read-only Bash script to collect a general OpenShift cluster health snapshot from a bastion, admin workstation, or troubleshooting host where the `oc` CLI is available.

## Files

- `ocp-general-health-check.sh`: main executable script.
- `README-ocp-general-health-check.md`: usage notes and operational guidance.

## What it checks

1. Local OpenShift CLI and login context.
2. ClusterVersion and infrastructure baseline.
3. ClusterOperators status.
4. Node readiness, pressure conditions, and resource usage.
5. MachineConfigPools, machines, and MachineSets.
6. Pods outside `Running` or `Completed`, plus high restart counts.
7. Core namespaces: kube-apiserver, etcd, authentication, ingress, DNS, network, monitoring, console.
8. Network, ingress, DNS, proxy, and console route configuration.
9. StorageClasses, PVs, PVCs, CSI nodes, CSI drivers, and VolumeAttachments.
10. OLM resources: CSVs, Subscriptions, InstallPlans, OperatorGroups, CatalogSources.
11. Recent warning events and active Prometheus alerts when the API proxy query is allowed.
12. Authentication, OAuth, CSRs, and unavailable APIService objects.
13. Optional `oc adm must-gather` collection.

## Requirements

- Bash.
- OpenShift CLI: `oc`.
- A logged-in OpenShift user, preferably with `cluster-admin` for complete results.
- Optional: `jq` for richer Prometheus alert parsing.
- Optional: `timeout` for per-command time limits.

## Basic execution

```bash
chmod +x ocp-general-health-check.sh
oc login https://api.<cluster>:6443
./ocp-general-health-check.sh
```

## Step-by-step guided mode

```bash
./ocp-general-health-check.sh --pause
```

## Deep collection mode

This adds additional `describe` output and limited log tails for problematic pods. It remains read-only, but the output can be larger.

```bash
./ocp-general-health-check.sh --deep
```

## Include must-gather

```bash
./ocp-general-health-check.sh --must-gather
```

## Recommended support execution

```bash
./ocp-general-health-check.sh \
  --output /tmp/ocp-health-$(date +%Y%m%d-%H%M%S) \
  --deep
```

Then review:

```bash
cat /tmp/ocp-health-*/summary.txt
less /tmp/ocp-health-*/health-report.md
```

## Status classification

The script classifies the cluster as:

- `HEALTHY`: no obvious general issue was detected.
- `WARNING`: something requires validation, but the cluster might still be operational.
- `CRITICAL`: degraded operators, unavailable core components, NotReady nodes, pressure conditions, critical alerts, or severe pod states were detected.

## Important notes

- The script does not modify cluster resources.
- The output can include operational metadata such as node names, routes, namespaces, IPs, events, and cluster names.
- Review and sanitize the output before sharing it externally.
- For Red Hat Support cases, `oc adm must-gather` remains the standard comprehensive collection mechanism.
