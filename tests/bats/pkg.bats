#!/usr/bin/env bats
# Unit tests for pkg.sh: the EL8-frontend failure hint and update bookkeeping.
# Sourcing happens inside `bash -c` subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
PKG="${BATS_TEST_DIRNAME}/../../src/lib/pkg.sh"

fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash
%s
' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

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

# --- PHP module stream for the frontend (CI, rocky 9 + Zabbix 8.0) ------------
# A Zabbix frontend enforces a PHP floor its packages never declare: the RPMs
# require only php-mysqlnd, so dnf installs cleanly against rocky 9's default
# PHP 8.0 and the 8.0 frontend then answers every request with HTTP 200 and
# "Minimum required PHP version is 8.2.0." — a working-looking install whose
# every page is an error.

@test "_zbx_php_min_version: 8.0 needs PHP 8.2, earlier majors need 8.0" {
  pprobe '_zbx_php_min_version 8.0; printf " "; _zbx_php_min_version 7.4; printf " "; _zbx_php_min_version 7.0'
  [ "$output" = "8.2 8.0 8.0" ]
}

@test "_ver_ge compares major.minor, not strings (8.10 > 8.9)" {
  # Setting IFS here is load-bearing: core.sh sets a global IFS of $'\n\t'
  # with no space, so an unquoted split on a space-separated pair silently
  # yields one word — the same trap the source modules guard against. (Plain
  # assignment, not `local`: the probe body runs at top level, not in a
  # function, where `local` is an error.)
  pprobe 'IFS=" "
    for p in "8.2 8.2" "8.3 8.2" "8.10 8.9" "8.1 8.2" "7.4 8.0" "9.0 8.2"; do
      set -- $p
      if _ver_ge "$1" "$2"; then printf "y"; else printf "n"; fi
    done'
  [ "$output" = "yyynny" ]
}

# pprobe sources core.sh + pkg.sh only; plan_has lives in recommend.sh, so the
# tests below stub it rather than drag the whole plan layer in.
mprobe_php() { # mprobe_php DIR SNIPPET — DIR first on PATH for the dnf stub
  run bash -c 'source "'"$CORE"'"; source "'"$PKG"'";
    plan_has() { [[ "$1" == frontend ]]; }
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/php.log"; core_color_init; DRY_RUN=0
    PATH="'"$1"':$PATH"; '"$2"
}

# dnf_stub DIR ENABLED — a dnf whose "module list" reports rocky 9's real
# stream set, with ENABLED (possibly empty) marked as the enabled one, and
# which records every module subcommand it is asked to run.
dnf_stub() {
  local dir="$1" enabled="$2"
  fake_tool "$dir" dnf '
if [[ "$1" == "module" && "$2" == "list" ]]; then
  if [[ "$3" == "--enabled" ]]; then
    [[ -n "'"$enabled"'" ]] && echo "php  '"$enabled"'    common [e]  PHP scripting language"
    exit 0
  fi
  echo "php  8.1    common [d]  PHP scripting language"
  echo "php  8.2    common [d]  PHP scripting language"
  echo "php  8.3    common [d]  PHP scripting language"
  exit 0
fi
echo "$@" >>"'"$BATS_TEST_TMPDIR"'/dnf.calls"
exit 0'
}

@test "pkg_php_module_enable picks the LOWEST stream that clears the floor" {
  local d="$BATS_TEST_TMPDIR/pick"
  dnf_stub "$d" ""
  : >"$BATS_TEST_TMPDIR/dnf.calls"
  mprobe_php "$d" 'DETECT_PKGMGR=dnf PLAN_ZBX_VERSION=8.0; pkg_php_module_enable'
  # 8.2 clears 8.2; 8.3 would be a bigger change to the box than asked for.
  grep -q "module enable php:8.2" "$BATS_TEST_TMPDIR/dnf.calls"
  ! grep -q "php:8.3" "$BATS_TEST_TMPDIR/dnf.calls"
  grep -q "module reset php" "$BATS_TEST_TMPDIR/dnf.calls"
}

@test "pkg_php_module_enable leaves an already-sufficient stream alone" {
  local d="$BATS_TEST_TMPDIR/keep"
  dnf_stub "$d" "8.3"
  : >"$BATS_TEST_TMPDIR/dnf.calls"
  mprobe_php "$d" 'DETECT_PKGMGR=dnf PLAN_ZBX_VERSION=8.0; pkg_php_module_enable'
  [ ! -s "$BATS_TEST_TMPDIR/dnf.calls" ]
}

@test "pkg_php_module_enable does nothing for a Zabbix major the default PHP already suits" {
  local d="$BATS_TEST_TMPDIR/old"
  dnf_stub "$d" "8.0"
  : >"$BATS_TEST_TMPDIR/dnf.calls"
  mprobe_php "$d" 'DETECT_PKGMGR=dnf PLAN_ZBX_VERSION=7.0; pkg_php_module_enable'
  [ ! -s "$BATS_TEST_TMPDIR/dnf.calls" ]
}

# EL8 has no native php >= 8.0 stream at all: warn and leave it to dnf and to
# _pkg_failure_hint's Remi guidance, rather than enabling something bogus.
@test "pkg_php_module_enable warns instead of acting when no stream clears the floor" {
  local d="$BATS_TEST_TMPDIR/none"
  fake_tool "$d" dnf '
if [[ "$1" == "module" && "$2" == "list" ]]; then
  [[ "$3" == "--enabled" ]] && exit 0
  echo "php  7.4    common [d]  PHP scripting language"
  exit 0
fi
echo "$@" >>"'"$BATS_TEST_TMPDIR"'/dnf.calls"
exit 0'
  : >"$BATS_TEST_TMPDIR/dnf.calls"
  mprobe_php "$d" 'DETECT_PKGMGR=dnf PLAN_ZBX_VERSION=8.0; pkg_php_module_enable'
  [[ "$output" == *"no native php module stream"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/dnf.calls" ]
}

@test "pkg_php_module_enable is a no-op on apt systems" {
  local d="$BATS_TEST_TMPDIR/apt"
  dnf_stub "$d" ""
  : >"$BATS_TEST_TMPDIR/dnf.calls"
  mprobe_php "$d" 'DETECT_PKGMGR=apt PLAN_ZBX_VERSION=8.0; pkg_php_module_enable'
  [ ! -s "$BATS_TEST_TMPDIR/dnf.calls" ]
}
