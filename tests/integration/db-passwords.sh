#!/usr/bin/env bash
# Runs only inside disposable official MariaDB/PostgreSQL containers.
set -Eeuo pipefail
source src/lib/core.sh
source src/lib/recommend.sh
source src/lib/db_mysql.sh
source src/lib/db_pgsql.sh
core_color_init
LOG_FILE=/tmp/password-test.log
PLAN_COMPONENTS=server
ZBX_DB_PASSWORD="Quote'back\\slash:semi;#end"
core_register_secret "$ZBX_DB_PASSWORD"
ZBX_DB_ADMIN_PASSWORD=""
trap core_on_exit EXIT
case "$1" in
  mysql)
    defaults=""
    _db_mysql_auth_setup
    _db_mysql_create_and_grant
    _db_mysql_defaults_file defaults zabbix "$ZBX_DB_PASSWORD"
    test "$(mysql --defaults-extra-file="$defaults" -N zabbix -e 'SELECT 1')" = 1
    ;;
  pgsql)
    pgpass=""
    sudo() {
      shift 2
      gosu postgres "$@"
    }
    _db_pgsql_create_role_and_db
    _db_pgsql_pgpass_file pgpass
    test "$(PGPASSFILE="$pgpass" psql -h localhost -U zabbix -d zabbix -tAc 'SELECT 1')" = 1
    ;;
  *) exit 2 ;;
esac
if grep -qF "$ZBX_DB_PASSWORD" "$LOG_FILE"; then exit 1; fi
core_on_exit
for credential_file in "${ZBX_TEMPFILES[@]}"; do test ! -e "$credential_file"; done
printf 'Password round-trip passed for %s\n' "$1"
