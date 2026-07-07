# shellcheck shell=bash
# recommend.sh — deterministic detection → recommended stack (§9), CLI-override
# resolution into the final plan, package computation (§12.2), and the plan
# summary / pipeline preview rendering.
#
# Contract:
#   inputs  : DETECT_* globals (detect.sh); OPT_* CLI overrides, FORCED_FAMILY
#             and mode from main.sh (all read via ${VAR:-} so pure helpers stay
#             testable without main.sh); DRY_RUN/UNATTENDED from core.
#   outputs : REC_* (the §9 recommendation, untouched by overrides), PLAN_*
#             (the final plan: recommendation + flags + custom picks),
#             PLAN_PACKAGES, and the printed plan summary. Rule helpers are
#             pure (args in → stdout out) for bats.

# --- REC/PLAN globals (assigned by recommend_run / resolve_plan) --------------
REC_ZBX_VERSION="" REC_DB_ENGINE="" REC_WEB_SERVER="" REC_COMPONENTS=""
REC_SIZING="" REC_TZ=""
PLAN_ZBX_VERSION="" PLAN_DB_ENGINE="" PLAN_WEB_SERVER="" PLAN_COMPONENTS=""
PLAN_AGENT_TYPE="zabbix-agent2" PLAN_AGENT_PLUGINS="" PLAN_TOOLS="no"
PLAN_TIMESCALE="no" PLAN_SIZING="" PLAN_TZ="" PLAN_UPDATE=""
PLAN_OPEN_FIREWALL="no" PLAN_ZBX_SERVER_IP="127.0.0.1" PLAN_CREDS_FILE=""
PLAN_PACKAGES=""

# --- pure rules (§9) -----------------------------------------------------------
# Rule 1: default to the newest LTS release; standard releases (e.g. 7.4) stay
# selectable and are labeled "current stable".
rec_zbx_version() { printf '%s' "$ZBX_DEFAULT_VERSION"; }

# _zbx_is_lts VERSION — is VERSION one of the Long Term Support releases
# (§9 rule 1)? Membership test over ZBX_LTS_VERSIONS (detect.sh), which can
# hold more than one entry (e.g. 7.0 and a future 8.0).
_zbx_is_lts() {
  local v
  for v in "${ZBX_LTS_VERSIONS[@]}"; do
    [[ "$v" == "$1" ]] && return 0
  done
  return 1
}

rec_version_label() {
  if _zbx_is_lts "$1"; then
    printf 'LTS'
  else
    printf 'current stable'
  fi
}

# Rule 2 — $1 = DETECT_DB_PRESENT (comma list or "none"): reuse what is already
# there (pgsql wins, then the more specific mariadb), else default MariaDB.
rec_db_engine() {
  case ",$1," in
    *,pgsql,*) printf 'pgsql' ;;
    *,mariadb,*) printf 'mariadb' ;;
    *,mysql,*) printf 'mysql' ;;
    *) printf 'mariadb' ;;
  esac
}

# Rule 3 — $1 = DETECT_WEB_PRESENT: nginx only when present without apache.
rec_web_server() {
  if [[ ",$1," == *,nginx,* && ",$1," != *,apache,* ]]; then
    printf 'nginx'
  else
    printf 'apache'
  fi
}

# Rule 4 — $1 = RAM MB: full stack unless < 2 GiB (then suggest agent-only).
rec_components() {
  if (($1 < 2048)); then
    printf 'agent'
  else
    printf 'server,frontend,agent'
  fi
}

# Rule 5 — $1 = RAM MB → sizing preset name.
rec_sizing_preset() {
  if (($1 < 2048)); then
    printf 'warn'
  elif (($1 < 4096)); then
    printf 'small'
  elif (($1 <= 8192)); then
    printf 'medium'
  else
    printf 'large'
  fi
}

# Rule 5 table — preset → "innodb_buffer_pool_size shared_buffers CacheSize
# ValueCacheSize" (§9). Rationale: DB engine, Zabbix server and frontend share
# the host, so the DB buffer gets ~25% of RAM (the usual 70%+ dedicated-DB
# guidance would starve the rest); CacheSize (config cache) and ValueCacheSize
# (history reads) grow with monitored items — Zabbix defaults (32M/8M) suit
# tiny installs, so each tier roughly doubles the headroom with RAM.
rec_sizing_values() {
  case "$1" in
    warn) printf '128M 128M 32M 64M' ;;
    small) printf '512M 512M 64M 128M' ;;
    medium) printf '1G 1G 128M 256M' ;;
    large) printf '2G 2G 256M 512M' ;;
    *) printf '' ;;
  esac
}

