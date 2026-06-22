# Validation Results

The delivered plugin was validated locally with the Headlamp plugin SDK `0.14.0`.

## Commands executed

```bash
npm run tsc
npm run lint
npm run build
npm run package
```

All commands completed successfully.

## Build output

```text
dist/main.js
openshift-rbac-html-report-0.1.0.tar.gz
```

## Packaged plugin SHA-256

```text
07f7094b812f12826e732ab99bf7cf8517106df814e8ad69757d43cedbf5fa72
```

## Additional validation

- Bash syntax validation was completed for every script under `scripts/`.
- The RBAC analysis functions were executed against representative mock OpenShift objects.
- The standalone HTML renderer was executed against mock data and generated `SAMPLE-REPORT.html`.
- The API collector implements Kubernetes list pagination using `metadata.continue`.

Actual cluster validation is still required because available API resources, permissions, identity-provider synchronization, SCCs, and Headlamp deployment details differ by environment.
