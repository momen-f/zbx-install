# shellcheck shell=bash
# health.sh — post-install checks + the final install summary (§13).
#
# Contract:
#   inputs  : PLAN_* (recommend.sh), ZBX_DB_PASSWORD (creds.sh), DETECT_FAMILY
#             (detect.sh), ZBX_ETC_DIR (config.sh), ZBX_DEGRADED_STEPS
#             (core.sh).
#   outputs : health_run_checks() runs only the §13 checks this plan's
#             components need, prints a red failure block with hints on any
#             failure, and returns 0/1 — it never prints the green summary
#             itself, so main.sh can call health_print_summary() exactly
#             once regardless of whether checks passed cleanly or were
#             skipped-as-degraded via err_menu('health', ...) (§14: re-run
#             checks / view log / continue to summary anyway (degraded) /
#             exit 6 — no "back to plan", §13 doesn't offer it). Unattended:
#             exit 6.
#
# Checks are skipped (not failed) when this plan has no matching component
# (agent-only has no server/frontend checks) or, for check 9, when
# zabbix_get simply isn't installed (§13: "if zabbix-get installed").

# Each check appends "NAME|0-or-1|HINT" (HINT empty on pass).
ZBX_HEALTH_RESULTS=()

_health_record() {
  ZBX_HEALTH_RESULTS+=("$1|$2|$3")
}

# Not readonly, and respects a pre-set value — same convention as
# ZBX_ETC_DIR/OS_RELEASE_FILE, here so bats can set it to 0 (checks exactly
# once, no delay) instead of eating the real grace period on every "fails"
# test. Real value: services.sh already waited up to 15s per unit before
# this step even starts, but a unit can still land in a fleeting
# "activating" window a moment later — observed for real in CI's
# containerized systemd (httpd took ~1-2s past its own "Started" log line to
# report is-active), and a first boot on a real target can plausibly hit the
# same brief gap, so this is a genuine robustness fix, not a CI-only patch.
: "${ZBX_HEALTH_SERVICE_RETRY_SECONDS:=5}"

# _health_wait_active UNIT — poll is-active for up to
# ZBX_HEALTH_SERVICE_RETRY_SECONDS, always checking at least once.
_health_wait_active() {
  local unit="$1" waited=0
  while true; do
    # TEMPORARY diagnostic (remove once the CI timing question is settled).
    # rc, not the printed text, is the real is-active contract (matches
    # --quiet) — the text is only logged for visibility.
    local state rc
    state="$(systemctl is-active "$unit" 2>&1)" && rc=0 || rc=$?
    log INFO "DIAG: $unit is-active (attempt $((waited + 1))) -> '$state' (rc=$rc)"
    ((rc == 0)) && return 0
    ((waited >= ZBX_HEALTH_SERVICE_RETRY_SECONDS)) && return 1
    sleep 1
    waited=$((waited + 1))
  done
}

# --- individual checks (§13 table) ----------------------------------------------

_health_check_server_service() {
  if _health_wait_active zabbix-server; then
    _health_record "zabbix-server service" 0 ""
  else
    _health_record "zabbix-server service" 1 "journalctl -u zabbix-server -n 50"
  fi
}

_health_check_agent_service() {
  local unit="zabbix-agent2"
  [[ "$PLAN_AGENT_TYPE" == "zabbix-agent2" ]] || unit="zabbix-agent"
  if _health_wait_active "$unit"; then
    _health_record "$unit service" 0 ""
  else
    _health_record "$unit service" 1 "journalctl -u $unit -n 50"
  fi
}

