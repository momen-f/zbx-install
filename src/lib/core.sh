# shellcheck shell=bash
# core.sh — strict mode, logging/redaction, run() wrapper, traps, state, err_menu
#
# Contract:
#   inputs  : global config set by main.sh (DRY_RUN, UNATTENDED, USE_COLOR,
#             LOG_FILE, STATE_FILE) and secrets registered via core_register_secret
#   outputs : side effects only — writes the log file and the state file, prints
#             to the terminal, and (on explicit user Exit / unattended failure)
#             terminates with an Appendix B exit code.
#
# Sourced first in the bundle, so it owns strict mode and the shared globals.

set -Eeuo pipefail
IFS=$'\n\t'

# --- shared globals (main.sh may override before the pipeline runs) ----------
: "${DRY_RUN:=0}"      # 1 = print commands, execute nothing
: "${UNATTENDED:=0}"   # 1 = no prompts; failures call die() with a code
: "${USE_COLOR:=auto}" # auto|1|0 — resolved by core_color_init
: "${LOG_FILE:=}"      # resolved by core_log_init if empty
: "${STATE_FILE:=/var/lib/zbx-install/state}"

# Values registered here are masked in every log line and dry-run print.
ZBX_SECRETS=()
# Temp paths registered here are removed by the EXIT trap.
ZBX_TEMPFILES=()
# Step IDs the user chose to skip via err_menu's [s] option — listed as
# degraded in the Phase 6 summary (§14).
ZBX_DEGRADED_STEPS=()

# err_menu return signals (the pipeline driver acts on these).
readonly ERRMENU_RETRY=0
readonly ERRMENU_SKIP=1
readonly ERRMENU_BACK=2
# _pipeline_step's own "go back to plan" signal (distinct from ERRMENU_BACK's
# numeric value only by convention — kept separate so a change to one doesn't
# silently change the other).
readonly PIPELINE_BACK=2

# Per-step retry counters, keyed by STEP_ID.
declare -A ZBX_RETRY_COUNT=()

# --- colors ------------------------------------------------------------------
# Resolve USE_COLOR against NO_COLOR and TTY, then define C_* escape variables.
core_color_init() {
  local enable=1
  if [[ -n "${NO_COLOR:-}" ]] || [[ "$USE_COLOR" == "0" ]]; then
    enable=0
  elif [[ "$USE_COLOR" == "auto" ]] && [[ ! -t 1 ]]; then
    enable=0
  fi
  if [[ "$enable" == "1" ]] && command -v tput >/dev/null 2>&1; then
    C_RESET="$(tput sgr0)" C_RED="$(tput setaf 1)" C_GREEN="$(tput setaf 2)"
    C_YELLOW="$(tput setaf 3)" C_BOLD="$(tput bold)"
  else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BOLD=""
  fi
  readonly C_RESET C_RED C_GREEN C_YELLOW C_BOLD
}

# --- secrets & redaction -----------------------------------------------------
# Register a secret so it is masked everywhere. No-op on empty values.
core_register_secret() {
  local value="$1"
  [[ -n "$value" ]] && ZBX_SECRETS+=("$value")
  return 0 # never fail the caller under set -e on an empty value
}

# Read stdin, replace every registered secret with ******** , write stdout.
# Uses parameter expansion (not sed) so secret contents are never treated as
# regex. §10.
core_redact() {
  local line secret
  while IFS= read -r line || [[ -n "$line" ]]; do
    for secret in "${ZBX_SECRETS[@]:-}"; do
      [[ -n "$secret" ]] && line="${line//"$secret"/********}"
    done
    printf '%s\n' "$line"
  done
}