# Rule 6 — timedatectl or empty; the flow resolves empty to a prompt/UTC.
rec_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  printf '%s' "$tz"
}

# _valid_zbx_version VERSION — is it one we offer (§4)?
_valid_zbx_version() {
  local v
  for v in "${SUPPORTED_ZBX_VERSIONS[@]}"; do
    if [[ "$v" == "$1" ]]; then return 0; fi
  done
  return 1
}

# _valid_components LIST — comma list of server|frontend|agent|proxy, non-empty.
# proxy is not offered in the interactive custom-mode component picker (it's
# a separate --proxy-only mode, mirroring agent-only) — accepted here only so
# --config/--components can still express a proxy plan explicitly, but ONLY on
# its own: proxy is mutually exclusive with server/frontend (§15.9 — a host is
# either a full server or a lightweight proxy, never both). A mixed list like
# "server,proxy" is rejected, because the two collide destructively: both
# daemons bind :10051, and plan_db_name/_db_mysql_schema_file resolve proxy
# first, so the server's DB step would provision into the proxy's database and
# schema while zabbix_server.conf still points at DBName=zabbix.
_valid_components() {
  local -a toks=()
  local c
  IFS=, read -ra toks <<<"$1"
  if ((${#toks[@]} == 0)); then return 1; fi
  for c in "${toks[@]}"; do
    case "$c" in
      server | frontend | agent | proxy) ;;
      *) return 1 ;;
    esac
  done
  # proxy only ever stands alone (§15.9).
  if [[ ",$1," == *",proxy,"* && "$1" != "proxy" ]]; then return 1; fi
  return 0
}

# --- orchestration -------------------------------------------------------------
recommend_run() {
  REC_ZBX_VERSION="$(rec_zbx_version)"
  REC_DB_ENGINE="$(rec_db_engine "$DETECT_DB_PRESENT")"
  REC_WEB_SERVER="$(rec_web_server "$DETECT_WEB_PRESENT")"
  REC_COMPONENTS="$(rec_components "$DETECT_RAM_MB")"
  REC_SIZING="$(rec_sizing_preset "$DETECT_RAM_MB")"
  REC_TZ="$(rec_timezone)"
  log INFO "recommendation: zbx=$REC_ZBX_VERSION db=$REC_DB_ENGINE web=$REC_WEB_SERVER comps=$REC_COMPONENTS sizing=$REC_SIZING tz=${REC_TZ:-unknown}"
  if [[ "$REC_SIZING" == "warn" ]]; then
    log WARN "RAM ${DETECT_RAM_MB} MB is below 2 GiB — full stack not recommended, suggesting agent-only (§9)"
  fi
}

# resolve_plan — recommendation + CLI overrides → PLAN_*. Custom-mode pickers
# then mutate PLAN_* further, so their defaults naturally include the flags.
#
# OPT_AGENT_TYPE/OPT_TIMESCALE/OPT_SERVER_IP/OPT_TZ/OPT_OPEN_FIREWALL have no
# CLI flag (SPEC §7 doesn't offer one) — only configfile.sh's Appendix A keys
# set them. Without this override point, resolve_plan's own hardcoded
# defaults below would silently clobber a config-file value every time
# prepare_plan calls it, since the custom-mode pickers that would otherwise
# apply a non-default choice are skipped entirely under UNATTENDED=1 (§18
# Phase 7 — a --config run never touches /dev/tty).
resolve_plan() {
  PLAN_ZBX_VERSION="${OPT_ZBX_VERSION:-$REC_ZBX_VERSION}"
  case "${OPT_DB:-}" in
    pgsql) PLAN_DB_ENGINE="pgsql" ;;
    mariadb) PLAN_DB_ENGINE="mariadb" ;; # config-file DB_ENGINE=mariadb: force it explicitly
    sqlite3) PLAN_DB_ENGINE="sqlite3" ;; # proxy-only stretch (§15.9): meaningless for server, not cross-validated
    mysql)
      # --db mysql covers MariaDB (§7): keep an existing MySQL-family engine,
      # otherwise fall to the MariaDB default.
      case "$REC_DB_ENGINE" in
        mariadb | mysql) PLAN_DB_ENGINE="$REC_DB_ENGINE" ;;
        *) PLAN_DB_ENGINE="mariadb" ;;
      esac
      ;;
    *) PLAN_DB_ENGINE="$REC_DB_ENGINE" ;;
  esac
  PLAN_WEB_SERVER="${OPT_WEB:-$REC_WEB_SERVER}"
  PLAN_COMPONENTS="${OPT_COMPONENTS:-$REC_COMPONENTS}"
  PLAN_AGENT_TYPE="${OPT_AGENT_TYPE:-zabbix-agent2}"
  PLAN_AGENT_PLUGINS=""
  PLAN_TOOLS="no"
  PLAN_TIMESCALE="${OPT_TIMESCALE:-no}"
  PLAN_SIZING="$REC_SIZING"
  PLAN_TZ="${OPT_TZ:-$REC_TZ}"
  if [[ -n "${OPT_OPEN_FIREWALL:-}" ]]; then
    PLAN_OPEN_FIREWALL="$OPT_OPEN_FIREWALL"
  elif [[ "$DETECT_FIREWALL" != "none" ]]; then
    PLAN_OPEN_FIREWALL="yes" # §12.5: default yes when a firewall is active
  else
    PLAN_OPEN_FIREWALL="no"
  fi
  PLAN_UPDATE="${OPT_UPDATE:-}" # empty = ask once in the flow (§11)
  PLAN_ZBX_SERVER_IP="${OPT_SERVER_IP:-127.0.0.1}"
  PLAN_CREDS_FILE="${OPT_CREDS_FILE:-/root/zbx-install-credentials.txt}"
  # proxy-only stretch (§15.9): must match the Proxy object's Name on the
  # real server exactly, so a real, unique hostname is a far more useful
  # default than the literal "Zabbix proxy" placeholder the packaged config
  # template ships with.
  PLAN_PROXY_HOSTNAME="${OPT_PROXY_HOSTNAME:-$(hostname 2>/dev/null || true)}"
  [[ -n "$PLAN_PROXY_HOSTNAME" ]] || PLAN_PROXY_HOSTNAME="zabbix-proxy"
}

