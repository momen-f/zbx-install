#!/usr/bin/env bats
# Unit tests for db_pgsql.sh (§12.3, §10). Sourcing happens inside `bash -c`
# subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DBP="${BATS_TEST_DIRNAME}/../../src/lib/db_pgsql.sh"
PKG="${BATS_TEST_DIRNAME}/../../src/lib/pkg.sh"
CONFIG="${BATS_TEST_DIRNAME}/../../src/lib/config.sh"

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
    _db_pgsql_timescale_package() { printf timescaledb-2-postgresql-16; }
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

@test "PostgreSQL SQL errors stop provisioning without marking db done or changing auth" {
  pprobe 'core_color_init; LOG_FILE="'"$BATS_TEST_TMPDIR"'/import.log";
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state"; core_state_init; DRY_RUN=0;
    _db_pgsql_initdb_needed() { return 1; }
    run() { return 0; }
    _db_pgsql_create_role_and_db() { return 0; }
    _db_pgsql_schema_present() { return 1; }
    _db_pgsql_schema_file() { echo "'"$BATS_TEST_FILENAME"'"; }
    _db_pgsql_import_pipe() { return 3; }
    _db_pgsql_add_hba_fallback() { echo unexpected-auth-change; return 0; }
    err_menu() { exit 8; }
    db_pgsql_provision'
  [ "$status" -eq 8 ]
  [[ "$output" != *unexpected-auth-change* ]]
  ! grep -qx 'db=done' "$BATS_TEST_TMPDIR/state"
}

@test "PostgreSQL connection failure still attempts the password fallback" {
  pprobe 'core_color_init; LOG_FILE=/dev/null; DRY_RUN=0;
    _db_pgsql_schema_present() { return 1; }
    _db_pgsql_schema_file() { echo "'"$BATS_TEST_FILENAME"'"; }
    _db_pgsql_import_pipe() { [[ "$1" == 0 ]] || return 2; }
    _db_pgsql_add_hba_fallback() { echo auth-fallback; }
    _db_pgsql_import'
  [ "$status" -eq 0 ]
  [[ "$output" == *auth-fallback* ]]
}

@test "TimescaleDB installs its package even when the main packages step is done" {
  for manager in apt dnf zypper; do
    local d="$BATS_TEST_TMPDIR/$manager"
    local tool="$manager" package=timescaledb-2-postgresql-16
    [[ "$manager" != apt ]] || tool=apt-get
    [[ "$manager" != zypper ]] || package=timescaledb
    fake_tool "$d" "$tool" 'echo "$*" >>"'"$d"'/packages"'
    printf "SELECT 'timescale-conversion';\n" >"$d/schema.sql"
    fake_tool "$d" sudo 'echo "$*" >>"'"$d"'/extension"
      case "$*" in
        *server_version_num*) echo 160015 ;;
        *shared_preload_libraries*) echo timescaledb ;;
        *) cat >>"'"$d"'/sql" ;;
      esac'
    pprobe 'source "'"$PKG"'"; core_color_init; LOG_FILE="'"$d"'/log";
      STATE_FILE="'"$d"'/state"; core_state_init; state_mark_done packages;
      DRY_RUN=0 PLAN_TIMESCALE=yes DETECT_PKGMGR="'"$manager"'" PATH="'"$d"':$PATH";
      _db_pgsql_timescale_available() { return 0; }
      zbx_schema_file() { echo "'"$d"'/schema.sql"; }
      _db_pgsql_timescale_enable'
    [ "$status" -eq 0 ]
    grep -q "install.*$package" "$d/packages"
    grep -q ON_ERROR_STOP=1 "$d/extension"
    grep -q timescale-conversion "$d/sql"
    grep -q 'TimescaleDB enabled' "$d/log"
  done
}

