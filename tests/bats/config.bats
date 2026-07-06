#!/usr/bin/env bats
# Unit tests for config.sh (§12.4). Sourcing happens inside `bash -c`
# subshells (see redact.bats for why core.sh is never sourced into the bats
# shell directly).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
CONFIG="${BATS_TEST_DIRNAME}/../../src/lib/config.sh"

cfprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$RECOMMEND"'"; source "'"$CONFIG"'"; '"$1"
}

# fake_tool DIR NAME BODY — drop an executable fake into a tool-farm dir.
fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

# --- set_conf --------------------------------------------------------------------

@test "set_conf replaces an existing uncommented KEY= line" {
  local f="$BATS_TEST_TMPDIR/t1.conf"
  printf 'DBName=zabbix\nDBUser=zabbix\n' >"$f"
  cfprobe 'DRY_RUN=0; set_conf "'"$f"'" DBUser somebody'
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" == *"DBUser=somebody"* ]]
  [[ "$output" != *"DBUser=zabbix"* ]]
}

@test "set_conf replaces a commented '# KEY=' line" {
  local f="$BATS_TEST_TMPDIR/t2.conf"
  printf '# DBPassword=\nDBName=zabbix\n' >"$f"
  cfprobe 'DRY_RUN=0; set_conf "'"$f"'" DBPassword s3cr3t'
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" == *"DBPassword=s3cr3t"* ]]
  [[ "$output" != *"# DBPassword="* ]]
}

@test "set_conf appends KEY=VALUE when the key is absent entirely" {
  local f="$BATS_TEST_TMPDIR/t3.conf"
  printf 'DBName=zabbix\n' >"$f"
  cfprobe 'DRY_RUN=0; set_conf "'"$f"'" CacheSize 128M'
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" == *"CacheSize=128M"* ]]
}

@test "set_conf is idempotent — a second call does not duplicate the line" {
  local f="$BATS_TEST_TMPDIR/t4.conf"
  printf 'DBName=zabbix\n' >"$f"
  cfprobe 'DRY_RUN=0; set_conf "'"$f"'" CacheSize 128M; set_conf "'"$f"'" CacheSize 128M'
  [ "$status" -eq 0 ]
  run grep -c '^CacheSize=' "$f"
  [ "$output" = "1" ]
}

@test "set_conf under DRY_RUN does not touch the file" {
  local f="$BATS_TEST_TMPDIR/t5.conf"
  printf 'DBName=zabbix\n' >"$f"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=1; set_conf "'"$f"'" DBPassword s3cr3t'
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" != *"DBPassword"* ]]
}

@test "set_conf fails cleanly when the target file does not exist" {
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; set_conf "'"$BATS_TEST_TMPDIR"'/nope.conf" DBName zabbix'
  [ "$status" -eq 1 ]
}

# --- config_web_user ---------------------------------------------------------------

@test "config_web_user maps family to the process owner that reads zabbix.conf.php" {
  cfprobe 'DETECT_FAMILY=rhel; config_web_user'
  [ "$output" = "apache" ]
  cfprobe 'DETECT_FAMILY=debian; config_web_user'
  [ "$output" = "www-data" ]
  cfprobe 'DETECT_FAMILY=suse; config_web_user'
  [ "$output" = "wwwrun" ]
}

# --- config_render_server -----------------------------------------------------------

@test "config_render_server sets DBName/DBUser/DBPassword and the sizing cache values" {
  local d="$BATS_TEST_TMPDIR/etc1"
  mkdir -p "$d"
  printf '# DBPassword=\n# CacheSize=32M\n# ValueCacheSize=8M\n' >"$d/zabbix_server.conf"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    ZBX_DB_PASSWORD="s3cr3t-server-pass"; PLAN_SIZING=medium;
    config_render_server'
  [ "$status" -eq 0 ]
  run cat "$d/zabbix_server.conf"
  [[ "$output" == *"DBName=zabbix"* ]]
  [[ "$output" == *"DBUser=zabbix"* ]]
  [[ "$output" == *"DBPassword=s3cr3t-server-pass"* ]]
  [[ "$output" == *"CacheSize=128M"* ]]
  [[ "$output" == *"ValueCacheSize=256M"* ]]
}

# Regression test for the acceptance criterion set_conf/_config_replace_or_
# append exist to satisfy (§10): a secret value must never touch a
# subprocess's argv. set_conf is pure bash (temp file + line-by-line read),
# not sed/awk — this locks that in by making sed/awk fail outright (a
# regression back to a subprocess-based implementation would break this test
# even though it never inspects the password itself).
@test "config_render_server never shells out to sed/awk to write the password" {
  local d="$BATS_TEST_TMPDIR/etc1b" pd="$BATS_TEST_TMPDIR/etc1b-noargv"
  mkdir -p "$d" "$pd"
  printf 'DBPassword=\n' >"$d/zabbix_server.conf"
  fake_tool "$pd" sed 'echo "sed must not be called" >&2; exit 1'
  fake_tool "$pd" awk 'echo "awk must not be called" >&2; exit 1'
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    ZBX_DB_PASSWORD="s3cr3t-argv-check"; PLAN_SIZING=medium;
    export PATH="'"$pd"':$PATH";
    config_render_server'
  [ "$status" -eq 0 ]
  run cat "$d/zabbix_server.conf"
  [[ "$output" == *"DBPassword=s3cr3t-argv-check"* ]]
}

