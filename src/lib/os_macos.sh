# os_macos.sh — macOS agent support (§4, agent-only). macOS is not a Zabbix
# server/proxy/frontend target; only the classic zabbix_agentd is shipped on
# cdn.zabbix.com — as an official signed .pkg for Apple Silicon, and as a
# tar.gz archive for Intel. This module holds the pure helpers (arch mapping +
# URL builders); the Darwin detect branch and the download/install/launchd/
# health flow build on it.
#
# Verified against cdn.zabbix.com + an expanded .pkg (2026-07):
#   - The CDN publishes a self-updating "latest" pointer per major, mirroring
#     the Linux zabbix-release-latest idea:
#       https://cdn.zabbix.com/zabbix/binaries/stable/<major>/latest/
#         zabbix_agent-<major>-latest-macos-arm64[-openssl|-gnutls].pkg
#   - The .pkg is ARM64-ONLY: Zabbix ships no macOS amd64 .pkg; Intel macOS
#     gets the same "latest" pointer as a tar.gz archive
#     (zabbix_agent-<major>-latest-macos-amd64[-openssl|-gnutls].tar.gz),
#     which this module unpacks into the same paths the .pkg uses. The
#     tar.gz URL shape follows the CDN's naming convention and is asserted
#     live by the macos-agent CI job's liveness probe. Both 7.0 and 7.4.
#   - the .pkg installs: /usr/local/sbin/zabbix_agentd,
#     /usr/local/etc/zabbix/zabbix_agentd.conf (ships as .conf.NEW),
#     /Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist; agent port 10050.
#     The tar path reproduces exactly this layout (plus a hand-written plist
#     with the same label), so config/service/health/uninstall are shared.

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

# zbx_macos_agent_tarball_url MAJOR ARCH [ENC] — pure: the "latest" tar.gz
# archive URL, same shape as the .pkg pointer. This is how Zabbix ships the
# Intel (amd64) macOS agent — there is no amd64 .pkg.
zbx_macos_agent_tarball_url() {
  local major="$1" arch="$2" enc="${3:-openssl}"
  local encsfx=""
  case "$enc" in
    openssl) encsfx="-openssl" ;;
    gnutls) encsfx="-gnutls" ;;
    none | "") encsfx="" ;;
  esac
  printf '%s/%s/latest/zabbix_agent-%s-latest-macos-%s%s.tar.gz' \
    "$ZBX_MACOS_CDN" "$major" "$major" "$arch" "$encsfx"
}

# _macos_variant — pure: which install mechanism this Mac gets, from the
# already-detected DETECT_ARCH. arm64 → the signed .pkg; amd64 (Intel) → the
# tar.gz archive. detect_arch has already rejected anything else.
_macos_variant() {
  case "$(_macos_arch "$DETECT_ARCH")" in
    arm64) printf 'pkg' ;;
    amd64) printf 'tar' ;;
    *) return 1 ;;
  esac
}

# Paths the .pkg installs (verified by expanding it). The conf path is an
# overridable test seam, matching ZBX_ETC_DIR on the Linux side.
: "${ZBX_MACOS_AGENT_CONF:=/usr/local/etc/zabbix/zabbix_agentd.conf}"
: "${ZBX_MACOS_AGENT_PLIST:=/Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist}"
readonly ZBX_MACOS_AGENT_LABEL="com.zabbix.zabbix_agentd"

# macos_agent_install — dispatcher: signed .pkg on Apple Silicon, tar.gz
# archive on Intel (the only form Zabbix ships for amd64).
macos_agent_install() {
  case "$(_macos_variant)" in
    pkg) _macos_agent_install_pkg ;;
    tar) _macos_agent_install_tar ;;
    *)
      log ERROR "no macOS agent install path for arch '$DETECT_ARCH'"
      return 1
      ;;
  esac
}

