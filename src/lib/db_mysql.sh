# shellcheck shell=bash
# db_mysql.sh — MariaDB/MySQL provisioning + schema import (§12.3).
#
# Contract:
#   inputs  : PLAN_DB_ENGINE, DETECT_FAMILY (detect.sh), ZBX_DB_PASSWORD /
#             ZBX_DB_ADMIN_PASSWORD (creds.sh).
#   outputs : enables+starts the DB unit, creates the zabbix database/user,
#             imports the schema; state_mark_done("db"). On failure routes to
#             err_menu('db', ...) (§14: retry / re-enter credentials / view
#             log / exit 8 — never skip, a half-provisioned DB can't be
#             skipped over). Secrets never touch argv or SQL text logged in
#             the clear — passwords go in via a defaults-extra-file or stdin,
#             matching §10.

# --- unit + auth resolution ----------------------------------------------------
# _db_mysql_unit_name — first of mariadb/mysqld/mysql that systemd knows
# about (§12.3 point 1 — the unit name varies by distro/package).
_db_mysql_unit_name() {
  local name
  for name in mariadb mysqld mysql; do
    if systemctl list-unit-files "${name}.service" --no-legend 2>/dev/null | grep -q .; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

# _db_mysql_defaults_file USER PASSWORD — mktemp [client] file, chmod 600,
# cleaned up by the EXIT trap. Never pass a password as a command argument
# (§10 — visible in ps). Shared by the admin auth path here and health.sh's
# "connect as the zabbix user" checks (§13).
_db_mysql_defaults_file() {
  local user="$1" password="$2" f
  f="$(mktemp -t zbx-mysql-defaults.XXXXXX)"
  chmod 600 "$f"
  ZBX_TEMPFILES+=("$f")
  {
    printf '[client]\n'
    printf 'user=%s\n' "$user"
    printf 'password=%s\n' "$password"
  } >"$f"
  printf '%s' "$f"
}

_DB_MYSQL_ARGS=()

# _db_mysql_auth_setup — populate _DB_MYSQL_ARGS with the current best auth:
# unix_socket (fresh installs, no password — §10 preferred path) unless an
# admin password has been collected, in which case use it via defaults file.
_db_mysql_auth_setup() {
  if [[ -n "$ZBX_DB_ADMIN_PASSWORD" ]]; then
    local defaults_file
    defaults_file="$(_db_mysql_defaults_file root "$ZBX_DB_ADMIN_PASSWORD")"
    _DB_MYSQL_ARGS=(mysql "--defaults-extra-file=$defaults_file")
  else
    _DB_MYSQL_ARGS=(mysql -u root)
  fi
}

# _db_mysql_probe — does the current auth actually work? Skipped under
# DRY_RUN (no real server may exist yet to connect to).
_db_mysql_probe() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  printf 'SELECT 1;\n' | "${_DB_MYSQL_ARGS[@]}" >/dev/null 2>&1
}

# --- create + grant --------------------------------------------------------------
# _db_mysql_create_and_grant — idempotent (IF NOT EXISTS); password goes in
# via stdin SQL text, never argv (§10).
_db_mysql_create_and_grant() {
  local sql
  sql="CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${ZBX_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;"
  printf '%s\n' "$sql" | run "${_DB_MYSQL_ARGS[@]}"
}

# --- schema import (§12.3 point 4) ------------------------------------------------
_ZBX_MYSQL_TRUST_TOGGLED=0
readonly ZBX_MYSQL_SCHEMA=/usr/share/zabbix-sql-scripts/mysql/server.sql.gz

# db_mysql_cleanup_trust_flag — EXIT-trap hook (core.sh calls this if
# defined): restore log_bin_trust_function_creators on ANY exit path, not
# just the success path, if this run toggled it (§12.3/§14).
db_mysql_cleanup_trust_flag() {
  if [[ "$_ZBX_MYSQL_TRUST_TOGGLED" == "1" ]]; then
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
      printf 'SET GLOBAL log_bin_trust_function_creators = 0;\n' |
        "${_DB_MYSQL_ARGS[@]}" >/dev/null 2>&1 || true
    fi
    _ZBX_MYSQL_TRUST_TOGGLED=0
  fi
}

# _db_mysql_import_pipe SCHEMA_FILE — zcat | mysql, redacted and dry-run
# aware. A plain single-command run() can't express a pipe, so this is a
# small hand-rolled equivalent (see core.sh's run() for the same pattern).
_db_mysql_import_pipe() {
  local schema_file="$1" rc
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: import $schema_file into zabbix"
    return 0
  fi
  log INFO "RUN: import $schema_file into zabbix"
  { zcat "$schema_file" | "${_DB_MYSQL_ARGS[@]}" zabbix; } 2>&1 | core_redact >>"$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

# _db_mysql_import — resume guard (§12.3 point 4): skip if the schema already
# imported successfully in a prior run.
_db_mysql_import() {
  if [[ "$DRY_RUN" != "1" ]] &&
    printf 'SELECT COUNT(*) FROM users;\n' | "${_DB_MYSQL_ARGS[@]}" zabbix >/dev/null 2>&1; then
    log INFO "zabbix schema already present — skipping import"
    return 0
  fi
  if [[ "$DRY_RUN" != "1" && ! -f "$ZBX_MYSQL_SCHEMA" ]]; then
    log ERROR "schema file not found: $ZBX_MYSQL_SCHEMA"
    return 1
  fi
  printf 'SET GLOBAL log_bin_trust_function_creators = 1;\n' | run "${_DB_MYSQL_ARGS[@]}" || return 1
  _ZBX_MYSQL_TRUST_TOGGLED=1
  if ! _db_mysql_import_pipe "$ZBX_MYSQL_SCHEMA"; then
    db_mysql_cleanup_trust_flag
    return 1
  fi
  db_mysql_cleanup_trust_flag
}

# --- orchestration -----------------------------------------------------------------
db_mysql_provision() {
  if core_state_is_done db; then
    log INFO "database already provisioned (state file) — skipping"
    return 0
  fi

  local unit
  while true; do
    if [[ "$DRY_RUN" == "1" ]]; then
      unit="mariadb"
      break
    fi
    unit="$(_db_mysql_unit_name)" && break
    err_menu db "no mariadb/mysqld/mysql service unit found — is the DB engine installed?"
  done
  while true; do
    run systemctl enable --now "$unit" && break
    err_menu db "starting the $unit service failed — see the log"
  done

  while true; do
    _db_mysql_auth_setup
    _db_mysql_probe && break
    if [[ -z "$ZBX_DB_ADMIN_PASSWORD" ]]; then
      err_menu db "connecting as root over unix_socket failed — this install needs the existing admin password"
    else
      err_menu db "the admin password did not work — see the log"
    fi
  done

  while true; do
    _db_mysql_create_and_grant && _db_mysql_import && break
    err_menu db "provisioning the zabbix database failed — see the log"
  done

  state_mark_done db
  log INFO "database provisioned successfully"
}
