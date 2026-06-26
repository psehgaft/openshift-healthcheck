#!/usr/bin/env python3
"""Read-only OpenShift certificate inventory and expiration audit.

The program intentionally does not persist raw Secret objects, private keys, or
certificate bodies. Only X.509 metadata, fingerprints, resource references, and
findings are written to disk.
"""

from __future__ import annotations

import argparse
import base64
import csv
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import urllib.parse
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

PEM_CERT_RE = re.compile(
    br"-----BEGIN CERTIFICATE-----\s+.*?-----END CERTIFICATE-----\s*",
    re.DOTALL,
)
KUBECONFIG_YAML_RE = re.compile(
    r"(?mi)^\s*(client-certificate-data|certificate-authority-data)\s*:\s*[\"']?([A-Za-z0-9+/=]+)[\"']?\s*$"
)
KUBECONFIG_JSON_RE = re.compile(
    r'(?i)"(client-certificate-data|certificate-authority-data)"\s*:\s*"([A-Za-z0-9+/=]+)"'
)
DATA_URI_RE = re.compile(r"(?i)data:[^;,\s]+;base64,([A-Za-z0-9+/=]+)")
CERT_LIKE_KEY_RE = re.compile(
    r"(?i)(^|[._/-])(tls\.crt|ca\.crt|cert(ificate)?|ca[-_]?bundle|client[-_]?certificate|server[-_]?certificate)([._/-]|$)"
)
UNSUPPORTED_CONTAINER_RE = re.compile(r"(?i)\.(p12|pfx|jks|keystore)$")

STATUS_RANK = {
    "EXPIRED": 0,
    "NOT_YET_VALID": 1,
    "CRITICAL": 2,
    "WARNING": 3,
    "OK": 4,
    "UNKNOWN": 5,
}
FINDING_RANK = {"CRITICAL": 0, "WARNING": 1, "INFO": 2}


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value: dt.datetime | None) -> str:
    if value is None:
        return ""
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_openssl_date(value: str) -> dt.datetime | None:
    value = (value or "").strip()
    if not value:
        return None
    patterns = (
        "%b %d %H:%M:%S %Y %Z",
        "%b  %d %H:%M:%S %Y %Z",
        "%Y-%m-%d %H:%M:%SZ",
        "%Y%m%d%H%M%SZ",
    )
    for pattern in patterns:
        try:
            parsed = dt.datetime.strptime(value, pattern)
            return parsed.replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
    return None


def clean_text(value: Any, max_len: int = 20000) -> str:
    if value is None:
        return ""
    text = str(value).replace("\x00", "")
    text = re.sub(r"[\t\r\n]+", " ", text)
    text = re.sub(r"\s{2,}", " ", text).strip()
    return text[:max_len]


def md_escape(value: Any, max_len: int = 600) -> str:
    text = clean_text(value, max_len=max_len)
    return text.replace("|", "\\|")


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value or "cluster")
    return value.strip("-.") or "cluster"


def normalize_fingerprint(value: str) -> str:
    return re.sub(r"[^0-9A-Fa-f]", "", value or "").upper()


def b64decode_loose(value: str | bytes) -> bytes | None:
    try:
        raw = value.encode() if isinstance(value, str) else value
        raw = re.sub(br"\s+", b"", raw)
        if not raw:
            return b""
        padding = (-len(raw)) % 4
        return base64.b64decode(raw + (b"=" * padding), validate=False)
    except Exception:
        return None


def file_mode(path: Path, mode: int = 0o600) -> None:
    try:
        path.chmod(mode)
    except OSError:
        pass


def nested_get(obj: dict[str, Any], *keys: str, default: Any = None) -> Any:
    current: Any = obj
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


class AuditError(RuntimeError):
    pass


