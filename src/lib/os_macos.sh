# os_macos.sh — macOS agent support (§4, agent-only). macOS is not a Zabbix
# server/proxy/frontend target; only the classic zabbix_agentd is shipped, as
# an official signed .pkg on cdn.zabbix.com. This module holds the pure helpers
# (arch mapping + release-URL builder); the Darwin detect branch and the
# download/install/launchd/health flow build on it.
#
# Verified against cdn.zabbix.com + an expanded .pkg (2026-07, re-verified via
# the CI CDN-listing diagnostic 2026-07-10):
#   - The CDN publishes a self-updating "latest" pointer per major, mirroring
#     the Linux zabbix-release-latest idea:
#       https://cdn.zabbix.com/zabbix/binaries/stable/<major>/latest/
#         zabbix_agent-<major>-latest-macos-arm64[-openssl|-gnutls].pkg
#   - macOS artifacts are ARM64-ONLY across the board: the latest listing has
#     no macos-amd64 file in ANY form (.pkg or tar.gz), so Intel Macs cannot
#     be supported at all for 7.x. Both 7.0 and 7.4 offer the arm64 .pkg.
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

# _macos_curl_reason RC — curl's exit code as a sentence a human can act on.
# curl already runs with -fsSL (the S is --show-error), so curl's own message
# lands in the log via run(); this is what gets said on the CONSOLE, where the
# user actually is.
_macos_curl_reason() {
  case "$1" in
    6) printf 'DNS lookup for cdn.zabbix.com failed' ;;
    7) printf 'could not connect to cdn.zabbix.com' ;;
    18) printf 'the transfer ended early — the connection dropped mid-download' ;;
    22) printf 'the CDN returned an HTTP error (404/403/5xx)' ;;
    23) printf 'could not write the downloaded file to disk' ;;
    28) printf 'the download timed out' ;;
    35 | 60 | 77) printf 'the TLS handshake failed — something is intercepting HTTPS' ;;
    56) printf 'the connection was reset mid-transfer — a proxy, VPN or content filter cut it' ;;
    *) printf 'curl failed' ;;
  esac
}

# macos_agent_install — download the signed .pkg and install it. run() makes
# every system command DRY_RUN-aware. Integrity is the .pkg's Apple Developer
# ID signature (verified to be Zabbix's), not a hash: the self-updating
# "latest" build has no stable checksum to pin.
#
# The download is ~12 MB over a single TLS connection — the exact traffic shape
# that filtering middleboxes and flaky links cut mid-transfer — so it is
# bounded by timeouts and retried with -C - (resume), and every failure says
# which of the three steps failed and why. A one-line-per-step bare `return 1`
# used to make all three indistinguishable to the caller.
macos_agent_install() {
  local url pkg base rc=0 attempt bytes="" magic sig chain
  url="$(zbx_macos_agent_url "$PLAN_ZBX_VERSION" arm64 openssl)"
  # installer(8) validates the extension and rejects a path not ending in
  # .pkg ("package path specified was invalid"); BSD mktemp can't add a suffix,
  # so append one. Register both the bare temp file and the .pkg for cleanup.
  base="$(mktemp -t zbx-macos-agent 2>/dev/null || echo "/tmp/zbx-macos-agent.$$")"
  pkg="${base}.pkg"
  ZBX_TEMPFILES+=("$base" "$pkg")
  log INFO "macOS agent package: $url"
  for attempt in 1 2 3; do
    rc=0
    # -w appends a transfer summary that run() folds into the log, so the log
    # records http=/bytes= even when curl's own message is vague. -C - resumes
    # a partial file (a no-op at offset 0); the CDN serves ranges.
    run curl -fsSL --connect-timeout 15 --max-time 900 -C - \
      -w 'curl: http=%{http_code} bytes=%{size_download} time=%{time_total}s\n' \
      -o "$pkg" "$url" || rc=$?
    ((rc == 0)) && break
    bytes="$(wc -c <"$pkg" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    log WARN "agent download attempt ${attempt}/3 failed (curl exit ${rc}, ${bytes:-0} bytes so far)"
    # An explicit loop rather than curl's --retry: the errors this guards
    # against (18 partial, 56 reset) are not in curl's transient set on older
    # curls, so --retry alone would not retry them.
    if ((attempt < 3)); then sleep 3; fi
  done
  if ((rc != 0)); then
    log ERROR "downloading the agent package failed: $(_macos_curl_reason "$rc") (curl exit $rc) — $url"
    return 1
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    bytes="$(wc -c <"$pkg" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    # A flat .pkg is a xar archive. An HTML error page, a captive-portal login
    # or an empty 200 body all satisfy `curl -f` and fail here. Checked BEFORE
    # pkgutil on purpose: pkgutil's "could not open package" would otherwise be
    # reported as "not signed by Zabbix", sending the user after the wrong bug.
    magic="$(head -c 4 "$pkg" 2>/dev/null || true)"
    if [[ "$magic" != 'xar!' ]]; then
      log ERROR "the downloaded file is not a macOS package (${bytes:-0} bytes, magic '${magic}') — $url"
      return 1
    fi
    # Captured, not piped into `grep -q`: under pipefail (core.sh) a grep that
    # matches and exits early can SIGPIPE pkgutil, so the pipeline returns 141
    # and a correctly signed package is rejected. Capturing also keeps
    # pkgutil's own stderr instead of discarding the real reason.
    sig="$(pkgutil --check-signature "$pkg" 2>&1)" || true
    log INFO "pkgutil --check-signature: $sig"
    # Match below the first line only: pkgutil echoes the package path there,
    # so a whole-output match could be satisfied by the temp filename alone.
    if [[ "$sig" == *$'\n'* ]]; then chain="${sig#*$'\n'}"; else chain=""; fi
    if [[ "$(printf '%s' "$chain" | tr '[:upper:]' '[:lower:]')" != *zabbix* ]]; then
      log ERROR "macOS agent package is not signed by Zabbix — refusing to install (pkgutil: ${sig%%$'\n'*})"
      return 1
    fi
  fi
  run installer -pkg "$pkg" -target / || {
    log ERROR "installer(8) refused the package (${bytes:-unknown} bytes from $url) — its output is in the log above"
    return 1
  }
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
  # macos_agent_install has already logged an ERROR naming the step that failed
  # and why; die() prints the log tail, so that reason is on screen above this.
  macos_agent_install || die "macOS agent installation failed (reason above)" 5
  macos_agent_config || die "configuring the macOS agent failed — see ${LOG_FILE}" 5
  macos_agent_service
  macos_agent_health || true
}

# macos_agent_uninstall — remove what the .pkg installed: stop + unload the
# LaunchDaemon, delete the binaries/config, and forget any zabbix pkg receipts.
# Best-effort (each step logged via run()); only touches Zabbix-owned paths.
# main() routes --uninstall here on macOS in place of the Linux uninstall_run.
macos_agent_uninstall() {
  run launchctl bootout system "$ZBX_MACOS_AGENT_PLIST" || true
  run rm -f "$ZBX_MACOS_AGENT_PLIST" \
    /usr/local/sbin/zabbix_agentd /usr/local/bin/zabbix_get /usr/local/bin/zabbix_sender
  run rm -rf /usr/local/etc/zabbix
  if [[ "$DRY_RUN" != "1" ]]; then
    local pid
    for pid in $(pkgutil --pkgs 2>/dev/null | grep -i zabbix || true); do
      run pkgutil --forget "$pid" || true
    done
  fi
  printf 'Removed the Zabbix macOS agent (binaries, config, LaunchDaemon).\n'
}
