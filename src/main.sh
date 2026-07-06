#!/usr/bin/env bash
# main.sh — arg parsing, mode dispatch, top-level flow
#
# Contract:
#   inputs  : argv (SPEC §7) and, when bundled, the ZBX_BUILD_* variables
#             injected by build.sh.
#   outputs : orchestrates detect → guards → recommend → mode/pickers → plan →
#             confirm → pipeline (execution lands in Phases 3+). Owns every
#             prompt in the flow; logic lives in the lib modules.

# --- dev-only sourcing (build.sh strips every '# @dev-source' line) ----------
# shellcheck source-path=SCRIPTDIR
_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # @dev-source
# shellcheck source=lib/core.sh
source "$_SRC_DIR/lib/core.sh" # @dev-source
# shellcheck source=lib/ui.sh
source "$_SRC_DIR/lib/ui.sh" # @dev-source
# shellcheck source=lib/detect.sh
source "$_SRC_DIR/lib/detect.sh" # @dev-source
# shellcheck source=lib/recommend.sh
source "$_SRC_DIR/lib/recommend.sh" # @dev-source
# shellcheck source=lib/creds.sh
source "$_SRC_DIR/lib/creds.sh" # @dev-source
# shellcheck source=lib/configfile.sh
source "$_SRC_DIR/lib/configfile.sh" # @dev-source
# shellcheck source=lib/repo.sh
source "$_SRC_DIR/lib/repo.sh" # @dev-source
# shellcheck source=lib/pkg.sh
source "$_SRC_DIR/lib/pkg.sh" # @dev-source
# shellcheck source=lib/db_mysql.sh
source "$_SRC_DIR/lib/db_mysql.sh" # @dev-source
# shellcheck source=lib/db_pgsql.sh
source "$_SRC_DIR/lib/db_pgsql.sh" # @dev-source
# shellcheck source=lib/config.sh
source "$_SRC_DIR/lib/config.sh" # @dev-source
# shellcheck source=lib/firewall.sh
source "$_SRC_DIR/lib/firewall.sh" # @dev-source
# shellcheck source=lib/services.sh
source "$_SRC_DIR/lib/services.sh" # @dev-source
# shellcheck source=lib/health.sh
source "$_SRC_DIR/lib/health.sh" # @dev-source
# shellcheck source=lib/adminpass.sh
source "$_SRC_DIR/lib/adminpass.sh" # @dev-source

# Version/date: injected by build.sh; fall back to the VERSION file in dev.
main_version() {
  if [[ -n "${ZBX_BUILD_VERSION:-}" ]]; then
    printf '%s (built %s)\n' "$ZBX_BUILD_VERSION" "${ZBX_BUILD_DATE:-?}"
  elif [[ -f "${_SRC_DIR:-.}/../VERSION" ]]; then
    printf '%s (dev)\n' "$(cat "${_SRC_DIR:-.}/../VERSION")"
  else
    printf 'unknown (dev)\n'
  fi
}

usage() {
  cat <<'EOF'
zbx-install.sh [MODE] [OPTIONS]

Modes (mutually exclusive; default: interactive menu)
  --express               accept the recommended stack, minimal prompts
  --agent-only            install and configure only the agent
  --config FILE           unattended: read answers from FILE
  --detect-only           print the environment report and exit
  --uninstall             remove Zabbix (asks about data/config retention)

Options
  --yes                   assume yes on confirmations (required for headless)
  --resume                skip the resume/fresh-start question, resume
  --dry-run               print every command instead of executing
  --zabbix-version X.Y    override suggested Zabbix version
  --db mysql|pgsql        override DB engine (mysql covers MariaDB)
  --web apache|nginx      override web server
  --components LIST       comma list: server,frontend,agent (agent2 implied)
  --update / --no-update  force/skip the system-update step
  --generate-passwords    auto-generate all secrets without prompting
  --admin-pass            also change the frontend Admin password (prompted,
                          or auto-generated with --generate-passwords)
  --creds-file PATH       where to write the credentials summary
  --log-file PATH         default /var/log/zbx-install-<timestamp>.log
  --no-color              disable ANSI colors (also honors NO_COLOR)
  -h|--help, -V|--version
EOF
}

