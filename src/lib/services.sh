# shellcheck shell=bash
# services.sh — enable & start DB -> zabbix-server -> web (+php-fpm) -> agent (§12.6).
# Also starts a mysql-backed proxy's DB unit -> zabbix-proxy (§15.9 stretch;
# sqlite3-backed skips the DB unit — mutually exclusive with server).
#
# Contract:
#   inputs  : PLAN_DB_ENGINE, PLAN_WEB_SERVER, PLAN_AGENT_TYPE (recommend.sh),
#             DETECT_FAMILY (detect.sh).
#   outputs : systemctl enable --now, in order, for every unit this plan
#             needs; polls is-active up to 15s per unit. A single unit not
#             becoming active is logged (journalctl dump) and does NOT stop
#             the sequence — health checks (Phase 6) surface it with context,
#             per spec. The overall step still routes to err_menu('services',
#             ...) (§14: retry / skip / view log / exit 5) if starting units
#             is impossible altogether (e.g. no systemctl at all).

# _services_wait_active UNIT — poll up to 15s.
_services_wait_active() {
  local unit="$1" waited=0
  while ((waited < 15)); do
    [[ "$(systemctl is-active "$unit" 2>/dev/null)" == "active" ]] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# _services_start_unit UNIT — always returns 0: a slow/failed unit is logged
# with journal context and left for health checks to report, never treated
# as fatal here (§12.6, §13). The is-active poll is a real, blocking
# `systemctl`/`sleep` call outside run()'s own DRY_RUN handling, so it's
# explicitly skipped under --dry-run (no real units exist to poll then).
_services_start_unit() {
  local unit="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: enable --now $unit"
    return 0
  fi
  if ! run systemctl enable --now "$unit"; then
    log WARN "enabling $unit failed — see the log"
  fi
  if ! _services_wait_active "$unit"; then
    log WARN "service $unit is not active after 15s — dumping the last 30 journal lines"
    { journalctl -u "$unit" -n 30 --no-pager 2>&1 || true; } | core_redact >>"$LOG_FILE"
  fi
  return 0
}

# _services_php_fpm_unit — Debian's unit is version-suffixed (phpX.Y-fpm);
# RHEL/SUSE ship the plain "php-fpm" name. Same list-unit-files pattern as
# db_mysql.sh's _db_mysql_unit_name.
_services_php_fpm_unit() {
  local f
  # pipefail (core.sh) means a failing systemctl (missing/no matching units)
  # would fail the whole pipeline — || true so the empty-f fallback below
  # runs instead of tripping set -e on a bare assignment (§15 gotcha).
  f="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk 'NR==1{print $1}')" || true
  if [[ -n "$f" ]]; then
    printf '%s' "${f%.service}"
  else
    printf 'php-fpm'
  fi
}

# _services_web_units — the web server unit, plus php-fpm when this
# family/web-server combo needs it (same rule as config.sh's PHP-tz target:
# nginx anywhere, or RHEL regardless of web server — both are always fpm).
_services_web_units() {
  local -a units=()
  if [[ "$PLAN_WEB_SERVER" == "nginx" ]]; then
    units+=(nginx)
  elif [[ "$DETECT_FAMILY" == "rhel" ]]; then
    units+=(httpd)
  else
    units+=(apache2)
  fi
  if [[ "$PLAN_WEB_SERVER" == "nginx" || "$DETECT_FAMILY" == "rhel" ]]; then
    units+=("$(_services_php_fpm_unit)")
  fi
  local IFS=' '
  printf '%s' "${units[*]}"
}

# --- orchestration ---------------------------------------------------------------
services_start() {
  if core_state_is_done services; then
    log INFO "services already started (state file) — skipping"
    return 0
  fi
  if plan_has server; then
    local db_unit
    case "$PLAN_DB_ENGINE" in
      pgsql) db_unit="postgresql" ;;
      *) db_unit="$(_db_mysql_unit_name 2>/dev/null || printf 'mariadb')" ;;
    esac
    _services_start_unit "$db_unit"
    _services_start_unit zabbix-server
  fi
  if plan_has proxy; then
    # sqlite3-backed proxy has no DB unit to start (§15.9 stretch) — the
    # embedded file is created by zabbix-proxy itself on first start.
    if [[ "$PLAN_DB_ENGINE" != "sqlite3" ]]; then
      _services_start_unit "$(_db_mysql_unit_name 2>/dev/null || printf 'mariadb')"
    fi
    # Unit name is always "zabbix-proxy" regardless of DB backend (verified
    # against the real RPM/deb packages).
    _services_start_unit zabbix-proxy
  fi
  if plan_has frontend; then
    local -a web_units=()
    IFS=' ' read -ra web_units <<<"$(_services_web_units)"
    local u
    for u in "${web_units[@]}"; do
      _services_start_unit "$u"
    done
  fi
  if plan_has agent; then
    if [[ "$PLAN_AGENT_TYPE" == "zabbix-agent2" ]]; then
      _services_start_unit zabbix-agent2
    else
      _services_start_unit zabbix-agent
    fi
  fi
  state_mark_done services
  log INFO "services step complete"
}
