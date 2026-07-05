# shellcheck shell=bash
# config.sh — render server/agent/web configs, skip the frontend setup wizard (§12.4).
#
# Contract:
#   inputs  : PLAN_* (recommend.sh), ZBX_DB_PASSWORD (creds.sh), DETECT_FAMILY
#             (detect.sh).
#   outputs : renders zabbix_server.conf, the agent conf, the frontend's
#             zabbix.conf.php (so the setup wizard is skipped), PHP timezone,
#             and (nginx only) listen/server_name; state_mark_done("config").
#             On failure routes to err_menu('config', ...) (§14: retry / skip
#             (warn, degraded) / view log / exit 5).
#
# Paths verified live 2026-07-05 by downloading and inspecting the real
# packages (apt .deb + rpm2cpio) for ubuntu 24.04 / rhel 9 / sles 15 — SPEC.md
# only names the RHEL php-fpm path, the rest were confirmed this way:
#   PHP timezone directive (php_value, not a plain KEY=VALUE — set_conf
#   doesn't apply here):
#     debian+apache : /etc/zabbix/apache.conf        (php_value KEY VALUE)
#     debian+nginx  : /etc/zabbix/php-fpm.conf        (php_value[KEY] = VALUE)
#     rhel (either) : /etc/php-fpm.d/zabbix.conf      (php_value[KEY] = VALUE)
#     suse+apache   : /etc/apache2/conf.d/zabbix.conf (php_value KEY VALUE)
#     suse+nginx    : /etc/php8/fpm/php-fpm.d/zabbix.conf (php_value[KEY] = VALUE)
#   nginx server block (listen/server_name):
#     debian        : /etc/zabbix/nginx.conf
#     rhel/suse     : /etc/nginx/conf.d/zabbix.conf
#   Web user that must own zabbix.conf.php (matches whichever process reads
#   it — the shared php-fpm pool's "user=", or apache/mod_php's own worker
#   user; identical for apache/nginx within a family):
#     rhel -> apache   debian -> www-data   suse -> wwwrun
#   /etc/zabbix/web/zabbix.conf.php and /etc/zabbix/zabbix_server.conf are
#   identical paths across all three families (same upstream app, only the
#   web-server glue differs).

# Not readonly, and respects a pre-set value — same convention as
# OS_RELEASE_FILE/MEMINFO_FILE (detect.sh) and ZBX_PGSQL_DATA_DIR
# (db_pgsql.sh), purely so bats can redirect every "/etc/zabbix/..." path
# below into a fixture tmpdir without touching the real filesystem.
: "${ZBX_ETC_DIR:=/etc/zabbix}"

# zabbix_server.conf's DBName/DBUser already ship uncommented with the
# correct defaults ("zabbix"/"zabbix") — set_conf still runs on them so this
# stays correct if that ever changes upstream. §9's "innodb_buffer_pool_size
# / shared_buffers ... in zabbix_server.conf" is not literally possible
# (those are DB engine settings, zabbix_server.conf has no such keys — only
# CacheSize/ValueCacheSize genuinely live there); config_apply_db_sizing
# applies the DB-engine ones through the engine itself instead (MySQL/MariaDB
# config-include directory, PostgreSQL ALTER SYSTEM) — best effort, a DB
# restart is needed to pick them up, same "log and continue" precedent as
# Phase 4's TimescaleDB/EL8-Remi gaps.

# set_conf FILE KEY VALUE — idempotent: replace an existing "KEY=" or
# "# KEY=" line, append "KEY=VALUE" if neither exists (§12.4). Pure bash (no
# sed/awk subprocess) so a secret VALUE never touches a command's argv (§10).
set_conf() {
  local file="$1" key="$2" value="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: set $key in $file"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    log ERROR "cannot set $key — $file does not exist"
    return 1
  fi
  _config_replace_or_append "$file" "^#? ?${key}=" "${key}=${value}"
  log INFO "set $key in $file"
}

# _config_replace_or_append FILE PATTERN LINE — replace the first line
# matching the bash regex PATTERN with LINE; append LINE if nothing matches.
# Pure bash (temp file + line-by-line read), same secret-safety reason as
# set_conf above.
_config_replace_or_append() {
  local file="$1" pattern="$2" line="$3" tmp cur found=0
  tmp="$(mktemp -t zbx-conf.XXXXXX)"
  ZBX_TEMPFILES+=("$tmp")
  while IFS= read -r cur || [[ -n "$cur" ]]; do
    if [[ "$cur" =~ $pattern ]]; then
      if ((!found)); then
        printf '%s\n' "$line"
        found=1
      fi
    else
      printf '%s\n' "$cur"
    fi
  done <"$file" >"$tmp"
  ((found)) || printf '%s\n' "$line" >>"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# _config_php_escape VALUE — escape backslash and single-quote for embedding
# in a PHP single-quoted string literal (a user-entered password, unlike a
# generated one, can contain either).
_config_php_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\'/\\\'}"
  printf '%s' "$v"
}