# --- selected configuration (populated by parse_args) ------------------------
MODE="interactive"
CONFIG_FILE=""
ASSUME_YES=0
FORCED_FAMILY=0
RESUME=0
CUR_MODE=""
OPT_ZBX_VERSION="" OPT_DB="" OPT_WEB="" OPT_COMPONENTS=""
OPT_UPDATE="" OPT_GENPASS=0 OPT_CREDS_FILE="" OPT_ADMIN_PASS=0
# Appendix A keys with no CLI-flag equivalent (SPEC §7 offers none) — only
# configfile.sh's --config parsing ever sets these; resolve_plan (recommend.sh)
# consults them the same way it does the flag-backed OPT_* above.
OPT_TZ="" OPT_OPEN_FIREWALL="" OPT_AGENT_TYPE="" OPT_SERVER_IP="" OPT_TIMESCALE=""
_MODE_SET=0

usage_err() {
  printf '%s\n' "$1" >&2
  printf "Try --help for usage.\n" >&2
  exit 2
}

# _need_val FLAG VALUE — value-taking flags must have a non-empty value.
_need_val() {
  if [[ -z "$2" ]]; then usage_err "Missing value for $1"; fi
}

# _set_mode NAME — modes are mutually exclusive (§7).
_set_mode() {
  if [[ "$_MODE_SET" == "1" ]]; then usage_err "Modes are mutually exclusive"; fi
  MODE="$1"
  _MODE_SET=1
}

# parse_args ARGS... — validate argv and populate the config globals. Invalid
# input is a usage error (exit 2, Appendix B).
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -V | --version)
        main_version
        exit 0
        ;;
      --express | --agent-only | --detect-only | --uninstall) _set_mode "${1#--}" ;;
      --config)
        _need_val "$1" "${2:-}"
        _set_mode "unattended"
        UNATTENDED=1
        CONFIG_FILE="$2"
        shift
        ;;
      --yes)
        # §14: --yes marks the run unattended — failures fail fast via die().
        ASSUME_YES=1
        UNATTENDED=1
        ;;
      --resume) RESUME=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-color) USE_COLOR=0 ;;
      --zabbix-version)
        _need_val "$1" "${2:-}"
        _valid_zbx_version "$2" ||
          usage_err "Unsupported Zabbix version '$2' (offered: $(printf '%s ' "${SUPPORTED_ZBX_VERSIONS[@]}"))"
        OPT_ZBX_VERSION="$2"
        shift
        ;;
      --db)
        _need_val "$1" "${2:-}"
        case "$2" in
          mysql | pgsql) OPT_DB="$2" ;;
          *) usage_err "--db must be mysql or pgsql (got '$2')" ;;
        esac
        shift
        ;;
      --web)
        _need_val "$1" "${2:-}"
        case "$2" in
          apache | nginx) OPT_WEB="$2" ;;
          *) usage_err "--web must be apache or nginx (got '$2')" ;;
        esac
        shift
        ;;
      --components)
        _need_val "$1" "${2:-}"
        _valid_components "$2" ||
          usage_err "--components must be a comma list of server,frontend,agent (got '$2')"
        OPT_COMPONENTS="$2"
        shift
        ;;
      --update) OPT_UPDATE="yes" ;;
      --no-update) OPT_UPDATE="no" ;;
      --generate-passwords) OPT_GENPASS=1 ;;
      --admin-pass) OPT_ADMIN_PASS=1 ;;
      --creds-file)
        _need_val "$1" "${2:-}"
        OPT_CREDS_FILE="$2"
        shift
        ;;
      --log-file)
        _need_val "$1" "${2:-}"
        LOG_FILE="$2"
        shift
        ;;
      -*) usage_err "Unknown option: $1" ;;
      *) usage_err "Unexpected argument: $1" ;;
    esac
    shift
  done
}

# --- guards (run before any recommendation) ----------------------------------
# guard_tty — prompts are impossible without a TTY. The one sanctioned
# self-exit in interactive mode (§6.2). §6.2 requires an explicit mode
# (--config or --express; we also allow --agent-only, which likewise needs
# zero prompts under --yes) together with --yes — bare --yes still falls
# through to the interactive mode_menu, which needs a real TTY, so it must
# NOT bypass this guard (a failed /dev/tty read there would otherwise default
# silently to option 1 and install unattended without ever exiting 2).
guard_tty() {
  if [[ -t 0 ]]; then return 0; fi
  # [[ -r/-w /dev/tty ]] only checks permission bits on the special file and
  # is true even with no controlling terminal at all — an actual open attempt
  # is the only reliable test.
  if { : </dev/tty; } 2>/dev/null; then return 0; fi
  if [[ "$UNATTENDED" == "1" && "$MODE" != "interactive" ]]; then return 0; fi
  return 1
}