# --- logging -----------------------------------------------------------------
# Pick a default log path if main.sh did not set one, then create the file.
core_log_init() {
  if [[ -z "$LOG_FILE" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="/var/log/zbx-install-${ts}.log"
  fi
  if ! { : >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_FILE="${TMPDIR:-/tmp}/zbx-install-$$.log"
    : >>"$LOG_FILE"
  fi
  readonly LOG_FILE
}

# log LEVEL MSG... — append a redacted, timestamped line to the log; echo
# WARN/ERROR to stderr so the user sees them too.
log() {
  local level="$1"
  shift
  local ts msg
  ts="$(date +%H:%M:%S)"
  msg="$(printf '%s [%s] %s' "$ts" "$level" "$*" | core_redact)"
  [[ -n "$LOG_FILE" ]] && printf '%s\n' "$msg" >>"$LOG_FILE"
  case "$level" in
    WARN) printf '%s%s%s\n' "$C_YELLOW" "$msg" "$C_RESET" >&2 ;;
    ERROR) printf '%s%s%s\n' "$C_RED" "$msg" "$C_RESET" >&2 ;;
  esac
}

# --- command runner ----------------------------------------------------------
# run CMD... — log the (redacted) command, then execute it unless DRY_RUN=1.
# Returns the command's exit status so callers can route failures to err_menu.
run() {
  local shown rc
  shown="$(core_redact <<<"$*")"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  + %s\n' "$shown"
    log INFO "DRY-RUN: $*"
    return 0
  fi
  log INFO "RUN: $*"
  # The command's OWN output is piped through core_redact too, not just the
  # announced command line — a DB client echoing a bad statement back (e.g.
  # a syntax error near a password literal) must not leak it into the log.
  "$@" 2>&1 | core_redact >>"$LOG_FILE"
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

# --- state file --------------------------------------------------------------
core_state_init() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local dir="${STATE_FILE%/*}"
  mkdir -p "$dir" >/dev/null 2>&1 || true
  # Grouped so 2>/dev/null covers the redirection itself, not just the
  # command before it — an unwritable path (e.g. no root) is degraded
  # resume support, never a fatal error (§14 principle: never crash the
  # install over a nice-to-have).
  { [[ -f "$STATE_FILE" ]] || : >"$STATE_FILE"; } 2>/dev/null || true
}

# Mark a pipeline STEP_ID complete (idempotent).
state_mark_done() {
  local step="$1"
  [[ "$DRY_RUN" == "1" ]] && return 0
  core_state_is_done "$step" && return 0
  { printf '%s=done\n' "$step" >>"$STATE_FILE"; } 2>/dev/null || true
}

core_state_is_done() {
  local step="$1"
  [[ -f "$STATE_FILE" ]] && grep -qxF "${step}=done" "$STATE_FILE"
}

# core_state_has_progress — a previous run left at least one step marked
# done (§14 resume: "if state exists and is incomplete"). Which exact steps
# a *finished* run would have isn't knowable before a plan exists, so this
# only asks the weaker, sufficient question: is there anything to resume?
core_state_has_progress() {
  [[ -s "$STATE_FILE" ]]
}

# core_state_clear — wipe saved progress so every step re-runs: the "start
# fresh" resume choice (§14), and also used by uninstall so a later reinstall
# doesn't skip steps a removed package set makes newly-undone.
core_state_clear() {
  { : >"$STATE_FILE"; } 2>/dev/null || true
}

# --- error menu (§14) — the no-exit policy ----------------------------------
# Map a STEP_ID to its Appendix B exit code (used on explicit Exit / unattended).
core_exit_code_for() {
  case "$1" in
    detect) echo 3 ;;
    network) echo 4 ;;
    repo | packages | config | firewall | services) echo 5 ;;
    health) echo 6 ;;
    db) echo 8 ;;
    *) echo 7 ;;
  esac
}

# Print the last N redacted log lines (default 5).
core_tail_log() {
  local n="${1:-5}"
  [[ -f "$LOG_FILE" ]] && tail -n "$n" "$LOG_FILE"
}

# die MSG CODE — unattended-only hard stop (menus are impossible). §14.
die() {
  local msg="$1" code="${2:-1}"
  log ERROR "$msg"
  printf '%s✗ %s%s\n' "$C_RED" "$msg" "$C_RESET" >&2
  [[ -n "$LOG_FILE" ]] && printf 'See log: %s\n' "$LOG_FILE" >&2
  exit "$code"
}

# _errmenu_opts_for STEP — which letters are enabled for this step's menu, per
# the §14 per-context table (Exit is implicit and always available). Unlisted
# steps get the generic fallback. v (pick a different Zabbix version),
# c (re-enter credentials), and s (skip) are step-specific: skip must never
# appear for repo/packages/db (§14: "never" — a half-installed repo, package
# set, or DB can't be skipped over). health has no "back to plan" (§13 lists
# re-run/log/continue-anyway only, not back).
_errmenu_opts_for() {
  case "$1" in
    repo) echo "rvl" ;;
    packages) echo "rl" ;;
    db) echo "rcl" ;;
    health) echo "rls" ;;
    *) echo "rlsb" ;;
  esac
}

# _errmenu_print_options STEP OPTS — labels are mostly generic, but health's
# retry/skip read differently in §13 ("re-run checks" / "continue to summary
# anyway (degraded)") than the generic "Retry"/"Skip" everywhere else.
_errmenu_print_options() {
  local step="$1" opts="$2" line=""
  if [[ "$opts" == *r* ]]; then
    if [[ "$step" == "health" ]]; then line+="[r] Re-run checks  "; else line+="[r] Retry  "; fi
  fi
  [[ "$opts" == *v* ]] && line+="[v] Pick a different Zabbix version  "
  [[ "$opts" == *c* ]] && line+="[c] Re-enter credentials  "
  [[ "$opts" == *l* ]] && line+="[l] View log (last 50)  "
  if [[ "$opts" == *s* ]]; then
    if [[ "$step" == "health" ]]; then line+="[s] Continue to summary anyway (degraded)  "; else line+="[s] Skip*  "; fi
  fi
  [[ "$opts" == *b* ]] && line+="[b] Back to plan  "
  printf '%s[x] Exit\n' "$line"
}