# config_web_user — the user that must own zabbix.conf.php (see module header).
config_web_user() {
  case "$DETECT_FAMILY" in
    rhel) printf 'apache' ;;
    suse) printf 'wwwrun' ;;
    *) printf 'www-data' ;;
  esac
}

# --- zabbix_server.conf --------------------------------------------------------
config_render_server() {
  local file="$ZBX_ETC_DIR/zabbix_server.conf"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: render $file"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    log ERROR "cannot render $file — it does not exist"
    return 1
  fi
  local -a sv
  IFS=' ' read -ra sv <<<"$(rec_sizing_values "$PLAN_SIZING")"
  set_conf "$file" DBName zabbix || return 1
  set_conf "$file" DBUser zabbix || return 1
  set_conf "$file" DBPassword "$ZBX_DB_PASSWORD" || return 1
  set_conf "$file" CacheSize "${sv[2]}" || return 1
  set_conf "$file" ValueCacheSize "${sv[3]}" || return 1
  chown root:zabbix "$file" 2>/dev/null || log WARN "could not chown $file to root:zabbix"
  chmod 0640 "$file"
  log INFO "rendered $file (sizing preset $PLAN_SIZING)"
}

# config_apply_db_sizing — best effort (§9): the DB engine's own buffer size,
# via the engine itself rather than guessing a distro-specific config path.
# Needs a DB restart to take effect — not forced here (Phase 5 doesn't
# restart an already-provisioned, already-imported DB over a tuning knob).
config_apply_db_sizing() {
  local -a sv
  IFS=' ' read -ra sv <<<"$(rec_sizing_values "$PLAN_SIZING")"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: tune DB buffer size for $PLAN_DB_ENGINE (sizing preset $PLAN_SIZING)"
    return 0
  fi
  if [[ "$PLAN_DB_ENGINE" == "pgsql" ]]; then
    printf 'ALTER SYSTEM SET shared_buffers = %s;\n' "${sv[1]}" | run sudo -u postgres psql || return 1
    log INFO "set shared_buffers=${sv[1]} via ALTER SYSTEM — restart postgresql to apply"
    return 0
  fi
  local dir
  for dir in /etc/mysql/mariadb.conf.d /etc/my.cnf.d; do
    if [[ -d "$dir" ]]; then
      printf '[mysqld]\ninnodb_buffer_pool_size=%s\n' "${sv[0]}" |
        run tee "$dir/90-zbx-install.cnf" >/dev/null || return 1
      log INFO "set innodb_buffer_pool_size=${sv[0]} in $dir/90-zbx-install.cnf — restart the DB service to apply"
      return 0
    fi
  done
  log WARN "no known MySQL/MariaDB config directory found — DB sizing not applied"
}

# --- PHP timezone (§12.4) -------------------------------------------------------
_config_php_tz_target() {
  case "$DETECT_FAMILY" in
    rhel) printf '/etc/php-fpm.d/zabbix.conf:fpm' ;;
    suse)
      if [[ "$PLAN_WEB_SERVER" == "nginx" ]]; then
        printf '/etc/php8/fpm/php-fpm.d/zabbix.conf:fpm'
      else
        printf '/etc/apache2/conf.d/zabbix.conf:apache'
      fi
      ;;
    *) # debian
      if [[ "$PLAN_WEB_SERVER" == "nginx" ]]; then
        printf '%s/php-fpm.conf:fpm' "$ZBX_ETC_DIR"
      else
        printf '%s/apache.conf:apache' "$ZBX_ETC_DIR"
      fi
      ;;
  esac
}

config_set_php_tz() {
  local target file style
  target="$(_config_php_tz_target)"
  file="${target%%:*}" style="${target##*:}"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: set PHP date.timezone=$PLAN_TZ in $file"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    log WARN "no known PHP config path for $DETECT_FAMILY/$PLAN_WEB_SERVER — timezone not set"
    return 0
  fi
  if [[ "$style" == "fpm" ]]; then
    _config_replace_or_append "$file" '^[[:space:]]*php_value\[date\.timezone\]' "php_value[date.timezone] = $PLAN_TZ"
  else
    _config_replace_or_append "$file" '^[[:space:]]*php_value date\.timezone' "php_value date.timezone $PLAN_TZ"
  fi
  log INFO "set PHP date.timezone=$PLAN_TZ in $file"
}

# --- nginx listen/server_name (§12.4, nginx only) -------------------------------
_config_nginx_conf_path() {
  case "$DETECT_FAMILY" in
    debian) printf '%s/nginx.conf' "$ZBX_ETC_DIR" ;;
    *) printf '/etc/nginx/conf.d/zabbix.conf' ;;
  esac
}