# guard_supported — §14 table: show report · force closest family · exit 3.
guard_supported() {
  if [[ "$DETECT_SUPPORTED" == "yes" ]]; then return 0; fi
  log WARN "unsupported OS: ${DETECT_OS_ID} ${DETECT_OS_VERSION}"
  if [[ "$UNATTENDED" == "1" ]]; then
    die "unsupported OS: ${DETECT_OS_ID} ${DETECT_OS_VERSION} (see the report above)" 3
  fi
  if [[ "$DETECT_FAMILY" == "unknown" ]]; then
    # No "force family" is possible here (there is no family to force to), but
    # the no-exit policy (§3/§14) still applies: offer a real action and only
    # exit after an explicit confirmation, never a bare read-then-exit.
    local choice
    while true; do
      ask_choice choice "${DETECT_OS_ID} ${DETECT_OS_VERSION} is unsupported and matches no known family (§4). Choose:" \
        "show the detection report again" \
        "exit the installer (3)"
      case "$choice" in
        show*) detect_report ;;
        exit*) if ask_yn "Exit installer?" n; then exit 3; fi ;;
      esac
    done
  fi
  if ask_yn "Unsupported OS. Force closest family '${DETECT_FAMILY}' (best effort)?" n; then
    log WARN "user forced family=${DETECT_FAMILY} on unsupported ${DETECT_OS_ID} ${DETECT_OS_VERSION}"
    FORCED_FAMILY=1
    return 0
  fi
  exit 3
}

guard_arch() {
  case "$DETECT_ARCH_OK" in
    yes) return 0 ;;
    maybe)
      log WARN "arch ${DETECT_ARCH}: repo coverage varies — the repo probe decides (§15.10)"
      return 0
      ;;
  esac
  log ERROR "unsupported architecture: ${DETECT_ARCH}"
  if [[ "$UNATTENDED" == "1" ]]; then
    die "unsupported architecture: ${DETECT_ARCH}" 3
  fi
  # No force option (an architecture cannot be "forced" the way an OS family
  # can); still must not bare-exit — offer the report and require confirm.
  local choice
  while true; do
    ask_choice choice "Architecture ${DETECT_ARCH} is not supported (§4). Choose:" \
      "show the detection report again" \
      "exit the installer (3)"
    case "$choice" in
      show*) detect_report ;;
      exit*) if ask_yn "Exit installer?" n; then exit 3; fi ;;
    esac
  done
}

# guard_existing — never upgrade in v1; repair/uninstall land in Phase 7 (§8).
guard_existing() {
  if [[ "$DETECT_ZBX_PRESENT" == "no" ]]; then return 0; fi
  log WARN "existing Zabbix installation detected"
  if [[ "$UNATTENDED" == "1" ]]; then
    die "existing Zabbix detected — repair/uninstall flows arrive in Phase 7; aborting" 3
  fi
  if ask_yn "Existing Zabbix detected. Continue anyway (may conflict)?" n; then
    return 0
  fi
  log INFO "user stopped at existing-Zabbix guard"
  exit 7
}

# guard_network — §8: retry · continue with --dry-run · exit 4.
guard_network() {
  if [[ "$DETECT_NET_OK" != "no" ]]; then return 0; fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log WARN "repo.zabbix.com unreachable — continuing (dry-run)"
    return 0
  fi
  if [[ "$UNATTENDED" == "1" ]]; then
    die "cannot reach https://repo.zabbix.com/ — check network/proxy" 4
  fi
  local choice
  while [[ "$DETECT_NET_OK" == "no" ]]; do
    ask_choice choice "Cannot reach https://repo.zabbix.com/ — choose:" \
      "retry the connectivity check" \
      "continue in dry-run mode (print commands only)" \
      "exit the installer (4)"
    case "$choice" in
      retry*) detect_network ;;
      continue*)
        DRY_RUN=1
        log WARN "network unreachable — user switched to dry-run"
        return 0
        ;;
      exit*)
        if ask_yn "Exit installer?" n; then exit 4; fi
        ;;
    esac
  done
}

