#!/usr/bin/env bats
# Unit tests for health.sh (§13). Sourcing happens inside `bash -c` subshells
# (see redact.bats for why); a small fake-tool PATH is used for systemctl/ss/
# curl/zabbix_get/mysql/sudo, built fresh per test.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
CONFIG="${BATS_TEST_DIRNAME}/../../src/lib/config.sh"
DBM="${BATS_TEST_DIRNAME}/../../src/lib/db_mysql.sh"
DBP="${BATS_TEST_DIRNAME}/../../src/lib/db_pgsql.sh"
SERVICES="${BATS_TEST_DIRNAME}/../../src/lib/services.sh"
HEALTH="${BATS_TEST_DIRNAME}/../../src/lib/health.sh"

hprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$RECOMMEND"'"; source "'"$CONFIG"'"; source "'"$DBM"'"; source "'"$DBP"'"; source "'"$SERVICES"'"; source "'"$HEALTH"'"; '"$1"
}

fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

# --- individual checks -------------------------------------------------------------

@test "_health_check_server_service passes when systemctl reports active" {
  local d="$BATS_TEST_TMPDIR/t1"
  fake_tool "$d" systemctl 'exit 0'
  hprobe 'PATH="'"$d"':$PATH" _health_check_server_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "zabbix-server service|0|" ]]
}

@test "_health_check_server_service fails with the journalctl hint when inactive" {
  local d="$BATS_TEST_TMPDIR/t2"
  fake_tool "$d" systemctl 'exit 3'
  hprobe 'PATH="'"$d"':$PATH" _health_check_server_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|journalctl -u zabbix-server -n 50"* ]]
}

@test "_health_check_agent_service checks zabbix-agent2 by default, zabbix-agent for classic" {
  local d="$BATS_TEST_TMPDIR/t3"
  fake_tool "$d" systemctl 'case "$*" in *zabbix-agent2*) exit 0 ;; *) exit 3 ;; esac'
  hprobe 'PATH="'"$d"':$PATH" PLAN_AGENT_TYPE=zabbix-agent2; _health_check_agent_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "zabbix-agent2 service|0|" ]]
  hprobe 'PATH="'"$d"':$PATH" PLAN_AGENT_TYPE=zabbix-agent; _health_check_agent_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"zabbix-agent service|1|"* ]]
}

@test "_health_check_web_service reports which unit(s) failed and the right config-test hint" {
  local d="$BATS_TEST_TMPDIR/t4"
  fake_tool "$d" systemctl 'case "$*" in *apache2*) exit 0 ;; *) exit 3 ;; esac'
  hprobe 'PATH="'"$d"':$PATH" PLAN_WEB_SERVER=apache DETECT_FAMILY=debian;
    _health_check_web_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "web service (apache2)|0|" ]]

  hprobe 'PATH="'"$d"':$PATH" PLAN_WEB_SERVER=nginx DETECT_FAMILY=debian;
    _health_check_web_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|config test: nginx -t"* ]]
}

# Regression test: RHEL's web check always has TWO units (httpd + php-fpm —
# see _services_web_units). The name/failed lists are joined with "${arr[*]}"
# — under the global IFS ($'\n\t', no space) that joins with a newline
# instead of a space, embedding one into the "NAME|PASS|HINT" string
# _health_record encodes; `read` then silently stops at the embedded
# newline, dropping PASS/HINT and making a clean pass register as a failure.
# Hit for real in CI (RHEL, apache) before both call sites got their own
# "local IFS=' '" guard.
@test "_health_check_web_service joins a multi-unit name/list with a space, not a corrupting newline" {
  local d="$BATS_TEST_TMPDIR/t4b"
  fake_tool "$d" systemctl 'exit 0'
  hprobe 'PATH="'"$d"':$PATH" PLAN_WEB_SERVER=apache DETECT_FAMILY=rhel;
    _health_check_web_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "web service (httpd php-fpm)|0|" ]]

  fake_tool "$d" systemctl 'exit 3'
  hprobe 'PATH="'"$d"':$PATH" PLAN_WEB_SERVER=apache DETECT_FAMILY=rhel;
    _health_check_web_service; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "web service (httpd php-fpm)|1|config test: apachectl configtest" ]]
}

