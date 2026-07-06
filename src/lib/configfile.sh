# shellcheck shell=bash
# configfile.sh — --config FILE parser (Appendix A): a fully unattended
# install driven by a KEY=VALUE file instead of flags or prompts.
#
# Contract:
#   inputs  : a file path.
#   outputs : on success, populates the same OPT_*-prefixed globals main.sh's
#             CLI parsing already sets (OPT_ZBX_VERSION, OPT_DB, OPT_WEB,
#             OPT_COMPONENTS, OPT_UPDATE, OPT_GENPASS, OPT_CREDS_FILE,
#             OPT_TZ, OPT_OPEN_FIREWALL, OPT_AGENT_TYPE, OPT_SERVER_IP,
#             OPT_TIMESCALE, OPT_ADMIN_PASS), creds.sh's
#             ZBX_DB_PASSWORD/ZBX_DB_ADMIN_PASSWORD/ZBX_ADMIN_PASSWORD,
#             main.sh's ASSUME_YES, and CFGFILE_MODE (the resolved
#             express/custom/agent-only sub-mode) — so --config reuses the
#             exact same resolve_plan -> prepare_plan -> plan_packages path
#             every other mode takes, instead of a parallel one. On any
#             problem, returns 1 with CFGFILE_ERR set; the caller (main.sh)
#             routes that through die() (§14: unattended-only hard stop — a
#             malformed config file has no interactive retry story, and
#             --config is unattended by definition).
#
# A file mode other than 0600 is a warning only, not a hard failure
# (Appendix A: "file must be 0600 or a warning is printed").

CFGFILE_ERR=""
CFGFILE_MODE=""

# Appendix A's exact key list — anything else is a typo, not a future key.
readonly -a CFGFILE_KEYS=(
  MODE ZBX_VERSION COMPONENTS DB_ENGINE DB_PASS DB_ADMIN_PASS WEB_SERVER
  PHP_TZ UPDATE_SYSTEM OPEN_FIREWALL GENERATE_PASSWORDS CREDS_FILE
  AGENT_TYPE ZBX_SERVER_IP TIMESCALEDB ASSUME_YES ADMIN_PASS
)

_cfgfile_is_known_key() {
  local k
  for k in "${CFGFILE_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

# _cfgfile_validate KEY VALUE — per-key format check (Appendix A). Sets
# CFGFILE_ERR and returns 1 on a bad value; CREDS_FILE/DB_PASS/DB_ADMIN_PASS/
# PHP_TZ/ZBX_SERVER_IP are free-form, so there's nothing to check.
_cfgfile_validate() {
  local key="$1" val="$2" ok=1
  case "$key" in
    MODE) [[ "$val" =~ ^(express|custom|agent-only)$ ]] && ok=0 ;;
    ZBX_VERSION) _valid_zbx_version "$val" && ok=0 ;;
    COMPONENTS) _valid_components "$val" && ok=0 ;;
    DB_ENGINE) [[ "$val" =~ ^(mariadb|mysql|pgsql)$ ]] && ok=0 ;;
    WEB_SERVER) [[ "$val" =~ ^(apache|nginx)$ ]] && ok=0 ;;
    AGENT_TYPE) [[ "$val" =~ ^(agent2|agent)$ ]] && ok=0 ;;
    UPDATE_SYSTEM | OPEN_FIREWALL | GENERATE_PASSWORDS | TIMESCALEDB | ASSUME_YES)
      [[ "$val" =~ ^(yes|no)$ ]] && ok=0
      ;;
    CREDS_FILE | DB_PASS | DB_ADMIN_PASS | PHP_TZ | ZBX_SERVER_IP | ADMIN_PASS) ok=0 ;;
  esac
  ((ok == 0)) && return 0
  CFGFILE_ERR="invalid value for $key: '$val'"
  return 1
}

# _cfgfile_apply KEY VALUE — wire a validated key onto the globals
# resolve_plan()/prepare_plan()/creds_collect() already consult.
_cfgfile_apply() {
  local key="$1" val="$2"
  case "$key" in
    MODE) CFGFILE_MODE="$val" ;;
    ZBX_VERSION) OPT_ZBX_VERSION="$val" ;;
    COMPONENTS) OPT_COMPONENTS="$val" ;;
    DB_ENGINE) OPT_DB="$val" ;;
    DB_PASS)
      ZBX_DB_PASSWORD="$val"
      core_register_secret "$val"
      ;;
    DB_ADMIN_PASS)
      ZBX_DB_ADMIN_PASSWORD="$val"
      core_register_secret "$val"
      ;;
    WEB_SERVER) OPT_WEB="$val" ;;
    PHP_TZ) OPT_TZ="$val" ;;
    UPDATE_SYSTEM) OPT_UPDATE="$val" ;;
    OPEN_FIREWALL) OPT_OPEN_FIREWALL="$val" ;;
    GENERATE_PASSWORDS) [[ "$val" == "yes" ]] && OPT_GENPASS=1 ;;
    CREDS_FILE) OPT_CREDS_FILE="$val" ;;
    AGENT_TYPE) OPT_AGENT_TYPE="zabbix-$val" ;; # agent2 -> zabbix-agent2, agent -> zabbix-agent
    ZBX_SERVER_IP) OPT_SERVER_IP="$val" ;;
    TIMESCALEDB) OPT_TIMESCALE="$val" ;;
    ASSUME_YES) [[ "$val" == "yes" ]] && ASSUME_YES=1 ;;
    ADMIN_PASS)
      OPT_ADMIN_PASS=1
      # "generate" is a sentinel, not a literal password (§10 recommends a
      # fresh generated one over a human-chosen value anyway) — leave
      # ZBX_ADMIN_PASSWORD empty so creds_collect_admin_pass's own
      # UNATTENDED-implies-generate fallback fires, same as DB_PASS unset.
      if [[ "$val" != "generate" ]]; then
        ZBX_ADMIN_PASSWORD="$val"
        core_register_secret "$val"
      fi
      ;;
  esac
}

# _cfgfile_mode_warn FILE — Appendix A: 0600 or a warning, never a hard
# failure (a config file with secrets in it losing exclusivity shouldn't
# block an otherwise-valid unattended run).
_cfgfile_mode_warn() {
  local file="$1" mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)"
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    log WARN "$file is mode $mode, not 600 — secrets in it may be readable by other users"
  fi
}

# cfgfile_parse FILE — read KEY=VALUE lines (blank lines and #-comments
# skipped), reject unknown keys and bad values outright (typos must be loud,
# per Appendix A), apply everything that validates.
cfgfile_parse() {
  local file="$1" n=0 line key val
  CFGFILE_ERR="" CFGFILE_MODE=""
  if [[ ! -f "$file" ]]; then
    CFGFILE_ERR="$file: no such file"
    return 1
  fi
  _cfgfile_mode_warn "$file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" != *=* ]]; then
      CFGFILE_ERR="$file:$n: not a KEY=VALUE line: '$line'"
      return 1
    fi
    key="${line%%=*}"
    val="${line#*=}"
    if ! _cfgfile_is_known_key "$key"; then
      CFGFILE_ERR="$file:$n: unknown key '$key'"
      return 1
    fi
    if ! _cfgfile_validate "$key" "$val"; then
      CFGFILE_ERR="$file:$n: $CFGFILE_ERR"
      return 1
    fi
    _cfgfile_apply "$key" "$val"
  done <"$file"
  if [[ -z "$CFGFILE_MODE" ]]; then
    CFGFILE_ERR="$file: MODE is required"
    return 1
  fi
  return 0
}
