#!/bin/bash
# ============================================================
#  OCP 4.18 - Endpoint Connectivity Pre-Check Script
#  Cluster  : psehgaft
#  Bastion  : bastion
#  Valida alcanzabilidad HTTPS (443) a endpoints requeridos
#  por Red Hat Assisted Installer y OCP 4.18
# ============================================================

# ─── Colores ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Contadores ─────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0

# ─── Configuración ──────────────────────────────────────────
TIMEOUT=10        # segundos por intento
LOG_FILE="endpoint_precheck_$(date +%Y%m%d_%H%M%S).log"

# ─── Helpers ────────────────────────────────────────────────
print_header() {
  local msg="$1"
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  ${msg}${NC}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"
}

# Verifica conectividad TCP al puerto (rápido, sin TLS)
check_tcp() {
  local host="$1"
  local port="$2"
  local desc="$3"

  # Saltar hosts con comodín — no se pueden conectar directamente
  if [[ "$host" == \** ]]; then
    echo -e "  ${YELLOW}[SKIP]${NC} ${host}:${port} — comodín, no testeable directamente"
    echo "SKIP  ${host}:${port}  ${desc}" >> "$LOG_FILE"
    ((WARN++))
    return
  fi

  if nc -z -w "$TIMEOUT" "$host" "$port" 2>/dev/null; then
    echo -e "  ${GREEN}[PASS]${NC} ${host}:${port}"
    echo "PASS  ${host}:${port}  ${desc}" >> "$LOG_FILE"
    ((PASS++))
  else
    echo -e "  ${RED}[FAIL]${NC} ${host}:${port}  — ${RED}NO alcanzable${NC}  (${desc})"
    echo "FAIL  ${host}:${port}  ${desc}" >> "$LOG_FILE"
    ((FAIL++))
  fi
}

# Verifica conectividad HTTPS con curl (valida TLS + HTTP 200/301/302/401)
check_https() {
  local host="$1"
  local port="$2"
  local desc="$3"
  local url="https://${host}"
  [[ "$port" != "443" ]] && url="https://${host}:${port}"

  # Saltar hosts con comodín
  if [[ "$host" == \** ]]; then
    echo -e "  ${YELLOW}[SKIP]${NC} ${host}:${port} — comodín, no testeable directamente"
    echo "SKIP  ${host}:${port}  ${desc}" >> "$LOG_FILE"
    ((WARN++))
    return
  fi

  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" \
    --max-time "$TIMEOUT" \
    --connect-timeout "$TIMEOUT" \
    -L \
    "$url" 2>/dev/null)

  # Códigos aceptables: 200 OK, 301/302 redirect, 400 bad request (server respondió),
  # 401/403 unauthorized (server respondió), 404 (server respondió)
  if [[ "$http_code" =~ ^(200|301|302|307|308|400|401|403|404)$ ]]; then
    echo -e "  ${GREEN}[PASS]${NC} ${host}:${port}  HTTP ${http_code}"
    echo "PASS  ${host}:${port}  HTTP_${http_code}  ${desc}" >> "$LOG_FILE"
    ((PASS++))
  elif [[ "$http_code" == "000" ]]; then
    # Distinguir timeout real de connection reset (puerto abierto pero curl falló)
    if nc -z -w "$TIMEOUT" "$host" "$port" 2>/dev/null; then
      echo -e "  ${YELLOW}[WARN]${NC} ${host}:${port}  — Puerto abierto pero curl falló (reset/TLS issue)  (${desc})"
      echo "WARN  ${host}:${port}  CURL_RESET  ${desc}" >> "$LOG_FILE"
      ((WARN++))
    else
      echo -e "  ${RED}[FAIL]${NC} ${host}:${port}  — ${RED}Sin respuesta / timeout${NC}  (${desc})"
      echo "FAIL  ${host}:${port}  TIMEOUT  ${desc}" >> "$LOG_FILE"
      ((FAIL++))
    fi
  else
    echo -e "  ${YELLOW}[WARN]${NC} ${host}:${port}  HTTP ${http_code}  (${desc})"
    echo "WARN  ${host}:${port}  HTTP_${http_code}  ${desc}" >> "$LOG_FILE"
    ((WARN++))
  fi
}

# ════════════════════════════════════════════════════════════
print_header "OCP 4.18 ENDPOINT CONNECTIVITY PRE-CHECK"
echo -e "  Cluster      : ${BOLD}corenokia${NC}"
echo -e "  Bastion      : ${BOLD}$(hostname -f 2>/dev/null || hostname)${NC}"
echo -e "  Fecha/Hora   : ${BOLD}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "  Timeout      : ${BOLD}${TIMEOUT}s por host${NC}"
echo -e "  Log file     : ${BOLD}${LOG_FILE}${NC}"
echo -e "  Herramientas : curl=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')  nc=$(nc -h 2>&1 | head -1)"

# Inicializar log
echo "OCP 4.18 Endpoint Pre-Check — $(date)" > "$LOG_FILE"
echo "Bastion: $(hostname -f 2>/dev/null)" >> "$LOG_FILE"
echo "────────────────────────────────────────────────────────" >> "$LOG_FILE"

# ─── Verificar dependencias ──────────────────────────────────
print_section "0. DEPENDENCIAS"
for tool in curl nc dig; do
  if command -v "$tool" &>/dev/null; then
    echo -e "  ${GREEN}[PASS]${NC} $tool disponible ($(command -v $tool))"
  else
    echo -e "  ${RED}[FAIL]${NC} $tool ${RED}NO encontrado${NC} — instalar antes de continuar"
  fi
done

