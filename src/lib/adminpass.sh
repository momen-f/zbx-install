# shellcheck shell=bash
# adminpass.sh — optional post-install step (SPEC §15 gotcha 8, formerly a
# Phase 7 stretch goal): logs into the frontend as the still-default
# Admin/zabbix user and changes the Admin password via the JSON-RPC API
# (user.login/user.update), so "always warn about the default login" doesn't
# have to be the end of the story.
#
# Contract:
#   inputs  : ZBX_ADMIN_PASSWORD (creds.sh — resolved pre-confirm; empty
#             means the feature wasn't requested), PLAN_* (recommend.sh).
#   outputs : admin_pass_update() is a no-op (returns 0) unless the user
#             opted in AND this plan has both a frontend and a server (the
#             known Admin/zabbix default only applies to a schema this
#             install itself just imported — a frontend-only plan pointing
#             at a remote/pre-existing DB has no such guarantee); otherwise
#             logs into the API with the known Zabbix default credentials,
#             changes the Admin password, logs out, marks state, and
#             re-writes the credentials summary file (creds_write_summary)
#             so it now includes the change. Wired into the pipeline
#             (main.sh) after health_run_checks confirms the frontend is
#             actually reachable (§13), before the final summary — a failure
#             here never blocks the rest of a successful install (rls
#             err_menu, same context as health: skip is always safe, it just
#             leaves the login as Admin/zabbix; no "back to plan" either,
#             for the same reason health has none — everything already ran).
#
# No jq (§3): the JSON-RPC bodies below are simple and fixed-shape enough to
# build with printf and parse with grep/cut.

ZBX_ADMIN_API_URL="http://127.0.0.1/zabbix/api_jsonrpc.php"

# _adminpass_json_escape STR — backslash and double-quote are the only two
# characters that can break a JSON string literal from a value we control
# (ask_secret/ui_gen_password never produce embedded newlines — read -rs
# stops at one — so nothing else needs escaping here).
_adminpass_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# _adminpass_json_field JSON FIELD — pull a top-level-or-nested string
# field's value out of a flat JSON-RPC response. Only matches string values
# ("field":"value") — good enough for the token (user.login's plain-string
# result) and error text (error.data/error.message), never used against a
# field whose value is an object. A field that's absent (or object-valued)
# is a normal, expected outcome here, not a caller error — always returns 0
# (an empty string on no match) so a bare call under this project's
# errexit+pipefail strict mode never aborts the script on a "not found".
_adminpass_json_field() {
  local json="$1" field="$2"
  printf '%s' "$json" | grep -o "\"$field\":\"[^\"]*\"" | head -1 | cut -d'"' -f4 || true
}

# _adminpass_login — log in with the known Zabbix defaults; prints the auth
# token on success, prints nothing on failure (network error, non-2xx, or a
# JSON-RPC error body — e.g. the password was already changed by an earlier
# partial run whose state mark never got persisted).
_adminpass_login() {
  local resp
  resp="$(curl -fsS -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
    "$ZBX_ADMIN_API_URL" 2>/dev/null)" || return 1
  [[ "$resp" == *'"error"'* ]] && return 1
  _adminpass_json_field "$resp" result
}

# _adminpass_set_password TOKEN — userid 1 is always Admin's on a fresh
# Zabbix install (the schema seeds it). current_passwd is required by the
# API when a user changes their own password — hardcoding "zabbix" here is
# correct precisely because we only ever reach this after logging in with
# that exact password. The body goes over stdin (curl -d @-), never argv
# (§10) — the new password is a secret.
_adminpass_set_password() {
  local token="$1" body
  body="$(printf '{"jsonrpc":"2.0","method":"user.update","params":{"userid":"1","passwd":"%s","current_passwd":"zabbix"},"id":2}' \
    "$(_adminpass_json_escape "$ZBX_ADMIN_PASSWORD")")"
  printf '%s' "$body" | curl -fsS -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" -d @- "$ZBX_ADMIN_API_URL" 2>/dev/null
}

# _adminpass_logout TOKEN — best-effort session cleanup; never fails the step.
_adminpass_logout() {
  local token="$1"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -d '{"jsonrpc":"2.0","method":"user.logout","params":{},"id":3}' \
    "$ZBX_ADMIN_API_URL" >/dev/null 2>&1 || true
}

admin_pass_update() {
  [[ -n "$ZBX_ADMIN_PASSWORD" ]] || return 0
  # Both, not just frontend: the known Admin/zabbix default only applies to
  # a schema THIS install just imported — a frontend-only plan (pointing at
  # a remote/pre-existing DB) has no such guarantee, so there's nothing for
  # this step to do (mirrors creds_collect_admin_pass's/plan_report's gate).
  plan_has frontend && plan_has server || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: would change the frontend Admin password via the API"
    return 0
  fi
  if core_state_is_done adminpass; then
    log INFO "frontend Admin password already changed (state file) — skipping"
    return 0
  fi
  local token resp
  token="$(_adminpass_login)"
  if [[ -z "$token" ]]; then
    log WARN "admin-pass: could not log into the API with the default Admin/zabbix credentials (already changed?)"
    return 1
  fi
  resp="$(_adminpass_set_password "$token")"
  if [[ "$resp" == *'"error"'* || -z "$resp" ]]; then
    local hint
    hint="$(_adminpass_json_field "$resp" data)"
    log WARN "admin-pass: user.update failed: ${hint:-$resp}"
    _adminpass_logout "$token"
    return 1
  fi
  _adminpass_logout "$token"
  state_mark_done adminpass
  creds_write_summary
  log INFO "changed the frontend Admin password"
}
