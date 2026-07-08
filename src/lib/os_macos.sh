# os_macos.sh — macOS agent support (§4, agent-only). macOS is not a Zabbix
# server/proxy/frontend target; only the classic zabbix_agentd is shipped, as
# an official signed .pkg on cdn.zabbix.com. This module holds the pure helpers
# (arch mapping + release-URL builder); the Darwin detect branch and the
# download/install/launchd/health flow build on it.
#
# Verified against cdn.zabbix.com + an expanded .pkg (2026-07):
#   - URL:  https://cdn.zabbix.com/zabbix/binaries/stable/<major>/<release>/
#           zabbix_agent-<release>-macos-<arch>[-openssl|-gnutls].pkg
#   - arch: arm64 (Apple Silicon) and amd64 (Intel); .pkg for 7.4 (7.0 is
#           archive-only on arm64), resolved at run time by a HEAD probe.
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

# zbx_macos_agent_url RELEASE ARCH [ENC] — pure: the .pkg URL for a full
# x.y.z RELEASE and a Zabbix macOS ARCH token (arm64|amd64). ENC is the TLS
# backend: openssl (default), gnutls, or none (no suffix).
zbx_macos_agent_url() {
  local release="$1" arch="$2" enc="${3:-openssl}"
  local major="${release%.*}" encsfx=""
  case "$enc" in
    openssl) encsfx="-openssl" ;;
    gnutls) encsfx="-gnutls" ;;
    none | "") encsfx="" ;;
  esac
  printf '%s/%s/%s/zabbix_agent-%s-macos-%s%s.pkg' \
    "$ZBX_MACOS_CDN" "$major" "$release" "$release" "$arch" "$encsfx"
}
