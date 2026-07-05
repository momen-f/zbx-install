# shellcheck shell=bash
# db_pgsql.sh — PostgreSQL provisioning + schema import (§12.3).
#
# Contract:
#   inputs  : PLAN_DB_ENGINE, DETECT_FAMILY, PLAN_TIMESCALE (recommend.sh),
#             ZBX_DB_PASSWORD (creds.sh).
#   outputs : initializes (RHEL only)/enables/starts PostgreSQL, creates the
#             zabbix role+database, imports the schema; state_mark_done("db").
#             On failure routes to err_menu('db', ...) (§14 — retry / view
#             log / exit 8; no "re-enter credentials" here since PostgreSQL
#             is always peer-auth for admin actions, no admin password
#             exists to re-enter). The zabbix role's password is set via an
#             ALTER USER stdin heredoc, never via psql -c argv (§10).
#
# TimescaleDB (§12.3 point 4) needs its own third-party apt/yum repository —
# out of scope to auto-add (same call as the EL8/Remi situation in Phase 3:
# too large a trust decision to automate). If the package is already
# resolvable (the user configured that repo themselves), it's used; otherwise
# this prints a warning and continues without it, per spec.

readonly ZBX_PGSQL_SCHEMA=/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz
# Not readonly, and respects a pre-set value — same convention as
# OS_RELEASE_FILE/MEMINFO_FILE (detect.sh), purely so bats can inject a
# fixture path for _db_pgsql_initdb_needed without touching a real system.
: "${ZBX_PGSQL_DATA_DIR:=/var/lib/pgsql/data}"

# --- init / service -----------------------------------------------------------
# _db_pgsql_initdb_needed — RHEL ships PostgreSQL uninitialized (§15.4).
_db_pgsql_initdb_needed() {
  [[ "$DETECT_FAMILY" == "rhel" ]] && [[ ! -f "$ZBX_PGSQL_DATA_DIR/PG_VERSION" ]]
}

# --- role / database (idempotent) ---------------------------------------------
_db_pgsql_role_exists() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='zabbix'" 2>/dev/null |
    grep -q 1
}

_db_pgsql_database_exists() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='zabbix'" 2>/dev/null |
    grep -q 1
}

# _db_pgsql_create_role_and_db — password set via stdin heredoc, never argv
# or an exported env var (§10).
_db_pgsql_create_role_and_db() {
  if ! _db_pgsql_role_exists; then
    run sudo -u postgres createuser zabbix || return 1
  fi
  printf "ALTER USER zabbix PASSWORD '%s';\n" "$ZBX_DB_PASSWORD" |
    run sudo -u postgres psql || return 1
  if ! _db_pgsql_database_exists; then
    run sudo -u postgres createdb -O zabbix zabbix || return 1
  fi
}

# --- pg_hba fallback (§12.3 point 3) --------------------------------------------
# _db_pgsql_hba_path — best-effort location of the active pg_hba.conf.
_db_pgsql_hba_path() {
  sudo -u postgres psql -tAc 'SHOW hba_file' 2>/dev/null | tr -d ' '
}

# _db_pgsql_add_hba_fallback — peer auth for the "zabbix" OS user is the
# expected path (the zabbix-server package creates that system user); if it
# genuinely fails, add one permissive local md5 line for the zabbix role and
# reload, so imports can proceed over a password instead.
_db_pgsql_add_hba_fallback() {
  local hba
  hba="$(_db_pgsql_hba_path)" || true
  if [[ -z "$hba" || ! -f "$hba" ]]; then
    log ERROR "could not locate pg_hba.conf to add a fallback auth line"
    return 1
  fi
  if grep -qE '^local +zabbix +zabbix +md5' "$hba" 2>/dev/null; then
    return 0
  fi
  printf 'local   zabbix   zabbix   md5\n' | run tee -a "$hba" >/dev/null || return 1
  run sudo -u postgres psql -c 'SELECT pg_reload_conf()'
}

# _db_pgsql_pgpass_file — a .pgpass line for the zabbix role, chmod 600,
# cleaned up by the EXIT trap. PGPASSFILE (a path) is the only thing that
# reaches the environment — never the password itself (§10, same pattern as
# MySQL's defaults-extra-file).
_db_pgsql_pgpass_file() {
  local f
  f="$(mktemp -t zbx-pgpass.XXXXXX)"
  chmod 600 "$f"
  ZBX_TEMPFILES+=("$f")
  printf 'localhost:*:zabbix:zabbix:%s\n' "$ZBX_DB_PASSWORD" >"$f"
  printf '%s' "$f"
}

# --- schema import (§12.3 point 3) ----------------------------------------------
_db_pgsql_schema_present() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  sudo -u zabbix psql zabbix -tAc 'SELECT COUNT(*) FROM users' >/dev/null 2>&1
}

