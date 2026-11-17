#!/usr/bin/env bash
# Run after db-passwords.sh pgsql in the same disposable PostgreSQL container.
set -Eeuo pipefail
source src/lib/core.sh
source src/lib/pkg.sh
source src/lib/db_pgsql.sh
core_color_init
LOG_FILE=/tmp/pgsql-import-test.log
ZBX_DB_PASSWORD="Quote'back\\slash:semi;#end"
core_register_secret "$ZBX_DB_PASSWORD"
trap core_on_exit EXIT
id zabbix >/dev/null 2>&1 || useradd --system zabbix
sudo() {
  local user="$2"
  shift 2
  gosu "$user" "$@"
}
schema="$(mktemp)"
ZBX_TEMPFILES+=("$schema" "${schema}.gz")
for peer in 0 1; do
  for compressed in 0 1; do
    cat >"$schema" <<'SQL'
CREATE TABLE users (id integer);
INSERT INTO users VALUES (1);
SELECT 1 / 0;
CREATE TABLE after_error (id integer);
SQL
    ZBX_PGSQL_SCHEMA="$schema"
    if [[ "$compressed" == 1 ]]; then
      gzip -c "$schema" >"${schema}.gz"
      ZBX_PGSQL_SCHEMA="${schema}.gz"
    fi
    rc=0
    _db_pgsql_import_pipe "$peer" || rc=$?
    test "$rc" -eq 3
    test "$(sudo -u postgres psql -d zabbix -tAc "SELECT to_regclass('public.users') IS NULL AND to_regclass('public.after_error') IS NULL")" = t
    printf 'CREATE TABLE users (id integer);\nINSERT INTO users VALUES (1);\n' >"$schema"
    if [[ "$compressed" == 1 ]]; then gzip -c "$schema" >"${schema}.gz"; fi
    _db_pgsql_import_pipe "$peer"
    _db_pgsql_schema_present
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d zabbix -c 'DROP TABLE users' >/dev/null
  done
done
core_on_exit
for path in "${ZBX_TEMPFILES[@]}"; do test ! -e "$path"; done
printf 'PostgreSQL imports stop on SQL errors, roll back, and retry successfully\n'