@test "_health_check_port passes when ss reports a listener, fails on header-only output" {
  local d="$BATS_TEST_TMPDIR/t5"
  fake_tool "$d" ss 'printf "header\nLISTEN 0 128\n"'
  hprobe 'PATH="'"$d"':$PATH" _health_check_port 10051 zabbix-server "some hint"; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "zabbix-server (port 10051)|0|" ]]

  fake_tool "$d" ss 'printf "header\n"'
  hprobe 'PATH="'"$d"':$PATH" _health_check_port 10051 zabbix-server "some hint"; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|some hint"* ]]
}

@test "_health_check_db_reachable (mysql) connects as the zabbix user via a defaults file, never argv" {
  local d="$BATS_TEST_TMPDIR/t6"
  fake_tool "$d" mysql 'echo "ARGV:$*" >>"'"$BATS_TEST_TMPDIR"'/mysql-argv.log"; exit 0'
  hprobe 'core_color_init; core_log_init; PATH="'"$d"':$PATH";
    PLAN_DB_ENGINE=mariadb; ZBX_DB_PASSWORD="s3cr3t-health-check";
    _health_check_db_reachable; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "DB reachable as zabbix|0|" ]]
  run cat "$BATS_TEST_TMPDIR/mysql-argv.log"
  [[ "$output" != *"s3cr3t-health-check"* ]]
  [[ "$output" == *"--defaults-extra-file="* ]]
  # Regression: connects as "zabbix", not "root" — read the defaults file
  # itself, not just its presence, so reverting the user param would fail.
  local defaults_file="${output#*--defaults-extra-file=}"
  defaults_file="${defaults_file%% *}"
  run cat "$defaults_file"
  [[ "$output" == *"user=zabbix"* ]]
  [[ "$output" != *"user=root"* ]]
  [[ "$output" == *"password=s3cr3t-health-check"* ]]
}

@test "_health_check_db_reachable (pgsql) uses peer auth as the zabbix OS user" {
  local d="$BATS_TEST_TMPDIR/t7"
  fake_tool "$d" sudo 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/sudo.log"; exit 0'
  hprobe 'PATH="'"$d"':$PATH" PLAN_DB_ENGINE=pgsql; _health_check_db_reachable; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "DB reachable as zabbix|0|" ]]
  run cat "$BATS_TEST_TMPDIR/sudo.log"
  [[ "$output" == *"-u zabbix psql zabbix"* ]]
}

@test "_health_check_db_reachable fails with an engine-appropriate hint" {
  local d="$BATS_TEST_TMPDIR/t8"
  fake_tool "$d" mysql 'exit 1'
  hprobe 'core_color_init; core_log_init; PATH="'"$d"':$PATH"; PLAN_DB_ENGINE=mariadb; ZBX_DB_PASSWORD=pw;
    _health_check_db_reachable; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|check DBPassword / grants"* ]]

  fake_tool "$d" sudo 'exit 1'
  hprobe 'PATH="'"$d"':$PATH" PLAN_DB_ENGINE=pgsql; _health_check_db_reachable; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|check DBPassword / pg_hba.conf"* ]]
}

@test "_health_check_schema_present (mysql) reads the row count back, not just the exit code" {
  local d="$BATS_TEST_TMPDIR/t9"
  fake_tool "$d" mysql 'echo 5; exit 0'
  hprobe 'core_color_init; core_log_init; PATH="'"$d"':$PATH"; PLAN_DB_ENGINE=mariadb; ZBX_DB_PASSWORD=pw;
    _health_check_schema_present; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "schema present (users table)|0|" ]]

  fake_tool "$d" mysql 'exit 0'
  hprobe 'core_color_init; core_log_init; PATH="'"$d"':$PATH"; PLAN_DB_ENGINE=mariadb; ZBX_DB_PASSWORD=pw2;
    _health_check_schema_present; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|re-run the install"* ]]
}