# _db_pgsql_import_pipe — zcat | psql, redacted + dry-run aware, same
# hand-rolled pattern as db_mysql.sh's equivalent (a plain single-command
# run() can't express a pipe). AS_ZABBIX=1 uses peer auth; otherwise falls
# back to a password-authenticated connection via a .pgpass file.
_db_pgsql_import_pipe() {
  local as_zabbix="$1" rc pgpass
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: import $ZBX_PGSQL_SCHEMA into zabbix"
    return 0
  fi
  log INFO "RUN: import $ZBX_PGSQL_SCHEMA into zabbix"
  if [[ "$as_zabbix" == "1" ]]; then
    { zcat "$ZBX_PGSQL_SCHEMA" | sudo -u zabbix psql zabbix; } 2>&1 | core_redact >>"$LOG_FILE"
  else
    pgpass="$(_db_pgsql_pgpass_file)"
    { zcat "$ZBX_PGSQL_SCHEMA" | PGPASSFILE="$pgpass" psql -U zabbix -h localhost zabbix; } \
      2>&1 | core_redact >>"$LOG_FILE"
  fi
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

_db_pgsql_import() {
  if _db_pgsql_schema_present; then
    log INFO "zabbix schema already present — skipping import"
    return 0
  fi
  if [[ "$DRY_RUN" != "1" && ! -f "$ZBX_PGSQL_SCHEMA" ]]; then
    log ERROR "schema file not found: $ZBX_PGSQL_SCHEMA"
    return 1
  fi
  if [[ "$DRY_RUN" == "1" ]] || _db_pgsql_import_pipe 1; then
    return 0
  fi
  log WARN "peer auth as the zabbix OS user failed — adding a pg_hba fallback"
  _db_pgsql_add_hba_fallback || return 1
  _db_pgsql_import_pipe 0
}

# --- TimescaleDB (§12.3 point 4, optional, custom mode only) --------------------
# _db_pgsql_timescale_available — is a timescaledb package resolvable right
# now? Only true if the user already configured TimescaleDB's own repo
# (never added automatically here — see the module header).
_db_pgsql_timescale_available() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  case "$DETECT_PKGMGR" in
    apt) apt-cache policy timescaledb-2-postgresql 2>/dev/null | grep -qv 'Unable to locate' ;;
    dnf) dnf info timescaledb-2-postgresql >/dev/null 2>&1 ;;
    zypper)
      zypper info timescaledb 2>/dev/null | grep -q '^Version'
      ;;
    *) return 1 ;;
  esac
}

_db_pgsql_timescale_enable() {
  [[ "$PLAN_TIMESCALE" != "yes" ]] && return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "dry-run: would check TimescaleDB availability and enable it if the PG major matches"
    return 0
  fi
  if ! _db_pgsql_timescale_available; then
    log WARN "TimescaleDB requested but no matching package is available (its own repo isn't configured) — continuing without it"
    return 0
  fi
  local -a pkgs=()
  case "$DETECT_PKGMGR" in
    apt) pkgs=(timescaledb-2-postgresql) ;;
    dnf) pkgs=(timescaledb-2-postgresql) ;;
    zypper) pkgs=(timescaledb) ;;
  esac
  if ! pkg_install "${pkgs[@]}"; then
    log WARN "TimescaleDB package install failed — continuing without it"
    return 0
  fi
  printf 'CREATE EXTENSION IF NOT EXISTS timescaledb;\n' | run sudo -u postgres psql -d zabbix || {
    log WARN "enabling the TimescaleDB extension failed — continuing without it"
    return 0
  }
  log INFO "TimescaleDB enabled — note: some features are TSL-licensed, not Apache; see https://www.zabbix.com/documentation/current/en/manual/appendix/install/timescaledb"
}

# --- orchestration -----------------------------------------------------------------
db_pgsql_provision() {
  if core_state_is_done db; then
    log INFO "database already provisioned (state file) — skipping"
    return 0
  fi

  if _db_pgsql_initdb_needed; then
    while true; do
      run postgresql-setup --initdb && break
      err_menu db "postgresql-setup --initdb failed — see the log"
    done
  fi

  while true; do
    run systemctl enable --now postgresql && break
    err_menu db "starting the postgresql service failed — see the log"
  done

  while true; do
    _db_pgsql_create_role_and_db && break
    err_menu db "creating the zabbix role/database failed — see the log"
  done

  while true; do
    _db_pgsql_import && break
    err_menu db "importing the zabbix schema failed — see the log"
  done

  _db_pgsql_timescale_enable

  state_mark_done db
  log INFO "database provisioned successfully"
}
