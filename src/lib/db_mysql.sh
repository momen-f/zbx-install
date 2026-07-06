# shellcheck shell=bash
# db_mysql.sh — MariaDB/MySQL provisioning + schema import (§12.3).
#
# Also backs a mysql-backed proxy (§15.9 stretch): server and proxy are
# mutually exclusive components, so plan_db_name() (recommend.sh) picking
# "zabbix" vs "zabbix_proxy" and _db_mysql_schema_file() picking
# server.sql.gz vs proxy.sql is unambiguous — never both in the same plan.
#
# Contract:
#   inputs  : PLAN_DB_ENGINE, DETECT_FAMILY (detect.sh), ZBX_DB_PASSWORD /
#             ZBX_DB_ADMIN_PASSWORD (creds.sh).
#   outputs : enables+starts the DB unit, creates the database/user (plan_db_name),
#             imports the schema; state_mark_done("db"). On failure routes to
#             err_menu('db', ...) (§14: retry / re-enter credentials / view
#             log / exit 8 — never skip, a half-provisioned DB can't be
#             skipped over). Secrets never touch argv or SQL text logged in
#             the clear — passwords go in via a defaults-extra-file or stdin,
#             matching §10.

# --- dnf module stream (§15) --------------------------------------------------
# _db_mysql_mariadb_module_stream — echo the mariadb dnf module stream to
# enable before installing mariadb-server, or nothing if no sensible pick
# exists (caller no-ops in that case; a plain install still runs its own
# course). apt/zypper never call this — dnf modules are a dnf-only concept.
#
# Live bug, reproduced 2026-07-06 on a bare `rockylinux:9` container (no
# Zabbix repo involved): AppStream's mariadb module currently ships two
# streams, 10.11 and 11.8, but its module-defaults metadata sets no
# top-level `stream:` at all (confirmed by downloading and reading the real
# repodata modules.yaml — the modulemd-defaults document for mariadb has
# only `profiles: {10.11: [server]}`, no `stream:` key). With no stream
# pre-enabled, a plain `dnf install mariadb-server` resolves across every
# available stream by highest NEVRA and lands on 11.8, whose modular
# metadata is currently broken on Rocky's live mirrors: "No available
# modular metadata for modular package ..., it cannot be installed on the
# system" — surfaces at the transaction-check step, after every package
# (including the broken one) has already downloaded. `dnf clean all` +
# `makecache` does NOT fix this; it's not a local cache staleness issue,
# the live repodata itself is inconsistent. mysql-server and postgresql
# don't hit this — verified live the same day, neither has more than one
# viable stream in play on EL9's AppStream today.
#
# There being no `stream:` key means there is nothing to dynamically read
# as "the marked default" — the closest real signal dnf exposes is which
# stream(s), if any, carry a `[d]`-flagged profile in `dnf module list`
# output (10.11 does, 11.8 doesn't). Preference order below: an actual
# stream-level [d] flag first (EL8's mariadb module sets one for real —
# this keeps working unchanged if EL9's metadata ever grows one too);
# else the stream with a default profile marked; else the lowest version,
# so a newer-but-broken stream never wins by default. `$3 == "[d]"` (not
# "line contains [d]") specifically targets the Stream column — every
# stream's Profiles column routinely carries its own `[d]` too and would
# otherwise make every row look tied.
_db_mysql_mariadb_module_stream() {
  local stream
  stream="$(dnf -y module list mariadb 2>/dev/null | awk '
    $1 == "mariadb" {
      streamdef = ($3 == "[d]") ? 1 : 0
      profdef = ($0 ~ /\[d\]/) ? 1 : 0
      print $2, streamdef, profdef
    }
  ' | sort -k2,2rn -k3,3rn -k1,1V | awk 'NR==1 { print $1 }')" || true
  [[ -n "$stream" ]] && printf '%s' "$stream"
}

