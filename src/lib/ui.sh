# shellcheck shell=bash
# ui.sh — interactive prompts and progress display
#
# Contract:
#   inputs  : reads keystrokes from /dev/tty; relies on core.sh colors + log().
#   outputs : prompt text to stderr; answers returned via printf -v into a
#             caller-named variable (works on Bash 4.2, no nameref required).
#
# Every prompt here has a flag/config equivalent in main.sh, so unattended runs
# never reach this module. §3.

# ui_row LABEL VALUE [COLOR] — one aligned two-column report line (shared by
# detect_report and plan_report).
ui_row() {
  local color="${3:-}"
  if [[ -n "$color" ]]; then
    printf '  %-16s %s%s%s\n' "$1" "$color" "$2" "$C_RESET"
  else
    printf '  %-16s %s\n' "$1" "$2"
  fi
}

# ui_gen_password — 20-char secret, openssl preferred, /dev/urandom fallback. §10
ui_gen_password() {
  local out
  if command -v openssl >/dev/null 2>&1; then
    out="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
  else
    out="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  fi
  printf '%s' "$out"
}

# ask_yn PROMPT DEFAULT(y|n) — returns 0 for yes, 1 for no.
ask_yn() {
  local prompt="$1" default="${2:-n}" hint reply
  [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  while true; do
    read -r -p "$prompt $hint " reply </dev/tty || reply=""
    reply="${reply:-$default}"
    case "$reply" in
      y | Y) return 0 ;;
      n | N) return 1 ;;
      *) printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

# ask_choice VARNAME PROMPT OPTION... — numbered single-select; sets VARNAME to
# the chosen option string.
ask_choice() {
  local var="$1" prompt="$2"
  shift 2
  local -a opts=("$@")
  local i reply
  while true; do
    printf '%s\n' "$prompt" >&2
    for i in "${!opts[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${opts[i]}" >&2
    done
    read -r -p '> ' reply </dev/tty || reply=""
    if [[ "$reply" =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= ${#opts[@]})); then
      printf -v "$var" '%s' "${opts[reply - 1]}"
      return 0
    fi
    printf 'Enter a number between 1 and %d.\n' "${#opts[@]}" >&2
  done
}

# ask_choice_def VARNAME PROMPT DEFAULT_IDX OPTION... — like ask_choice, but an
# empty reply picks DEFAULT_IDX (1-based, marked with *). Custom mode uses this
# so every picker pre-selects the recommendation (§9).
ask_choice_def() {
  local var="$1" prompt="$2" def="$3"
  shift 3
  local -a opts=("$@")
  local i reply mark
  while true; do
    printf '%s\n' "$prompt" >&2
    for i in "${!opts[@]}"; do
      mark=" "
      if [[ "$((i + 1))" == "$def" ]]; then mark="*"; fi
      printf ' %s%d) %s\n' "$mark" "$((i + 1))" "${opts[i]}" >&2
    done
    read -r -p "> [${def}] " reply </dev/tty || reply=""
    reply="${reply:-$def}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= ${#opts[@]})); then
      printf -v "$var" '%s' "${opts[reply - 1]}"
      return 0
    fi
    printf 'Enter a number between 1 and %d (empty = %s).\n' "${#opts[@]}" "$def" >&2
  done
}

# _ask_multi_tokens REPLY OPTION... — pure: echo the comma-joined subset of
# OPTIONs picked by REPLY's space/comma-separated 1-based indices. Split out
# from ask_multi so the tokenizing logic is unit-testable without /dev/tty.
_ask_multi_tokens() {
  local reply="$1" tok
  shift
  local -a opts=("$@") chosen=()
  # Global IFS is $'\n\t' (core.sh) — it has no space, so this unquoted
  # expansion would not split on the spaces just substituted for commas,
  # collapsing "1 2" into a single non-numeric token that never matches.
  local IFS=' '
  for tok in ${reply//,/ }; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && ((tok >= 1 && tok <= ${#opts[@]})); then
      chosen+=("${opts[tok - 1]}")
    fi
  done
  local IFS=,
  printf '%s' "${chosen[*]:-}"
}

# ask_multi VARNAME PROMPT OPTION... — multi-select; sets VARNAME to a
# comma-separated list of chosen options. Empty selection is allowed.
ask_multi() {
  local var="$1" prompt="$2"
  shift 2
  local -a opts=("$@")
  local i reply
  printf '%s (space/comma-separated numbers, empty = none)\n' "$prompt" >&2
  for i in "${!opts[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${opts[i]}" >&2
  done
  read -r -p '> ' reply </dev/tty || reply=""
  printf -v "$var" '%s' "$(_ask_multi_tokens "$reply" "${opts[@]}")"
}

# ask_secret VARNAME LABEL [USERNAME] — hidden double-entry, min 12 chars, must
# not contain the username; 'g' auto-generates. Sets VARNAME. §10
ask_secret() {
  local var="$1" label="$2" username="${3:-}"
  local first second
  while true; do
    read -rs -p "$label (or 'g' to generate): " first </dev/tty || first=""
    printf '\n' >&2
    if [[ "$first" == "g" ]]; then
      first="$(ui_gen_password)"
      printf -v "$var" '%s' "$first"
      core_register_secret "$first"
      printf 'Generated a %d-char password.\n' "${#first}" >&2
      return 0
    fi
    if ((${#first} < 12)); then
      printf 'Too short — minimum 12 characters.\n' >&2
      continue
    fi
    if [[ -n "$username" && "$first" == *"$username"* ]]; then
      printf 'Must not contain the username.\n' >&2
      continue
    fi
    read -rs -p 'Confirm: ' second </dev/tty || second=""
    printf '\n' >&2
    if [[ "$first" != "$second" ]]; then
      printf 'Entries did not match — try again.\n' >&2
      continue
    fi
    printf -v "$var" '%s' "$first"
    core_register_secret "$first"
    return 0
  done
}

# ui_spinner PID MSG — animate while background PID runs; clears the line after.
ui_spinner() {
  local pid="$1" msg="${2:-working}"
  local frames='\|/-' i=0
  if [[ ! -t 2 ]]; then
    wait "$pid"
    return $?
  fi
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s' "${frames:i++%${#frames}:1}" "$msg" >&2
    sleep 0.1
  done
  printf '\r\033[K' >&2
  wait "$pid"
}
