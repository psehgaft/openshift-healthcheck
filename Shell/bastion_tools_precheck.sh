#!/bin/bash
# ============================================================
#  OCP 4.18 - Bastion Tools Pre-Check Script
#  Cluster  : psehgaft
#  Bastion  : bastion
#  Valida herramientas requeridas en el nodo bastion
# ============================================================

# ─── Colores ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Contadores ─────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0

# ─── Versiones mínimas requeridas ───────────────────────────
OCP_VERSION="4.18"
PODMAN_MIN="4.0"
SKOPEO_MIN="1.9"

# ─── Log ────────────────────────────────────────────────────
LOG_FILE="bastion_tools_precheck_$(date +%Y%m%d_%H%M%S).log"
echo "OCP 4.18 Bastion Tools Pre-Check — $(date)" > "$LOG_FILE"
echo "Bastion: $(hostname -f 2>/dev/null)" >> "$LOG_FILE"
echo "────────────────────────────────────────────────────────" >> "$LOG_FILE"

# ─── Helpers ────────────────────────────────────────────────
print_header() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $1${NC}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
}

print_section() {
  echo ""
  echo -e "${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"
}

log() { echo "$1" >> "$LOG_FILE"; }

# Verifica si un comando existe y muestra su versión
check_tool() {
  local cmd="$1"
  local version_flag="$2"
  local description="$3"
  local min_version="$4"

  if command -v "$cmd" &>/dev/null; then
    local path
    path=$(command -v "$cmd")
    local version
    version=$($cmd $version_flag 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+[\.\d]*' | head -1)
    echo -e "  ${GREEN}[PASS]${NC} ${BOLD}${cmd}${NC} — ${version:-versión no detectada}  (${path})"
    echo -e "         ${description}"
    log "PASS  $cmd  $version  $path"
    ((PASS++))
  else
    echo -e "  ${RED}[FAIL]${NC} ${BOLD}${cmd}${NC} — ${RED}NO encontrado${NC}"
    echo -e "         ${description}"
    log "FAIL  $cmd  NOT_FOUND"
    ((FAIL++))
  fi
}

# Verifica si un comando existe (sin requerir versión)
check_tool_simple() {
  local cmd="$1"
  local description="$2"
  local install_hint="$3"

  if command -v "$cmd" &>/dev/null; then
    local path
    path=$(command -v "$cmd")
    local version

    # Usar flags específicas con timeout para evitar cuelgues
    case "$cmd" in
      dig)
        version=$(timeout 3 dig -v 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+[\.[\d]*' | head -1) ;;
      nslookup)
        version=$(timeout 3 nslookup -version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+[\.[\d]*' | head -1) ;;
      ssh|scp)
        version=$(timeout 3 "$cmd" -V 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+[\w.]*' | head -1) ;;
      vim)
        version=$(timeout 3 vim --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+' | head -1) ;;
      *)
        version=$(timeout 3 "$cmd" --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+[\.[\d]*' | head -1) ;;
    esac

    echo -e "  ${GREEN}[PASS]${NC} ${BOLD}${cmd}${NC} — ${version:-disponible}  (${path})"
    echo -e "         ${description}"
    log "PASS  $cmd  $version"
    ((PASS++))
  else
    echo -e "  ${RED}[FAIL]${NC} ${BOLD}${cmd}${NC} — ${RED}NO encontrado${NC}"
    echo -e "         ${description}"
    [[ -n "$install_hint" ]] && echo -e "         ${YELLOW}Instalar:${NC} ${install_hint}"
    log "FAIL  $cmd  NOT_FOUND"
    ((FAIL++))
  fi
}

# Verifica acceso a un registry con podman/skopeo
check_registry() {
  local registry="$1"
  local description="$2"

  if command -v podman &>/dev/null; then
    if podman search "$registry/ubi9/ubi" --limit 1 &>/dev/null 2>&1; then
      echo -e "  ${GREEN}[PASS]${NC} Acceso a ${registry} verificado"
      log "PASS  registry_access  $registry"
      ((PASS++))
    else
      echo -e "  ${YELLOW}[WARN]${NC} No se pudo verificar acceso a ${registry} (puede requerir login)"
      echo -e "         ${description}"
      log "WARN  registry_access  $registry"
      ((WARN++))
    fi
  else
    echo -e "  ${YELLOW}[SKIP]${NC} Skipping registry check — podman no disponible"
    ((WARN++))
  fi
}

# Verifica que el pull secret es JSON válido
check_pull_secret() {
  local candidates=(
    "$HOME/pull-secret.txt"
    "$HOME/pull-secret.json"
    "/root/pull-secret.txt"
    "/root/pull-secret.json"
    "$HOME/.docker/config.json"
  )

  local found=0
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      if python3 -m json.tool "$f" &>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} Pull secret encontrado y JSON válido: ${f}"
        # Verificar que contiene los registries clave
        local registries
        registries=$(python3 -c "
import json, sys
with open('$f') as fp:
    d = json.load(fp)
auths = d.get('auths', {})
for r in ['registry.redhat.io','quay.io','cloud.openshift.com']:
    print('  ✓ ' + r if r in auths else '  ✗ FALTA: ' + r)
" 2>/dev/null)
        echo -e "${registries}"
        log "PASS  pull_secret  $f"
        ((PASS++))
        found=1
        break
      else
        echo -e "  ${RED}[FAIL]${NC} Pull secret encontrado pero JSON inválido: ${f}"
        log "FAIL  pull_secret  INVALID_JSON  $f"
        ((FAIL++))
        found=1
        break
      fi
    fi
  done

  if [[ $found -eq 0 ]]; then
    echo -e "  ${YELLOW}[WARN]${NC} Pull secret no encontrado en rutas estándar"
    echo -e "         Rutas buscadas: ${candidates[*]}"
    echo -e "         Descargar desde: https://console.redhat.com/openshift/downloads#tool-pull-secret"
    log "WARN  pull_secret  NOT_FOUND"
    ((WARN++))
  fi
}

# Verifica espacio en disco
check_disk_space() {
  local path="$1"
  local min_gb="$2"
  local description="$3"

  local available_kb
  available_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z "$available_kb" ]]; then
    echo -e "  ${YELLOW}[WARN]${NC} No se pudo verificar espacio en ${path}"
    ((WARN++))
    return
  fi

  local available_gb=$(( available_kb / 1024 / 1024 ))
  if [[ $available_gb -ge $min_gb ]]; then
    echo -e "  ${GREEN}[PASS]${NC} ${path} — ${available_gb} GB disponibles (mínimo: ${min_gb} GB)"
    log "PASS  disk_space  $path  ${available_gb}GB"
    ((PASS++))
  else
    echo -e "  ${RED}[FAIL]${NC} ${path} — solo ${available_gb} GB disponibles (mínimo: ${min_gb} GB)"
    log "FAIL  disk_space  $path  ${available_gb}GB"
    ((FAIL++))
  fi
}

# Verifica conectividad básica
check_connectivity() {
  local host="$1"
  local port="$2"
  local description="$3"

  if nc -z -w 5 "$host" "$port" &>/dev/null; then
    echo -e "  ${GREEN}[PASS]${NC} ${host}:${port} — alcanzable  (${description})"
    log "PASS  connectivity  $host:$port"
    ((PASS++))
  else
    echo -e "  ${RED}[FAIL]${NC} ${host}:${port} — ${RED}NO alcanzable${NC}  (${description})"
    log "FAIL  connectivity  $host:$port"
    ((FAIL++))
  fi
}

# ════════════════════════════════════════════════════════════
print_header "OCP 4.18 BASTION TOOLS PRE-CHECK — cluster: corenokia"
echo -e "  Bastion      : ${BOLD}$(hostname -f 2>/dev/null || hostname)${NC}"
echo -e "  OS           : ${BOLD}$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')${NC}"
echo -e "  Kernel       : ${BOLD}$(uname -r)${NC}"
echo -e "  Arquitectura : ${BOLD}$(uname -m)${NC}"
echo -e "  Usuario      : ${BOLD}$(whoami)${NC}"
echo -e "  Fecha/Hora   : ${BOLD}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "  Log file     : ${BOLD}${LOG_FILE}${NC}"

# ────────────────────────────────────────────────────────────
# 1. CLI DE OPENSHIFT
# ────────────────────────────────────────────────────────────
print_section "1. CLI OPENSHIFT"
check_tool "oc"      "version --client" "OpenShift CLI — gestión del clúster OCP"
check_tool "kubectl" "version --client" "Kubernetes CLI — alternativa a oc para recursos genéricos"

# Verificar que oc es >= 4.18
if command -v oc &>/dev/null; then
  OC_VER=$(oc version --client 2>/dev/null | grep -oP '[\d]+\.[\d]+' | head -1)
  if [[ -n "$OC_VER" ]]; then
    OC_MAJOR=$(echo "$OC_VER" | cut -d. -f1)
    OC_MINOR=$(echo "$OC_VER" | cut -d. -f2)
    if [[ "$OC_MAJOR" -ge 4 && "$OC_MINOR" -ge 18 ]]; then
      echo -e "  ${GREEN}[PASS]${NC} oc versión ${OC_VER} >= ${OCP_VERSION} ✓"
      log "PASS  oc_version_check  $OC_VER"
      ((PASS++))
    else
      echo -e "  ${YELLOW}[WARN]${NC} oc versión ${OC_VER} — se recomienda >= ${OCP_VERSION} para este despliegue"
      echo -e "         Descargar: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.18/"
      log "WARN  oc_version_check  $OC_VER"
      ((WARN++))
    fi
  fi
fi

# ────────────────────────────────────────────────────────────
# 2. HERRAMIENTAS DE CONTENEDORES
# ────────────────────────────────────────────────────────────
print_section "2. HERRAMIENTAS DE CONTENEDORES"
check_tool_simple "podman"  "Runtime de contenedores — pull/push de imágenes OCP" \
                  "dnf install -y podman"
check_tool_simple "skopeo"  "Inspección y copia de imágenes entre registries" \
                  "dnf install -y skopeo"
check_tool_simple "buildah" "Construcción de imágenes de contenedor (opcional)" \
                  "dnf install -y buildah"

# ────────────────────────────────────────────────────────────
# 3. HERRAMIENTAS DE RED
# ────────────────────────────────────────────────────────────
print_section "3. HERRAMIENTAS DE RED"
check_tool_simple "curl"    "Transferencia HTTP/HTTPS — validación de endpoints" \
                  "dnf install -y curl"
check_tool_simple "wget"    "Descarga de archivos — alternativa a curl" \
                  "dnf install -y wget"
check_tool_simple "dig"     "Resolución y diagnóstico DNS" \
                  "dnf install -y bind-utils"
check_tool_simple "nslookup" "Resolución DNS alternativa" \
                  "dnf install -y bind-utils"
check_tool_simple "nc"      "Verificación de puertos TCP/UDP (netcat)" \
                  "dnf install -y nmap-ncat"
check_tool_simple "nmap"    "Escaneo de puertos y red (opcional pero útil)" \
                  "dnf install -y nmap"
check_tool_simple "ssh"     "Acceso remoto a nodos del clúster" \
                  "dnf install -y openssh-clients"
check_tool_simple "scp"     "Transferencia segura de archivos a nodos" \
                  "dnf install -y openssh-clients"
check_tool_simple "nmcli"   "Gestión de red NetworkManager" \
                  "dnf install -y NetworkManager"

# ────────────────────────────────────────────────────────────
# 4. HERRAMIENTAS DE SISTEMA
# ────────────────────────────────────────────────────────────
print_section "4. HERRAMIENTAS DE SISTEMA"
check_tool_simple "jq"      "Procesamiento de JSON — útil para APIs y pull secret" \
                  "dnf install -y jq"
check_tool_simple "python3" "Python 3 — scripts de automatización y validación" \
                  "dnf install -y python3"
check_tool_simple "git"     "Control de versiones — manifiestos y configuraciones" \
                  "dnf install -y git"
check_tool_simple "tar"     "Descompresión de binarios OCP descargados" \
                  "dnf install -y tar"
check_tool_simple "vim"     "Editor de texto para archivos de configuración" \
                  "dnf install -y vim"
check_tool_simple "tmux"    "Multiplexor de terminal — mantener sesiones activas durante el deploy" \
                  "dnf install -y tmux"
check_tool_simple "rsync"   "Sincronización de archivos" \
                  "dnf install -y rsync"

# ────────────────────────────────────────────────────────────
# 5. PULL SECRET
# ────────────────────────────────────────────────────────────
print_section "5. PULL SECRET"
check_pull_secret

# ────────────────────────────────────────────────────────────
# 6. CLAVES SSH
# ────────────────────────────────────────────────────────────
print_section "6. CLAVES SSH"
if [[ -f "$HOME/.ssh/id_rsa.pub" ]] || [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  for key in "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$key" ]] && echo -e "  ${GREEN}[PASS]${NC} Clave pública SSH encontrada: ${key}" && ((PASS++))
  done
  echo -e "         Esta clave debe ingresarse en el campo SSH Public Key del Assisted Installer"
  log "PASS  ssh_key"
else
  echo -e "  ${YELLOW}[WARN]${NC} No se encontró clave SSH pública en ${HOME}/.ssh/"
  echo -e "         Generar con: ssh-keygen -t ed25519 -C 'bastion-corenokia'"
  log "WARN  ssh_key  NOT_FOUND"
  ((WARN++))
fi

# ────────────────────────────────────────────────────────────
# 7. ESPACIO EN DISCO
# ────────────────────────────────────────────────────────────
print_section "7. ESPACIO EN DISCO"
check_disk_space "/"     20  "Raíz del sistema — binarios y logs"
check_disk_space "/tmp"   5  "Directorio temporal — ISOs y descargas temporales"
check_disk_space "$HOME" 10  "Home del usuario — kubeconfig, pull secret, scripts"

# ────────────────────────────────────────────────────────────
# 8. CONECTIVIDAD DESDE EL BASTION
# ────────────────────────────────────────────────────────────
print_section "8. CONECTIVIDAD CLAVE DESDE EL BASTION"
check_connectivity "10.207.52.57"   53   "DNS Server del cluster"
check_connectivity "10.192.183.11"  22   "Master 01 — SSH"
check_connectivity "10.192.183.14"  22   "Worker 01 — SSH"
check_connectivity "console.redhat.com" 443 "Red Hat Hybrid Cloud Console"
check_connectivity "registry.redhat.io" 443 "Red Hat Registry"
check_connectivity "quay.io"            443 "Quay.io"

# ────────────────────────────────────────────────────────────
# 9. KUBECONFIG (si el cluster ya fue desplegado)
# ────────────────────────────────────────────────────────────
print_section "9. KUBECONFIG (post-deploy)"
KUBECONFIG_CANDIDATES=(
  "$HOME/.kube/config"
  "$HOME/auth/kubeconfig"
  "/root/.kube/config"
)
KUBE_FOUND=0
for kc in "${KUBECONFIG_CANDIDATES[@]}"; do
  if [[ -f "$kc" ]]; then
    echo -e "  ${GREEN}[PASS]${NC} kubeconfig encontrado: ${kc}"
    # Intentar conectar al API
    if KUBECONFIG="$kc" oc whoami &>/dev/null 2>&1; then
      CLUSTER_USER=$(KUBECONFIG="$kc" oc whoami 2>/dev/null)
      CLUSTER_URL=$(KUBECONFIG="$kc" oc whoami --show-server 2>/dev/null)
      echo -e "         Usuario activo : ${CLUSTER_USER}"
      echo -e "         API Server     : ${CLUSTER_URL}"
      log "PASS  kubeconfig  $kc  user=$CLUSTER_USER"
      ((PASS++))
    else
      echo -e "  ${YELLOW}[WARN]${NC} kubeconfig encontrado pero el API no responde (normal pre-deploy)"
      log "WARN  kubeconfig  $kc  API_UNREACHABLE"
      ((WARN++))
    fi
    KUBE_FOUND=1
    break
  fi
done
if [[ $KUBE_FOUND -eq 0 ]]; then
  echo -e "  ${YELLOW}[WARN]${NC} kubeconfig no encontrado — normal si el cluster aún no está desplegado"
  echo -e "         Post-deploy: exportar con export KUBECONFIG=<path>/auth/kubeconfig"
  log "WARN  kubeconfig  NOT_FOUND"
  ((WARN++))
fi

# ─── RESUMEN ────────────────────────────────────────────────
print_header "RESUMEN"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  Total de checks : ${BOLD}${TOTAL}${NC}"
echo -e "  ${GREEN}${BOLD}PASS${NC}            : ${PASS}"
echo -e "  ${RED}${BOLD}FAIL${NC}            : ${FAIL}"
echo -e "  ${YELLOW}${BOLD}WARN${NC}            : ${WARN}"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}✔  BASTION LISTO — todas las herramientas críticas disponibles.${NC}"
else
  echo -e "  ${RED}${BOLD}✘  HAY ${FAIL} HERRAMIENTA(S) FALTANTE(S) — instalar antes de continuar.${NC}"
  echo ""
  echo -e "  ${RED}${BOLD}Herramientas faltantes:${NC}"
  grep "^FAIL" "$LOG_FILE" | while IFS= read -r line; do
    echo -e "    ${RED}→${NC} $line"
  done
  echo ""
  echo -e "  ${YELLOW}Instalar todas las faltantes de una vez:${NC}"
  echo -e "    sudo dnf install -y bind-utils nmap-ncat podman skopeo buildah curl wget jq git tar vim tmux rsync nmap openssh-clients"
fi

if [[ $WARN -gt 0 ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠  ${WARN} advertencia(s) — revisar items en WARN antes del deploy.${NC}"
fi

echo ""
echo -e "  Log guardado en: ${BOLD}${LOG_FILE}${NC}"
echo ""
# ════════════════════════════════════════════════════════════
