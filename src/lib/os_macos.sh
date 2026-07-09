# os_macos.sh — macOS agent support (§4, agent-only). macOS is not a Zabbix
# server/proxy/frontend target; only the classic zabbix_agentd is shipped, as
# an official signed .pkg on cdn.zabbix.com. This module holds the pure helpers
# (arch mapping + release-URL builder); the Darwin detect branch and the
# download/install/launchd/health flow build on it.
#
# Verified against cdn.zabbix.com + an expanded .pkg (2026-07):
#   - The CDN publishes a self-updating "latest" pointer per major, mirroring
#     the Linux zabbix-release-latest idea:
#       https://cdn.zabbix.com/zabbix/binaries/stable/<major>/latest/
#         zabbix_agent-<major>-latest-macos-arm64[-openssl|-gnutls].pkg
#   - The .pkg is ARM64-ONLY: Zabbix ships no macOS amd64 .pkg (Intel macOS is
#     tar.gz-archive-only), so this path supports Apple Silicon. Both 7.0 and
#     7.4 offer the arm64 .pkg.
#   - the .pkg installs: /usr/local/sbin/zabbix_agentd,
#     /usr/local/etc/zabbix/zabbix_agentd.conf (ships as .conf.NEW),
#     /Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist; agent port 10050.

readonly ZBX_MACOS_CDN="https://cdn.zabbix.com/zabbix/binaries/stable"

# _macos_arch UNAME_M — map `uname -m` to the token Zabbix uses in its macOS
# package names. Fails (non-zero) on an arch Zabbix does not build for.
_macos_arch() {
  case "$1" in
    arm64 | aarch64) printf 'arm64' ;;
    x86_64 | amd64) printf 'amd64' ;;
    *) return 1 ;;
  esac
}

# zbx_macos_agent_url MAJOR ARCH [ENC] — pure: the self-updating "latest" .pkg
# URL for a MAJOR (e.g. 7.4) and a Zabbix macOS ARCH token. Zabbix only builds
# the macOS .pkg for arm64. ENC is the TLS backend: openssl (default), gnutls,
# or none (no suffix).
zbx_macos_agent_url() {
  local major="$1" arch="$2" enc="${3:-openssl}"
  local encsfx=""
  case "$enc" in
    openssl) encsfx="-openssl" ;;
    gnutls) encsfx="-gnutls" ;;
    none | "") encsfx="" ;;
  esac
  printf '%s/%s/latest/zabbix_agent-%s-latest-macos-%s%s.pkg' \
    "$ZBX_MACOS_CDN" "$major" "$major" "$arch" "$encsfx"
}

# Paths the .pkg installs (verified by expanding it). The conf path is an
# overridable test seam, matching ZBX_ETC_DIR on the Linux side.
: "${ZBX_MACOS_AGENT_CONF:=/usr/local/etc/zabbix/zabbix_agentd.conf}"
: "${ZBX_MACOS_AGENT_PLIST:=/Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist}"
readonly ZBX_MACOS_AGENT_LABEL="com.zabbix.zabbix_agentd"

# macos_agent_install — download the signed .pkg and install it. run() makes
# every system command DRY_RUN-aware. Integrity is the .pkg's Apple Developer
# ID signature (verified to be Zabbix's), not a hash: the self-updating
# "latest" build has no stable checksum to pin.
macos_agent_install() {
  local url pkg base
  url="$(zbx_macos_agent_url "$PLAN_ZBX_VERSION" arm64 openssl)"
  # installer(8) validates the extension and rejects a path not ending in
  # .pkg ("package path specified was invalid"); BSD mktemp can't add a suffix,
  # so append one. Register both the bare temp file and the .pkg for cleanup.
  base="$(mktemp -t zbx-macos-agent 2>/dev/null || echo "/tmp/zbx-macos-agent.$$")"
  pkg="${base}.pkg"
  ZBX_TEMPFILES+=("$base" "$pkg")
  log INFO "macOS agent package: $url"
  run curl -fsSL -o "$pkg" "$url" || return 1
  if [[ "$DRY_RUN" != "1" ]]; then
    if ! pkgutil --check-signature "$pkg" 2>/dev/null | grep -qi 'zabbix'; then
      log ERROR "macOS agent package is not signed by Zabbix — refusing to install"
      return 1
    fi
  fi
  run installer -pkg "$pkg" -target / || return 1
}

# macos_agent_config — point the agent at its server. The .pkg seeds
# zabbix_agentd.conf.NEW on a fresh install; promote it, then set the keys.
macos_agent_config() {
  local conf="$ZBX_MACOS_AGENT_CONF" hn
  hn="$(hostname 2>/dev/null || echo zabbix-agent)"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  + configure %s (Server/ServerActive=%s, Hostname=%s)\n' \
      "$conf" "$PLAN_ZBX_SERVER_IP" "$hn"
    return 0
  fi
  if [[ ! -f "$conf" && -f "${conf}.NEW" ]]; then
    cp "${conf}.NEW" "$conf" || return 1
  fi
  set_conf "$conf" Server "$PLAN_ZBX_SERVER_IP" || return 1
  set_conf "$conf" ServerActive "$PLAN_ZBX_SERVER_IP" || return 1
  set_conf "$conf" Hostname "$hn" || return 1
}

# macos_agent_service — load + enable the LaunchDaemon the .pkg installed
# (the .pkg postinstall may already have; bootstrap-then-load is idempotent
# enough, and macos_agent_health is the real gate).
macos_agent_service() {
  run launchctl bootstrap system "$ZBX_MACOS_AGENT_PLIST" ||
    run launchctl load -w "$ZBX_MACOS_AGENT_PLIST" || true
}

# macos_agent_health — confirm the agent is listening on 10050. macOS has no
# ss; use lsof. Polls like health.sh's Linux port check (§13).
macos_agent_health() {
  if [[ "$DRY_RUN" == "1" ]]; then
    _health_record "agent (port 10050)" 0 ""
    return 0
  fi
  local tries="${ZBX_HEALTH_PORT_TRIES:-15}" i
  for ((i = 1; i <= tries; i++)); do
    if lsof -nP -iTCP:10050 -sTCP:LISTEN >/dev/null 2>&1; then
      _health_record "agent (port 10050)" 0 ""
      return 0
    fi
    ((i < tries)) && sleep 1
  done
  _health_record "agent (port 10050)" 1 "launchctl print system/${ZBX_MACOS_AGENT_LABEL}"
}

# macos_agent_run — the macOS analog of run_pipeline: install → configure →
# start → health. Fails LOUD (die, exit 5) if the install/config step fails —
# never falls through to a health summary on an install that never happened.
# The health result is recorded (not propagated); macos_main_flow reads the
# summary to decide the exit code.
macos_agent_run() {
  macos_agent_install || die "macOS agent download/install failed — see ${LOG_FILE}" 5
  macos_agent_config || die "configuring the macOS agent failed — see ${LOG_FILE}" 5
  macos_agent_service
  macos_agent_health || true
}