# ────────────────────────────────────────────────────────────
# 1. RED HAT REGISTRIES — Imágenes core
# ────────────────────────────────────────────────────────────
print_section "1. RED HAT REGISTRIES — Imágenes core (puerto 443)"
DESC="Provides core container images"
check_https "registry.access.redhat.com"   443  "$DESC"
check_https "registry.redhat.io"           443  "$DESC"
check_https "registry.connect.redhat.com"  443  "$DESC"
check_https "sso.redhat.com"               443  "$DESC"
check_https "cdn-ubi.redhat.com"           443  "$DESC"

# ────────────────────────────────────────────────────────────
# 2. QUAY.IO CDN — Imágenes core
# ────────────────────────────────────────────────────────────
print_section "2. QUAY.IO CDN — Imágenes core (puerto 443)"
DESC="Provides core container images via Quay CDN"
check_https "quay.io"       443  "$DESC (base)"
check_https "cdn.quay.io"   443  "$DESC"
check_https "cdn01.quay.io" 443  "$DESC"
check_https "cdn02.quay.io" 443  "$DESC"
check_https "cdn03.quay.io" 443  "$DESC"
check_https "cdn04.quay.io" 443  "$DESC"
check_https "cdn05.quay.io" 443  "$DESC"
check_https "cdn06.quay.io" 443  "$DESC"

# ────────────────────────────────────────────────────────────
# 3. AUTENTICACIÓN Y CLOUD CONSOLE
# ────────────────────────────────────────────────────────────
print_section "3. AUTENTICACIÓN Y CLOUD CONSOLE (puerto 443)"
check_https "sso.redhat.com"       443  "Autenticación OAuth Red Hat (cloud.redhat.com)"
check_https "console.redhat.com"   443  "Telemetry / cluster token / insights-operator"
check_https "api.openshift.com"    443  "Cluster token / check de actualizaciones disponibles"

# ────────────────────────────────────────────────────────────
# 4. RHCOS — Imágenes del sistema operativo
# ────────────────────────────────────────────────────────────
print_section "4. RHCOS — Imágenes del sistema operativo (puerto 443)"
check_https "openshift.org"                    443  "Imágenes RHCOS"
check_https "rhcos.mirror.openshift.com"       443  "Contenido de instalación mirrored / firmas de release"
check_https "art-rhcos-ci.s3.amazonaws.com"    443  "Descarga de imágenes RHCOS desde S3"

# ────────────────────────────────────────────────────────────
# 5. TELEMETRÍA Y SOPORTE
# ────────────────────────────────────────────────────────────
print_section "5. TELEMETRÍA Y SOPORTE (puerto 443)"
check_https "api.access.redhat.com"      443  "Telemetry"
check_https "infogw.api.openshift.com"   443  "Telemetry gateway"
check_https "cert-api.access.redhat.com" 443  "Telemetry (cert endpoint)"

# ────────────────────────────────────────────────────────────
# 6. FIRMAS DE RELEASE — Cluster Version Operator
# ────────────────────────────────────────────────────────────
print_section "6. FIRMAS DE RELEASE — Cluster Version Operator (puerto 443)"
check_https "storage.googleapis.com"   443  "Fuente de firmas de release image"

# ────────────────────────────────────────────────────────────
# 7. AMAZON S3 — Contenido de imágenes y operadores
# ────────────────────────────────────────────────────────────
print_section "7. AMAZON S3 — Imágenes y operadores certificados (puerto 443)"
check_https "quayio-production-s3.s3.amazonaws.com"                                                        443  "Contenido de imágenes Quay en AWS"
check_https "rhc4tp-prod-z8cxf-image-registry-us-east-1-evenkyleffocxqvofrk.s3.dualstack.us-east-1.amazonaws.com" 443 "registry.connect.redhat.com backend"
check_https "oso-rhc4tp-docker-registry.s3-us-west-2.amazonaws.com"                                       443  "Sonatype Nexus / F5 Big IP operators"

# ────────────────────────────────────────────────────────────
# 8. COMODINES — Solo referencia, no testeables directamente
# ────────────────────────────────────────────────────────────
print_section "8. HOSTS CON COMODÍN — Verificación de host base (referencia)"
echo -e "  ${YELLOW}[INFO]${NC} Los registros wildcard no pueden testearse con nc/curl directamente."
echo -e "         Se verifica el host base como referencia de alcanzabilidad."
check_https "quay.io"  443  "*.quay.io — base testeable"

# ─── RESUMEN ────────────────────────────────────────────────
print_header "RESUMEN"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  Total de checks : ${BOLD}${TOTAL}${NC}"
echo -e "  ${GREEN}${BOLD}PASS${NC}            : ${PASS}"
echo -e "  ${RED}${BOLD}FAIL${NC}            : ${FAIL}"
echo -e "  ${YELLOW}${BOLD}WARN/SKIP${NC}       : ${WARN}"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}✔  TODOS LOS ENDPOINTS SON ALCANZABLES — Conectividad OK para el despliegue.${NC}"
else
  echo -e "  ${RED}${BOLD}✘  HAY ${FAIL} ENDPOINT(S) NO ALCANZABLE(S) — Revisar firewall/proxy antes de instalar.${NC}"
  echo ""
  echo -e "  ${RED}${BOLD}Endpoints fallidos:${NC}"
  grep "^FAIL" "$LOG_FILE" | while IFS= read -r line; do
    echo -e "    ${RED}→${NC} $line"
  done
fi

echo ""
echo -e "  Log completo guardado en: ${BOLD}${LOG_FILE}${NC}"
echo ""
# ════════════════════════════════════════════════════════════