# db_mysql_module_enable — enable the right mariadb dnf module stream before
# pkg_install runs (see the function above). No-op on apt/zypper, non-
# mariadb engines, or when mariadb is already present (pkg_install won't
# try to install it in that case either — same condition as
# recommend.sh's _plan_db_web_packages).
db_mysql_module_enable() {
  [[ "$DETECT_PKGMGR" == "dnf" ]] || return 0
  [[ "$PLAN_DB_ENGINE" == "mariadb" ]] || return 0
  (plan_has server || plan_has proxy) || return 0
  [[ ",${DETECT_DB_PRESENT:-}," != *",$PLAN_DB_ENGINE,"* ]] || return 0
  local stream
  stream="$(_db_mysql_mariadb_module_stream)" || true
  [[ -n "$stream" ]] || return 0
  run dnf module enable "mariadb:${stream}" -y || true
}

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
# via stdin SQL text, never argv (§10). Same 'zabbix'@'localhost' username
# for both server and proxy (matches Zabbix's own documented convention for
# either) — only the database name (plan_db_name) differs.
_db_mysql_create_and_grant() {
  local dbname sql
  dbname="$(plan_db_name)"
  sql="CREATE DATABASE IF NOT EXISTS ${dbname} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${ZBX_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${dbname}.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;"
  printf '%s\n' "$sql" | run "${_DB_MYSQL_ARGS[@]}"
}

# --- schema import (§12.3 point 4) ------------------------------------------------
_ZBX_MYSQL_TRUST_TOGGLED=0

# _db_mysql_schema_file — the schema to import for this plan's component.
# proxy's proxy.sql is plain text (imported via stdin redirection below, not
# zcat) — unlike server's gzipped server.sql.gz. Both ship in the same
# zabbix-sql-scripts package; verified against the real package contents
# (§15.9 stretch).
_db_mysql_schema_file() {
  if plan_has proxy; then
    printf '/usr/share/zabbix-sql-scripts/mysql/proxy.sql'
  else
    printf '/usr/share/zabbix-sql-scripts/mysql/server.sql.gz'
  fi
}

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

# _db_mysql_import_pipe SCHEMA_FILE DBNAME — zcat|mysql (gzipped server
# schema) or mysql<schema (plain-text proxy schema), redacted and dry-run
# aware. A plain single-command run() can't express a pipe/redirection, so
# this is a small hand-rolled equivalent (see core.sh's run() for the same
# pattern).
_db_mysql_import_pipe() {
  local schema_file="$1" dbname="$2" rc
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: import $schema_file into $dbname"
    return 0
  fi
  log INFO "RUN: import $schema_file into $dbname"
  case "$schema_file" in
    *.gz)
      { zcat "$schema_file" | "${_DB_MYSQL_ARGS[@]}" "$dbname"; } 2>&1 | core_redact >>"$LOG_FILE"
      ;;
    *)
      { "${_DB_MYSQL_ARGS[@]}" "$dbname" <"$schema_file"; } 2>&1 | core_redact >>"$LOG_FILE"
      ;;
  esac
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

# _db_mysql_import — resume guard (§12.3 point 4): skip if the schema already
# imported successfully in a prior run. proxy.sql has a users table too
# (verified against the real package contents), so the same guard query
# works unchanged for both schemas.
_db_mysql_import() {
  local dbname schema_file
  dbname="$(plan_db_name)"
  schema_file="$(_db_mysql_schema_file)"
  if [[ "$DRY_RUN" != "1" ]] &&
    printf 'SELECT COUNT(*) FROM users;\n' | "${_DB_MYSQL_ARGS[@]}" "$dbname" >/dev/null 2>&1; then
    log INFO "$dbname schema already present — skipping import"
    return 0
  fi
  if [[ "$DRY_RUN" != "1" && ! -f "$schema_file" ]]; then
    log ERROR "schema file not found: $schema_file"
    return 1
  fi
  printf 'SET GLOBAL log_bin_trust_function_creators = 1;\n' | run "${_DB_MYSQL_ARGS[@]}" || return 1
  _ZBX_MYSQL_TRUST_TOGGLED=1
  if ! _db_mysql_import_pipe "$schema_file" "$dbname"; then
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