# plan_has COMPONENT — is it in the comma list?
plan_has() { [[ ",$PLAN_COMPONENTS," == *",$1,"* ]]; }

# plan_db_name — the mysql/pgsql database name this plan's DB step creates.
# server and proxy are mutually exclusive components (never both in the same
# plan — a host is either a full server or a lightweight proxy, never
# both), so a single helper covering both is unambiguous. Not meaningful for
# a sqlite3-backed proxy (a file path, not a database name — see
# config_render_proxy, config.sh).
plan_db_name() {
  if plan_has proxy; then
    printf 'zabbix_proxy'
  else
    printf 'zabbix'
  fi
}

# --- package computation (§12.2) ------------------------------------------------
plan_packages() {
  local -a pkgs=()
  if plan_has server; then
    if [[ "$PLAN_DB_ENGINE" == "pgsql" ]]; then
      pkgs+=(zabbix-server-pgsql)
    else
      pkgs+=(zabbix-server-mysql)
    fi
    pkgs+=(zabbix-sql-scripts)
  fi
  if plan_has frontend; then
    # Verified live 2026-07-05: the frontend package is DB-engine-specific
    # on RHEL/SLES (zabbix-web-mysql / zabbix-web-pgsql) — SPEC.md's "identical
    # names across families" assumption only holds for apt, which uses the
    # generic zabbix-frontend-php regardless of DB engine.
    if [[ "$DETECT_FAMILY" == "debian" ]]; then
      pkgs+=(zabbix-frontend-php)
    elif [[ "$PLAN_DB_ENGINE" == "pgsql" ]]; then
      pkgs+=(zabbix-web-pgsql)
    else
      pkgs+=(zabbix-web-mysql)
    fi
    # Verified live 2026-07-05: SLES only ships these two under a "-php8"
    # suffix (zabbix-apache-conf-php8 / zabbix-nginx-conf-php8) — the
    # unsuffixed names don't exist there at all, only on apt/dnf.
    local suffix=""
    [[ "$DETECT_FAMILY" == "suse" ]] && suffix="-php8"
    if [[ "$PLAN_WEB_SERVER" == "nginx" ]]; then
      pkgs+=("zabbix-nginx-conf${suffix}")
    else
      pkgs+=("zabbix-apache-conf${suffix}")
    fi
  fi
  if plan_has proxy; then
    # sqlite3 (§15.9 stretch): no zabbix-sql-scripts companion needed — the
    # embedded DB is created automatically on first start, verified against
    # the real Zabbix docs and package dependency metadata, unlike mysql's
    # proxy.sql which still needs a manual import (db_mysql.sh).
    if [[ "$PLAN_DB_ENGINE" == "sqlite3" ]]; then
      pkgs+=(zabbix-proxy-sqlite3)
    else
      pkgs+=(zabbix-proxy-mysql zabbix-sql-scripts)
    fi
  fi
  if plan_has agent; then
    pkgs+=("$PLAN_AGENT_TYPE")
    local -a plugs=()
    local p
    IFS=, read -ra plugs <<<"$PLAN_AGENT_PLUGINS"
    for p in ${plugs[@]+"${plugs[@]}"}; do
      pkgs+=("zabbix-agent2-plugin-$p")
    done
  fi
  if [[ "$PLAN_TOOLS" == "yes" ]]; then
    pkgs+=(zabbix-get zabbix-sender)
  fi
  if [[ "$DETECT_FAMILY" == "rhel" && "$DETECT_SELINUX" == "enforcing" ]]; then
    pkgs+=(zabbix-selinux-policy) # §12.2: RHEL only, automatic
  fi
  local -a extra=()
  # Explicit IFS on the read: the global IFS ($'\n\t') would not split spaces.
  IFS=' ' read -ra extra <<<"$(_plan_db_web_packages)"
  pkgs+=(${extra[@]+"${extra[@]}"})
  local IFS=' '
  PLAN_PACKAGES="${pkgs[*]:-}"
}