# resume_check — §14: "on start, if state exists and is incomplete, offer
# resume or fresh; --resume skips the question." Which exact steps a
# *finished* run needs isn't known this early (no plan exists yet) — the
# per-step core_state_is_done() checks already scattered through
# repo.sh/pkg.sh/db_*.sh/services.sh/health.sh are what actually skip
# completed work; this only decides whether to keep or wipe that record.
# Unattended (config-file or --yes) always resumes without asking — there is
# no TTY to ask on, and silently redoing already-finished work on every
# retry would be a worse default for automation than picking up where a
# previous run left off.
resume_check() {
  core_state_init
  core_state_has_progress || return 0
  if [[ "$RESUME" == "1" || "$UNATTENDED" == "1" ]]; then
    log INFO "resuming previous run (state file has progress)"
    return 0
  fi
  local choice
  ask_choice choice "A previous run left partial progress ($STATE_FILE). Choose:" \
    "resume — skip steps already completed" \
    "start fresh — clear saved progress and redo everything"
  case "$choice" in
    resume*) log INFO "user chose to resume" ;;
    "start fresh"*)
      core_state_clear
      log INFO "user chose to start fresh — state cleared"
      ;;
  esac
}

# --- mode selection and pickers -----------------------------------------------
mode_menu() {
  local choice
  while true; do
    ask_choice_def choice "Select installation mode" 1 \
      "express — accept the recommendation (Zabbix ${REC_ZBX_VERSION}, ${REC_DB_ENGINE}, ${REC_WEB_SERVER})" \
      "custom — pick every component" \
      "agent-only — monitoring agent only" \
      "exit — leave the installer"
    case "$choice" in
      express*)
        CUR_MODE="express"
        return 0
        ;;
      custom*)
        CUR_MODE="custom"
        return 0
        ;;
      agent-only*)
        CUR_MODE="agent-only"
        return 0
        ;;
      exit*)
        if ask_yn "Exit installer?" n; then
          log INFO "user exited at the mode menu"
          exit 7
        fi
        ;;
    esac
  done
}

# picker_stack — custom mode: version, DB, web, components (defaults = plan).
picker_stack() {
  local choice v idx n
  local -a vopts=()
  idx=1 n=1
  for v in "${SUPPORTED_ZBX_VERSIONS[@]}"; do
    vopts+=("$v ($(rec_version_label "$v"))")
    if [[ "$v" == "$PLAN_ZBX_VERSION" ]]; then idx="$n"; fi
    n=$((n + 1))
  done
  ask_choice_def choice "Zabbix version" "$idx" "${vopts[@]}"
  PLAN_ZBX_VERSION="${choice%% *}"

  printf 'Detected existing DB: %s\n' "$DETECT_DB_PRESENT" >&2
  case "$PLAN_DB_ENGINE" in
    mariadb) idx=1 ;; mysql) idx=2 ;; pgsql) idx=3 ;;
  esac
  ask_choice_def choice "Database engine" "$idx" "mariadb" "mysql" "pgsql"
  PLAN_DB_ENGINE="$choice"

  if [[ "$PLAN_WEB_SERVER" == "apache" ]]; then idx=1; else idx=2; fi
  ask_choice_def choice "Web server" "$idx" "apache" "nginx"
  PLAN_WEB_SERVER="$choice"

  picker_components
}

