#!/usr/bin/env bats
# Unit tests for db_pgsql.sh (§12.3, §10). Sourcing happens inside `bash -c`
# subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DBP="${BATS_TEST_DIRNAME}/../../src/lib/db_pgsql.sh"

pprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DBP"'"; '"$1"
}

# pprobe_env VARS_ASSIGNMENT SNIPPET — like pprobe, but VARS_ASSIGNMENT is
# exported into the environment BEFORE sourcing, so it can seed a variable
# that db_pgsql.sh sets via `: "${VAR:=default}"` (e.g. ZBX_PGSQL_DATA_DIR).
pprobe_env() {
  run env "$1" bash -c 'source "'"$CORE"'"; source "'"$DBP"'"; '"$2"
}

fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

@test "_db_pgsql_initdb_needed is true only on RHEL with no PG_VERSION file" {
  pprobe_env "ZBX_PGSQL_DATA_DIR=$BATS_TEST_TMPDIR/no-such-dir" 'DETECT_FAMILY=rhel; _db_pgsql_initdb_needed && echo yes'
  [[ "$output" == *"yes"* ]]
}

@test "_db_pgsql_initdb_needed is false on debian regardless of the data dir" {
  pprobe_env "ZBX_PGSQL_DATA_DIR=$BATS_TEST_TMPDIR/no-such-dir" 'DETECT_FAMILY=debian; _db_pgsql_initdb_needed'
  [ "$status" -eq 1 ]
}

@test "_db_pgsql_initdb_needed is false on RHEL once PG_VERSION exists" {
  mkdir -p "$BATS_TEST_TMPDIR/pgdata"
  touch "$BATS_TEST_TMPDIR/pgdata/PG_VERSION"
  pprobe_env "ZBX_PGSQL_DATA_DIR=$BATS_TEST_TMPDIR/pgdata" 'DETECT_FAMILY=rhel; _db_pgsql_initdb_needed'
  [ "$status" -eq 1 ]
}

# Regression-style check for the same acceptance criterion as db_mysql.bats:
# the zabbix role's password is set via an ALTER USER stdin heredoc, never
# argv, using a recording fake sudo/psql pair.
@test "_db_pgsql_create_role_and_db sends the password via stdin, not argv" {
  local d="$BATS_TEST_TMPDIR/t1"
  fake_tool "$d" sudo 'echo "ARGV:$*" >>"'"$BATS_TEST_TMPDIR"'/sudo-calls.log";
    case "$*" in
      *createuser*) exit 0 ;;
      *createdb*) exit 0 ;;
      *psql*) cat >>"'"$BATS_TEST_TMPDIR"'/psql-stdin.log"; exit 0 ;;
    esac'
  rm -f "$BATS_TEST_TMPDIR/sudo-calls.log" "$BATS_TEST_TMPDIR/psql-stdin.log"
  pprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    ZBX_DB_PASSWORD="s3cr3t-pg-check";
    _db_pgsql_role_exists() { return 1; }
    _db_pgsql_database_exists() { return 1; }
    _db_pgsql_create_role_and_db'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/sudo-calls.log"
  [[ "$output" != *"s3cr3t-pg-check"* ]]
  run cat "$BATS_TEST_TMPDIR/psql-stdin.log"
  [[ "$output" == *"ALTER USER zabbix PASSWORD 's3cr3t-pg-check'"* ]]
}

@test "_db_pgsql_create_role_and_db skips createuser/createdb when they already exist" {
  local d="$BATS_TEST_TMPDIR/t2"
  fake_tool "$d" sudo 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/sudo2.log"; cat >/dev/null; exit 0'
  rm -f "$BATS_TEST_TMPDIR/sudo2.log"
  pprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    ZBX_DB_PASSWORD="pw";
    _db_pgsql_role_exists() { return 0; }
    _db_pgsql_database_exists() { return 0; }
    _db_pgsql_create_role_and_db'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/sudo2.log"
  [[ "$output" != *"createuser"* ]]
  [[ "$output" != *"createdb"* ]]
  [[ "$output" == *"psql"* ]]
}

@test "_db_pgsql_timescale_enable is a no-op when TimescaleDB was not requested" {
  pprobe 'PLAN_TIMESCALE=no; _db_pgsql_timescale_enable; echo ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "_db_pgsql_timescale_enable warns and continues (returns 0) when unavailable" {
  pprobe 'core_color_init; core_log_init; DRY_RUN=0; PLAN_TIMESCALE=yes;
    _db_pgsql_timescale_available() { return 1; }
    _db_pgsql_timescale_enable; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "_db_pgsql_timescale_enable does nothing under DRY_RUN" {
  pprobe 'core_color_init; core_log_init; DRY_RUN=1; PLAN_TIMESCALE=yes; _db_pgsql_timescale_enable; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}