# _plan_db_web_packages — echo (space-separated) the DB engine and web server
# packages when the plan needs them and they are not already installed (§12.2).
# Echo, not nameref: namerefs need bash 4.3, we target 4.2 (§3).
# php-fpm companions for nginx vary per family — resolved in Phase 3 (§12.2).
# proxy shares this gate with server (§15.9 stretch) — a mysql-backed proxy
# needs the same DB server package a mysql-backed full server would; a
# sqlite3-backed proxy matches none of the case arms below and correctly
# adds nothing, no separate exclusion needed.
_plan_db_web_packages() {
  local -a pk=()
  if (plan_has server || plan_has proxy) && [[ ",$DETECT_DB_PRESENT," != *",$PLAN_DB_ENGINE,"* ]]; then
    case "$PLAN_DB_ENGINE" in
      mariadb) pk+=(mariadb-server) ;;
      mysql) pk+=(mysql-server) ;;
      pgsql)
        pk+=(postgresql)
        if [[ "$DETECT_FAMILY" == "rhel" ]]; then
          pk+=(postgresql-server) # RHEL splits client/server (§12.2)
        fi
        ;;
    esac
  fi
  if plan_has frontend && [[ ",$DETECT_WEB_PRESENT," != *",$PLAN_WEB_SERVER,"* ]]; then
    if [[ "$PLAN_WEB_SERVER" == "nginx" ]]; then
      pk+=(nginx)
    elif [[ "$DETECT_FAMILY" == "rhel" ]]; then
      pk+=(httpd)
    else
      pk+=(apache2)
    fi
  fi
  local IFS=' '
  printf '%s' "${pk[*]:-}"
}

