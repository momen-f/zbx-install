# shellcheck shell=bash
# Resume metadata is private data, never shell code. Save before any mutation.
readonly -a RESUME_PLAN_KEYS=(
  DETECT_OS_ID DETECT_OS_VERSION DETECT_ARCH ZBX_RESUME_MODE
  PLAN_ZBX_VERSION PLAN_COMPONENTS PLAN_DB_ENGINE PLAN_WEB_SERVER
  PLAN_AGENT_TYPE PLAN_AGENT_PLUGINS PLAN_TOOLS PLAN_TIMESCALE PLAN_SIZING
  PLAN_TZ PLAN_UPDATE PLAN_OPEN_FIREWALL PLAN_ZBX_SERVER_IP PLAN_PROXY_HOSTNAME
  PLAN_CREDS_FILE OPT_ADMIN_PASS
)
ZBX_RESUMING=0

resume_plan_restore() {
  ZBX_RESUMING=0
  local file="${STATE_FILE}.plan" key value="" mode i=1
  local -a saved=()
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    if core_state_has_progress; then
      die "saved progress has no recovery plan; cannot safely resume this older install" 3
    fi
    return 0
  fi
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)" || return 1
  [[ -f "$file" && ! -L "$file" && -O "$file" && "$mode" == 600 ]] ||
    die "unsafe recovery file: $file (requires owner-only mode 600)" 3
  while IFS= read -r -d '' value; do saved+=("$value"); done <"$file"
  [[ -z "$value" && "${saved[0]:-}" == zbx-resume-1 && ${#saved[@]} -eq $((${#RESUME_PLAN_KEYS[@]} + 3)) ]] ||
    die "invalid recovery file: $file" 3
  for key in "${RESUME_PLAN_KEYS[@]}"; do
    # Detection changes after installing packages; keep the original implicit choices.
    case "$key" in
      PLAN_DB_ENGINE)
        if [[ -z "${OPT_DB:-}" || ("${OPT_DB:-}" == mysql && "${saved[i]}" =~ ^(mysql|mariadb)$) ]]; then
          PLAN_DB_ENGINE="${saved[i]}"
        fi
        ;;
      PLAN_WEB_SERVER) [[ -n "${OPT_WEB:-}" ]] || PLAN_WEB_SERVER="${saved[i]}" ;;
      PLAN_COMPONENTS) [[ -n "${OPT_COMPONENTS:-}" ]] || PLAN_COMPONENTS="${saved[i]}" ;;
      PLAN_TZ) [[ -n "${OPT_TZ:-}" ]] || PLAN_TZ="${saved[i]}" ;;
      PLAN_SIZING) PLAN_SIZING="${saved[i]}" ;;
    esac
    [[ "${!key:-}" == "${saved[i]}" ]] || die "resume plan differs at $key; repeat the original installation choices" 3
    i=$((i + 1))
  done
  for key in ZBX_DB_PASSWORD ZBX_ADMIN_PASSWORD; do
    if [[ -n "${!key}" && "${!key}" != "${saved[i]}" ]]; then
      die "supplied credentials differ from the saved installation" 3
    fi
    printf -v "$key" '%s' "${saved[i]}"
    core_register_secret "${saved[i]}"
    i=$((i + 1))
  done
  ZBX_RESUMING=1
}

resume_plan_save() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  local tmp key
  tmp="$(mktemp "${STATE_FILE}.plan.XXXXXX")" || return 1
  ZBX_TEMPFILES+=("$tmp")
  chmod 600 "$tmp" || return 1
  {
    printf '%s\0' zbx-resume-1 || return 1
    for key in "${RESUME_PLAN_KEYS[@]}"; do printf '%s\0' "${!key:-}" || return 1; done
    printf '%s\0' "$ZBX_DB_PASSWORD" "$ZBX_ADMIN_PASSWORD" || return 1
  } >"$tmp" || return 1
  mv -f "$tmp" "${STATE_FILE}.plan"
}
