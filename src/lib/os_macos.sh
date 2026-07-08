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