# --- plan summary ---------------------------------------------------------------
plan_report() {
  local mode="$1"
  local IFS=' '
  local banner=""
  if [[ "$DRY_RUN" == "1" ]]; then banner=" (DRY-RUN)"; fi
  printf '\n%sPlan summary%s%s\n' "$C_BOLD" "$banner" "$C_RESET"
  ui_row "Mode:" "$mode"
  ui_row "Target OS:" "$DETECT_OS_NAME"
  ui_row "Zabbix version:" "$PLAN_ZBX_VERSION ($(rec_version_label "$PLAN_ZBX_VERSION"))"
  ui_row "Components:" "$PLAN_COMPONENTS"
  if plan_has server || plan_has frontend || plan_has proxy; then
    local dbnote="new install"
    if [[ "$PLAN_DB_ENGINE" == "sqlite3" ]]; then
      dbnote="embedded, created automatically"
    elif [[ ",$DETECT_DB_PRESENT," == *",$PLAN_DB_ENGINE,"* ]]; then
      dbnote="existing"
    fi
    ui_row "DB engine:" "$PLAN_DB_ENGINE ($dbnote)"
  fi
  if plan_has frontend; then
    ui_row "Web server:" "$PLAN_WEB_SERVER"
  fi
  if plan_has agent; then
    ui_row "Agent:" "$PLAN_AGENT_TYPE${PLAN_AGENT_PLUGINS:+ (plugins: $PLAN_AGENT_PLUGINS)}"
  fi
  if plan_has server; then
    local -a sv=()
    read -ra sv <<<"$(rec_sizing_values "$PLAN_SIZING")"
    ui_row "Sizing preset:" "$PLAN_SIZING (db buffer ${sv[0]}, CacheSize ${sv[2]}, ValueCacheSize ${sv[3]})"
    if [[ "$PLAN_DB_ENGINE" == "pgsql" && "$PLAN_TIMESCALE" == "yes" ]]; then
      ui_row "TimescaleDB:" "yes (version must match the PG major, §12.3)"
    fi
  fi
  ui_row "Timezone:" "$PLAN_TZ"
  ui_row "Update system:" "${PLAN_UPDATE:-no}"
  if [[ "$PLAN_OPEN_FIREWALL" == "yes" ]]; then
    ui_row "Firewall:" "open 10050,10051,80,443 via $DETECT_FIREWALL"
  elif [[ "$DETECT_FIREWALL" != "none" ]]; then
    # PLAN_OPEN_FIREWALL=no here means the user declined in the custom picker
    # — the firewall is still active and may be blocking the needed ports.
    ui_row "Firewall:" "no action — $DETECT_FIREWALL active but left as-is; needed ports: 10050,10051,80,443" "$C_YELLOW"
  else
    ui_row "Firewall:" "no action — none active${DETECT_FW_NOTE:+ ($DETECT_FW_NOTE)}; needed ports: 10050,10051,80,443"
  fi
  if [[ "$DETECT_SELINUX" == "enforcing" ]]; then
    ui_row "SELinux:" "enforcing — will set httpd_can_connect_zabbix + zabbix_can_network (§12.5)"
  fi
  if [[ "$mode" == "agent-only" || "$mode" == "proxy-only" ]]; then
    ui_row "Server IP:" "$PLAN_ZBX_SERVER_IP"
  fi
  if plan_has proxy; then
    ui_row "Proxy hostname:" "$PLAN_PROXY_HOSTNAME"
    _plan_warn "this Hostname must be registered as a matching Proxy object on the real Zabbix server (Administration > Proxies) before this proxy can connect — see §15.9"
  fi
  ui_row "Packages:" "$PLAN_PACKAGES"
  local cred="not needed (no database in this plan)"
  if plan_has server || (plan_has proxy && [[ "$PLAN_DB_ENGINE" != "sqlite3" ]]); then
    if [[ "$UNATTENDED" == "1" || "${OPT_GENPASS:-0}" == "1" ]]; then
      cred="auto-generated"
    else
      cred="collected (hidden)"
    fi
  fi
  ui_row "Credentials:" "$cred; summary file: $PLAN_CREDS_FILE"
  # Matches admin_pass_update's own gate exactly (adminpass.sh): a config
  # file can set ZBX_ADMIN_PASSWORD directly regardless of components, so
  # checking the value alone isn't enough to predict whether this will
  # actually run — plan_has frontend/server must agree too, or a
  # frontend-only + ADMIN_PASS=... plan would show a promise this step
  # will silently no-op on.
  if [[ -n "${ZBX_ADMIN_PASSWORD:-}" ]] && plan_has frontend && plan_has server; then
    ui_row "Admin login:" "will be changed after install (§15 gotcha 8)"
  fi
  ui_row "Log file:" "$LOG_FILE"
  plan_report_warnings
  printf '\n  Nothing has been executed yet.\n'
}