# picker_components — per-component yes/no, defaults from the current plan.
picker_components() {
  local d
  local -a comps=()
  until ((${#comps[@]} > 0)); do
    if plan_has server; then d=y; else d=n; fi
    if ask_yn "  component: server?" "$d"; then comps+=(server); fi
    if plan_has frontend; then d=y; else d=n; fi
    if ask_yn "  component: frontend?" "$d"; then comps+=(frontend); fi
    if plan_has agent; then d=y; else d=n; fi
    if ask_yn "  component: agent?" "$d"; then comps+=(agent); fi
    if ((${#comps[@]} == 0)); then
      printf 'Pick at least one component.\n' >&2
    fi
  done
  local IFS=,
  PLAN_COMPONENTS="${comps[*]}"
}

# picker_extras — custom mode: agent type/plugins, tools, timescale, firewall, tz.
picker_extras() {
  local choice idx reply
  if plan_has agent; then
    if [[ "$PLAN_AGENT_TYPE" == "zabbix-agent2" ]]; then idx=1; else idx=2; fi
    ask_choice_def choice "Agent type" "$idx" \
      "zabbix-agent2 (recommended)" "zabbix-agent (classic)"
    PLAN_AGENT_TYPE="${choice%% *}"
    if [[ "$PLAN_AGENT_TYPE" == "zabbix-agent2" ]]; then
      ask_multi PLAN_AGENT_PLUGINS "Optional agent2 plugins" \
        postgresql mongodb mssql
    fi
  fi
  if ask_yn "Install CLI tools (zabbix-get, zabbix-sender)?" n; then
    PLAN_TOOLS="yes"
  else
    PLAN_TOOLS="no"
  fi
  if [[ "$PLAN_DB_ENGINE" == "pgsql" ]] && plan_has server; then
    if ask_yn "Enable TimescaleDB (version must match the PG major, §12.3)?" n; then
      PLAN_TIMESCALE="yes"
    else
      PLAN_TIMESCALE="no"
    fi
  fi
  if [[ "$DETECT_FIREWALL" != "none" ]]; then
    local fd=n
    if [[ "$PLAN_OPEN_FIREWALL" == "yes" ]]; then fd=y; fi
    if ask_yn "Open Zabbix ports via ${DETECT_FIREWALL}?" "$fd"; then
      PLAN_OPEN_FIREWALL="yes"
    else
      PLAN_OPEN_FIREWALL="no"
    fi
  fi
  read -r -p "PHP timezone [${PLAN_TZ:-UTC}]: " reply </dev/tty || reply=""
  PLAN_TZ="${reply:-${PLAN_TZ:-UTC}}"
}

# agent_params — agent-only mode: which server the agent reports to.
agent_params() {
  if [[ "$UNATTENDED" == "1" ]]; then return 0; fi
  local reply
  read -r -p "Zabbix server IP for the agent [${PLAN_ZBX_SERVER_IP}]: " reply </dev/tty || reply=""
  if [[ -n "$reply" ]]; then PLAN_ZBX_SERVER_IP="$reply"; fi
}

# resolve_update — the §11 question, asked once; flags/unattended skip it.
resolve_update() {
  if [[ -n "$PLAN_UPDATE" ]]; then return 0; fi
  if [[ "$UNATTENDED" == "1" ]]; then
    PLAN_UPDATE="no"
    return 0
  fi
  if ask_yn "Update all system packages before installing?" n; then
    PLAN_UPDATE="yes"
  else
    PLAN_UPDATE="no"
  fi
}

# resolve_tz — §9 rule 6: timedatectl value → prompt → UTC.
resolve_tz() {
  if [[ -n "$PLAN_TZ" ]]; then return 0; fi
  if [[ "$UNATTENDED" == "1" ]]; then
    PLAN_TZ="UTC"
    return 0
  fi
  local reply
  read -r -p 'Timezone for PHP [UTC]: ' reply </dev/tty || reply=""
  PLAN_TZ="${reply:-UTC}"
}

# --- plan / confirm / pipeline --------------------------------------------------
prepare_plan() {
  resolve_plan
  case "$1" in
    agent-only)
      PLAN_COMPONENTS="agent"
      agent_params
      ;;
    custom)
      # MODE=custom via --config (§18 Phase 7) means "every choice comes from
      # the file's OPT_*-mapped keys, not an interactive picker" — these two
      # read from /dev/tty unconditionally, so they'd break (or block
      # forever) a --config run that has no TTY at all.
      if [[ "$UNATTENDED" != "1" ]]; then
        picker_stack
        picker_extras
      fi
      ;;
  esac
  resolve_update
  resolve_tz
  creds_collect
  creds_collect_admin_pass
}

# plan_confirm — §1.7: nothing executes before explicit confirmation.
plan_confirm() {
  if [[ "$UNATTENDED" == "1" || "$ASSUME_YES" == "1" ]]; then
    log INFO "plan auto-confirmed (--yes/unattended)"
    printf '\nProceeding (auto-confirmed by --yes).\n'
    return 0
  fi
  ask_yn "Proceed with this plan?" n
}

# run_pipeline — execute every step this build implements (update, repo,
# packages, database, config, firewall, services, health — Phases 3-6).
# run() itself no-ops-and-prints every real command under DRY_RUN, so this
# is safe to call unconditionally and doubles as the detailed dry-run
# preview for the steps it covers (health.sh skips its checks outright
# under DRY_RUN — nothing above it actually ran). Returns PIPELINE_BACK if
# the user picked "back to plan" from an error menu mid-pipeline; main_flow
# re-enters the mode menu in that case.
run_pipeline() {
  core_state_init
  local label="Running the implemented steps (repo, packages"
  if plan_has server; then label+=", database"; fi
  label+=", config, firewall, services, health"
  [[ -n "$ZBX_ADMIN_PASSWORD" ]] && label+=", admin-pass"
  label+=")"
  [[ "$DRY_RUN" == "1" ]] && label+=" — dry-run"
  printf '\n%s%s%s\n' "$C_BOLD" "$label" "$C_RESET"

  pkg_update
  repo_install
  db_mysql_module_enable
  local -a pkgs=()
  IFS=' ' read -ra pkgs <<<"$PLAN_PACKAGES"
  pkg_install ${pkgs[@]+"${pkgs[@]}"}

  if plan_has server; then
    case "$PLAN_DB_ENGINE" in
      pgsql) db_pgsql_provision ;;
      *) db_mysql_provision ;;
    esac
    creds_write_summary
  fi

  _pipeline_step config config_apply || return "$PIPELINE_BACK"
  _pipeline_step firewall firewall_apply || return "$PIPELINE_BACK"
  _pipeline_step services services_start || return "$PIPELINE_BACK"
  _pipeline_step health health_run_checks || return "$PIPELINE_BACK"
  _pipeline_step adminpass admin_pass_update || return "$PIPELINE_BACK"
  health_print_summary
  return 0
}

# --- uninstall (§14, §18 Phase 7) ---------------------------------------------
# _uninstall_find_packages — currently-installed zabbix-owned packages,
# discovered from the package manager itself rather than replayed from
# PLAN_PACKAGES (a separate --uninstall invocation has no plan at all, and a
# stale/guessed list could miss packages a later --components run added).
# Every Zabbix-shipped package name starts with "zabbix" (zabbix-release
# included, so removing this list also removes the repo file/key §14 asks
# for) — mariadb-server/httpd/nginx/postgresql never match, so the "never
# remove the DB engine or web server" rule holds by construction, not by a
# separate exclude list.
_uninstall_find_packages() {
  local out=""
  case "$DETECT_PKGMGR" in
    apt) out="$(dpkg-query -W -f '${Package}\n' 'zabbix*' 2>/dev/null)" || true ;;
    dnf | zypper) out="$(rpm -qa --qf '%{NAME}\n' 'zabbix*' 2>/dev/null)" || true ;;
  esac
  printf '%s' "$out" | tr '\n' ' '
}

