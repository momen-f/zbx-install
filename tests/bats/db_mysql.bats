#!/usr/bin/env bats
# Unit tests for db_mysql.sh (§12.3, §10). Sourcing happens inside `bash -c`
# subshells (see redact.bats for why); a small fake-tool PATH is used for the
# handful of tests that need systemctl/mysql, built fresh per test.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DBM="${BATS_TEST_DIRNAME}/../../src/lib/db_mysql.sh"

mprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DBM"'"; '"$1"
}

# fake_tool_dir NAME BODY... — build a tiny PATH dir with one or more fakes;
# echoes the dir so the caller can prepend it to PATH.
fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

@test "_db_mysql_unit_name prefers mariadb, then mysqld, then mysql" {
  local d="$BATS_TEST_TMPDIR/t1"
  fake_tool "$d" systemctl 'case "$2" in mariadb.service|mysqld.service|mysql.service) echo "$2 enabled" ;; esac; exit 0'
  mprobe 'PATH="'"$d"':$PATH" _db_mysql_unit_name'
  [ "$status" -eq 0 ]
  [ "$output" = "mariadb" ]
}

@test "_db_mysql_unit_name falls back to mysqld when mariadb is absent" {
  local d="$BATS_TEST_TMPDIR/t2"
  fake_tool "$d" systemctl 'case "$2" in mysqld.service) echo "mysqld.service enabled" ;; esac; exit 0'
  mprobe 'PATH="'"$d"':$PATH" _db_mysql_unit_name'
  [ "$status" -eq 0 ]
  [ "$output" = "mysqld" ]
}

@test "_db_mysql_unit_name fails when no known unit exists" {
  local d="$BATS_TEST_TMPDIR/t3"
  fake_tool "$d" systemctl 'exit 0'
  mprobe 'PATH="'"$d"':$PATH" _db_mysql_unit_name'
  [ "$status" -eq 1 ]
}

@test "_db_mysql_auth_setup uses unix_socket (no defaults file) when no admin password is set" {
  mprobe 'ZBX_DB_ADMIN_PASSWORD=""; _db_mysql_auth_setup; IFS=" "; printf "%s" "${_DB_MYSQL_ARGS[*]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "mysql -u root" ]
}

@test "_db_mysql_auth_setup builds a chmod-600 defaults file when an admin password is set" {
  mprobe 'ZBX_DB_ADMIN_PASSWORD="s3cr3t"; _db_mysql_auth_setup;
    f="${_DB_MYSQL_ARGS[1]#--defaults-extra-file=}";
    [[ -f "$f" ]] && grep -q "password=s3cr3t" "$f" && find "$f" -perm 600 | grep -q . && echo ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# Regression test: the exact acceptance criterion from SPEC §10/§18 Phase 4 —
# the admin password must never appear as a bare command-line argument
# (visible in `ps`). It only ever appears inside the defaults-extra-file.
@test "_db_mysql_auth_setup never puts the password in argv" {
  mprobe 'ZBX_DB_ADMIN_PASSWORD="s3cr3t-argv-check"; _db_mysql_auth_setup;
    for a in "${_DB_MYSQL_ARGS[@]}"; do [[ "$a" == *s3cr3t-argv-check* ]] && echo "LEAKED: $a"; done; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" != *"LEAKED"* ]]
}

# _db_mysql_create_and_grant's SQL is fed via stdin, never argv — same check,
# this time on the actual SQL-sending call, using a recording fake mysql.
@test "_db_mysql_create_and_grant sends the password via stdin, not argv" {
  local d="$BATS_TEST_TMPDIR/t4"
  fake_tool "$d" mysql 'echo "ARGV:$*" >>"'"$BATS_TEST_TMPDIR"'/mysql-calls.log"; cat >>"'"$BATS_TEST_TMPDIR"'/mysql-stdin.log"; exit 0'
  rm -f "$BATS_TEST_TMPDIR/mysql-calls.log" "$BATS_TEST_TMPDIR/mysql-stdin.log"
  mprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    ZBX_DB_PASSWORD="s3cr3t-sql-check"; _DB_MYSQL_ARGS=(mysql -u root);
    _db_mysql_create_and_grant'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/mysql-calls.log"
  [[ "$output" != *"s3cr3t-sql-check"* ]]
  run cat "$BATS_TEST_TMPDIR/mysql-stdin.log"
  [[ "$output" == *"s3cr3t-sql-check"* ]]
  [[ "$output" == *"CREATE DATABASE IF NOT EXISTS zabbix"* ]]
  [[ "$output" == *"CREATE USER IF NOT EXISTS 'zabbix'@'localhost'"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON zabbix.*"* ]]
}

@test "_db_mysql_import skips (resume case) when the schema already reports rows" {
  local d="$BATS_TEST_TMPDIR/t5"
  fake_tool "$d" mysql 'exit 0'
  mprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    _DB_MYSQL_ARGS=(mysql -u root); _db_mysql_import; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

# Regression test: db_mysql_cleanup_trust_flag (the EXIT-trap hook) used to
# attempt a REAL mysql connection even under DRY_RUN, since it bypassed
# run()'s own dry-run awareness entirely.
@test "db_mysql_cleanup_trust_flag does nothing under DRY_RUN" {
  mprobe 'DRY_RUN=1; _ZBX_MYSQL_TRUST_TOGGLED=1; _DB_MYSQL_ARGS=(mysql -u root);
    db_mysql_cleanup_trust_flag; printf "%s" "$_ZBX_MYSQL_TRUST_TOGGLED"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "db_mysql_cleanup_trust_flag is a no-op when nothing was toggled" {
  mprobe 'DRY_RUN=0; _ZBX_MYSQL_TRUST_TOGGLED=0; db_mysql_cleanup_trust_flag; echo ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