# --- config_render_frontend ---------------------------------------------------------

@test "config_render_frontend writes MYSQL/POSTGRESQL, escapes a quote in the password" {
  local d="$BATS_TEST_TMPDIR/etc2"
  mkdir -p "$d/web"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    DETECT_FAMILY=debian; PLAN_DB_ENGINE=pgsql; ZBX_DB_PASSWORD="p'"'"'ss"; # embedded single quote
    config_render_frontend'
  [ "$status" -eq 0 ]
  run cat "$d/web/zabbix.conf.php"
  [[ "$output" == *"'POSTGRESQL'"* ]]
  [[ "$output" == *"p\\'ss"* ]]
  run find "$d/web/zabbix.conf.php" -perm 600
  [[ "$output" == *"zabbix.conf.php"* ]]
}

@test "config_render_frontend defaults to MYSQL for mariadb/mysql engines" {
  local d="$BATS_TEST_TMPDIR/etc2b"
  mkdir -p "$d/web"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    DETECT_FAMILY=debian; PLAN_DB_ENGINE=mariadb; ZBX_DB_PASSWORD="pw";
    config_render_frontend'
  [ "$status" -eq 0 ]
  run cat "$d/web/zabbix.conf.php"
  [[ "$output" == *"'MYSQL'"* ]]
}

# --- config_set_php_tz --------------------------------------------------------------

@test "config_set_php_tz uses unbracketed php_value on debian+apache" {
  local d="$BATS_TEST_TMPDIR/etc3"
  mkdir -p "$d"
  : >"$d/apache.conf"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    DETECT_FAMILY=debian; PLAN_WEB_SERVER=apache; PLAN_TZ=Europe/Riga;
    config_set_php_tz'
  [ "$status" -eq 0 ]
  run cat "$d/apache.conf"
  [[ "$output" == "php_value date.timezone Europe/Riga" ]]
}

@test "config_set_php_tz uses bracketed php_value[...] on debian+nginx" {
  local d="$BATS_TEST_TMPDIR/etc4"
  mkdir -p "$d"
  : >"$d/php-fpm.conf"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    DETECT_FAMILY=debian; PLAN_WEB_SERVER=nginx; PLAN_TZ=Europe/Riga;
    config_set_php_tz'
  [ "$status" -eq 0 ]
  run cat "$d/php-fpm.conf"
  [[ "$output" == "php_value[date.timezone] = Europe/Riga" ]]
}

@test "config_set_php_tz warns and continues (does not fail the step) when the path is unknown" {
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/does-not-exist";
    DETECT_FAMILY=debian; PLAN_WEB_SERVER=apache; PLAN_TZ=UTC;
    config_set_php_tz; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
}

# --- config_render_nginx ------------------------------------------------------------

@test "config_render_nginx uncomments listen/server_name and is idempotent" {
  local d="$BATS_TEST_TMPDIR/etc5"
  mkdir -p "$d"
  printf 'server {\n#        listen          8080;\n#        server_name     example.com;\n}\n' >"$d/nginx.conf"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    DETECT_FAMILY=debian; PLAN_WEB_SERVER=nginx;
    config_render_nginx; config_render_nginx'
  [ "$status" -eq 0 ]
  run cat "$d/nginx.conf"
  [[ "$output" == *"        listen          80;"* ]]
  [[ "$output" == *"        server_name     _;"* ]]
  [[ "$output" != *"#"*"listen"* ]]
  run grep -c 'listen' "$d/nginx.conf"
  [ "$output" = "1" ]
}