# _uninstall_drop_db — best-effort DROP for whichever engine is actually
# present; detected from the client binary, not PLAN_DB_ENGINE (uninstall
# never builds a plan). Never touches the engine service/package itself.
_uninstall_drop_db() {
  if command -v mysql >/dev/null 2>&1; then
    _db_mysql_auth_setup
    if ! printf "DROP DATABASE IF EXISTS zabbix;\nDROP USER IF EXISTS 'zabbix'@'localhost';\n" |
      run "${_DB_MYSQL_ARGS[@]}"; then
      log WARN "dropping the zabbix mysql database/user failed — see the log"
    fi
  elif command -v psql >/dev/null 2>&1; then
    if ! { run sudo -u postgres psql -c 'DROP DATABASE IF EXISTS zabbix' &&
      run sudo -u postgres psql -c 'DROP ROLE IF EXISTS zabbix'; }; then
      log WARN "dropping the zabbix postgres database/role failed — see the log"
    fi
  else
    log WARN "no mysql/psql client found — cannot drop the zabbix database"
  fi
}

# uninstall_run — §14: remove zabbix packages + the repo package only; ask
# separately (default: keep) whether to also drop the zabbix DB/user and
# whether to delete ZBX_ETC_DIR. Never removes the DB engine or web server.
# Always prints what was kept, per spec.
uninstall_run() {
  log INFO "starting uninstall"
  # Global IFS ($'\n\t', core.sh) has no space — every "${zpkgs[*]}" join
  # below needs this scoped override, or it silently joins with a newline
  # instead (§15 gotcha).
  local IFS=' '
  local -a zpkgs=()
  IFS=' ' read -ra zpkgs <<<"$(_uninstall_find_packages)"
  if ((${#zpkgs[@]} == 0)); then
    printf 'No Zabbix packages found — nothing to remove.\n'
  else
    printf 'Removing: %s\n' "${zpkgs[*]}"
    pkg_remove "${zpkgs[@]}"
  fi

  local drop_db=0 del_config=0
  if [[ "$UNATTENDED" == "1" ]]; then
    log INFO "unattended uninstall — keeping the zabbix DB/user and $ZBX_ETC_DIR by default"
  else
    ask_yn "Drop the 'zabbix' database and DB user too?" n && drop_db=1
    ask_yn "Delete ${ZBX_ETC_DIR} (all Zabbix config files) too?" n && del_config=1
  fi
  ((drop_db == 1)) && _uninstall_drop_db
  ((del_config == 1)) && run rm -rf "$ZBX_ETC_DIR"
  # A removed package set makes prior repo/packages/db progress meaningless —
  # a later reinstall must not skip those steps just because this state file
  # still says they're done.
  core_state_clear

  printf '\n%sUninstall summary%s\n' "$C_BOLD" "$C_RESET"
  if ((${#zpkgs[@]} > 0)); then
    printf '  Removed packages: %s\n' "${zpkgs[*]}"
  fi
  printf '  Kept: database engine, web server (never removed by this installer)\n'
  if ((drop_db == 1)); then printf '  Removed: zabbix database/user\n'; else printf '  Kept: zabbix database/user\n'; fi
  if ((del_config == 1)); then printf '  Removed: %s\n' "$ZBX_ETC_DIR"; else printf '  Kept: %s\n' "$ZBX_ETC_DIR"; fi
  log INFO "uninstall complete"
}

main_flow() {
  local m rc
  while true; do
    if [[ "$MODE" == "interactive" ]]; then
      mode_menu
      m="$CUR_MODE"
    else
      m="$MODE"
    fi
    prepare_plan "$m"
    plan_packages
    plan_report "$m"
    if plan_confirm; then
      plan_pipeline_preview
      log INFO "plan confirmed (mode=$m)"
      run_pipeline && rc=0 || rc=$?
      if [[ "$rc" == "$PIPELINE_BACK" ]]; then
        log INFO "user chose 'back to plan' mid-pipeline"
        MODE="interactive"
        continue
      fi
      return 0
    fi
    log INFO "plan rejected — returning to the mode menu (flowchart: confirm->no->mode)"
    MODE="interactive"
  done
}

main() {
  parse_args "$@"
  core_color_init
  core_log_init
  core_init_traps
  log INFO "zbx-install starting (mode=$MODE, dry_run=$DRY_RUN, yes=$ASSUME_YES)"
  if [[ -n "$CONFIG_FILE" ]]; then log INFO "config file: $CONFIG_FILE"; fi
  case "$MODE" in
    detect-only)
      detect_run
      detect_report
      exit 0
      ;;
    unattended)
      # --config is unattended by definition (parse_args already set
      # UNATTENDED=1) — a malformed file has no interactive retry story, so
      # this is exactly die()'s documented case, not err_menu's.
      cfgfile_parse "$CONFIG_FILE" || die "$CFGFILE_ERR" 2
      MODE="$CFGFILE_MODE"
      ;;
  esac
  if ! guard_tty; then
    printf '✗ No TTY available: interactive prompts are impossible.\n' >&2
    printf '  Use "--config FILE --yes" or "--express --yes" (SPEC §6).\n' >&2
    exit 2
  fi
  if [[ "$MODE" == "uninstall" ]]; then
    # Needs DETECT_PKGMGR/DETECT_FAMILY, but none of the install-flow guards
    # or recommendation apply to removing an existing install.
    detect_run
    uninstall_run
    exit 0
  fi
  resume_check
  detect_run
  detect_report
  guard_supported
  guard_arch
  guard_existing
  guard_network
  recommend_run
  main_flow
}

main "$@"
