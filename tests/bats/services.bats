#!/usr/bin/env bats
# Unit tests for services.sh (§12.6). Sourcing happens inside `bash -c`
# subshells (see redact.bats for why); db_mysql.sh is sourced too since
# services_start's mysql/mariadb branch reuses its _db_mysql_unit_name.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
DBM="${BATS_TEST_DIRNAME}/../../src/lib/db_mysql.sh"
SERVICES="${BATS_TEST_DIRNAME}/../../src/lib/services.sh"

svprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$RECOMMEND"'"; source "'"$DBM"'"; source "'"$SERVICES"'"; '"$1"
}

fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

# --- _services_php_fpm_unit -----------------------------------------------------------

@test "_services_php_fpm_unit finds Debian's versioned unit" {
  local d="$BATS_TEST_TMPDIR/t1"
  fake_tool "$d" systemctl 'case "$*" in
    "list-unit-files php*-fpm.service --no-legend") echo "php8.3-fpm.service enabled" ;;
    esac'
  svprobe 'PATH="'"$d"':$PATH" _services_php_fpm_unit'
  [ "$status" -eq 0 ]
  [ "$output" = "php8.3-fpm" ]
}

@test "_services_php_fpm_unit falls back to the plain name when listing fails" {
  local d="$BATS_TEST_TMPDIR/t2"
  fake_tool "$d" systemctl 'exit 1'
  svprobe 'PATH="'"$d"':$PATH" _services_php_fpm_unit'
  [ "$status" -eq 0 ]
  [ "$output" = "php-fpm" ]
}

# --- _services_web_units ---------------------------------------------------------------

@test "_services_web_units: nginx needs its own unit plus php-fpm" {
  local d="$BATS_TEST_TMPDIR/t3"
  fake_tool "$d" systemctl 'exit 1'
  svprobe 'PATH="'"$d"':$PATH" PLAN_WEB_SERVER=nginx DETECT_FAMILY=debian; _services_web_units'
  [ "$output" = "nginx php-fpm" ]
}

@test "_services_web_units: apache on RHEL also needs php-fpm (always-fpm family)" {
  local d="$BATS_TEST_TMPDIR/t4"
  fake_tool "$d" systemctl 'exit 1'
  svprobe 'PATH="'"$d"':$PATH" PLAN_WEB_SERVER=apache DETECT_FAMILY=rhel; _services_web_units'
  [ "$output" = "httpd php-fpm" ]
}

@test "_services_web_units: apache on Debian is mod_php — no separate php-fpm unit" {
  svprobe 'PLAN_WEB_SERVER=apache DETECT_FAMILY=debian; _services_web_units'
  [ "$output" = "apache2" ]
}

# --- _services_start_unit / _services_wait_active ---------------------------------------

@test "_services_start_unit does nothing under DRY_RUN (no real systemctl/sleep)" {
  svprobe 'core_color_init; core_log_init; DRY_RUN=1; _services_start_unit zabbix-server; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

@test "_services_wait_active returns immediately once the unit reports active" {
  local d="$BATS_TEST_TMPDIR/t5"
  fake_tool "$d" systemctl 'case "$1" in is-active) echo active ;; esac; exit 0'
  svprobe 'PATH="'"$d"':$PATH" _services_wait_active mariadb'
  [ "$status" -eq 0 ]
}

# Real timing on purpose (~15s): this is the one path that actually exercises
# the spec's "poll up to 15s" contract end to end, including the journalctl
# dump on timeout — worth the wall-clock cost once.
@test "_services_start_unit enables the unit, waits out the full 15s, dumps the journal, and still returns 0" {
  local d="$BATS_TEST_TMPDIR/t6" log="$BATS_TEST_TMPDIR/t6.log"
  fake_tool "$d" systemctl 'case "$1" in enable) exit 0 ;; is-active) exit 3 ;; esac'
  fake_tool "$d" journalctl 'echo "journalctl $*" >>"'"$log"'"; exit 0'
  svprobe 'core_color_init; LOG_FILE="'"$BATS_TEST_TMPDIR"'/t6.zbx.log"; core_log_init; DRY_RUN=0;
    PATH="'"$d"':$PATH";
    _services_start_unit mariadb; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  run cat "$log"
  [[ "$output" == *"journalctl -u mariadb -n 30 --no-pager"* ]]
}

# --- services_start orchestration ---------------------------------------------------

@test "services_start skips entirely when the state file already marks it done" {
  local log="$BATS_TEST_TMPDIR/skip.log"
  svprobe 'core_color_init; LOG_FILE="'"$log"'"; core_log_init;
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state"; : >"$STATE_FILE";
    state_mark_done services;
    services_start; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  run cat "$log"
  [[ "$output" == *"already started"* ]]
}

@test "services_start under DRY_RUN starts nothing for real and completes instantly" {
  svprobe 'core_color_init; core_log_init; DRY_RUN=1;
    PLAN_COMPONENTS=server,frontend,agent; PLAN_DB_ENGINE=mariadb;
    PLAN_WEB_SERVER=apache; DETECT_FAMILY=debian; PLAN_AGENT_TYPE=zabbix-agent2;
    services_start; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

# --- proxy (§15.9 stretch) ---------------------------------------------------------

@test "services_start starts the DB unit then zabbix-proxy for a mysql-backed proxy plan" {
  local d="$BATS_TEST_TMPDIR/t7" log="$BATS_TEST_TMPDIR/t7.log"
  fake_tool "$d" systemctl '
    case "$1 $2" in
      "list-unit-files mariadb.service") echo "mariadb.service enabled" ;;
      "enable --now") echo "ENABLE:$3" >>"'"$log"'" ;;
      "is-active") exit 0 ;;
    esac
    exit 0
  '
  rm -f "$log"
  svprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    PLAN_COMPONENTS=proxy; PLAN_DB_ENGINE=mariadb;
    services_start; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  run cat "$log"
  [[ "$output" == *"ENABLE:mariadb"* ]]
  [[ "$output" == *"ENABLE:zabbix-proxy"* ]]
}

@test "services_start starts only zabbix-proxy (no DB unit) for a sqlite3-backed proxy plan" {
  local d="$BATS_TEST_TMPDIR/t8" log="$BATS_TEST_TMPDIR/t8.log"
  fake_tool "$d" systemctl '
    case "$1 $2" in
      "enable --now") echo "ENABLE:$3" >>"'"$log"'" ;;
      "is-active") exit 0 ;;
    esac
    exit 0
  '
  rm -f "$log"
  svprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    PLAN_COMPONENTS=proxy; PLAN_DB_ENGINE=sqlite3;
    services_start; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  run cat "$log"
  [[ "$output" == "ENABLE:zabbix-proxy" ]]
}