# Regression test: _db_pgsql_schema_present (db_pgsql.sh) used to treat a
# successful-but-empty COUNT(*) query as "present" — an existing-but-empty
# users table must still fail this check, same as the mysql branch already
# required, per §13 check 7 ("SELECT COUNT(*) FROM users >= 1").
@test "_health_check_schema_present (pgsql) requires an actual row count, not just query success" {
  local d="$BATS_TEST_TMPDIR/t9b"
  fake_tool "$d" sudo 'echo 5; exit 0'
  hprobe 'core_color_init; core_log_init; PATH="'"$d"':$PATH"; PLAN_DB_ENGINE=pgsql;
    _health_check_schema_present; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "schema present (users table)|0|" ]]

  fake_tool "$d" sudo 'echo 0; exit 0'
  hprobe 'core_color_init; core_log_init; PATH="'"$d"':$PATH"; PLAN_DB_ENGINE=pgsql;
    _health_check_schema_present; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|re-run the install"* ]]
}

@test "_health_check_frontend_http accepts 200 and 302, rejects everything else" {
  local d="$BATS_TEST_TMPDIR/t10"
  fake_tool "$d" curl 'printf 200'
  hprobe 'PATH="'"$d"':$PATH" _health_check_frontend_http; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "frontend HTTP|0|" ]]

  fake_tool "$d" curl 'printf 302'
  hprobe 'PATH="'"$d"':$PATH" _health_check_frontend_http; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "frontend HTTP|0|" ]]

  fake_tool "$d" curl 'exit 22'
  hprobe 'PATH="'"$d"':$PATH" _health_check_frontend_http; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|check web conf, SELinux booleans, php-fpm"* ]]
}

@test "_health_check_agent_answers is skipped (no result recorded) when zabbix_get isn't installed" {
  hprobe 'PATH=/nonexistent _health_check_agent_answers; printf "%d" "${#ZBX_HEALTH_RESULTS[@]}"'
  [ "$output" = "0" ]
}

@test "_health_check_agent_answers passes on '1', fails otherwise" {
  local d="$BATS_TEST_TMPDIR/t11"
  fake_tool "$d" zabbix_get 'printf 1'
  hprobe 'PATH="'"$d"':$PATH" _health_check_agent_answers; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == "agent answers (zabbix_get)|0|" ]]

  fake_tool "$d" zabbix_get 'exit 1'
  hprobe 'PATH="'"$d"':$PATH" _health_check_agent_answers; printf "%s" "${ZBX_HEALTH_RESULTS[0]}"'
  [[ "$output" == *"|1|check the agent's Server= line"* ]]
}

# --- health_run_checks orchestration -------------------------------------------------

@test "health_run_checks does nothing under DRY_RUN" {
  hprobe 'core_color_init; core_log_init; DRY_RUN=1; health_run_checks; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" != *"failed"* ]]
}

@test "health_run_checks only runs agent checks for an agent-only plan" {
  local d="$BATS_TEST_TMPDIR/t12"
  fake_tool "$d" systemctl 'exit 0'
  fake_tool "$d" ss 'printf "h\nLISTEN\n"'
  hprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    PLAN_COMPONENTS=agent; PLAN_AGENT_TYPE=zabbix-agent2;
    health_run_checks; printf "%d" "${#ZBX_HEALTH_RESULTS[@]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "health_run_checks returns 0 and prints nothing extra when every applicable check passes" {
  local d="$BATS_TEST_TMPDIR/t13"
  fake_tool "$d" systemctl 'exit 0'
  fake_tool "$d" ss 'printf "h\nLISTEN\n"'
  hprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    PLAN_COMPONENTS=agent; PLAN_AGENT_TYPE=zabbix-agent2;
    health_run_checks; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" != *"checks failed"* ]]
}

