#!/usr/bin/env bats
# Unit tests for pkg.sh: the EL8-frontend failure hint and update bookkeeping.
# Sourcing happens inside `bash -c` subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
PKG="${BATS_TEST_DIRNAME}/../../src/lib/pkg.sh"

pprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$PKG"'"; '"$1"
}

# Regression test: pkg.sh's failure-hint word match uses $* under core.sh's
# global IFS=$'\n\t' (no space) — without a scoped `local IFS=' '`, the
# space-padded "*\" zabbix-web-mysql \"*" glob would never match, silently
# losing the EL8/Remi-specific guidance and falling back to the generic hint.
# Note: the RHEL frontend package is zabbix-web-mysql/-pgsql, NOT
# zabbix-frontend-php (that name is apt-only — verified live 2026-07-05,
# after a real CI install on rockylinux:9 failed on the wrong name).
@test "_pkg_failure_hint gives the Remi hint for EL8 + frontend (mysql)" {
  pprobe 'DETECT_FAMILY=rhel DETECT_OS_MAJOR=8 DETECT_PKGMGR=dnf; _pkg_failure_hint zabbix-agent2 zabbix-web-mysql zabbix-apache-conf'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remi"* ]]
  [[ "$output" == *"PHP >= 8.0.0"* ]]
}

@test "_pkg_failure_hint gives the Remi hint for EL8 + frontend (pgsql)" {
  pprobe 'DETECT_FAMILY=rhel DETECT_OS_MAJOR=8 DETECT_PKGMGR=dnf; _pkg_failure_hint zabbix-agent2 zabbix-web-pgsql zabbix-apache-conf'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remi"* ]]
}

@test "_pkg_failure_hint is generic for EL8 without the frontend package" {
  pprobe 'DETECT_FAMILY=rhel DETECT_OS_MAJOR=8 DETECT_PKGMGR=dnf; _pkg_failure_hint zabbix-agent2'
  [ "$status" -eq 0 ]
  [[ "$output" != *"Remi"* ]]
  [[ "$output" == *"package transaction failed"* ]]
}

@test "_pkg_failure_hint is generic on EL9 even with the frontend package" {
  pprobe 'DETECT_FAMILY=rhel DETECT_OS_MAJOR=9 DETECT_PKGMGR=dnf; _pkg_failure_hint zabbix-agent2 zabbix-web-mysql'
  [ "$status" -eq 0 ]
  [[ "$output" != *"Remi"* ]]
}

@test "_pkg_failure_hint is generic on debian even with the frontend package" {
  pprobe 'DETECT_FAMILY=debian DETECT_OS_MAJOR=12 DETECT_PKGMGR=apt; _pkg_failure_hint zabbix-frontend-php'
  [ "$status" -eq 0 ]
  [[ "$output" != *"Remi"* ]]
}

@test "pkg_install with zero packages is a no-op, not an error" {
  pprobe 'USE_COLOR=0; core_color_init; DETECT_PKGMGR=apt; DRY_RUN=1; LOG_FILE=/dev/null; pkg_install'
  [ "$status" -eq 0 ]
}

@test "pkg_update is a no-op when PLAN_UPDATE is not yes" {
  pprobe 'PLAN_UPDATE=no; DRY_RUN=1; LOG_FILE=/dev/null; pkg_update; echo ran-ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran-ok"* ]]
}