@test "config_render_nginx is a no-op for apache" {
  cfprobe 'PLAN_WEB_SERVER=apache; config_render_nginx; echo ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- config_render_agent ------------------------------------------------------------

@test "config_render_agent sets Server/ServerActive/Hostname" {
  local d="$BATS_TEST_TMPDIR/etc6"
  mkdir -p "$d"
  printf 'Server=127.0.0.1\nServerActive=127.0.0.1\nHostname=Zabbix server\n' >"$d/zabbix_agent2.conf"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    PLAN_AGENT_TYPE=zabbix-agent2; PLAN_ZBX_SERVER_IP=10.0.0.5;
    config_render_agent'
  [ "$status" -eq 0 ]
  run cat "$d/zabbix_agent2.conf"
  [[ "$output" == *"Server=10.0.0.5"* ]]
  [[ "$output" == *"ServerActive=10.0.0.5"* ]]
  [[ "$output" != *"Hostname=Zabbix server"* ]]
}

# --- config_render_proxy (§15.9 stretch) --------------------------------------------

@test "config_render_proxy (sqlite3): sets Hostname/Server/absolute DBName, creates the zabbix home dir" {
  local d="$BATS_TEST_TMPDIR/etc7" td="$BATS_TEST_TMPDIR/etc7-tools"
  mkdir -p "$d"
  : >"$d/zabbix_proxy.conf"
  fake_tool "$td" mkdir 'echo "MKDIR $*" >>"'"$BATS_TEST_TMPDIR"'/etc7-calls.log"; exit 0'
  fake_tool "$td" chown 'echo "CHOWN $*" >>"'"$BATS_TEST_TMPDIR"'/etc7-calls.log"; exit 0'
  rm -f "$BATS_TEST_TMPDIR/etc7-calls.log"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    PATH="'"$td"':$PATH"; PLAN_COMPONENTS=proxy; PLAN_DB_ENGINE=sqlite3;
    PLAN_PROXY_HOSTNAME=branch-1; PLAN_ZBX_SERVER_IP=10.0.0.5;
    config_render_proxy'
  [ "$status" -eq 0 ]
  run cat "$d/zabbix_proxy.conf"
  [[ "$output" == *"Hostname=branch-1"* ]]
  [[ "$output" == *"Server=10.0.0.5"* ]]
  [[ "$output" == *"DBName=/var/lib/zabbix/zabbix_proxy.db"* ]]
  run cat "$BATS_TEST_TMPDIR/etc7-calls.log"
  [[ "$output" == *"MKDIR -p /var/lib/zabbix"* ]]
  [[ "$output" == *"CHOWN zabbix:zabbix /var/lib/zabbix"* ]]
}

@test "config_render_proxy (mysql): sets DBName/DBUser/DBPassword using plan_db_name" {
  local d="$BATS_TEST_TMPDIR/etc8"
  mkdir -p "$d"
  : >"$d/zabbix_proxy.conf"
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    PLAN_COMPONENTS=proxy; PLAN_DB_ENGINE=mariadb;
    PLAN_PROXY_HOSTNAME=branch-2; PLAN_ZBX_SERVER_IP=10.0.0.9;
    ZBX_DB_PASSWORD="s3cr3t-proxy-pw";
    config_render_proxy'
  [ "$status" -eq 0 ]
  run cat "$d/zabbix_proxy.conf"
  [[ "$output" == *"Hostname=branch-2"* ]]
  [[ "$output" == *"Server=10.0.0.9"* ]]
  [[ "$output" == *"DBName=zabbix_proxy"* ]]
  [[ "$output" == *"DBUser=zabbix"* ]]
  [[ "$output" == *"DBPassword=s3cr3t-proxy-pw"* ]]
  [[ "$output" != *"/var/lib/zabbix"* ]]
}

@test "config_render_proxy fails cleanly when the target file does not exist" {
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$BATS_TEST_TMPDIR"'/does-not-exist";
    PLAN_COMPONENTS=proxy; PLAN_DB_ENGINE=sqlite3; PLAN_PROXY_HOSTNAME=h; PLAN_ZBX_SERVER_IP=127.0.0.1;
    config_render_proxy'
  [ "$status" -eq 1 ]
}

@test "config_apply renders zabbix_proxy.conf for a proxy plan" {
  local d="$BATS_TEST_TMPDIR/etc9" td="$BATS_TEST_TMPDIR/etc9-tools"
  mkdir -p "$d"
  : >"$d/zabbix_proxy.conf"
  fake_tool "$td" mkdir 'exit 0'
  fake_tool "$td" chown 'exit 0'
  cfprobe 'core_color_init; core_log_init; DRY_RUN=0; ZBX_ETC_DIR="'"$d"'";
    PATH="'"$td"':$PATH";
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state-proxy-apply";
    PLAN_COMPONENTS=proxy; PLAN_DB_ENGINE=sqlite3; PLAN_PROXY_HOSTNAME=h; PLAN_ZBX_SERVER_IP=127.0.0.1;
    config_apply; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  run cat "$d/zabbix_proxy.conf"
  [[ "$output" == *"Hostname=h"* ]]
}

# --- config_apply orchestration ------------------------------------------------------

@test "config_apply skips entirely when the state file already marks it done" {
  local log="$BATS_TEST_TMPDIR/skip.log"
  cfprobe 'core_color_init; LOG_FILE="'"$log"'"; core_log_init;
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state"; : >"$STATE_FILE";
    state_mark_done config;
    config_apply; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  run cat "$log"
  [[ "$output" == *"already rendered"* ]]
}
