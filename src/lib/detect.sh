# shellcheck shell=bash
# detect.sh — environment scan → DETECT_* variables + a report table.
#
# Contract:
#   inputs  : ${OS_RELEASE_FILE:-/etc/os-release} (override exists so bats can
#             inject fixtures), plus the live host (uname, /proc, df, systemctl,
#             ss, getenforce, systemd-detect-virt). DETECT_SKIP_NET=1 skips the
#             repo.zabbix.com probe (used by container smoke tests).
#   outputs : sets the DETECT_* globals (made readonly by detect_run) and, via
#             detect_report, prints the --detect-only table. Pure OS functions
#             (detect_os/family/supported) touch nothing but OS_RELEASE_FILE, so
#             they are unit-testable with fixtures.

# The one place the offered Zabbix versions live (§4). Adding 8.0 LTS later is a
# one-line change here.
readonly SUPPORTED_ZBX_VERSIONS=("7.0" "7.4")

# --- DETECT_* defaults (keep set -u happy before/if a probe is skipped) ------
DETECT_OS_ID="" DETECT_OS_LIKE="" DETECT_OS_VERSION="" DETECT_OS_MAJOR=""
DETECT_OS_NAME="" DETECT_FAMILY="unknown" DETECT_SUPPORTED="no"
DETECT_PKGMGR="" DETECT_PKGMGR_OK="no" DETECT_ARCH="" DETECT_ARCH_OK="no"
DETECT_RAM_MB=0 DETECT_CPU=0 DETECT_DISK_VAR_GB=0 DETECT_DISK_ROOT_GB=0
DETECT_DISK_WARN="no" DETECT_NET_OK="unknown" DETECT_ZBX_PRESENT="no"
DETECT_DB_PRESENT="none" DETECT_WEB_PRESENT="none" DETECT_SELINUX="absent"
DETECT_FIREWALL="none" DETECT_PORT_CONFLICTS="none" DETECT_VIRT="none"
DETECT_IS_CONTAINER="no"

# --- OS release parsing (pure) ----------------------------------------------
# _osr_get KEY FILE — echo the value of KEY, stripping surrounding quotes.
# Uses sed (not sourcing) so an untrusted os-release cannot execute anything.
_osr_get() {
  local key="$1" file="$2" val
  val="$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n1)"
  val="${val%\"}"
  val="${val#\"}"
  printf '%s' "$val"
}

detect_os() {
  local f="${OS_RELEASE_FILE:-/etc/os-release}"
  if [[ ! -r "$f" ]]; then
    DETECT_OS_ID="unknown"
    return 1
  fi
  DETECT_OS_ID="$(_osr_get ID "$f")"
  DETECT_OS_LIKE="$(_osr_get ID_LIKE "$f")"
  DETECT_OS_VERSION="$(_osr_get VERSION_ID "$f")"
  DETECT_OS_MAJOR="${DETECT_OS_VERSION%%.*}"
  DETECT_OS_NAME="$(_osr_get PRETTY_NAME "$f")"
  [[ -n "$DETECT_OS_ID" ]] || DETECT_OS_ID="unknown"
}

# _family_from_like — best-effort family from ID_LIKE tokens (§4 fallback).
_family_from_like() {
  case " $DETECT_OS_LIKE " in
    *debian*) echo debian ;;
    *rhel* | *fedora*) echo rhel ;;
    *suse*) echo suse ;;
    *) echo unknown ;;
  esac
}

detect_family() {
  case "$DETECT_OS_ID" in
    debian | ubuntu | raspbian) DETECT_FAMILY="debian" ;;
    rhel | centos | rocky | almalinux | ol | amzn | fedora) DETECT_FAMILY="rhel" ;;
    sles | opensuse-leap | opensuse | sled) DETECT_FAMILY="suse" ;;
    *) DETECT_FAMILY="$(_family_from_like)" ;;
  esac
}

# detect_supported — is this exact ID/version in the v1 support matrix (§4)?
detect_supported() {
  local v="$DETECT_OS_VERSION" m="$DETECT_OS_MAJOR" minor
  minor="${v#*.}"
  [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
  DETECT_SUPPORTED="no"
  case "$DETECT_OS_ID" in
    debian) [[ "$m" == 12 || "$m" == 13 ]] && DETECT_SUPPORTED="yes" ;;
    ubuntu) [[ "$v" == 22.04 || "$v" == 24.04 ]] && DETECT_SUPPORTED="yes" ;;
    rhel | centos | rocky | almalinux | ol) [[ "$m" == 8 || "$m" == 9 ]] && DETECT_SUPPORTED="yes" ;;
    sles) [[ "$m" == 15 && "$minor" -ge 5 ]] && DETECT_SUPPORTED="yes" ;;
    opensuse-leap) [[ "$v" == 15.6 ]] && DETECT_SUPPORTED="yes" ;;
  esac
  return 0
}

