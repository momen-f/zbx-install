#!/usr/bin/env bats
# Unit tests for repo.sh's pure URL builder (§12.1, §16: "bats unit tests for
# pure logic: URL builder"). Every pattern here was verified live against
# repo.zabbix.com on 2026-07-05 — see BUILD_REFERENCE.md Phase 3 entry.
#
# Sourcing happens inside `bash -c` subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DETECT="${BATS_TEST_DIRNAME}/../../src/lib/detect.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
REPO="${BATS_TEST_DIRNAME}/../../src/lib/repo.sh"

rprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'"; source "'"$RECOMMEND"'"; source "'"$REPO"'"; '"$1"
}

# --- apt (debian/ubuntu) ------------------------------------------------------
@test "zbx_release_url apt flat: ubuntu 24.04 / 7.0" {
  rprobe 'zbx_release_url flat debian ubuntu 24.04 "" 7.0 x86_64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb" ]
}

@test "zbx_release_url apt legacy: debian 12 / 7.4" {
  rprobe 'zbx_release_url legacy debian debian 12 "" 7.4 x86_64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb" ]
}

# --- dnf (rhel-like) -----------------------------------------------------------
@test "zbx_release_url dnf flat: rhel major 9 / 7.0 / x86_64" {
  rprobe 'zbx_release_url flat rhel rocky "" 9 7.0 x86_64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.0/rhel/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm" ]
}

@test "zbx_release_url dnf flat: aarch64 uses the aarch64 arch dir" {
  rprobe 'zbx_release_url flat rhel almalinux "" 8 7.0 aarch64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.0/rhel/8/aarch64/zabbix-release-latest-7.0.el8.noarch.rpm" ]
}

@test "zbx_release_url dnf legacy: rhel major 9 / 7.4 uses noarch/, not the arch dir" {
  rprobe 'zbx_release_url legacy rhel rocky "" 9 7.4 x86_64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.4/release/rhel/9/noarch/zabbix-release-latest-7.4.el9.noarch.rpm" ]
}

# --- zypper (sles/leap) --------------------------------------------------------
@test "zbx_release_url zypper flat: filename says sles15, not sl15 (SPEC.md typo caught 2026-07-05)" {
  rprobe 'zbx_release_url flat suse sles "" 15 7.0 x86_64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.0/sles/15/x86_64/zabbix-release-latest-7.0.sles15.noarch.rpm" ]
}

@test "zbx_release_url zypper legacy: opensuse-leap shares the sles path" {
  rprobe 'zbx_release_url legacy suse opensuse-leap "" 15 7.4 x86_64'
  [ "$output" = "https://repo.zabbix.com/zabbix/7.4/release/sles/15/noarch/zabbix-release-latest-7.4.sles15.noarch.rpm" ]
}

# --- dispatch / error cases ------------------------------------------------------
@test "zbx_release_url: unknown family fails" {
  rprobe 'zbx_release_url flat unknownfamily foo 1.0 "" 7.0 x86_64'
  [ "$status" -eq 1 ]
}

# --- repo_resolve_url: dry-run never touches the network -----------------------
@test "repo_resolve_url under DRY_RUN returns the flat URL without probing" {
  rprobe 'DETECT_FAMILY=debian DETECT_OS_ID=ubuntu DETECT_OS_VERSION=24.04 DETECT_OS_MAJOR=24 DETECT_ARCH=x86_64 PLAN_ZBX_VERSION=7.0 DRY_RUN=1;
    repo_resolve_url'
  [ "$status" -eq 0 ]
  [ "$output" = "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb" ]
}

@test "repo_resolve_url with no curl on PATH still returns the flat URL" {
  rprobe 'DETECT_FAMILY=debian DETECT_OS_ID=ubuntu DETECT_OS_VERSION=24.04 DETECT_OS_MAJOR=24 DETECT_ARCH=x86_64 PLAN_ZBX_VERSION=7.0 DRY_RUN=0 PATH=/nonexistent;
    repo_resolve_url'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/zabbix/7.0/ubuntu/pool/main/"* ]]
}
