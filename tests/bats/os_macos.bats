#!/usr/bin/env bats
# Unit tests for os_macos.sh pure helpers — the macOS agent arch map + release
# URL builder. Verified live against cdn.zabbix.com (2026-07). Sourced inside a
# `bash -c` subshell (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
CONFIG="${BATS_TEST_DIRNAME}/../../src/lib/config.sh"
HEALTH="${BATS_TEST_DIRNAME}/../../src/lib/health.sh"
MACOS="${BATS_TEST_DIRNAME}/../../src/lib/os_macos.sh"

mprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$MACOS"'"; '"$1"
}

# dprobe SNIPPET — sources the modules the macOS execute path touches, with
# DRY_RUN=1 and a throwaway LOG_FILE, then runs SNIPPET. run() prints "  + cmd"
# to stdout under DRY_RUN, so $output carries the commands that would run.
dprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$CONFIG"'"; source "'"$HEALTH"'"; source "'"$MACOS"'";
    DRY_RUN=1 LOG_FILE="$(mktemp)"; '"$1"
}

@test "_macos_arch maps uname arch to Zabbix macOS tokens" {
  mprobe 'for a in arm64 aarch64 x86_64 amd64; do _macos_arch "$a"; echo; done | paste -sd" " -'
  [ "$output" = "arm64 arm64 amd64 amd64" ]
}

@test "_macos_arch fails on an unsupported arch" {
  mprobe 'if _macos_arch i386; then echo yes; else echo no; fi'
  [ "$output" = "no" ]
}

@test "zbx_macos_agent_url: 7.4 arm64 openssl (self-updating latest pointer, default)" {
  mprobe 'zbx_macos_agent_url 7.4 arm64'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64-openssl.pkg" ]
}

@test "zbx_macos_agent_url: no-encryption drops the suffix" {
  mprobe 'zbx_macos_agent_url 7.4 arm64 none'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64.pkg" ]
}

@test "zbx_macos_agent_url: gnutls variant" {
  mprobe 'zbx_macos_agent_url 7.4 arm64 gnutls'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64-gnutls.pkg" ]
}

@test "zbx_macos_agent_url: 7.0 LTS also offers the arm64 latest pkg" {
  mprobe 'zbx_macos_agent_url 7.0 arm64 openssl'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/latest/zabbix_agent-7.0-latest-macos-arm64-openssl.pkg" ]
}

@test "zbx_macos_agent_tarball_url: 7.4 amd64 openssl (the Intel archive)" {
  mprobe 'zbx_macos_agent_tarball_url 7.4 amd64'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-amd64-openssl.tar.gz" ]
}

@test "zbx_macos_agent_tarball_url: 7.0 amd64, no-encryption drops the suffix" {
  mprobe 'zbx_macos_agent_tarball_url 7.0 amd64 none'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/latest/zabbix_agent-7.0-latest-macos-amd64.tar.gz" ]
}

@test "_macos_variant: arm64 -> pkg, x86_64 -> tar" {
  mprobe 'DETECT_ARCH=arm64; _macos_variant; echo; DETECT_ARCH=x86_64; _macos_variant; echo'
  [ "${lines[0]}" = "pkg" ]
  [ "${lines[1]}" = "tar" ]
}

# --- execute path (dry-run) ---------------------------------------------------
@test "macos_agent_install (dry-run, arm64) fetches the arm64 latest .pkg and runs installer" {
  dprobe 'PLAN_ZBX_VERSION=7.4 DETECT_ARCH=arm64; macos_agent_install'
  [ "$status" -eq 0 ]
  [[ "$output" == *"cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64-openssl.pkg"* ]]
  # run() prints each arg on its own line (global IFS=$'\n\t'), so match the
  # command token, not "installer -pkg".
  [[ "$output" == *"+ installer"* ]]
}

@test "macos_agent_install (dry-run, x86_64) routes to the amd64 tar.gz archive path" {
  dprobe 'PLAN_ZBX_VERSION=7.4 DETECT_ARCH=x86_64; macos_agent_install'
  [ "$status" -eq 0 ]
  [[ "$output" == *"cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-amd64-openssl.tar.gz"* ]]
  [[ "$output" == *"tar -xzf"* ]]
  [[ "$output" == *"/usr/local/sbin"* ]]
  [[ "$output" == *"write LaunchDaemon"* ]]
  [[ "$output" != *"+ installer"* ]]
}

@test "_macos_write_plist writes a launchd plist with the shared label and foreground agent" {
  # Real write (not dry-run) into a temp path via the ZBX_MACOS_AGENT_PLIST seam.
  dprobe 'DRY_RUN=0 ZBX_MACOS_AGENT_PLIST="'"$BATS_TEST_TMPDIR"'/zbx.plist"
    _macos_write_plist && cat "$ZBX_MACOS_AGENT_PLIST"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<string>com.zabbix.zabbix_agentd</string>"* ]]
  [[ "$output" == *"<string>/usr/local/sbin/zabbix_agentd</string>"* ]]
  [[ "$output" == *"<string>-f</string>"* ]]
  [[ "$output" == *"<key>KeepAlive</key>"* ]]
}

@test "macos_agent_config (dry-run) points the agent at the server, writes nothing" {
  dprobe 'PLAN_ZBX_SERVER_IP=192.0.2.10; macos_agent_config'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Server/ServerActive=192.0.2.10"* ]]
}

@test "macos_agent_run (dry-run) completes install -> config -> service -> health" {
  dprobe 'PLAN_ZBX_VERSION=7.4 PLAN_ZBX_SERVER_IP=192.0.2.10 DETECT_ARCH=arm64; macos_agent_run'
  [ "$status" -eq 0 ]
}

@test "macos_agent_uninstall (dry-run) unloads the daemon and removes the files" {
  dprobe 'macos_agent_uninstall'
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ launchctl"* ]]
  [[ "$output" == *"com.zabbix.zabbix_agentd.plist"* ]]
  [[ "$output" == *"+ rm"* ]]
  [[ "$output" == *"Removed the Zabbix macOS agent"* ]]
}