# err_menu STEP_ID REASON — every interactive failure lands here. Returns one of
# ERRMENU_RETRY/SKIP/BACK, loops on "view log", and only exits on explicit Exit.
# Unattended mode fails fast via die() with the step's code.
err_menu() {
  local step="$1" reason="$2"
  local code
  code="$(core_exit_code_for "$step")"
  log ERROR "step '$step' failed: $reason"
  if [[ "$UNATTENDED" == "1" ]]; then
    die "step '$step' failed: $reason" "$code"
  fi

  ZBX_RETRY_COUNT["$step"]=$((${ZBX_RETRY_COUNT["$step"]:-0} + 1))
  local opts choice
  opts="$(_errmenu_opts_for "$step")"
  while true; do
    printf '\n%s✗ %s failed — %s%s\n' "$C_RED" "$step" "$reason" "$C_RESET" >&2
    core_tail_log 5 >&2
    if ((${ZBX_RETRY_COUNT["$step"]} >= 3)); then
      printf '%shint: see %s and SPEC §15 for this step%s\n' \
        "$C_YELLOW" "$LOG_FILE" "$C_RESET" >&2
    fi
    _errmenu_print_options "$step" "$opts" >&2
    read -r -p '> ' choice </dev/tty || choice=x
    case "$choice" in
      r | R)
        [[ "$opts" == *r* ]] || continue
        return "$ERRMENU_RETRY"
        ;;
      v | V)
        [[ "$opts" == *v* ]] || continue
        ask_choice_def PLAN_ZBX_VERSION "Pick a Zabbix version to retry with" 1 \
          "${SUPPORTED_ZBX_VERSIONS[@]}"
        log INFO "user switched to Zabbix version $PLAN_ZBX_VERSION for the retry"
        return "$ERRMENU_RETRY"
        ;;
      c | C)
        [[ "$opts" == *c* ]] || continue
        creds_reenter_admin_password
        return "$ERRMENU_RETRY"
        ;;
      l | L)
        [[ "$opts" == *l* ]] || continue
        core_tail_log 50 >&2
        ;;
      s | S)
        [[ "$opts" == *s* ]] || continue
        log WARN "step '$step' skipped by user (degraded)"
        return "$ERRMENU_SKIP"
        ;;
      b | B)
        [[ "$opts" == *b* ]] || continue
        return "$ERRMENU_BACK"
        ;;
      x | X)
        read -r -p 'Exit installer? [y/N] ' confirm </dev/tty || confirm=y
        [[ "$confirm" =~ ^[Yy]$ ]] && exit "$code"
        ;;
      *) : ;;
    esac
  done
}

# Record a step the user chose to skip via err_menu's [s] option — the
# Phase 6 summary lists these as degraded (§14).
core_mark_degraded() {
  ZBX_DEGRADED_STEPS+=("$1")
}

# _pipeline_step STEP_ID FN — wraps a zero-arg boolean FN in the retry/skip/
# back loop implied by err_menu's "rlsb" context (config/firewall/services,
# §14). Unlike repo/packages/db, these steps CAN be meaningfully skipped, so
# (unattended-mode die() aside) this never itself fails: it returns 0 to
# continue the pipeline, or PIPELINE_BACK to tell the caller to return to the
# plan. repo.sh/pkg.sh/db_*.sh keep their own inline loops — their option
# sets never include skip/back, so a shared wrapper would buy them nothing.
_pipeline_step() {
  local step="$1" fn="$2" rc
  while true; do
    if "$fn"; then
      return 0
    fi
    # err_menu returning non-zero (SKIP/BACK) is the expected outcome here,
    # not a real failure — a bare call would trip set -e before the case
    # below ever ran, so capture it via &&/|| instead (§15 gotcha).
    err_menu "$step" "step '$step' failed — see the log" && rc=0 || rc=$?
    case "$rc" in
      "$ERRMENU_SKIP")
        core_mark_degraded "$step"
        return 0
        ;;
      "$ERRMENU_BACK") return "$PIPELINE_BACK" ;;
    esac
  done
}

# --- traps -------------------------------------------------------------------
core_on_err() {
  local rc=$? src="${BASH_SOURCE[1]:-?}" line="${BASH_LINENO[0]:-?}"
  log ERROR "${src}:${line}: command failed (rc=${rc})"
}

core_on_exit() {
  local f
  for f in "${ZBX_TEMPFILES[@]:-}"; do
    if [[ -n "$f" && -e "$f" ]]; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
  # Extension hook, not a hardcoded dependency: core.sh stays DB-engine-
  # agnostic, but db_mysql.sh (if loaded) can register cleanup here for
  # settings that must be restored on every exit path, not just success —
  # e.g. log_bin_trust_function_creators (§12.3/§14).
  if declare -f db_mysql_cleanup_trust_flag >/dev/null 2>&1; then
    db_mysql_cleanup_trust_flag
  fi
}

core_on_int() {
  if [[ "$UNATTENDED" == "1" ]]; then exit 7; fi
  local confirm
  printf '\n' >&2
  read -r -p 'Exit installer? [y/N] ' confirm </dev/tty || confirm=y
  [[ "$confirm" =~ ^[Yy]$ ]] && exit 7
}

# Install the traps. Call once, early, from main.sh.
core_init_traps() {
  trap core_on_err ERR
  trap core_on_exit EXIT
  trap core_on_int INT
}