# --- package manager (host) --------------------------------------------------
_pkgmgr_for_family() {
  case "$1" in
    debian) echo apt ;;
    rhel) echo dnf ;;
    suse) echo zypper ;;
    *) echo "" ;;
  esac
}

detect_pkgmgr() {
  if command -v apt-get >/dev/null 2>&1; then
    DETECT_PKGMGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    DETECT_PKGMGR="dnf"
  elif command -v zypper >/dev/null 2>&1; then
    DETECT_PKGMGR="zypper"
  fi
  [[ "$DETECT_PKGMGR" == "$(_pkgmgr_for_family "$DETECT_FAMILY")" && -n "$DETECT_PKGMGR" ]] &&
    DETECT_PKGMGR_OK="yes"
  return 0
}

# --- architecture (host, class is pure) -------------------------------------
# _arch_class ARCH — yes (supported), maybe (repo-dependent, §15.10), or no.
_arch_class() {
  case "$1" in
    x86_64 | amd64) echo yes ;;
    aarch64 | arm64) echo maybe ;;
    *) echo no ;;
  esac
}

detect_arch() {
  DETECT_ARCH="$(uname -m)"
  DETECT_ARCH_OK="$(_arch_class "$DETECT_ARCH")"
}

# --- hardware / disk (host) --------------------------------------------------
detect_hw() {
  if [[ -r /proc/meminfo ]]; then
    DETECT_RAM_MB="$(awk '/^MemTotal:/ {print int($2/1024); exit}' /proc/meminfo)"
  fi
  if command -v nproc >/dev/null 2>&1; then
    DETECT_CPU="$(nproc)"
  elif [[ -r /proc/cpuinfo ]]; then
    DETECT_CPU="$(grep -c '^processor' /proc/cpuinfo)"
  fi
  : "${DETECT_RAM_MB:=0}" "${DETECT_CPU:=0}"
}

_disk_avail_gb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'
}

detect_disk() {
  DETECT_DISK_VAR_GB="$(_disk_avail_gb /var)"
  DETECT_DISK_ROOT_GB="$(_disk_avail_gb /)"
  : "${DETECT_DISK_VAR_GB:=0}" "${DETECT_DISK_ROOT_GB:=0}"
  ((DETECT_DISK_VAR_GB < 10)) && DETECT_DISK_WARN="yes"
  return 0
}

# --- network (host) — probe repo.zabbix.com reachability (§8) ----------------
detect_network() {
  local url="https://repo.zabbix.com/"
  if [[ "${DETECT_SKIP_NET:-0}" == "1" ]]; then
    DETECT_NET_OK="skipped"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -sI --max-time 8 "$url" >/dev/null 2>&1; then
      DETECT_NET_OK="yes"
    else
      DETECT_NET_OK="no"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --spider --timeout=8 "$url"; then
      DETECT_NET_OK="yes"
    else
      DETECT_NET_OK="no"
    fi
  else
    DETECT_NET_OK="no"
  fi
}