@test "health_run_checks returns 1 and prints a red block with hints when a check fails" {
  local d="$BATS_TEST_TMPDIR/t14"
  fake_tool "$d" systemctl 'exit 3'
  fake_tool "$d" ss 'printf "h\n"'
  hprobe 'core_color_init; LOG_FILE="'"$BATS_TEST_TMPDIR"'/t14.log"; core_log_init; DRY_RUN=0;
    PATH="'"$d"':$PATH"; PLAN_COMPONENTS=agent; PLAN_AGENT_TYPE=zabbix-agent2;
    health_run_checks'
  [ "$status" -eq 1 ]
  [[ "$output" == *"of 2 checks failed"* ]]
  [[ "$output" == *"journalctl -u zabbix-agent2"* ]]
}

# --- health_print_summary -----------------------------------------------------------

@test "health_print_summary does nothing under DRY_RUN" {
  hprobe 'DRY_RUN=1; health_print_summary; echo ok'
  [[ "$output" == *"ok"* ]]
  [[ "$output" != *"passed"* ]]
}

@test "health_print_summary shows a green banner and the frontend URL when clean" {
  hprobe 'core_color_init; DRY_RUN=0; LOG_FILE=/tmp/x.log; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/etc";
    PLAN_COMPONENTS=server,frontend,agent; PLAN_DB_ENGINE=mariadb; PLAN_CREDS_FILE=none;
    PLAN_AGENT_TYPE=zabbix-agent2; ZBX_DEGRADED_STEPS=();
    health_print_summary'
  [[ "$output" == *"All checks passed"* ]]
  [[ "$output" == *"/zabbix/"* ]]
  [[ "$output" == *"Admin / zabbix"* ]]
  [[ "$output" == *"change this password now"* ]]
}

@test "health_print_summary shows a degraded note (not the clean banner) when steps were skipped" {
  hprobe 'core_color_init; DRY_RUN=0; LOG_FILE=/tmp/x.log; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/etc";
    PLAN_COMPONENTS=agent; PLAN_AGENT_TYPE=zabbix-agent2; PLAN_CREDS_FILE=none;
    ZBX_DEGRADED_STEPS=(health);
    health_print_summary'
  [[ "$output" == *"degraded"* ]]
  [[ "$output" != *"All checks passed"* ]]
}

# Regression test: multiple degraded steps must join with a space (the
# global IFS has no space — same class of bug as the web-service one above).
@test "health_print_summary joins multiple degraded steps with a space" {
  hprobe 'core_color_init; DRY_RUN=0; LOG_FILE=/tmp/x.log; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/etc";
    PLAN_COMPONENTS=agent; PLAN_AGENT_TYPE=zabbix-agent2; PLAN_CREDS_FILE=none;
    ZBX_DEGRADED_STEPS=(firewall health);
    health_print_summary'
  [[ "$output" == *"firewall health"* ]]
}

@test "health_print_summary omits the frontend block for an agent-only plan" {
  hprobe 'core_color_init; DRY_RUN=0; LOG_FILE=/tmp/x.log; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/etc";
    PLAN_COMPONENTS=agent; PLAN_AGENT_TYPE=zabbix-agent2; PLAN_CREDS_FILE=none;
    ZBX_DEGRADED_STEPS=();
    health_print_summary'
  [[ "$output" != *"Frontend:"* ]]
  [[ "$output" != *"Default login"* ]]
}

@test "health_print_summary shows the credentials file path only when one was actually written" {
  local f="$BATS_TEST_TMPDIR/creds.txt"
  : >"$f"
  hprobe 'core_color_init; DRY_RUN=0; LOG_FILE=/tmp/x.log; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/etc";
    PLAN_COMPONENTS=server,agent; PLAN_DB_ENGINE=mariadb; PLAN_CREDS_FILE="'"$f"'";
    PLAN_AGENT_TYPE=zabbix-agent2; ZBX_DEGRADED_STEPS=();
    health_print_summary'
  [[ "$output" == *"Credentials:"*"$f"* ]]

  hprobe 'core_color_init; DRY_RUN=0; LOG_FILE=/tmp/x.log; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/etc";
    PLAN_COMPONENTS=server,agent; PLAN_DB_ENGINE=mariadb; PLAN_CREDS_FILE=none;
    PLAN_AGENT_TYPE=zabbix-agent2; ZBX_DEGRADED_STEPS=();
    health_print_summary'
  [[ "$output" != *"Credentials:"* ]]
}
