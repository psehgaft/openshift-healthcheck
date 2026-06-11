# Reports Code

`ocp-report-renderer.py` receives a run directory produced by the unified collector and generates:

- `report-<cluster>.html`
- `report-<cluster>.md`
- `errors-<cluster>.html`
- `cer-fill-sections.md`
- CSV copies for findings, backlog, namespace review, workload review and evidence index

Normally it is called automatically by `ocp-healthcheck.sh`.

Manual usage:

```bash
python3 reports/ocp-report-renderer.py --run-dir ./ocp-healthcheck-runs/<run-dir> --cluster-name non-prod-ocp --client-label example
```
