# shellcheck shell=bash
# creds.sh — credential collection, generation, redaction (§10).
#
# Contract:
#   inputs  : PLAN_COMPONENTS (recommend.sh), OPT_GENPASS/UNATTENDED (main.sh),
#             PLAN_CREDS_FILE.
#   outputs : ZBX_DB_PASSWORD (the new zabbix DB user's password — resolved
#             pre-confirm, matching §1's flow order) and, only if an existing
#             DB engine turns out to need one, ZBX_DB_ADMIN_PASSWORD (resolved
#             reactively, mid-pipeline, the first time db_mysql.sh's socket
#             auth attempt fails — see creds_reenter_admin_password). Both are
#             registered with core_register_secret so log()/run() redact them.
#             creds_write_summary renders the opt-in summary file (§10) after
#             provisioning succeeds.

ZBX_DB_PASSWORD=""
ZBX_DB_ADMIN_PASSWORD=""

# creds_collect — resolve the zabbix DB user's password. Called pre-confirm
# (prepare_plan) so the plan can be shown and confirmed before anything runs;
# a no-op when no DB will be provisioned by this plan.
creds_collect() {
  if ! plan_has server; then
    return 0
  fi
  # configfile.sh's DB_PASS already set (and registered) this — an explicit
  # password from the config file must win over auto-generation, and must
  # never be regenerated on a resumed/retried call into this function.
  if [[ -n "$ZBX_DB_PASSWORD" ]]; then
    return 0
  fi
  if [[ "$UNATTENDED" == "1" || "${OPT_GENPASS:-0}" == "1" ]]; then
    ZBX_DB_PASSWORD="$(ui_gen_password)"
    core_register_secret "$ZBX_DB_PASSWORD"
    log INFO "generated the zabbix DB user password"
    return 0
  fi
  ask_secret ZBX_DB_PASSWORD "Password for the new 'zabbix' DB user" "zabbix"
}

# creds_reenter_admin_password — called from err_menu's 'c' option when the
# db step fails needing (or rejecting) the existing engine's admin password.
# Only reachable interactively (err_menu already routes UNATTENDED to die()
# before offering this), so prompting here is always safe.
creds_reenter_admin_password() {
  ask_secret ZBX_DB_ADMIN_PASSWORD "Existing database admin (root) password" "root"
}

# creds_write_summary — opt-in credentials file (§10): umask 077, chmod 600,
# header warning, only what THIS installer set (never the pre-existing admin
# password — that's the user's own secret, not ours to persist again).
creds_write_summary() {
  if [[ "$PLAN_CREDS_FILE" == "none" || -z "$PLAN_CREDS_FILE" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "dry-run: would write credentials summary to $PLAN_CREDS_FILE"
    return 0
  fi
  local old_umask
  old_umask="$(umask)"
  umask 077
  # Grouped redirection + || true: a write failure (e.g. no root) must fall
  # into the -f check below, not crash the whole install over a nicety —
  # same pattern as core_state_init's fix (redirection ordering means a bare
  # 2>/dev/null after >"$file" doesn't suppress >"$file" failing to open).
  {
    {
      printf '# zbx-install credentials summary — %s\n' "$(date +%Y-%m-%d)"
      printf '# SECURITY: this file contains a plaintext password. Move it to a\n'
      printf '# password vault, then delete this file — it is not needed for the\n'
      printf '# installer or Zabbix to keep working.\n\n'
      printf 'Database engine:   %s\n' "$PLAN_DB_ENGINE"
      printf 'Database name:     zabbix\n'
      printf 'Database user:     zabbix\n'
      printf 'Database password: %s\n' "$ZBX_DB_PASSWORD"
      printf 'Database host:     localhost\n'
    } >"$PLAN_CREDS_FILE"
  } 2>/dev/null || true
  umask "$old_umask"
  if [[ -f "$PLAN_CREDS_FILE" ]]; then
    chmod 600 "$PLAN_CREDS_FILE" 2>/dev/null || true
    log INFO "wrote credentials summary to $PLAN_CREDS_FILE"
  else
    log WARN "could not write credentials summary to $PLAN_CREDS_FILE"
  fi
}
