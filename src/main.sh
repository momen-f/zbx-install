#!/usr/bin/env bash
# main.sh — arg parsing, mode dispatch, top-level flow
#
# Contract:
#   inputs  : argv (see usage / SPEC §7) and, when bundled, the ZBX_BUILD_*
#             variables injected by build.sh.
#   outputs : orchestrates the install by calling the lib modules. In Phase 0
#             only --help/--version and arg parsing are wired; later phases fill
#             in detect/recommend/pipeline dispatch.

# --- dev-only sourcing (build.sh strips every '# @dev-source' line) ----------
# shellcheck source-path=SCRIPTDIR
_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # @dev-source
# shellcheck source=lib/core.sh
source "$_SRC_DIR/lib/core.sh" # @dev-source
# shellcheck source=lib/ui.sh
source "$_SRC_DIR/lib/ui.sh" # @dev-source

# Version/date: injected by build.sh; fall back to the VERSION file in dev.
main_version() {
  if [[ -n "${ZBX_BUILD_VERSION:-}" ]]; then
    printf '%s (built %s)\n' "$ZBX_BUILD_VERSION" "${ZBX_BUILD_DATE:-?}"
  elif [[ -f "${_SRC_DIR:-.}/../VERSION" ]]; then
    printf '%s (dev)\n' "$(cat "${_SRC_DIR}/../VERSION")"
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
  --dry-run               print every command instead of executing
  --zabbix-version X.Y    override suggested Zabbix version
  --db mysql|pgsql        override DB engine (mysql covers MariaDB)
  --web apache|nginx      override web server
  --components LIST       comma list: server,frontend,agent (agent2 implied)
  --update / --no-update  force/skip the system-update step
  --generate-passwords    auto-generate all secrets without prompting
  --creds-file PATH       where to write the credentials summary
  --log-file PATH         default /var/log/zbx-install-<timestamp>.log
  --no-color              disable ANSI colors (also honors NO_COLOR)
  -h|--help, -V|--version
EOF
}

# --- selected configuration (populated by parse_args) ------------------------
MODE="interactive"
CONFIG_FILE=""

# parse_args ARGS... — validate argv and populate the config globals. Unknown
# flags are a usage error (exit 2), matching Appendix B.
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
      --express) MODE="express" ;;
      --agent-only) MODE="agent-only" ;;
      --detect-only) MODE="detect-only" ;;
      --uninstall) MODE="uninstall" ;;
      --config)
        MODE="unattended"
        UNATTENDED=1
        CONFIG_FILE="${2:-}"
        shift
        ;;
      --yes) : "${UNATTENDED:=0}" ;;
      --dry-run) DRY_RUN=1 ;;
      --no-color) USE_COLOR=0 ;;
      --zabbix-version | --db | --web | --components | --creds-file | --log-file)
        # Value-taking flags: consume the value (wired up in later phases).
        [[ -n "${2:-}" ]] || {
          printf 'Missing value for %s\n' "$1" >&2
          exit 2
        }
        [[ "$1" == "--log-file" ]] && LOG_FILE="$2"
        shift
        ;;
      --update | --no-update | --generate-passwords) : ;;
      -*)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
      *)
        printf 'Unexpected argument: %s\n' "$1" >&2
        exit 2
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  core_color_init
  core_log_init
  core_init_traps
  log INFO "zbx-install starting (mode=$MODE, dry_run=$DRY_RUN)"
  [[ -n "$CONFIG_FILE" ]] && log INFO "config file: $CONFIG_FILE"

  # Phase 0 scaffold: the pipeline modules land in later phases.
  printf '%szbx-install %s%s\n' "$C_BOLD" "$(main_version)" "$C_RESET"
  printf 'Selected mode: %s\n' "$MODE"
  printf 'Pipeline not yet implemented in this build (SPEC §18 Phase 0).\n'
  log INFO "exiting Phase 0 scaffold cleanly"
}

main "$@"