# _plan_warn MSG — one yellow warning line.
_plan_warn() { printf '  %s⚠ %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }

plan_report_warnings() {
  if [[ "${FORCED_FAMILY:-0}" == "1" ]]; then
    _plan_warn "unsupported OS forced to family '$DETECT_FAMILY' — best effort only"
  fi
  if [[ "$REC_SIZING" == "warn" ]]; then
    _plan_warn "RAM ${DETECT_RAM_MB} MB < 2 GiB: full stack not recommended (suggestion was agent-only, §9)"
  fi
  if [[ "$DETECT_ARCH_OK" == "maybe" ]]; then
    _plan_warn "arch $DETECT_ARCH: Zabbix repo coverage varies — the repo probe may fail (§15.10)"
  fi
  if [[ "$DETECT_IS_CONTAINER" == "yes" ]]; then
    _plan_warn "container detected: systemd services may not work (§15.12)"
  fi
  if [[ "$DETECT_ZBX_PRESENT" == "yes" ]]; then
    _plan_warn "existing Zabbix detected — proceeding may conflict (repair/uninstall arrive in Phase 7)"
  fi
  # RHEL 8's native AppStream tops out at php:7.4; Zabbix 7.0/7.4 frontends
  # need PHP >= 8.0.0 (verified live 2026-07-05).
  # Warn at plan time; pkg.sh gives the same Remi hint if the install fails.
  if [[ "$DETECT_FAMILY" == "rhel" && "$DETECT_OS_MAJOR" == "8" ]] && plan_has frontend; then
    _plan_warn "RHEL 8's native PHP tops out at 7.4, but this frontend needs PHP >= 8.0.0 — install will fail unless a newer PHP (e.g. via the Remi repo) is already configured"
  fi
  plan_port_warnings
}

# Warn only about conflicts on ports the selected components actually need.
plan_port_warnings() {
  local p
  local -a ports=()
  case "$DETECT_PORT_CONFLICTS" in none | unknown) return 0 ;; esac
  IFS=, read -ra ports <<<"$DETECT_PORT_CONFLICTS"
  for p in ${ports[@]+"${ports[@]}"}; do
    case "$p" in
      10051) if plan_has server; then _plan_warn "port 10051 already in use — zabbix-server will not bind"; fi ;;
      10050) if plan_has agent; then _plan_warn "port 10050 already in use — the agent will not bind"; fi ;;
      80 | 443) if plan_has frontend; then _plan_warn "port $p already in use — check the web server vhost"; fi ;;
      3306)
        # §8: only relevant when that engine is newly installed by this plan.
        if plan_has server && [[ "$PLAN_DB_ENGINE" != "pgsql" ]] &&
          [[ ",$DETECT_DB_PRESENT," != *",$PLAN_DB_ENGINE,"* ]]; then
          _plan_warn "port 3306 already in use — new $PLAN_DB_ENGINE install may fail to bind"
        fi
        ;;
      5432)
        if plan_has server && [[ "$PLAN_DB_ENGINE" == "pgsql" ]] &&
          [[ ",$DETECT_DB_PRESENT," != *",pgsql,"* ]]; then
          _plan_warn "port 5432 already in use — new PostgreSQL install may fail to bind"
        fi
        ;;
    esac
  done
}

# --- pipeline preview (execution lands in Phases 3–6) ----------------------------
_plan_step() {
  printf '  %d. %-9s %s\n' "$_PLAN_STEP_N" "$1" "$2"
  _PLAN_STEP_N=$((_PLAN_STEP_N + 1))
}

plan_pipeline_preview() {
  _PLAN_STEP_N=1
  printf '\n%sPipeline for this plan%s:\n' "$C_BOLD" "$C_RESET"
  if [[ "${PLAN_UPDATE:-no}" == "yes" ]]; then
    _plan_step "update" "full system update via $DETECT_PKGMGR (§11)"
  fi
  _plan_step "repo" "add the Zabbix $PLAN_ZBX_VERSION repository for $DETECT_OS_ID $DETECT_OS_VERSION (§12.1)"
  _plan_step "packages" "install: $PLAN_PACKAGES (§12.2)"
  if plan_has server || (plan_has proxy && [[ "$PLAN_DB_ENGINE" != "sqlite3" ]]); then
    _plan_step "db" "provision $PLAN_DB_ENGINE, create $(plan_db_name) DB/user, import schema (§12.3)"
  fi
  _plan_step "config" "render server/agent/web configs, skip the frontend wizard (§12.4)"
  if [[ "$PLAN_OPEN_FIREWALL" == "yes" || "$DETECT_SELINUX" == "enforcing" ]]; then
    _plan_step "firewall" "open ports via $DETECT_FIREWALL / set SELinux booleans (§12.5)"
  fi
  if plan_has proxy; then
    if [[ "$PLAN_DB_ENGINE" == "sqlite3" ]]; then
      _plan_step "services" "enable & start: zabbix-proxy (§12.6)"
    else
      _plan_step "services" "enable & start: DB -> zabbix-proxy (§12.6)"
    fi
  else
    _plan_step "services" "enable & start: DB -> zabbix-server -> web -> agent (§12.6)"
  fi
  _plan_step "health" "run the 9 post-install checks (§13)"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '\nDRY-RUN: no commands were executed. Re-run without --dry-run to install.\n'
  fi
}