config_render_nginx() {
  [[ "$PLAN_WEB_SERVER" == "nginx" ]] || return 0
  local file
  file="$(_config_nginx_conf_path)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: uncomment listen/server_name in $file"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    log WARN "nginx config not found at $file — listen/server_name not set"
    return 0
  fi
  # Pattern matches with or without a leading "#" so a second run (resume)
  # recognizes the already-uncommented line instead of appending a duplicate.
  _config_replace_or_append "$file" '^[[:space:]]*#?[[:space:]]*listen[[:space:]]' '        listen          80;'
  _config_replace_or_append "$file" '^[[:space:]]*#?[[:space:]]*server_name[[:space:]]' '        server_name     _;'
  log INFO "uncommented listen/server_name in $file"
}

# --- frontend: skip the setup wizard (§12.4) ------------------------------------
# Template mirrors the real zabbix.conf.php.example shipped in the frontend
# package (verified live 2026-07-05); CConfigFile::load() only strictly
# requires DB TYPE + DATABASE, everything else already has an internal
# default, but SERVER/USER/PASSWORD/SCHEMA are set anyway for a real
# connection to actually succeed (skipping the wizard requires more than
# just "the file parses" — the DB must be reachable too).
config_render_frontend() {
  local file="$ZBX_ETC_DIR/web/zabbix.conf.php" dbtype pass name dir
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: render $file"
    return 0
  fi
  dir="${file%/*}"
  if [[ ! -d "$dir" ]]; then
    log ERROR "cannot render $file — $dir does not exist"
    return 1
  fi
  case "$PLAN_DB_ENGINE" in
    pgsql) dbtype="POSTGRESQL" ;;
    *) dbtype="MYSQL" ;;
  esac
  pass="$(_config_php_escape "$ZBX_DB_PASSWORD")"
  name="$(_config_php_escape "$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)")"
  {
    printf "<?php\n"
    printf "// Zabbix GUI configuration file.\n\n"
    printf "\$DB['TYPE']\t\t\t= '%s';\n" "$dbtype"
    printf "\$DB['SERVER']\t\t\t= 'localhost';\n"
    printf "\$DB['PORT']\t\t\t\t= '0';\n"
    printf "\$DB['DATABASE']\t\t\t= 'zabbix';\n"
    printf "\$DB['USER']\t\t\t\t= 'zabbix';\n"
    printf "\$DB['PASSWORD']\t\t\t= '%s';\n\n" "$pass"
    printf "// Schema name. Used for PostgreSQL.\n"
    printf "\$DB['SCHEMA']\t\t\t= '';\n\n"
    printf "// Used for TLS connection.\n"
    printf "\$DB['ENCRYPTION']\t\t= false;\n"
    printf "\$DB['KEY_FILE']\t\t\t= '';\n"
    printf "\$DB['CERT_FILE']\t\t= '';\n"
    printf "\$DB['CA_FILE']\t\t\t= '';\n"
    printf "\$DB['VERIFY_HOST']\t\t= true;\n"
    printf "\$DB['CIPHER_LIST']\t\t= '';\n\n"
    printf "\$ZBX_SERVER_NAME\t\t= '%s';\n\n" "$name"
    printf "\$IMAGE_FORMAT_DEFAULT\t= IMAGE_FORMAT_PNG;\n"
  } >"$file"
  chown "$(config_web_user)" "$file" 2>/dev/null ||
    log WARN "could not chown $file to $(config_web_user)"
  chmod 600 "$file"
  log INFO "rendered $file (DB type $dbtype) — setup wizard skipped"
}

# --- agent (§12.4) ---------------------------------------------------------------
_config_agent_conf_path() {
  if [[ "$PLAN_AGENT_TYPE" == "zabbix-agent2" ]]; then
    printf '%s/zabbix_agent2.conf' "$ZBX_ETC_DIR"
  else
    printf '%s/zabbix_agentd.conf' "$ZBX_ETC_DIR"
  fi
}

config_render_agent() {
  local file hn
  file="$(_config_agent_conf_path)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log INFO "DRY-RUN: render $file"
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    log ERROR "cannot render $file — it does not exist"
    return 1
  fi
  hn="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  set_conf "$file" Server "$PLAN_ZBX_SERVER_IP" || return 1
  set_conf "$file" ServerActive "$PLAN_ZBX_SERVER_IP" || return 1
  set_conf "$file" Hostname "$hn" || return 1
  log INFO "rendered $file"
}

# --- orchestration ---------------------------------------------------------------
config_apply() {
  if core_state_is_done config; then
    log INFO "config already rendered (state file) — skipping"
    return 0
  fi
  if plan_has server; then
    config_render_server || return 1
    config_apply_db_sizing || return 1
  fi
  if plan_has frontend; then
    config_set_php_tz || return 1
    config_render_nginx || return 1
    config_render_frontend || return 1
  fi
  if plan_has agent; then
    config_render_agent || return 1
  fi
  state_mark_done config
  log INFO "config rendered successfully"
}