# _health_check_web_service — reuses services.sh's own unit list (§12.6) so
# the two never drift apart.
_health_check_web_service() {
  local -a units=()
  IFS=' ' read -ra units <<<"$(_services_web_units)"
  local -a failed=()
  local u
  for u in "${units[@]}"; do
    _health_wait_active "$u" || failed+=("$u")
  done
  if ((${#failed[@]} == 0)); then
    _health_record "web service (${units[*]})" 0 ""
  else
    local hint="config test: nginx -t"
    [[ "$PLAN_WEB_SERVER" == "nginx" ]] || hint="config test: apachectl configtest"
    _health_record "web service (${failed[*]})" 1 "$hint"
  fi
}

# _health_check_port PORT LABEL HINT — "non-empty" per §13 means ss printed
# more than just its own header line.
_health_check_port() {
  local port="$1" label="$2" hint="$3" n
  n="$(ss -ltn "sport = :$port" 2>/dev/null | wc -l)" || true
  if ((n > 1)); then
    _health_record "$label (port $port)" 0 ""
  else
    _health_record "$label (port $port)" 1 "$hint"
  fi
}

# _health_mysql_auth_setup — lazily build a zabbix-user defaults file (§10:
# never -p"$PASS" on argv), shared by the two DB checks below so only one
# temp file is created per run.
_HEALTH_MYSQL_ARGS=()
_health_mysql_auth_setup() {
  ((${#_HEALTH_MYSQL_ARGS[@]} > 0)) && return 0
  local defaults_file
  defaults_file="$(_db_mysql_defaults_file zabbix "$ZBX_DB_PASSWORD")"
  _HEALTH_MYSQL_ARGS=(mysql "--defaults-extra-file=$defaults_file")
}

_health_check_db_reachable() {
  local ok=1
  if [[ "$PLAN_DB_ENGINE" == "pgsql" ]]; then
    # Peer auth as the "zabbix" OS user — same connection path db_pgsql.sh
    # itself used to import the schema (§12.3), not the admin path.
    sudo -u zabbix psql zabbix -tAc 'SELECT 1' >/dev/null 2>&1 && ok=0
  else
    _health_mysql_auth_setup
    printf 'SELECT 1;\n' | "${_HEALTH_MYSQL_ARGS[@]}" zabbix >/dev/null 2>&1 && ok=0
  fi
  if ((ok == 0)); then
    _health_record "DB reachable as zabbix" 0 ""
  elif [[ "$PLAN_DB_ENGINE" == "pgsql" ]]; then
    _health_record "DB reachable as zabbix" 1 "check DBPassword / pg_hba.conf"
  else
    _health_record "DB reachable as zabbix" 1 "check DBPassword / grants"
  fi
}

_health_check_schema_present() {
  local ok=1
  if [[ "$PLAN_DB_ENGINE" == "pgsql" ]]; then
    _db_pgsql_schema_present && ok=0
  else
    _health_mysql_auth_setup
    local rows
    rows="$(printf 'SELECT COUNT(*) FROM users;\n' | "${_HEALTH_MYSQL_ARGS[@]}" -N zabbix 2>/dev/null)" || true
    [[ "${rows:-0}" =~ ^[0-9]+$ ]] && ((rows >= 1)) && ok=0
  fi
  if ((ok == 0)); then
    _health_record "schema present (users table)" 0 ""
  else
    _health_record "schema present (users table)" 1 "re-run the install to retry the schema import (state file tracks it)"
  fi
}

_health_check_frontend_http() {
  local code
  code="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/zabbix/ 2>/dev/null)" || true
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    _health_record "frontend HTTP" 0 ""
  else
    _health_record "frontend HTTP" 1 "check web conf, SELinux booleans, php-fpm"
  fi
}

# _health_check_agent_answers — skipped entirely (not failed) when
# zabbix-get isn't installed (PLAN_TOOLS defaults to "no"), per §13.
_health_check_agent_answers() {
  command -v zabbix_get >/dev/null 2>&1 || return 0
  local answer
  answer="$(zabbix_get -s 127.0.0.1 -k agent.ping 2>/dev/null)" || true
  if [[ "$answer" == "1" ]]; then
    _health_record "agent answers (zabbix_get)" 0 ""
  else
    _health_record "agent answers (zabbix_get)" 1 "check the agent's Server= line"
  fi
}

# --- report --------------------------------------------------------------------

_health_print_failures() {
  local n_failed="$1" n_total="$2"
  printf '\n%s%s%d of %d checks failed%s\n' "$C_RED" "$C_BOLD" "$n_failed" "$n_total" "$C_RESET"
  local r name pass hint
  for r in ${ZBX_HEALTH_RESULTS[@]+"${ZBX_HEALTH_RESULTS[@]}"}; do
    IFS='|' read -r name pass hint <<<"$r"
    [[ "$pass" == "0" ]] && continue
    printf '  %s✗ %s%s — %s\n' "$C_RED" "$name" "$C_RESET" "$hint"
  done
  printf '\n  See log: %s\n' "$LOG_FILE"
}

# _health_print_report — tallies ZBX_HEALTH_RESULTS; prints the red block and
# returns 1 on any failure, otherwise returns 0 silently (the green summary
# is main.sh's job — see the module header).
_health_print_report() {
  local n_total=0 n_failed=0 r name pass hint
  for r in ${ZBX_HEALTH_RESULTS[@]+"${ZBX_HEALTH_RESULTS[@]}"}; do
    IFS='|' read -r name pass hint <<<"$r"
    n_total=$((n_total + 1))
    [[ "$pass" == "0" ]] || n_failed=$((n_failed + 1))
  done
  ((n_failed == 0)) && return 0
  _health_print_failures "$n_failed" "$n_total"
  return 1
}

# health_run_checks — orchestrator (§13, only the rows this plan needs).
health_run_checks() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: skipping health checks — nothing was actually installed/started"
    return 0
  fi
  ZBX_HEALTH_RESULTS=()
  if plan_has server; then
    _health_check_server_service
    _health_check_port 10051 "zabbix-server" "check DBPassword; server log /var/log/zabbix/zabbix_server.log"
    _health_check_db_reachable
    _health_check_schema_present
  fi
  if plan_has frontend; then
    _health_check_web_service
    _health_check_frontend_http
  fi
  if plan_has agent; then
    _health_check_agent_service
    _health_check_port 10050 "zabbix-agent" "check the agent log"
    _health_check_agent_answers
  fi
  _health_print_report
}

# --- final summary (§13: printed once all checks pass OR the user chose
# "continue to summary anyway (degraded)") ---------------------------------------

# _health_detect_ip — best-effort primary IP for the frontend URL; falls
# back to loopback (always valid) if hostname -I is unavailable/empty.
_health_detect_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  printf '%s' "${ip:-127.0.0.1}"
}

health_print_summary() {
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if ((${#ZBX_DEGRADED_STEPS[@]} > 0)); then
    printf '\n%s%sInstall finished, but some steps were skipped (degraded): %s%s\n' \
      "$C_YELLOW" "$C_BOLD" "${ZBX_DEGRADED_STEPS[*]}" "$C_RESET"
  else
    printf '\n%s%sAll checks passed — Zabbix is up.%s\n' "$C_GREEN" "$C_BOLD" "$C_RESET"
  fi

  if plan_has frontend; then
    local ip
    ip="$(_health_detect_ip)"
    printf '\n  Frontend:        http://%s/zabbix/\n' "$ip"
    [[ "$ip" != "127.0.0.1" ]] && printf '                   http://127.0.0.1/zabbix/\n'
    printf '  %sDefault login:   Admin / zabbix — change this password now.%s\n' "$C_BOLD" "$C_RESET"
  fi

  printf '\n  Config files:\n'
  plan_has server && printf '    %s\n' "$ZBX_ETC_DIR/zabbix_server.conf"
  plan_has frontend && printf '    %s\n' "$ZBX_ETC_DIR/web/zabbix.conf.php"
  plan_has agent && printf '    %s\n' "$(_config_agent_conf_path)"

  printf '\n  Logs:\n'
  [[ -n "$LOG_FILE" ]] && printf '    %s (installer)\n' "$LOG_FILE"
  plan_has server && printf '    /var/log/zabbix/zabbix_server.log\n'
  plan_has agent && printf '    /var/log/zabbix/zabbix_agent2.log\n'

  if plan_has server; then
    printf '\n  Database:        zabbix (user zabbix, engine %s)\n' "$PLAN_DB_ENGINE"
    if [[ "$PLAN_CREDS_FILE" != "none" && -n "$PLAN_CREDS_FILE" && -f "$PLAN_CREDS_FILE" ]]; then
      printf '  Credentials:     %s (delete after moving it to a vault)\n' "$PLAN_CREDS_FILE"
    fi
  fi

  printf '\n  Uninstall:       re-run this installer with --uninstall\n'
}