@test "TimescaleDB package failure warns; setup failures propagate without claiming success" {
  for failure in package preload extension schema; do
    pprobe 'core_color_init; LOG_FILE="'"$BATS_TEST_TMPDIR"'/'"$failure"'.log";
      DRY_RUN=0 PLAN_TIMESCALE=yes DETECT_PKGMGR=apt;
      _db_pgsql_timescale_package() { printf timescaledb-2-postgresql-16; }
      _db_pgsql_timescale_available() { return 0; }
      zbx_schema_file() { printf /fixture/schema.sql; }
      _pkg_install_cmd() { [[ "'"$failure"'" != package ]]; }
      _db_pgsql_timescale_preload() { [[ "'"$failure"'" != preload ]]; }
      _db_pgsql_import_pipe() { [[ "'"$failure"'" != schema ]]; }
      run() { echo extension-attempt; cat >/dev/null; [[ "'"$failure"'" != extension ]]; }
      _db_pgsql_timescale_enable'
    if [[ "$failure" == package ]]; then
      [ "$status" -eq 0 ]
      [[ "$output" == *'continuing without it'* && "$output" != *extension-attempt* ]]
    else
      [ "$status" -ne 0 ]
    fi
    ! grep -q 'TimescaleDB enabled' "$BATS_TEST_TMPDIR/$failure.log"
  done
}

@test "TimescaleDB package uses the running PostgreSQL major and rejects invalid versions" {
  pprobe 'DETECT_PKGMGR=apt; sudo() { echo 170006; }; _db_pgsql_timescale_package'
  [ "$output" = timescaledb-2-postgresql-17 ]
  pprobe 'DETECT_PKGMGR=dnf; sudo() { echo invalid; }; _db_pgsql_timescale_package'
  [ "$status" -ne 0 ]
}

@test "TimescaleDB apt availability requires a real candidate, not an empty or uninstalled entry" {
  for candidate in '' '  Installed: (none)' '  Candidate: (none)' '  Candidate: 2.30.2~ubuntu24.04'; do
    local d="$BATS_TEST_TMPDIR/policy"
    fake_tool "$d" apt-cache 'printf "%s\n" "'"$candidate"'"'
    pprobe 'DRY_RUN=0 DETECT_PKGMGR=apt PATH="'"$d"':$PATH"; _db_pgsql_timescale_available timescaledb-2-postgresql-16'
    if [[ "$candidate" == *2.30.2* ]]; then [ "$status" -eq 0 ]; else [ "$status" -ne 0 ]; fi
  done
}

@test "TimescaleDB preload preserves existing libraries and only restarts when missing" {
  local d="$BATS_TEST_TMPDIR/preload"
  mkdir -p "$d"
  printf "shared_preload_libraries = 'pg_stat_statements'\n" >"$d/postgresql.conf"
  fake_tool "$d" sudo 'case "$*" in
    *SHOW*) echo pg_stat_statements ;;
    *) echo "'"$d"'/postgresql.conf" ;;
  esac'
  fake_tool "$d" systemctl 'echo "$*" >"'"$d"'/restart"'
  pprobe 'source "'"$CONFIG"'"; core_color_init; LOG_FILE=/dev/null; DRY_RUN=0 PATH="'"$d"':$PATH"; _db_pgsql_timescale_preload'
  [ "$status" -eq 0 ]
  grep -qx "shared_preload_libraries='pg_stat_statements,timescaledb'" "$d/postgresql.conf"
  grep -qx 'restart postgresql' "$d/restart"
  rm "$d/restart"
  fake_tool "$d" sudo 'echo "pg_stat_statements, timescaledb"'
  pprobe 'DRY_RUN=0 PATH="'"$d"':$PATH"; _db_pgsql_timescale_preload'
  [ "$status" -eq 0 ]
  [ ! -e "$d/restart" ]
}

@test "TimescaleDB setup failure does not mark database provisioning complete" {
  pprobe 'core_color_init; LOG_FILE=/dev/null; STATE_FILE="'"$BATS_TEST_TMPDIR"'/state"; core_state_init;
    _db_pgsql_initdb_needed() { return 1; }
    run() { return 0; }
    _db_pgsql_create_role_and_db() { return 0; }
    _db_pgsql_import() { return 0; }
    _db_pgsql_timescale_enable() { return 1; }
    err_menu() { exit 8; }
    db_pgsql_provision'
  [ "$status" -eq 8 ]
  ! grep -qx 'db=done' "$BATS_TEST_TMPDIR/state"
}
