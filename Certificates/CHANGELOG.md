# Changelog

## 1.1.0 — Python 3.6 compatibility fix

- Removed `from __future__ import annotations`, which is unavailable before Python 3.7.
- Removed Python 3.9/3.10 runtime annotation syntax such as `list[str]` and `X | None`.
- Replaced `argparse.BooleanOptionalAction` with Python 3.6-compatible mutually exclusive CLI flags.
- Changed the playbook default to reuse `ansible_playbook_python`.
- Added an explicit Python runtime preflight to the Ansible playbook.
- Validated the collector against Python 3.6 grammar and an end-to-end mocked OpenShift API execution.