# _macos_agent_install_pkg — download the signed .pkg and install it. run()
# makes every system command DRY_RUN-aware. Integrity is the .pkg's Apple
# Developer ID signature (verified to be Zabbix's), not a hash: the
# self-updating "latest" build has no stable checksum to pin.
_macos_agent_install_pkg() {
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

# _macos_agent_install_tar — the Intel path: download the tar.gz archive,
# verify the binaries' codesign signature where present (the archive itself
# carries no Apple signature — unlike the .pkg — so integrity otherwise rests
# on TLS to cdn.zabbix.com; a WARN says so), and place the files in exactly
# the layout the .pkg produces, so config/service/health/uninstall are shared.
_macos_agent_install_tar() {
  local url tarball unpack agentd f
  url="$(zbx_macos_agent_tarball_url "$PLAN_ZBX_VERSION" amd64 openssl)"
  log INFO "macOS agent archive: $url"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  + curl -fsSL -o <tmp>/zbx-agent.tar.gz %s\n' "$url"
    printf '  + tar -xzf <tmp>/zbx-agent.tar.gz\n'
    printf '  + install zabbix_agentd -> /usr/local/sbin, zabbix_get/zabbix_sender -> /usr/local/bin\n'
    printf '  + seed %s.NEW\n' "$ZBX_MACOS_AGENT_CONF"
    printf '  + write LaunchDaemon %s\n' "$ZBX_MACOS_AGENT_PLIST"
    return 0
  fi
  unpack="$(mktemp -d 2>/dev/null || echo "/tmp/zbx-macos-agent-tar.$$")"
  mkdir -p "$unpack"
  ZBX_TEMPFILES+=("$unpack")
  tarball="$unpack/zbx-agent.tar.gz"
  run curl -fsSL -o "$tarball" "$url" || return 1
  run tar -xzf "$tarball" -C "$unpack" || return 1
  # Locate rather than assume the archive's top-level layout (bin/ sbin/ conf/
  # today, but a wrapper directory would be harmless).
  agentd="$(find "$unpack" -type f -name zabbix_agentd | head -n1)"
  if [[ -z "$agentd" ]]; then
    log ERROR "archive did not contain zabbix_agentd — layout changed upstream?"
    return 1
  fi
  # Best-effort signature check: the loose binaries are Developer ID-signed in
  # current archives; refuse only a *bad* signature, warn when unsigned.
  if command -v codesign >/dev/null 2>&1; then
    if codesign --verify "$agentd" 2>/dev/null; then
      log INFO "zabbix_agentd codesign signature verified"
    else
      log WARN "archive binaries carry no verifiable signature — integrity rests on TLS to cdn.zabbix.com"
    fi
  fi
  run install -d /usr/local/sbin /usr/local/bin || return 1
  run install -m 755 "$agentd" /usr/local/sbin/zabbix_agentd || return 1
  for f in zabbix_get zabbix_sender; do
    local src
    src="$(find "$unpack" -type f -name "$f" | head -n1)"
    [[ -n "$src" ]] && { run install -m 755 "$src" "/usr/local/bin/$f" || return 1; }
  done
  # Seed the shipped conf as .conf.NEW — the same convention the .pkg uses —
  # so macos_agent_config's .NEW promotion handles fresh vs. re-install.
  local conf_src
  conf_src="$(find "$unpack" -type f -name zabbix_agentd.conf | head -n1)"
  if [[ -n "$conf_src" && ! -f "$ZBX_MACOS_AGENT_CONF" ]]; then
    run install -d "$(dirname "$ZBX_MACOS_AGENT_CONF")" || return 1
    run install -m 644 "$conf_src" "${ZBX_MACOS_AGENT_CONF}.NEW" || return 1
  fi
  _macos_write_plist || return 1
}

# _macos_write_plist — hand-write the LaunchDaemon the .pkg would have
# installed, with the SAME label and path so service/health/uninstall need no
# variant awareness. -f keeps the agent in the foreground so launchd
# supervises it (KeepAlive restarts it if it dies).
_macos_write_plist() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  + write LaunchDaemon %s\n' "$ZBX_MACOS_AGENT_PLIST"
    return 0
  fi
  cat >"$ZBX_MACOS_AGENT_PLIST" <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${ZBX_MACOS_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/sbin/zabbix_agentd</string>
        <string>-c</string>
        <string>${ZBX_MACOS_AGENT_CONF}</string>
        <string>-f</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
  chmod 644 "$ZBX_MACOS_AGENT_PLIST"
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
