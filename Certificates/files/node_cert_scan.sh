#!/usr/bin/env bash
set -uo pipefail

NODE_NAME="${1:-unknown-node}"
TMP_DIR="$(mktemp -d /run/ocp-cert-audit.XXXXXX 2>/dev/null || mktemp -d /tmp/ocp-cert-audit.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Read-only scan roots. Historical static-pod revisions are intentionally included.
SCAN_ROOTS=(
  /etc/kubernetes
  /var/lib/kubelet
  /var/lib/etcd
  /etc/pki/ca-trust
  /etc/containers/certs.d
)

b64() {
  printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

clean() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

emit() {
  local value
  printf 'CERTMETA'
  for value in "$@"; do
    printf '\t%s' "$(b64 "$(clean "$value")")"
  done
  printf '\n'
}

parse_cert() {
  local cert_file="$1" source_path="$2" cert_index="$3"
  local meta subject issuer serial not_before not_after fingerprint
  local self_signed="no" is_ca="no" sig_alg="unknown" pubkey_alg="unknown"
  local pubkey_bits="" sans="" parse_error=""

  if ! meta="$(openssl x509 -in "$cert_file" -noout -subject -issuer -serial -startdate -enddate -fingerprint -sha256 -nameopt RFC2253 2>&1)"; then
    emit "$NODE_NAME" "$source_path" "$cert_index" "" "" "" "" "" "" "unknown" "unknown" "unknown" "unknown" "" "" "$meta"
    return 0
  fi

  subject="$(printf '%s\n' "$meta" | sed -n 's/^subject=//p' | head -n1)"
  issuer="$(printf '%s\n' "$meta" | sed -n 's/^issuer=//p' | head -n1)"
  serial="$(printf '%s\n' "$meta" | sed -n 's/^serial=//p' | head -n1)"
  not_before="$(printf '%s\n' "$meta" | sed -n 's/^notBefore=//p' | head -n1)"
  not_after="$(printf '%s\n' "$meta" | sed -n 's/^notAfter=//p' | head -n1)"
  fingerprint="$(printf '%s\n' "$meta" | sed -n 's/^sha256 Fingerprint=//Ip' | head -n1 | tr '[:lower:]' '[:upper:]')"

  if [[ -n "$subject" && "$subject" == "$issuer" ]]; then
    if openssl verify -CAfile "$cert_file" -check_ss_sig "$cert_file" >/dev/null 2>&1 || \
       openssl verify -CAfile "$cert_file" "$cert_file" >/dev/null 2>&1; then
      self_signed="yes"
    else
      self_signed="self-issued-unverified"
    fi
  fi

  if openssl x509 -in "$cert_file" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then
    is_ca="yes"
  fi

  sig_alg="$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | sed -n 's/^[[:space:]]*Signature Algorithm:[[:space:]]*//p' | head -n1)"
  pubkey_alg="$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | sed -n 's/^[[:space:]]*Public Key Algorithm:[[:space:]]*//p' | head -n1)"
  pubkey_bits="$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | sed -n 's/^[[:space:]]*Public-Key: (\([0-9][0-9]*\) bit).*/\1/p' | head -n1)"
  sans="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr '\n' ' ')"

  emit "$NODE_NAME" "$source_path" "$cert_index" "$fingerprint" "$serial" "$subject" "$issuer" "$not_before" "$not_after" "$self_signed" "$is_ca" "$sig_alg" "$pubkey_alg" "$pubkey_bits" "$sans" "$parse_error"
}

process_candidate() {
  local source_file="$1" work_dir="$2" count=0 nested_count=0 encoded decoded_file
  mkdir -p "$work_dir"

  awk -v d="$work_dir" '
    /-----BEGIN CERTIFICATE-----/ {inside=1; n++; out=sprintf("%s/pem-%06d.crt", d, n)}
    inside {print > out}
    /-----END CERTIFICATE-----/ {if (inside) {close(out); inside=0}}
  ' "$source_file" 2>/dev/null || true

  while IFS= read -r cert_file; do
    count=$((count + 1))
    parse_cert "$cert_file" "$source_file" "$count"
  done < <(find "$work_dir" -maxdepth 1 -type f -name 'pem-*.crt' -print 2>/dev/null | sort)

  # Handles normal kubeconfig YAML with unquoted or double-quoted base64 values.
  while IFS= read -r encoded; do
    encoded="${encoded%\"}"
    encoded="${encoded#\"}"
    [[ -n "$encoded" ]] || continue
    nested_count=$((nested_count + 1))
    decoded_file="$work_dir/embedded-${nested_count}.bin"
    if printf '%s' "$encoded" | base64 -d > "$decoded_file" 2>/dev/null; then
      awk -v d="$work_dir" -v p="$nested_count" '
        /-----BEGIN CERTIFICATE-----/ {inside=1; n++; out=sprintf("%s/embedded-%06d-%06d.crt", d, p, n)}
        inside {print > out}
        /-----END CERTIFICATE-----/ {if (inside) {close(out); inside=0}}
      ' "$decoded_file" 2>/dev/null || true
    fi
  done < <(sed -nE 's/^[[:space:]]*(client-certificate-data|certificate-authority-data):[[:space:]]*([^[:space:]]+)[[:space:]]*$/\2/p' "$source_file" 2>/dev/null)

  while IFS= read -r cert_file; do
    count=$((count + 1))
    parse_cert "$cert_file" "$source_file#embedded" "$count"
  done < <(find "$work_dir" -maxdepth 1 -type f -name 'embedded-*.crt' -print 2>/dev/null | sort)

  if [[ "$count" -eq 0 ]] && [[ "$source_file" =~ \.(der|cer|crt|cert)$ ]]; then
    if openssl x509 -inform DER -in "$source_file" -out "$work_dir/der.crt" >/dev/null 2>&1; then
      parse_cert "$work_dir/der.crt" "$source_file" "1"
    fi
  fi
}

candidate_list="$TMP_DIR/candidates.list"
: > "$candidate_list"
for root in "${SCAN_ROOTS[@]}"; do
  [[ -e "$root" ]] || continue
  find "$root" -xdev -type f -size -4M \
    \( -iname '*.crt' -o -iname '*.cer' -o -iname '*.cert' -o -iname '*.der' \
       -o -iname '*.pem' -o -iname '*kubeconfig*' \) \
    -print 2>/dev/null >> "$candidate_list" || true
done

sort -u "$candidate_list" -o "$candidate_list"
file_no=0
while IFS= read -r source_file; do
  [[ -r "$source_file" ]] || continue
  file_no=$((file_no + 1))
  process_candidate "$source_file" "$TMP_DIR/file-${file_no}"
done < "$candidate_list"
