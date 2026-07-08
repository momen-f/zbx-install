#!/usr/bin/env bats
# Unit tests for os_macos.sh pure helpers — the macOS agent arch map + release
# URL builder. Verified live against cdn.zabbix.com (2026-07). Sourced inside a
# `bash -c` subshell (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
MACOS="${BATS_TEST_DIRNAME}/../../src/lib/os_macos.sh"

mprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$MACOS"'"; '"$1"
}

@test "_macos_arch maps uname arch to Zabbix macOS tokens" {
  mprobe 'for a in arm64 aarch64 x86_64 amd64; do _macos_arch "$a"; echo; done | paste -sd" " -'
  [ "$output" = "arm64 arm64 amd64 amd64" ]
}

@test "_macos_arch fails on an unsupported arch" {
  mprobe 'if _macos_arch i386; then echo yes; else echo no; fi'
  [ "$output" = "no" ]
}

@test "zbx_macos_agent_url: arm64 openssl is the default variant" {
  mprobe 'zbx_macos_agent_url 7.4.11 arm64'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/7.4.11/zabbix_agent-7.4.11-macos-arm64-openssl.pkg" ]
}

@test "zbx_macos_agent_url: amd64, no-encryption drops the suffix" {
  mprobe 'zbx_macos_agent_url 7.4.11 amd64 none'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/7.4.11/zabbix_agent-7.4.11-macos-amd64.pkg" ]
}

@test "zbx_macos_agent_url: gnutls variant" {
  mprobe 'zbx_macos_agent_url 7.4.11 arm64 gnutls'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/7.4.11/zabbix_agent-7.4.11-macos-arm64-gnutls.pkg" ]
}

@test "zbx_macos_agent_url: major is derived from the x.y.z release" {
  mprobe 'zbx_macos_agent_url 7.0.16 amd64 openssl'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/7.0.16/zabbix_agent-7.0.16-macos-amd64-openssl.pkg" ]
}
