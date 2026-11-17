#!/usr/bin/env bats

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
}

@test "admin, health and PostgreSQL credentials are removed on success and failure exits" {
  for rc in 0 8; do
    run bash -c '
      source "$1/src/lib/core.sh"
      source "$1/src/lib/db_mysql.sh"
      source "$1/src/lib/db_pgsql.sh"
      source "$1/src/lib/health.sh"
      trap core_on_exit EXIT
      ZBX_DB_ADMIN_PASSWORD=admin-secret ZBX_DB_PASSWORD=zabbix-secret
      _db_mysql_auth_setup
      _health_mysql_auth_setup
      _db_pgsql_pgpass_file pgpass
      printf "%s\n" "${ZBX_TEMPFILES[@]}" >"$2"
      [[ ${#ZBX_TEMPFILES[@]} -eq 3 ]]
      for path in "${ZBX_TEMPFILES[@]}"; do
        [[ -s "$path" ]]
        [[ "$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path")" == 600 ]]
      done
      exit "$3"
    ' _ "$ROOT" "$BATS_TEST_TMPDIR/paths" "$rc"
    [ "$status" -eq "$rc" ]
    while IFS= read -r path; do [ ! -e "$path" ]; done <"$BATS_TEST_TMPDIR/paths"
  done
}

@test "failed credential file preparation stays registered and is never used" {
  run bash -c '
    source "$1/src/lib/core.sh"
    source "$1/src/lib/db_mysql.sh"
    source "$1/src/lib/db_pgsql.sh"
    source "$1/src/lib/health.sh"
    trap core_on_exit EXIT
    ZBX_DB_ADMIN_PASSWORD=admin-secret ZBX_DB_PASSWORD=zabbix-secret
    chmod() { return 1; }
    if _db_mysql_auth_setup; then exit 20; fi
    if _health_mysql_auth_setup; then exit 21; fi
    if _db_pgsql_pgpass_file pgpass; then exit 22; fi
    [[ ${#_DB_MYSQL_ARGS[@]} -eq 0 && ${#_HEALTH_MYSQL_ARGS[@]} -eq 0 ]]
    [[ ${#ZBX_TEMPFILES[@]} -eq 3 ]]
    printf "%s\n" "${ZBX_TEMPFILES[@]}" >"$2"
  ' _ "$ROOT" "$BATS_TEST_TMPDIR/paths"
  [ "$status" -eq 0 ]
  while IFS= read -r path; do [ ! -e "$path" ]; done <"$BATS_TEST_TMPDIR/paths"
}

@test "EXIT restores MySQL server settings before deleting its admin credentials" {
  run bash -c '
    source "$1/src/lib/core.sh"
    source "$1/src/lib/db_mysql.sh"
    trap core_on_exit EXIT
    ZBX_DB_ADMIN_PASSWORD=admin-secret
    _db_mysql_auth_setup
    printf "%s\n" "${ZBX_TEMPFILES[@]}" >"$2"
    marker="$3"
    mysql() {
      [[ -s "${1#--defaults-extra-file=}" ]] || return 1
      cat >"$marker"
    }
    _ZBX_MYSQL_TRUST_TOGGLED=1
  ' _ "$ROOT" "$BATS_TEST_TMPDIR/paths" "$BATS_TEST_TMPDIR/restored"
  [ "$status" -eq 0 ]
  grep -qx 'SET GLOBAL log_bin_trust_function_creators = 0;' "$BATS_TEST_TMPDIR/restored"
  while IFS= read -r path; do [ ! -e "$path" ]; done <"$BATS_TEST_TMPDIR/paths"
}

@test "health checks report failure when their credential file cannot be created" {
  run bash -c '
    source "$1/src/lib/core.sh"
    source "$1/src/lib/db_mysql.sh"
    source "$1/src/lib/health.sh"
    PLAN_DB_ENGINE=mysql ZBX_DB_PASSWORD=zabbix-secret
    plan_db_name() { printf zabbix; }
    mktemp() { return 1; }
    mysql() { echo unexpected-query; return 0; }
    _health_check_db_reachable
    _health_check_schema_present
    printf "%s\n" "${ZBX_HEALTH_RESULTS[@]}"
  ' _ "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'DB reachable as zabbix|1|'* ]]
  [[ "$output" == *'schema present (users table)|1|'* ]]
  [[ "$output" != *unexpected-query* ]]
}
