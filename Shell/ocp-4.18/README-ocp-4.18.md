# OpenShift 4.18 Health Check

This directory contains the version entrypoint for OpenShift 4.18+ health checks.

## Run

```bash
./ocp418-healthcheck-full.sh --env-file ../ocp-healthcheck.env --cluster-name <cluster-name> --client-label <client>
```

The script delegates to ../ocp-healthcheck.sh and generates a complete run directory with raw evidence, logs, describes, must-gather, HTML/Markdown reports, CSV annexes and backlog.