# --- existing Zabbix / DB / web (host) --------------------------------------
detect_existing() {
  if systemctl list-unit-files 'zabbix*' 2>/dev/null | grep -q '^zabbix' ||
    command -v zabbix_server >/dev/null 2>&1 ||
    command -v zabbix_agent2 >/dev/null 2>&1; then
    DETECT_ZBX_PRESENT="yes"
  fi

  local dbs=()
  command -v mariadb >/dev/null 2>&1 && dbs+=("mariadb")
  command -v mysql >/dev/null 2>&1 && dbs+=("mysql")
  command -v psql >/dev/null 2>&1 && dbs+=("pgsql")
  if ((${#dbs[@]})); then
    local IFS=,
    DETECT_DB_PRESENT="${dbs[*]}"
  fi

  local webs=()
  if command -v httpd >/dev/null 2>&1 || command -v apache2 >/dev/null 2>&1; then
    webs+=("apache")
  fi
  command -v nginx >/dev/null 2>&1 && webs+=("nginx")
  if ((${#webs[@]})); then
    local IFS=,
    DETECT_WEB_PRESENT="${webs[*]}"
  fi
  return 0
}

# --- SELinux / firewall / ports / virt (host) --------------------------------
detect_selinux() {
  if command -v getenforce >/dev/null 2>&1; then
    DETECT_SELINUX="$(getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    : "${DETECT_SELINUX:=absent}"
  fi
}

detect_firewall() {
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    DETECT_FIREWALL="firewalld"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'status: active'; then
    DETECT_FIREWALL="ufw"
  else
    DETECT_FIREWALL="none"
  fi
}

detect_ports() {
  if ! command -v ss >/dev/null 2>&1; then
    DETECT_PORT_CONFLICTS="unknown"
    return 0
  fi
  local conflicts=() p
  for p in 80 443 10050 10051; do
    if ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
      conflicts+=("$p")
    fi
  done
  if ((${#conflicts[@]})); then
    local IFS=,
    DETECT_PORT_CONFLICTS="${conflicts[*]}"
  else
    DETECT_PORT_CONFLICTS="none"
  fi
}

detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    DETECT_VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    : "${DETECT_VIRT:=none}"
    if systemd-detect-virt --container >/dev/null 2>&1; then
      DETECT_IS_CONTAINER="yes"
    fi
  fi
}

# --- orchestration -----------------------------------------------------------
detect_run() {
  detect_os || true
  detect_family
  detect_supported
  detect_pkgmgr
  detect_arch
  detect_hw
  detect_disk
  detect_network
  detect_existing
  detect_selinux
  detect_firewall
  detect_ports
  detect_virt
  readonly DETECT_OS_ID DETECT_OS_LIKE DETECT_OS_VERSION DETECT_OS_MAJOR \
    DETECT_OS_NAME DETECT_FAMILY DETECT_SUPPORTED DETECT_PKGMGR DETECT_PKGMGR_OK \
    DETECT_ARCH DETECT_ARCH_OK DETECT_RAM_MB DETECT_CPU DETECT_DISK_VAR_GB \
    DETECT_DISK_ROOT_GB DETECT_DISK_WARN DETECT_NET_OK DETECT_ZBX_PRESENT \
    DETECT_DB_PRESENT DETECT_WEB_PRESENT DETECT_SELINUX DETECT_FIREWALL \
    DETECT_PORT_CONFLICTS DETECT_VIRT DETECT_IS_CONTAINER
  log INFO "detected: ${DETECT_OS_ID} ${DETECT_OS_VERSION} (${DETECT_FAMILY}), pkgmgr=${DETECT_PKGMGR}, arch=${DETECT_ARCH}, supported=${DETECT_SUPPORTED}"
}

# _row LABEL VALUE [COLOR] — one aligned report line, optionally colored.
_row() {
  local color="${3:-}"
  if [[ -n "$color" ]]; then
    printf '  %-16s %s%s%s\n' "$1" "$color" "$2" "$C_RESET"
  else
    printf '  %-16s %s\n' "$1" "$2"
  fi
}

detect_report() {
  # Global IFS is $'\n\t' (core.sh); use a space so array [*] joins render inline.
  local IFS=' '
  local sup_color="" arch_color="" disk_color="" net_color=""
  [[ "$DETECT_SUPPORTED" == "no" ]] && sup_color="$C_RED"
  [[ "$DETECT_ARCH_OK" == "no" ]] && arch_color="$C_RED"
  [[ "$DETECT_ARCH_OK" == "maybe" ]] && arch_color="$C_YELLOW"
  [[ "$DETECT_DISK_WARN" == "yes" ]] && disk_color="$C_YELLOW"
  [[ "$DETECT_NET_OK" == "no" ]] && net_color="$C_RED"

  printf '%sEnvironment report%s\n' "$C_BOLD" "$C_RESET"
  _row "OS:" "$DETECT_OS_NAME"
  _row "ID / version:" "${DETECT_OS_ID} / ${DETECT_OS_VERSION}"
  _row "Family:" "$DETECT_FAMILY"
  _row "Supported:" "$DETECT_SUPPORTED" "$sup_color"
  _row "Pkg manager:" "${DETECT_PKGMGR:-none} (ok=${DETECT_PKGMGR_OK})"
  _row "Arch:" "${DETECT_ARCH} (ok=${DETECT_ARCH_OK})" "$arch_color"
  _row "RAM / CPU:" "${DETECT_RAM_MB} MB / ${DETECT_CPU} vCPU"
  _row "Disk /var,/:" "${DETECT_DISK_VAR_GB},${DETECT_DISK_ROOT_GB} GiB free" "$disk_color"
  _row "Repo reachable:" "$DETECT_NET_OK" "$net_color"
  _row "Existing Zabbix:" "$DETECT_ZBX_PRESENT"
  _row "Existing DB:" "$DETECT_DB_PRESENT"
  _row "Existing web:" "$DETECT_WEB_PRESENT"
  _row "SELinux:" "$DETECT_SELINUX"
  _row "Firewall:" "$DETECT_FIREWALL"
  _row "Port conflicts:" "$DETECT_PORT_CONFLICTS"
  _row "Virtualization:" "${DETECT_VIRT} (container=${DETECT_IS_CONTAINER})"
  printf '  %-16s %s\n' "Zabbix offered:" "${SUPPORTED_ZBX_VERSIONS[*]}"

  [[ "$DETECT_IS_CONTAINER" == "yes" ]] &&
    printf '%s  note: container detected — systemd services may not work (§8, §15.12)%s\n' \
      "$C_YELLOW" "$C_RESET"
  return 0
}