class CertificateAuditor:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.now = utc_now()
        self.env = os.environ.copy()
        if args.kubeconfig:
            self.env["KUBECONFIG"] = args.kubeconfig
        if args.context:
            self.env["OC_CONTEXT"] = args.context

        self.records: list[dict[str, Any]] = []
        self.findings: list[dict[str, Any]] = []
        self.endpoint_results: list[dict[str, Any]] = []
        self.execution_messages: list[str] = []
        self.source_fingerprint_seen: set[tuple[str, str]] = set()
        self.report_dir: Path | None = None
        self.temp_dir_obj = tempfile.TemporaryDirectory(prefix="ocp-cert-audit-")
        self.temp_dir = Path(self.temp_dir_obj.name)
        self.temp_counter = 0

        self.service_cert_map: dict[tuple[str, str], str] = {}
        self.cert_manager_map: dict[tuple[str, str], str] = {}
        self.ingress_secret_map: dict[tuple[str, str], str] = {}
        self.apiserver_named_secrets: dict[tuple[str, str], str] = {}
        self.proxy_ca_configmaps: dict[tuple[str, str], str] = {}
        self.cluster_metadata: dict[str, Any] = {}

    def log(self, message: str) -> None:
        stamp = utc_now().strftime("%Y-%m-%dT%H:%M:%SZ")
        line = f"[{stamp}] {message}"
        self.execution_messages.append(line)
        print(line, file=sys.stderr, flush=True)

    def add_finding(
        self,
        severity: str,
        category: str,
        source: str,
        message: str,
        recommendation: str = "",
        fingerprint: str = "",
    ) -> None:
        self.findings.append(
            {
                "severity": severity,
                "category": category,
                "source": source,
                "message": clean_text(message, 4000),
                "recommendation": clean_text(recommendation, 4000),
                "fingerprint_sha256": normalize_fingerprint(fingerprint),
            }
        )

    def run_command(
        self,
        command: list[str],
        *,
        timeout: int = 120,
        input_bytes: bytes | None = None,
        sensitive: bool = False,
    ) -> subprocess.CompletedProcess[bytes]:
        display = command[0] if sensitive else " ".join(shlex.quote(v) for v in command)
        if not sensitive:
            self.log(f"Executing: {display}")
        try:
            return subprocess.run(
                command,
                input=input_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.env,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise AuditError(f"Command timed out after {timeout}s: {display}") from exc
        except FileNotFoundError as exc:
            raise AuditError(f"Required executable not found: {command[0]}") from exc

    def oc_command(self, args: list[str], *, timeout: int = 120) -> list[str]:
        command = [self.args.oc_binary]
        if self.args.context:
            command.extend(["--context", self.args.context])
        command.extend(args)
        return command

    def oc_text(
        self,
        args: list[str],
        *,
        required: bool = False,
        timeout: int = 120,
        sensitive: bool = False,
    ) -> str:
        result = self.run_command(
            self.oc_command(args), timeout=timeout, sensitive=sensitive
        )
        if result.returncode != 0:
            error = clean_text(result.stderr.decode(errors="replace"), 1200)
            if required:
                raise AuditError(
                    f"oc command failed ({' '.join(args[:4])}): {error or 'unknown error'}"
                )
            self.log(f"Optional oc command failed: {' '.join(args[:4])}: {error}")
            return ""
        return result.stdout.decode(errors="replace")

    def oc_json(
        self,
        args: list[str],
        *,
        required: bool = False,
        timeout: int = 180,
        sensitive: bool = False,
    ) -> dict[str, Any]:
        output = self.oc_text(
            args, required=required, timeout=timeout, sensitive=sensitive
        )
        if not output:
            return {}
        try:
            data = json.loads(output)
            return data if isinstance(data, dict) else {}
        except json.JSONDecodeError as exc:
            if required:
                raise AuditError(f"Invalid JSON returned by oc for {' '.join(args)}") from exc
            self.log(f"Unable to parse optional JSON from {' '.join(args[:4])}")
            return {}

    def preflight(self) -> None:
        self.log("Running local and cluster preflight checks")
        for binary in (self.args.oc_binary, self.args.openssl_binary):
            result = self.run_command([binary, "version"] if binary == self.args.oc_binary else [binary, "version"])
            if result.returncode != 0:
                raise AuditError(f"Unable to execute {binary}")

        whoami = self.oc_text(["whoami"], required=True).strip()
        server = self.oc_text(["whoami", "--show-server"], required=True).strip()
        version = self.oc_json(["version", "-o", "json"], required=False)
        infra = self.oc_json(
            ["get", "infrastructure.config.openshift.io", "cluster", "-o", "json"],
            required=True,
        )
        clusterversion = self.oc_json(
            ["get", "clusterversion.config.openshift.io", "version", "-o", "json"],
            required=False,
        )
        dns = self.oc_json(
            ["get", "dns.config.openshift.io", "cluster", "-o", "json"],
            required=False,
        )

        infra_name = nested_get(infra, "status", "infrastructureName", default="")
        cluster_name = infra_name or nested_get(dns, "spec", "baseDomain", default="cluster")
        ocp_version = nested_get(clusterversion, "status", "desired", "version", default="")
        self.cluster_metadata = {
            "cluster_name": cluster_name,
            "infrastructure_name": infra_name,
            "base_domain": nested_get(dns, "spec", "baseDomain", default=""),
            "api_server_url": nested_get(infra, "status", "apiServerURL", default=server),
            "console_url": nested_get(infra, "status", "controlPlaneTopology", default=""),
            "ocp_version": ocp_version,
            "oc_client_version": nested_get(version, "clientVersion", "gitVersion", default=""),
            "audit_user": whoami,
            "generated_at": iso_utc(self.now),
            "warning_days": self.args.warning_days,
            "critical_days": self.args.critical_days,
            "node_scan_enabled": self.args.scan_nodes,
            "route_endpoint_scan_enabled": self.args.scan_route_endpoints,
        }

        required_permissions = [
            ("get", "secrets", "--all-namespaces"),
            ("get", "configmaps", "--all-namespaces"),
            ("get", "routes.route.openshift.io", "--all-namespaces"),
            ("get", "nodes", ""),
            ("get", "certificatesigningrequests.certificates.k8s.io", ""),
        ]
        denied: list[str] = []
        for verb, resource, scope in required_permissions:
            args = ["auth", "can-i", verb, resource]
            if scope:
                args.append(scope)
            answer = self.oc_text(args, required=False).strip().lower()
            if answer != "yes":
                denied.append(f"{verb} {resource} {scope}".strip())
        if denied:
            message = ", ".join(denied)
            if self.args.require_complete_permissions:
                raise AuditError(
                    "The current identity lacks permissions required for a complete audit: "
                    + message
                )
            self.add_finding(
                "WARNING",
                "RBAC",
                "cluster",
                "The current identity lacks one or more inventory permissions: " + message,
                "Re-run with a cluster-admin identity for a complete inventory.",
            )

    def create_report_directory(self) -> None:
        root = Path(self.args.output_root).expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        root.chmod(0o700)
        stamp = self.now.strftime("%Y%m%dT%H%M%SZ")
        name = safe_name(self.cluster_metadata.get("cluster_name", "cluster"))
        self.report_dir = root / f"certificate-audit-{name}-{stamp}"
        self.report_dir.mkdir(mode=0o700, parents=False, exist_ok=False)

    def build_management_maps(self) -> None:
        self.log("Building certificate ownership and management maps")

        services = self.oc_json(
            ["get", "services", "-A", "-o", "json"], required=False, timeout=300
        )
        for item in services.get("items", []):
            meta = item.get("metadata", {})
            annotations = meta.get("annotations", {}) or {}
            secret_name = annotations.get(
                "service.beta.openshift.io/serving-cert-secret-name", ""
            )
            if secret_name:
                namespace = meta.get("namespace", "default")
                service_name = meta.get("name", "")
                self.service_cert_map[(namespace, secret_name)] = service_name

        certs = self.oc_json(
            ["get", "certificates.cert-manager.io", "-A", "-o", "json"],
            required=False,
            timeout=180,
        )
        for item in certs.get("items", []):
            meta = item.get("metadata", {})
            spec = item.get("spec", {})
            namespace = meta.get("namespace", "default")
            secret_name = spec.get("secretName", "")
            if secret_name:
                issuer = spec.get("issuerRef", {}) or {}
                description = (
                    f"cert-manager Certificate/{meta.get('name', '')}; "
                    f"issuer={issuer.get('kind', 'Issuer')}/{issuer.get('name', '')}"
                )
                self.cert_manager_map[(namespace, secret_name)] = description
            ready = False
            for condition in item.get("status", {}).get("conditions", []) or []:
                if condition.get("type") == "Ready" and condition.get("status") == "True":
                    ready = True
            if item.get("status", {}).get("conditions") and not ready:
                self.add_finding(
                    "WARNING",
                    "cert-manager",
                    f"Certificate {namespace}/{meta.get('name', '')}",
                    "The cert-manager Certificate resource is not Ready.",
                    "Inspect the Certificate, CertificateRequest, Issuer, and controller events.",
                )

        ingress_controllers = self.oc_json(
            [
                "get",
                "ingresscontrollers.operator.openshift.io",
                "-n",
                "openshift-ingress-operator",
                "-o",
                "json",
            ],
            required=False,
        )
        for item in ingress_controllers.get("items", []):
            name = nested_get(item, "metadata", "name", default="")
            secret_name = nested_get(item, "spec", "defaultCertificate", "name", default="")
            if secret_name:
                self.ingress_secret_map[("openshift-ingress", secret_name)] = (
                    f"user-managed default certificate for IngressController/{name}"
                )
            else:
                self.ingress_secret_map[("openshift-ingress", "router-certs-default")] = (
                    f"Ingress Operator generated default certificate for IngressController/{name}"
                )

        apiserver = self.oc_json(
            ["get", "apiserver.config.openshift.io", "cluster", "-o", "json"],
            required=False,
        )
        for entry in nested_get(apiserver, "spec", "servingCerts", "namedCertificates", default=[]) or []:
            secret_name = nested_get(entry, "servingCertificate", "name", default="")
            names = ",".join(entry.get("names", []) or [])
            if secret_name:
                self.apiserver_named_secrets[("openshift-config", secret_name)] = (
                    f"user-managed API server named certificate for {names or 'configured hostnames'}"
                )

        proxy = self.oc_json(
            ["get", "proxy.config.openshift.io", "cluster", "-o", "json"],
            required=False,
        )
        proxy_cm = nested_get(proxy, "spec", "trustedCA", "name", default="")
        if proxy_cm:
            self.proxy_ca_configmaps[("openshift-config", proxy_cm)] = (
                "user-managed cluster-wide proxy trusted CA bundle"
            )

    def management_hint(
        self,
        source_type: str,
        namespace: str,
        name: str,
        key: str,
        metadata: dict[str, Any] | None = None,
    ) -> str:
        metadata = metadata or {}
        annotations = metadata.get("annotations", {}) or {}
        labels = metadata.get("labels", {}) or {}
        identity = (namespace, name)

        if identity in self.cert_manager_map or labels.get("controller.cert-manager.io/fao") == "true":
            return self.cert_manager_map.get(identity, "cert-manager managed")
        if "cert-manager.io/certificate-name" in annotations:
            return "cert-manager managed"
        if identity in self.service_cert_map or "service.beta.openshift.io/originating-service-name" in annotations:
            service = self.service_cert_map.get(identity) or annotations.get(
                "service.beta.openshift.io/originating-service-name", ""
            )
            return f"OpenShift service-ca managed; service={service}"
        if identity in self.ingress_secret_map:
            return self.ingress_secret_map[identity]
        if identity in self.apiserver_named_secrets:
            return self.apiserver_named_secrets[identity]
        if identity in self.proxy_ca_configmaps:
            return self.proxy_ca_configmaps[identity]
        if source_type == "Route":
            return "user-managed Route TLS material"
        if source_type == "Endpoint":
            return "certificate observed from active TLS endpoint"
        if source_type in {
            "MutatingWebhookConfiguration",
            "ValidatingWebhookConfiguration",
            "APIService",
            "CustomResourceDefinition",
        }:
            return "component or operator injected CA bundle"
        if source_type == "CertificateSigningRequest":
            return "certificate issued through Kubernetes CSR API"
        if source_type == "NodeFile":
            return "OpenShift/RHCOS node certificate or trust material"
        if source_type == "LocalKubeconfig":
            return "local kubeconfig client certificate or trusted CA material"
        if source_type == "MachineConfig":
            return "certificate embedded in MachineConfig"
        if source_type == "ConfigMap" and name == "kube-root-ca.crt":
            return "Kubernetes root CA injection"
        if source_type == "ConfigMap" and name == "openshift-service-ca.crt":
            return "OpenShift service CA injection"
        if namespace.startswith("openshift-") or namespace == "openshift":
            return "platform component certificate; confirm owning Operator"
        if source_type == "Secret":
            return "application/user-managed Secret unless an Operator owner is identified"
        if "ca" in key.lower():
            return "trusted CA bundle"
        return "unknown management owner"

    def source_id(self, source: dict[str, Any]) -> str:
        namespace = source.get("namespace", "")
        ns_part = f"{namespace}/" if namespace else ""
        return (
            f"{source.get('source_type', 'Unknown')}:{ns_part}"
            f"{source.get('name', '')}:{source.get('key', '')}"
        )

    def openssl(self, args: list[str], *, timeout: int = 30) -> subprocess.CompletedProcess[bytes]:
        return self.run_command(
            [self.args.openssl_binary] + args, timeout=timeout, sensitive=True
        )

    def inspect_certificate(
        self,
        cert_bytes: bytes,
        source: dict[str, Any],
        *,
        inform: str = "PEM",
        index: int = 1,
    ) -> None:
        self.temp_counter += 1
        raw_file = self.temp_dir / f"cert-{self.temp_counter}.bin"
        raw_file.write_bytes(cert_bytes)
        file_mode(raw_file)
        cert_file = raw_file

        if inform.upper() == "DER":
            pem_file = self.temp_dir / f"cert-{self.temp_counter}.pem"
            convert = self.openssl(
                ["x509", "-inform", "DER", "-in", str(raw_file), "-out", str(pem_file)]
            )
            if convert.returncode != 0:
                self.add_finding(
                    "WARNING",
                    "ParseError",
                    self.source_id(source),
                    "A certificate-like DER object could not be parsed.",
                    clean_text(convert.stderr.decode(errors="replace"), 1000),
                )
                return
            cert_file = pem_file
            file_mode(cert_file)

        meta_result = self.openssl(
            [
                "x509",
                "-in",
                str(cert_file),
                "-noout",
                "-subject",
                "-issuer",
                "-serial",
                "-startdate",
                "-enddate",
                "-fingerprint",
                "-sha256",
                "-nameopt",
                "RFC2253",
            ]
        )
        if meta_result.returncode != 0:
            self.add_finding(
                "WARNING",
                "ParseError",
                self.source_id(source),
                "A PEM certificate block could not be parsed by OpenSSL.",
                clean_text(meta_result.stderr.decode(errors="replace"), 1000),
            )
            return

        meta_lines = meta_result.stdout.decode(errors="replace").splitlines()
        values: dict[str, str] = {}
        for line in meta_lines:
            if "=" in line:
                key, value = line.split("=", 1)
                values[key.strip().lower()] = value.strip()

        subject = values.get("subject", "")
        issuer = values.get("issuer", "")
        serial = values.get("serial", "")
        not_before_raw = values.get("notbefore", "")
        not_after_raw = values.get("notafter", "")
        fingerprint = normalize_fingerprint(values.get("sha256 fingerprint", ""))
        not_before = parse_openssl_date(not_before_raw)
        not_after = parse_openssl_date(not_after_raw)

        if not fingerprint:
            fingerprint = hashlib.sha256(cert_file.read_bytes()).hexdigest().upper()

        dedupe_key = (self.source_id(source) + f"#{index}", fingerprint)
        if dedupe_key in self.source_fingerprint_seen:
            return
        self.source_fingerprint_seen.add(dedupe_key)

        self_signed = "no"
        if subject and subject == issuer:
            verify = self.openssl(
                [
                    "verify",
                    "-CAfile",
                    str(cert_file),
                    "-check_ss_sig",
                    str(cert_file),
                ]
            )
            if verify.returncode != 0:
                verify = self.openssl(
                    ["verify", "-CAfile", str(cert_file), str(cert_file)]
                )
            self_signed = "yes" if verify.returncode == 0 else "self-issued-unverified"

        basic = self.openssl(
            ["x509", "-in", str(cert_file), "-noout", "-ext", "basicConstraints"]
        )
        is_ca = "yes" if b"CA:TRUE" in basic.stdout else "no"

        san_result = self.openssl(
            ["x509", "-in", str(cert_file), "-noout", "-ext", "subjectAltName"]
        )
        san_text = san_result.stdout.decode(errors="replace") if san_result.returncode == 0 else ""
        san_lines = [line.strip() for line in san_text.splitlines()[1:] if line.strip()]
        sans = clean_text(" ".join(san_lines), 12000)

        text_result = self.openssl(["x509", "-in", str(cert_file), "-noout", "-text"])
        text = text_result.stdout.decode(errors="replace")
        signature_algorithms = re.findall(
            r"(?m)^\s*Signature Algorithm:\s*(\S+)", text
        )
        pubkey_algorithm = ""
        pubkey_bits = ""
        pub_match = re.search(r"(?m)^\s*Public Key Algorithm:\s*(\S+)", text)
        if pub_match:
            pubkey_algorithm = pub_match.group(1)
        bits_match = re.search(r"(?m)^\s*Public-Key:\s*\((\d+) bit\)", text)
        if bits_match:
            pubkey_bits = bits_match.group(1)

        status, days_remaining = self.certificate_status(not_before, not_after)
        lifetime_days = ""
        if not_before and not_after:
            lifetime_days = round((not_after - not_before).total_seconds() / 86400, 2)

        source_type = source.get("source_type", "Unknown")
        namespace = source.get("namespace", "")
        name = source.get("name", "")
        key = source.get("key", "")
        management = source.get("management_hint") or self.management_hint(
            source_type,
            namespace,
            name,
            key,
            source.get("metadata", {}),
        )
        historical_possible = source.get("historical_possible", "no")
        if source_type == "NodeFile" and re.search(
            r"/(static-pod-resources|kube-apiserver-pod|kube-controller-manager-pod|kube-scheduler-pod|etcd-pod)-?\d+(/|$)",
            source.get("path", ""),
        ):
            historical_possible = "yes"

        record = {
            "status": status,
            "days_remaining": days_remaining,
            "not_before": iso_utc(not_before),
            "not_after": iso_utc(not_after),
            "lifetime_days": lifetime_days,
            "self_signed": self_signed,
            "is_ca": is_ca,
            "subject": subject,
            "issuer": issuer,
            "serial": serial,
            "fingerprint_sha256": fingerprint,
            "signature_algorithm": signature_algorithms[0] if signature_algorithms else "",
            "public_key_algorithm": pubkey_algorithm,
            "public_key_bits": pubkey_bits,
            "subject_alt_names": sans,
            "source_type": source_type,
            "namespace": namespace,
            "name": name,
            "key": key,
            "certificate_index": index,
            "path": source.get("path", ""),
            "endpoint": source.get("endpoint", ""),
            "management_hint": management,
            "historical_possible": historical_possible,
            "source_id": self.source_id(source),
        }
        self.records.append(record)
        self.evaluate_record(record)

    def certificate_status(
        self, not_before: dt.datetime | None, not_after: dt.datetime | None
    ) -> tuple[str, int | str]:
        if not_before and self.now < not_before:
            return "NOT_YET_VALID", int((not_before - self.now).total_seconds() // 86400)
        if not_after is None:
            return "UNKNOWN", ""
        seconds = (not_after - self.now).total_seconds()
        days = int(seconds // 86400)
        if seconds < 0:
            return "EXPIRED", days
        if seconds <= self.args.critical_days * 86400:
            return "CRITICAL", days
        if seconds <= self.args.warning_days * 86400:
            return "WARNING", days
        return "OK", days

    def evaluate_record(self, record: dict[str, Any]) -> None:
        status = record["status"]
        source = record["source_id"]
        fingerprint = record["fingerprint_sha256"]
        is_endpoint = record.get("source_type") == "Endpoint"
        historical = record.get("historical_possible") == "yes"
        trust_bundle = (
            record.get("is_ca") == "yes"
            and "bundle" in record.get("management_hint", "").lower()
        )

        if status == "EXPIRED":
            severity = "CRITICAL" if is_endpoint or (not historical and not trust_bundle) else "WARNING"
            self.add_finding(
                severity,
                "Expiration",
                source,
                f"Certificate expired on {record.get('not_after')}; subject={record.get('subject')}",
                "Confirm whether this occurrence is active. Replace user-managed certificates or investigate the owning Operator before deleting platform-managed material.",
                fingerprint,
            )
        elif status == "CRITICAL":
            severity = "CRITICAL" if is_endpoint else "WARNING"
            self.add_finding(
                severity,
                "Expiration",
                source,
                f"Certificate expires in {record.get('days_remaining')} day(s) on {record.get('not_after')}.",
                "Validate automatic rotation or schedule renewal before the critical threshold is reached.",
                fingerprint,
            )
        elif status == "WARNING":
            self.add_finding(
                "WARNING",
                "Expiration",
                source,
                f"Certificate expires in {record.get('days_remaining')} day(s) on {record.get('not_after')}.",
                "Confirm the renewal owner and rotation mechanism.",
                fingerprint,
            )
        elif status == "NOT_YET_VALID":
            self.add_finding(
                "WARNING",
                "Validity",
                source,
                f"Certificate is not valid before {record.get('not_before')}.",
                "Check clock synchronization and certificate issuance timing.",
                fingerprint,
            )

        signature = record.get("signature_algorithm", "").lower()
        if "md5" in signature or "sha1" in signature:
            severity = "WARNING"
            message = f"Weak or legacy signature algorithm detected: {record.get('signature_algorithm')}"
            if record.get("self_signed") == "yes" and record.get("is_ca") == "yes":
                message += "; this may be a legacy trust anchor, but should still be reviewed"
            self.add_finding(
                severity,
                "Cryptography",
                source,
                message,
                "Replace with a certificate using a currently approved signature algorithm where operationally supported.",
                fingerprint,
            )

        algorithm = record.get("public_key_algorithm", "").lower()
        bits_text = str(record.get("public_key_bits", ""))
        if "rsa" in algorithm and bits_text.isdigit() and int(bits_text) < 2048:
            self.add_finding(
                "WARNING",
                "Cryptography",
                source,
                f"RSA key size is {bits_text} bits.",
                "Replace with RSA 2048 bits or stronger, or an approved elliptic-curve key.",
                fingerprint,
            )

        if record.get("self_signed") == "yes":
            self.add_finding(
                "INFO",
                "SelfSigned",
                source,
                "The certificate is cryptographically verified as self-signed.",
                "Determine whether it is an expected internal trust anchor or an undesired self-signed endpoint certificate.",
                fingerprint,
            )

    def process_blob(
        self,
        blob: bytes | str | None,
        source: dict[str, Any],
        *,
        key_hint: str = "",
        allow_nested: bool = True,
    ) -> int:
        if blob is None:
            return 0
        data = blob.encode() if isinstance(blob, str) else blob
        count = 0
        material_hashes: set[str] = set()

        blocks = PEM_CERT_RE.findall(data)
        for index, block in enumerate(blocks, start=1):
            digest = hashlib.sha256(block).hexdigest()
            if digest in material_hashes:
                continue
            material_hashes.add(digest)
            child = dict(source)
            child["key"] = key_hint or source.get("key", "")
            self.inspect_certificate(block, child, inform="PEM", index=index)
            count += 1

        if allow_nested:
            text = data.decode(errors="ignore")
            nested_values: list[tuple[str, str]] = []
            nested_values.extend(KUBECONFIG_YAML_RE.findall(text))
            nested_values.extend(KUBECONFIG_JSON_RE.findall(text))
            nested_values.extend(("data-uri", value) for value in DATA_URI_RE.findall(text))
            for nested_index, (nested_key, encoded) in enumerate(nested_values, start=1):
                decoded = b64decode_loose(encoded)
                if not decoded:
                    continue
                nested_source = dict(source)
                nested_source["key"] = f"{key_hint or source.get('key', '')}#{nested_key}"
                count += self.process_blob(
                    decoded,
                    nested_source,
                    key_hint=nested_source["key"],
                    allow_nested=False,
                )

        key_for_detection = key_hint or source.get("key", "")
        if count == 0 and (
            CERT_LIKE_KEY_RE.search(key_for_detection)
            or re.search(r"(?i)\.(der|cer|crt|cert)$", key_for_detection)
        ):
            child = dict(source)
            child["key"] = key_for_detection
            before = len(self.records)
            self.inspect_certificate(data, child, inform="DER", index=1)
            if len(self.records) > before:
                count += 1

        if count == 0 and UNSUPPORTED_CONTAINER_RE.search(key_for_detection):
            self.add_finding(
                "INFO",
                "UnsupportedContainer",
                self.source_id(source),
                f"Certificate container {key_for_detection} was not opened because PKCS#12/JKS credentials were not supplied.",
                "Audit this keystore separately with an authorized password and keytool or openssl pkcs12.",
            )
        return count

    def process_local_kubeconfigs(self) -> None:
        self.log("Scanning local kubeconfig client certificates and CA data")
        configured = self.args.kubeconfig or self.env.get("KUBECONFIG", "")
        paths = [Path(value).expanduser() for value in configured.split(os.pathsep) if value]
        if not paths:
            paths = [Path.home() / ".kube" / "config"]
        file_ref_re = re.compile(
            r"(?mi)^\s*(client-certificate|certificate-authority)\s*:\s*[\"']?([^\"'\r\n]+)[\"']?\s*$"
        )
        seen_paths: set[Path] = set()
        for kubeconfig_path in paths:
            try:
                resolved = kubeconfig_path.resolve()
            except OSError:
                resolved = kubeconfig_path
            if resolved in seen_paths or not kubeconfig_path.is_file():
                continue
            seen_paths.add(resolved)
            try:
                content = kubeconfig_path.read_bytes()
            except OSError as exc:
                self.add_finding(
                    "WARNING",
                    "LocalKubeconfig",
                    str(kubeconfig_path),
                    f"Unable to read kubeconfig: {exc}",
                )
                continue
            source = {
                "source_type": "LocalKubeconfig",
                "namespace": "",
                "name": kubeconfig_path.name,
                "key": "embedded-certificate-data",
                "path": str(kubeconfig_path),
                "management_hint": "local kubeconfig client certificate or trusted CA material",
            }
            self.process_blob(content, source, key_hint="embedded-certificate-data")
            text = content.decode(errors="ignore")
            for field_name, referenced in file_ref_re.findall(text):
                cert_path = Path(referenced.strip())
                if not cert_path.is_absolute():
                    cert_path = kubeconfig_path.parent / cert_path
                if not cert_path.is_file():
                    self.add_finding(
                        "INFO",
                        "LocalKubeconfig",
                        str(kubeconfig_path),
                        f"Referenced {field_name} file does not exist or is not readable: {cert_path}",
                    )
                    continue
                try:
                    cert_content = cert_path.read_bytes()
                except OSError as exc:
                    self.add_finding(
                        "WARNING",
                        "LocalKubeconfig",
                        str(cert_path),
                        f"Unable to read referenced certificate file: {exc}",
                    )
                    continue
                ref_source = {
                    "source_type": "LocalKubeconfig",
                    "namespace": "",
                    "name": kubeconfig_path.name,
                    "key": field_name,
                    "path": str(cert_path),
                    "management_hint": "local kubeconfig client certificate or trusted CA material",
                }
                self.process_blob(cert_content, ref_source, key_hint=field_name)

    def process_secrets(self) -> None:
        self.log("Scanning Secret objects in memory without persisting raw data")
        secrets = self.oc_json(
            ["get", "secrets", "-A", "-o", "json"],
            required=True,
            timeout=self.args.cluster_query_timeout,
            sensitive=True,
        )
        for item in secrets.get("items", []):
            meta = item.get("metadata", {})
            namespace = meta.get("namespace", "default")
            name = meta.get("name", "")
            for key, encoded in (item.get("data", {}) or {}).items():
                decoded = b64decode_loose(encoded)
                if decoded is None:
                    self.add_finding(
                        "WARNING",
                        "ParseError",
                        f"Secret:{namespace}/{name}:{key}",
                        "Secret data could not be base64-decoded.",
                    )
                    continue
                source = {
                    "source_type": "Secret",
                    "namespace": namespace,
                    "name": name,
                    "key": key,
                    "metadata": {
                        "annotations": meta.get("annotations", {}) or {},
                        "labels": meta.get("labels", {}) or {},
                    },
                }
                source["management_hint"] = self.management_hint(
                    "Secret", namespace, name, key, source["metadata"]
                )
                self.process_blob(decoded, source, key_hint=key)

    def process_configmaps(self) -> None:
        self.log("Scanning ConfigMap certificate and trust-bundle content")
        configmaps = self.oc_json(
            ["get", "configmaps", "-A", "-o", "json"],
            required=True,
            timeout=self.args.cluster_query_timeout,
            sensitive=True,
        )
        for item in configmaps.get("items", []):
            meta = item.get("metadata", {})
            namespace = meta.get("namespace", "default")
            name = meta.get("name", "")
            metadata = {
                "annotations": meta.get("annotations", {}) or {},
                "labels": meta.get("labels", {}) or {},
            }
            for key, value in (item.get("data", {}) or {}).items():
                source = {
                    "source_type": "ConfigMap",
                    "namespace": namespace,
                    "name": name,
                    "key": key,
                    "metadata": metadata,
                }
                source["management_hint"] = self.management_hint(
                    "ConfigMap", namespace, name, key, metadata
                )
                if "-----BEGIN CERTIFICATE-----" in value or CERT_LIKE_KEY_RE.search(key):
                    self.process_blob(value, source, key_hint=key)
            for key, encoded in (item.get("binaryData", {}) or {}).items():
                decoded = b64decode_loose(encoded)
                if decoded is None:
                    continue
                source = {
                    "source_type": "ConfigMap",
                    "namespace": namespace,
                    "name": name,
                    "key": key,
                    "metadata": metadata,
                }
                source["management_hint"] = self.management_hint(
                    "ConfigMap", namespace, name, key, metadata
                )
                self.process_blob(decoded, source, key_hint=key)

    def process_routes(self) -> list[tuple[str, int, str]]:
        self.log("Scanning Route-embedded TLS certificate fields")
        routes = self.oc_json(
            ["get", "routes.route.openshift.io", "-A", "-o", "json"],
            required=True,
            timeout=self.args.cluster_query_timeout,
            sensitive=True,
        )
        endpoints: list[tuple[str, int, str]] = []
        for item in routes.get("items", []):
            meta = item.get("metadata", {})
            namespace = meta.get("namespace", "default")
            name = meta.get("name", "")
            tls = item.get("spec", {}).get("tls", {}) or {}
            for key in ("certificate", "caCertificate", "destinationCACertificate"):
                value = tls.get(key)
                if value:
                    source = {
                        "source_type": "Route",
                        "namespace": namespace,
                        "name": name,
                        "key": f"spec.tls.{key}",
                        "management_hint": "user-managed Route TLS material",
                    }
                    self.process_blob(value, source, key_hint=f"spec.tls.{key}")

            if tls:
                admitted_hosts: set[str] = set()
                spec_host = nested_get(item, "spec", "host", default="")
                if spec_host:
                    admitted_hosts.add(spec_host)
                for ingress in nested_get(item, "status", "ingress", default=[]) or []:
                    admitted = any(
                        condition.get("type") == "Admitted"
                        and condition.get("status") == "True"
                        for condition in ingress.get("conditions", []) or []
                    )
                    if admitted and ingress.get("host"):
                        admitted_hosts.add(ingress["host"])
                for host in sorted(admitted_hosts):
                    endpoints.append((host, 443, f"Route {namespace}/{name}"))
        return endpoints

    def recursive_certificate_fields(
        self,
        value: Any,
        *,
        path: str = "",
    ) -> Iterable[tuple[str, str, bool]]:
        if isinstance(value, dict):
            for key, child in value.items():
                child_path = f"{path}.{key}" if path else key
                if isinstance(child, str):
                    key_lower = key.lower()
                    if "-----BEGIN CERTIFICATE-----" in child:
                        yield child_path, child, False
                    elif key_lower in {
                        "cabundle",
                        "certificate",
                        "cacertificate",
                        "destinationcacertificate",
                        "clientcertificatedata",
                        "certificateauthoritydata",
                    }:
                        yield child_path, child, key_lower in {
                            "cabundle",
                            "clientcertificatedata",
                            "certificateauthoritydata",
                        }
                    elif child.startswith("data:") and ";base64," in child:
                        yield child_path, child, False
                else:
                    yield from self.recursive_certificate_fields(child, path=child_path)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                child_path = f"{path}[{index}]"
                yield from self.recursive_certificate_fields(child, path=child_path)

    def process_known_embedded_resources(self) -> None:
        resources = [
            (
                "MutatingWebhookConfiguration",
                "mutatingwebhookconfigurations.admissionregistration.k8s.io",
                False,
            ),
            (
                "ValidatingWebhookConfiguration",
                "validatingwebhookconfigurations.admissionregistration.k8s.io",
                False,
            ),
            ("APIService", "apiservices.apiregistration.k8s.io", False),
            (
                "CustomResourceDefinition",
                "customresourcedefinitions.apiextensions.k8s.io",
                False,
            ),
            ("MachineConfig", "machineconfigs.machineconfiguration.openshift.io", False),
        ]
        for source_type, resource, namespaced in resources:
            self.log(f"Scanning embedded certificate fields in {source_type} objects")
            args = ["get", resource]
            if namespaced:
                args.append("-A")
            args.extend(["-o", "json"])
            data = self.oc_json(
                args,
                required=False,
                timeout=self.args.cluster_query_timeout,
                sensitive=True,
            )
            for item in data.get("items", []):
                meta = item.get("metadata", {})
                namespace = meta.get("namespace", "")
                name = meta.get("name", "")
                for path, raw_value, encoded in self.recursive_certificate_fields(item):
                    blob: bytes | str | None = raw_value
                    if encoded:
                        blob = b64decode_loose(raw_value)
                    source = {
                        "source_type": source_type,
                        "namespace": namespace,
                        "name": name,
                        "key": path,
                        "management_hint": self.management_hint(
                            source_type, namespace, name, path
                        ),
                    }
                    self.process_blob(blob, source, key_hint=path)

    def process_csrs(self) -> None:
        self.log("Scanning issued certificates and pending states in CertificateSigningRequests")
        csrs = self.oc_json(
            [
                "get",
                "certificatesigningrequests.certificates.k8s.io",
                "-o",
                "json",
            ],
            required=False,
            timeout=self.args.cluster_query_timeout,
            sensitive=True,
        )
        for item in csrs.get("items", []):
            meta = item.get("metadata", {})
            name = meta.get("name", "")
            signer = nested_get(item, "spec", "signerName", default="")
            encoded = nested_get(item, "status", "certificate", default="")
            if encoded:
                decoded = b64decode_loose(encoded)
                source = {
                    "source_type": "CertificateSigningRequest",
                    "namespace": "",
                    "name": name,
                    "key": "status.certificate",
                    "management_hint": f"Kubernetes CSR signer={signer}",
                }
                self.process_blob(decoded, source, key_hint="status.certificate")
            conditions = nested_get(item, "status", "conditions", default=[]) or []
            approved = any(c.get("type") == "Approved" for c in conditions)
            denied = any(c.get("type") == "Denied" for c in conditions)
            if not conditions:
                self.add_finding(
                    "WARNING",
                    "CSR",
                    f"CertificateSigningRequest/{name}",
                    f"CSR is pending with signer {signer}.",
                    "Validate the requester identity and approve or deny the CSR according to the cluster CSR procedure.",
                )
            elif approved and not encoded:
                self.add_finding(
                    "WARNING",
                    "CSR",
                    f"CertificateSigningRequest/{name}",
                    f"CSR is approved but no issued certificate is present; signer={signer}.",
                    "Inspect the signer controller and related events.",
                )
            elif denied:
                self.add_finding(
                    "INFO",
                    "CSR",
                    f"CertificateSigningRequest/{name}",
                    f"CSR was denied; signer={signer}.",
                )

    def decode_node_field(self, value: str) -> str:
        try:
            return base64.b64decode(value.encode()).decode(errors="replace")
        except Exception:
            return ""

    def merge_node_record(self, fields: list[str]) -> None:
        if len(fields) != 16:
            self.add_finding(
                "WARNING",
                "NodeScan",
                "node-debug",
                f"Unexpected node certificate metadata field count: {len(fields)}",
            )
            return
        (
            node,
            path,
            cert_index,
            fingerprint,
            serial,
            subject,
            issuer,
            not_before_raw,
            not_after_raw,
            self_signed,
            is_ca,
            sig_alg,
            pubkey_alg,
            pubkey_bits,
            sans,
            parse_error,
        ) = [self.decode_node_field(value) for value in fields]

        source = {
            "source_type": "NodeFile",
            "namespace": "",
            "name": node,
            "key": path,
            "path": path,
            "management_hint": "OpenShift/RHCOS node certificate or trust material",
        }
        if parse_error:
            self.add_finding(
                "WARNING",
                "ParseError",
                self.source_id(source),
                f"Node certificate could not be parsed: {parse_error}",
            )
            return
        fingerprint = normalize_fingerprint(fingerprint)
        dedupe_key = (self.source_id(source) + f"#{cert_index}", fingerprint)
        if dedupe_key in self.source_fingerprint_seen:
            return
        self.source_fingerprint_seen.add(dedupe_key)

        not_before = parse_openssl_date(not_before_raw)
        not_after = parse_openssl_date(not_after_raw)
        status, days_remaining = self.certificate_status(not_before, not_after)
        lifetime_days: float | str = ""
        if not_before and not_after:
            lifetime_days = round((not_after - not_before).total_seconds() / 86400, 2)
        historical = (
            "yes"
            if re.search(
                r"/(static-pod-resources|kube-apiserver-pod|kube-controller-manager-pod|kube-scheduler-pod|etcd-pod)-?\d+(/|$)",
                path,
            )
            else "no"
        )
        record = {
            "status": status,
            "days_remaining": days_remaining,
            "not_before": iso_utc(not_before),
            "not_after": iso_utc(not_after),
            "lifetime_days": lifetime_days,
            "self_signed": self_signed or "unknown",
            "is_ca": is_ca or "unknown",
            "subject": subject,
            "issuer": issuer,
            "serial": serial,
            "fingerprint_sha256": fingerprint,
            "signature_algorithm": sig_alg,
            "public_key_algorithm": pubkey_alg,
            "public_key_bits": pubkey_bits,
            "subject_alt_names": sans,
            "source_type": "NodeFile",
            "namespace": "",
            "name": node,
            "key": path,
            "certificate_index": cert_index,
            "path": path,
            "endpoint": "",
            "management_hint": "OpenShift/RHCOS node certificate or trust material",
            "historical_possible": historical,
            "source_id": self.source_id(source),
        }
        self.records.append(record)
        self.evaluate_record(record)

    def scan_nodes(self) -> None:
        if not self.args.scan_nodes:
            self.log("Node filesystem scan disabled")
            return
        script_path = Path(self.args.node_scan_script).expanduser().resolve()
        if not script_path.is_file():
            raise AuditError(f"Node scan script not found: {script_path}")
        script_b64 = base64.b64encode(script_path.read_bytes()).decode()
        nodes = self.oc_json(["get", "nodes", "-o", "json"], required=True)
        node_names = sorted(
            item.get("metadata", {}).get("name", "")
            for item in nodes.get("items", [])
            if item.get("metadata", {}).get("name")
        )
        for node in node_names:
            self.log(f"Scanning certificate metadata on node {node}")
            remote = (
                f"printf '%s' {shlex.quote(script_b64)} | base64 -d | "
                f"bash -s -- {shlex.quote(node)}"
            )
            command = self.oc_command(
                ["debug", f"node/{node}", "--", "chroot", "/host", "bash", "-c", remote]
            )
            try:
                result = self.run_command(
                    command,
                    timeout=self.args.node_scan_timeout,
                    sensitive=True,
                )
            except AuditError as exc:
                self.add_finding(
                    "WARNING",
                    "NodeScan",
                    f"Node/{node}",
                    str(exc),
                    "Re-run the node scan for this node and inspect debug pod scheduling or RBAC restrictions.",
                )
                continue
            combined = result.stdout.decode(errors="replace") + "\n" + result.stderr.decode(errors="replace")
            parsed = 0
            for line in combined.splitlines():
                if not line.startswith("CERTMETA\t"):
                    continue
                parsed += 1
                self.merge_node_record(line.split("\t")[1:])
            if result.returncode != 0:
                self.add_finding(
                    "WARNING",
                    "NodeScan",
                    f"Node/{node}",
                    f"oc debug returned exit code {result.returncode}; parsed {parsed} certificate record(s).",
                    clean_text(result.stderr.decode(errors="replace"), 1000),
                )
            elif parsed == 0:
                self.add_finding(
                    "INFO",
                    "NodeScan",
                    f"Node/{node}",
                    "No certificate metadata was returned from the configured read-only node paths.",
                )

    def endpoint_from_url(self, value: str, description: str) -> tuple[str, int, str] | None:
        if not value:
            return None
        parsed = urllib.parse.urlparse(value if "://" in value else f"https://{value}")
        if not parsed.hostname:
            return None
        port = parsed.port or 443
        return parsed.hostname, port, description

    def collect_core_endpoints(self) -> list[tuple[str, int, str]]:
        endpoints: list[tuple[str, int, str]] = []
        api_url = self.cluster_metadata.get("api_server_url", "")
        api_endpoint = self.endpoint_from_url(api_url, "OpenShift API")
        if api_endpoint:
            endpoints.append(api_endpoint)
        route_specs = [
            ("openshift-console", "console", "OpenShift web console"),
            ("openshift-authentication", "oauth-openshift", "OpenShift OAuth"),
        ]
        for namespace, name, description in route_specs:
            route = self.oc_json(
                [
                    "get",
                    "route.route.openshift.io",
                    name,
                    "-n",
                    namespace,
                    "-o",
                    "json",
                ],
                required=False,
            )
            host = nested_get(route, "spec", "host", default="")
            if host:
                endpoints.append((host, 443, description))
        return endpoints

    def scan_endpoint(self, host: str, port: int, description: str) -> None:
        endpoint = f"{host}:{port}"
        self.log(f"Inspecting TLS endpoint {endpoint} ({description})")
        command = [
            self.args.openssl_binary,
            "s_client",
            "-showcerts",
            "-connect",
            endpoint,
            "-servername",
            host,
        ]
        try:
            result = self.run_command(
                command,
                timeout=self.args.endpoint_timeout,
                input_bytes=b"",
                sensitive=True,
            )
        except AuditError as exc:
            self.endpoint_results.append(
                {
                    "endpoint": endpoint,
                    "description": description,
                    "handshake": "timeout/error",
                    "verify_return_code": "",
                    "certificates_observed": 0,
                    "error": str(exc),
                }
            )
            self.add_finding(
                "WARNING",
                "Endpoint",
                endpoint,
                str(exc),
                "Validate DNS, load-balancer reachability, network policy, and endpoint availability from the audit host.",
            )
            return
        stdout = result.stdout
        stderr_text = result.stderr.decode(errors="replace")
        blocks = PEM_CERT_RE.findall(stdout)
        verify_text = stdout.decode(errors="replace") + "\n" + stderr_text
        verify_match = re.search(r"Verify return code:\s*(\d+)\s*\(([^)]*)\)", verify_text)
        verify_code = ""
        if verify_match:
            verify_code = f"{verify_match.group(1)} ({verify_match.group(2)})"
        handshake = "success" if blocks else "no certificate returned"
        self.endpoint_results.append(
            {
                "endpoint": endpoint,
                "description": description,
                "handshake": handshake,
                "verify_return_code": verify_code,
                "certificates_observed": len(blocks),
                "error": "" if blocks else clean_text(stderr_text, 1200),
            }
        )
        if not blocks:
            self.add_finding(
                "WARNING",
                "Endpoint",
                endpoint,
                "No certificate chain was returned by the TLS endpoint.",
                clean_text(stderr_text, 1000),
            )
            return
        for index, block in enumerate(blocks, start=1):
            source = {
                "source_type": "Endpoint",
                "namespace": "",
                "name": endpoint,
                "key": f"presented-chain[{index}]",
                "endpoint": endpoint,
                "management_hint": "certificate observed from active TLS endpoint",
            }
            self.inspect_certificate(block, source, index=index)

    def scan_endpoints(self, route_endpoints: list[tuple[str, int, str]]) -> None:
        endpoints = self.collect_core_endpoints()
        if self.args.scan_route_endpoints:
            endpoints.extend(route_endpoints)
        unique: dict[tuple[str, int], str] = {}
        for host, port, description in endpoints:
            unique.setdefault((host, port), description)
        endpoint_items = list(unique.items())
        if self.args.max_route_endpoints > 0:
            endpoint_items = endpoint_items[: self.args.max_route_endpoints]
        for (host, port), description in endpoint_items:
            self.scan_endpoint(host, port, description)

    def aggregate_unique(self) -> list[dict[str, Any]]:
        groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for record in self.records:
            groups[record["fingerprint_sha256"]].append(record)
        unique: list[dict[str, Any]] = []
        for fingerprint, occurrences in groups.items():
            representative = sorted(
                occurrences,
                key=lambda r: (
                    STATUS_RANK.get(r.get("status", "UNKNOWN"), 9),
                    0 if r.get("source_type") == "Endpoint" else 1,
                    str(r.get("source_id", "")),
                ),
            )[0]
            item = dict(representative)
            item["occurrences"] = len(occurrences)
            item["source_locations"] = sorted(
                {
                    f"{r.get('source_id', '')}"
                    + (f" path={r.get('path')}" if r.get("path") else "")
                    + (f" endpoint={r.get('endpoint')}" if r.get("endpoint") else "")
                    for r in occurrences
                }
            )
            item["management_hints"] = sorted(
                {r.get("management_hint", "") for r in occurrences if r.get("management_hint")}
            )
            item["active_endpoint_occurrences"] = sum(
                1 for r in occurrences if r.get("source_type") == "Endpoint"
            )
            item["historical_occurrences"] = sum(
                1 for r in occurrences if r.get("historical_possible") == "yes"
            )
            unique.append(item)
        unique.sort(
            key=lambda r: (
                STATUS_RANK.get(r.get("status", "UNKNOWN"), 9),
                r.get("days_remaining") if isinstance(r.get("days_remaining"), int) else 999999,
                r.get("subject", ""),
            )
        )
        return unique

    def summary(self, unique: list[dict[str, Any]]) -> dict[str, Any]:
        status_counts = Counter(record.get("status", "UNKNOWN") for record in unique)
        management_counts = Counter()
        for record in unique:
            management_counts[record.get("management_hint", "unknown")] += 1
        return {
            "certificate_occurrences": len(self.records),
            "unique_certificates": len(unique),
            "self_signed_unique": sum(1 for r in unique if r.get("self_signed") == "yes"),
            "ca_certificates_unique": sum(1 for r in unique if r.get("is_ca") == "yes"),
            "active_endpoint_certificates_unique": sum(
                1 for r in unique if r.get("active_endpoint_occurrences", 0) > 0
            ),
            "status_counts": dict(status_counts),
            "finding_counts": dict(Counter(f.get("severity") for f in self.findings)),
            "management_counts": dict(management_counts),
        }

    def write_csv(self, path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                cooked = dict(row)
                for key, value in list(cooked.items()):
                    if isinstance(value, list):
                        cooked[key] = " || ".join(clean_text(v, 4000) for v in value)
                    elif isinstance(value, dict):
                        cooked[key] = json.dumps(value, sort_keys=True)
                writer.writerow(cooked)
        file_mode(path)

    def write_markdown(
        self,
        path: Path,
        unique: list[dict[str, Any]],
        summary: dict[str, Any],
    ) -> None:
        lines: list[str] = []
        meta = self.cluster_metadata
        lines.extend(
            [
                "# OpenShift Certificate Audit Report",
                "",
                "## Audit metadata",
                "",
                f"- **Cluster:** `{md_escape(meta.get('cluster_name'))}`",
                f"- **OpenShift version:** `{md_escape(meta.get('ocp_version'))}`",
                f"- **API server:** `{md_escape(meta.get('api_server_url'))}`",
                f"- **Executed by:** `{md_escape(meta.get('audit_user'))}`",
                f"- **Generated:** `{md_escape(meta.get('generated_at'))}`",
                f"- **Thresholds:** critical ≤ {self.args.critical_days} days; warning ≤ {self.args.warning_days} days",
                f"- **Node filesystem scan:** `{self.args.scan_nodes}`",
                f"- **All Route endpoint probing:** `{self.args.scan_route_endpoints}`",
                "",
                "> Raw Secret objects, private keys, and certificate bodies were not written to this report directory. Only X.509 metadata and resource references were retained.",
                "",
                "## Executive summary",
                "",
                "| Metric | Count |",
                "|---|---:|",
                f"| Certificate occurrences | {summary['certificate_occurrences']} |",
                f"| Unique certificates | {summary['unique_certificates']} |",
                f"| Verified self-signed certificates | {summary['self_signed_unique']} |",
                f"| CA certificates | {summary['ca_certificates_unique']} |",
                f"| Certificates observed from active endpoints | {summary['active_endpoint_certificates_unique']} |",
            ]
        )
        for status in ("EXPIRED", "NOT_YET_VALID", "CRITICAL", "WARNING", "OK", "UNKNOWN"):
            lines.append(f"| {status} | {summary['status_counts'].get(status, 0)} |")

        lines.extend(
            [
                "",
                "## Priority findings",
                "",
                "| Severity | Category | Source | Finding | Recommendation |",
                "|---|---|---|---|---|",
            ]
        )
        for finding in sorted(
            self.findings,
            key=lambda f: (
                FINDING_RANK.get(f.get("severity", "INFO"), 9),
                f.get("category", ""),
                f.get("source", ""),
            ),
        ):
            if finding.get("severity") == "INFO" and finding.get("category") == "SelfSigned":
                continue
            lines.append(
                "| {severity} | {category} | `{source}` | {message} | {recommendation} |".format(
                    severity=md_escape(finding.get("severity")),
                    category=md_escape(finding.get("category")),
                    source=md_escape(finding.get("source"), 300),
                    message=md_escape(finding.get("message"), 700),
                    recommendation=md_escape(finding.get("recommendation"), 700),
                )
            )
        if not any(
            not (f.get("severity") == "INFO" and f.get("category") == "SelfSigned")
            for f in self.findings
        ):
            lines.append("| INFO | Audit | cluster | No priority findings were generated. | Continue periodic review. |")

        self_signed = [r for r in unique if r.get("self_signed") == "yes"]
        lines.extend(
            [
                "",
                "## Verified self-signed certificates",
                "",
                "A certificate is marked **self-signed** only when its normalized subject equals its issuer and OpenSSL successfully verifies the certificate with its own public key. Self-issued certificates whose signatures could not be verified are reported separately as `self-issued-unverified`.",
                "",
                "| Status | Days | Expires | CA | Subject | Management | Occurrences | SHA-256 fingerprint |",
                "|---|---:|---|---|---|---|---:|---|",
            ]
        )
        for record in self_signed:
            lines.append(
                "| {status} | {days} | {expires} | {is_ca} | {subject} | {management} | {occurrences} | `{fingerprint}` |".format(
                    status=md_escape(record.get("status")),
                    days=md_escape(record.get("days_remaining")),
                    expires=md_escape(record.get("not_after")),
                    is_ca=md_escape(record.get("is_ca")),
                    subject=md_escape(record.get("subject")),
                    management=md_escape("; ".join(record.get("management_hints", [])), 500),
                    occurrences=record.get("occurrences", 0),
                    fingerprint=md_escape(record.get("fingerprint_sha256")),
                )
            )
        if not self_signed:
            lines.append("| — | — | — | — | No verified self-signed certificates found | — | — | — |")

        lines.extend(
            [
                "",
                "## Complete unique certificate inventory",
                "",
                "| Status | Days | Not after | Self-signed | CA | Subject | Issuer | Management | Occurrences | Active endpoint | Historical-path occurrences | SHA-256 fingerprint |",
                "|---|---:|---|---|---|---|---|---|---:|---:|---:|---|",
            ]
        )
        for record in unique:
            lines.append(
                "| {status} | {days} | {expires} | {self_signed} | {is_ca} | {subject} | {issuer} | {management} | {occurrences} | {endpoint_count} | {historical_count} | `{fingerprint}` |".format(
                    status=md_escape(record.get("status")),
                    days=md_escape(record.get("days_remaining")),
                    expires=md_escape(record.get("not_after")),
                    self_signed=md_escape(record.get("self_signed")),
                    is_ca=md_escape(record.get("is_ca")),
                    subject=md_escape(record.get("subject")),
                    issuer=md_escape(record.get("issuer")),
                    management=md_escape("; ".join(record.get("management_hints", [])), 500),
                    occurrences=record.get("occurrences", 0),
                    endpoint_count=record.get("active_endpoint_occurrences", 0),
                    historical_count=record.get("historical_occurrences", 0),
                    fingerprint=md_escape(record.get("fingerprint_sha256")),
                )
            )

        lines.extend(
            [
                "",
                "## Interpretation notes",
                "",
                "1. OpenShift intentionally uses internal self-signed infrastructure CAs. A self-signed result is therefore a classification, not automatically a vulnerability.",
                "2. Certificates in retained static-pod revision directories can be expired without being active. Validate the active manifest or endpoint before remediation.",
                "3. Trust bundles can legitimately retain an older CA during a rotation grace period. Endpoint observations and owning Operator status carry more operational weight than an isolated bundle occurrence.",
                "4. Password-protected PKCS#12, PFX, JKS, and application-internal keystores cannot be exhaustively opened without authorized credentials. They are identified as unsupported containers when recognizable by key name.",
                "5. `certificates-all.csv` contains every discovered occurrence. `certificates-unique.csv` deduplicates by SHA-256 fingerprint while preserving source locations.",
                "",
                "## Generated files",
                "",
                "- `certificate-audit.md` — human-readable report.",
                "- `certificates-all.csv` — every certificate occurrence.",
                "- `certificates-unique.csv` — deduplicated inventory.",
                "- `certificate-audit.json` — full structured result.",
                "- `findings.csv` — expiration, validity, cryptography, CSR, and collection findings.",
                "- `endpoints.csv` — TLS endpoint handshake and chain-observation results.",
                "- `execution.log` — audit execution messages without raw Secret data.",
            ]
        )
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        file_mode(path)

    def write_reports(self) -> dict[str, Any]:
        if self.report_dir is None:
            raise AuditError("Report directory was not initialized")
        unique = self.aggregate_unique()
        summary = self.summary(unique)

        all_fields = [
            "status",
            "days_remaining",
            "not_before",
            "not_after",
            "lifetime_days",
            "self_signed",
            "is_ca",
            "subject",
            "issuer",
            "serial",
            "fingerprint_sha256",
            "signature_algorithm",
            "public_key_algorithm",
            "public_key_bits",
            "subject_alt_names",
            "source_type",
            "namespace",
            "name",
            "key",
            "certificate_index",
            "path",
            "endpoint",
            "management_hint",
            "historical_possible",
            "source_id",
        ]
        unique_fields = all_fields + [
            "occurrences",
            "active_endpoint_occurrences",
            "historical_occurrences",
            "management_hints",
            "source_locations",
        ]
        self.write_csv(self.report_dir / "certificates-all.csv", self.records, all_fields)
        self.write_csv(self.report_dir / "certificates-unique.csv", unique, unique_fields)
        self.write_csv(
            self.report_dir / "findings.csv",
            sorted(
                self.findings,
                key=lambda f: (
                    FINDING_RANK.get(f.get("severity", "INFO"), 9),
                    f.get("category", ""),
                    f.get("source", ""),
                ),
            ),
            [
                "severity",
                "category",
                "source",
                "message",
                "recommendation",
                "fingerprint_sha256",
            ],
        )
        self.write_csv(
            self.report_dir / "endpoints.csv",
            self.endpoint_results,
            [
                "endpoint",
                "description",
                "handshake",
                "verify_return_code",
                "certificates_observed",
                "error",
            ],
        )
        self.write_markdown(self.report_dir / "certificate-audit.md", unique, summary)

        structured = {
            "metadata": self.cluster_metadata,
            "summary": summary,
            "unique_certificates": unique,
            "certificate_occurrences": self.records,
            "findings": self.findings,
            "endpoints": self.endpoint_results,
        }
        json_path = self.report_dir / "certificate-audit.json"
        json_path.write_text(
            json.dumps(structured, indent=2, sort_keys=True), encoding="utf-8"
        )
        file_mode(json_path)

        log_path = self.report_dir / "execution.log"
        log_path.write_text("\n".join(self.execution_messages) + "\n", encoding="utf-8")
        file_mode(log_path)

        return summary

    def execute(self) -> dict[str, Any]:
        self.preflight()
        self.create_report_directory()
        self.build_management_maps()
        self.process_local_kubeconfigs()
        self.process_secrets()
        self.process_configmaps()
        route_endpoints = self.process_routes()
        self.process_known_embedded_resources()
        self.process_csrs()
        self.scan_nodes()
        self.scan_endpoints(route_endpoints)
        summary = self.write_reports()
        return {
            "report_dir": str(self.report_dir),
            "summary": summary,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only OpenShift certificate inventory and expiration audit"
    )
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--kubeconfig", default="")
    parser.add_argument("--context", default="")
    parser.add_argument("--oc-binary", default="oc")
    parser.add_argument("--openssl-binary", default="openssl")
    parser.add_argument("--warning-days", type=int, default=90)
    parser.add_argument("--critical-days", type=int, default=30)
    parser.add_argument("--scan-nodes", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--node-scan-script", required=True)
    parser.add_argument("--node-scan-timeout", type=int, default=420)
    parser.add_argument("--scan-route-endpoints", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--max-route-endpoints", type=int, default=0)
    parser.add_argument("--endpoint-timeout", type=int, default=12)
    parser.add_argument("--cluster-query-timeout", type=int, default=600)
    parser.add_argument(
        "--require-complete-permissions",
        action=argparse.BooleanOptionalAction,
        default=True,
    )
    args = parser.parse_args()
    if args.critical_days < 0 or args.warning_days < 0:
        parser.error("Expiration thresholds must be non-negative")
    if args.critical_days > args.warning_days:
        parser.error("critical-days cannot exceed warning-days")
    return args


def main() -> int:
    args = parse_args()
    auditor = CertificateAuditor(args)
    try:
        result = auditor.execute()
    except AuditError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stdout)
        return 2
    except KeyboardInterrupt:
        print(json.dumps({"error": "Audit interrupted by user"}), file=sys.stdout)
        return 130
    finally:
        auditor.temp_dir_obj.cleanup()
    print(json.dumps(result, sort_keys=True), file=sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
