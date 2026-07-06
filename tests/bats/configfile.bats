#!/usr/bin/env bats
# Unit tests for configfile.sh: the --config FILE parser (Appendix A, §18
# Phase 7). Sourcing happens inside `bash -c` subshells (see redact.bats for
# why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
DETECT="${BATS_TEST_DIRNAME}/../../src/lib/detect.sh"
REC="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
CREDS="${BATS_TEST_DIRNAME}/../../src/lib/creds.sh"
CFGFILE="${BATS_TEST_DIRNAME}/../../src/lib/configfile.sh"

# cprobe SNIPPET — run SNIPPET with every dependency configfile.sh needs
# sourced (core for log()/core_register_secret, detect for
# SUPPORTED_ZBX_VERSIONS, recommend for _valid_zbx_version/_valid_components).
cprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'"; source "'"$REC"'"; source "'"$CFGFILE"'"; USE_COLOR=0; core_color_init; LOG_FILE=/dev/null; '"$1"
}

mkcfg() {
  # 0600 so the permission warning (its own test below) doesn't pollute
  # every other test's captured output.
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/answers.conf"
  chmod 600 "$BATS_TEST_TMPDIR/answers.conf"
  printf '%s' "$BATS_TEST_TMPDIR/answers.conf"
}

@test "cfgfile_parse: a minimal valid express config sets CFGFILE_MODE and OPT_* correctly" {
  local f
  f="$(mkcfg 'MODE=express' 'DB_ENGINE=pgsql' 'WEB_SERVER=nginx' 'ZBX_VERSION=7.4')"
  cprobe 'cfgfile_parse "'"$f"'" && printf "%s|%s|%s|%s\n" "$CFGFILE_MODE" "$OPT_DB" "$OPT_WEB" "$OPT_ZBX_VERSION"'
  [ "$status" -eq 0 ]
  [ "$output" = "express|pgsql|nginx|7.4" ]
}

@test "cfgfile_parse: blank lines and # comments are ignored" {
  local f
  f="$(mkcfg '# a comment' '' 'MODE=express' '   ' '  # indented comment')"
  cprobe 'cfgfile_parse "'"$f"'" && echo "$CFGFILE_MODE"'
  [ "$status" -eq 0 ]
  [ "$output" = "express" ]
}

@test "cfgfile_parse: an unknown key is a hard error naming the file and line" {
  local f
  f="$(mkcfg 'MODE=express' 'BOGUS_KEY=yes')"
  cprobe 'cfgfile_parse "'"$f"'" || printf "ERR:%s\n" "$CFGFILE_ERR"'
  [[ "$output" == *"ERR:"*":2: unknown key 'BOGUS_KEY'"* ]]
}

@test "cfgfile_parse: an invalid value is a hard error naming the key and the bad value" {
  local f
  f="$(mkcfg 'MODE=bogus-mode')"
  cprobe 'cfgfile_parse "'"$f"'" || printf "ERR:%s\n" "$CFGFILE_ERR"'
  [[ "$output" == *"invalid value for MODE: 'bogus-mode'"* ]]
}

@test "cfgfile_parse: MODE is required" {
  local f
  f="$(mkcfg 'DB_ENGINE=mariadb')"
  cprobe 'cfgfile_parse "'"$f"'" || printf "ERR:%s\n" "$CFGFILE_ERR"'
  [[ "$output" == *"MODE is required"* ]]
}

@test "cfgfile_parse: a missing file is a clean error, not a crash" {
  cprobe 'cfgfile_parse "'"$BATS_TEST_TMPDIR"'/does-not-exist" || printf "ERR:%s\n" "$CFGFILE_ERR"'
  [[ "$output" == *"no such file"* ]]
}

@test "cfgfile_parse: a line with no '=' is a hard error" {
  printf 'MODE=express\nnotkeyvalue\n' >"$BATS_TEST_TMPDIR/bad.conf"
  cprobe 'cfgfile_parse "'"$BATS_TEST_TMPDIR"'/bad.conf" || printf "ERR:%s\n" "$CFGFILE_ERR"'
  [[ "$output" == *"not a KEY=VALUE line"* ]]
}

@test "cfgfile_parse: DB_PASS/DB_ADMIN_PASS are registered as secrets and redacted" {
  local f
  f="$(mkcfg 'MODE=express' 'DB_PASS=s3cr3t-one' 'DB_ADMIN_PASS=s3cr3t-two')"
  cprobe 'cfgfile_parse "'"$f"'" && printf "pw=%s admin=%s\n" "$ZBX_DB_PASSWORD" "$ZBX_DB_ADMIN_PASSWORD" && printf "s3cr3t-one and s3cr3t-two\n" | core_redact'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pw=s3cr3t-one admin=s3cr3t-two"* ]]
  [[ "$output" == *"******** and ********"* ]]
}

@test "cfgfile_parse: ADMIN_PASS=<value> enables the feature, sets the value, and registers it as a secret" {
  local f
  f="$(mkcfg 'MODE=express' 'ADMIN_PASS=s3cr3t-admin-frontend')"
  cprobe 'cfgfile_parse "'"$f"'" && printf "opt=%s pw=%s\n" "$OPT_ADMIN_PASS" "$ZBX_ADMIN_PASSWORD" && printf "s3cr3t-admin-frontend\n" | core_redact'
  [ "$status" -eq 0 ]
  [[ "$output" == *"opt=1 pw=s3cr3t-admin-frontend"* ]]
  [[ "$output" == *"********"* ]]
}

@test "cfgfile_parse: ADMIN_PASS=generate enables the feature but leaves the value empty for auto-generation" {
  local f
  f="$(mkcfg 'MODE=express' 'ADMIN_PASS=generate')"
  cprobe 'cfgfile_parse "'"$f"'" && printf "opt=%s pw=[%s]\n" "$OPT_ADMIN_PASS" "${ZBX_ADMIN_PASSWORD:-}"'
  [ "$status" -eq 0 ]
  [ "$output" = "opt=1 pw=[]" ]
}

@test "cfgfile_parse: without an ADMIN_PASS key, the feature stays off" {
  local f
  f="$(mkcfg 'MODE=express')"
  cprobe 'cfgfile_parse "'"$f"'" && printf "opt=%s pw=[%s]\n" "${OPT_ADMIN_PASS:-0}" "${ZBX_ADMIN_PASSWORD:-}"'
  [ "$status" -eq 0 ]
  [ "$output" = "opt=0 pw=[]" ]
}

# End-to-end composition check (not just each module's own unit test): an
# explicit ADMIN_PASS=<value> must survive all the way through
# creds_collect_admin_pass even when GENERATE_PASSWORDS=yes is also set in
# the same file — the explicit value must win, not be silently regenerated.
@test "cfgfile_parse + creds_collect_admin_pass: an explicit ADMIN_PASS wins over GENERATE_PASSWORDS=yes in the same file" {
  local f
  f="$(mkcfg 'MODE=express' 'COMPONENTS=server,frontend,agent' 'GENERATE_PASSWORDS=yes' 'ADMIN_PASS=explicit-from-file')"
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$DETECT"'"; source "'"$REC"'"; source "'"$CREDS"'"; source "'"$CFGFILE"'";
    USE_COLOR=0; core_color_init; LOG_FILE=/dev/null; UNATTENDED=1; PLAN_COMPONENTS=server,frontend,agent;
    cfgfile_parse "'"$f"'" && creds_collect_admin_pass && printf "%s" "$ZBX_ADMIN_PASSWORD"'
  [ "$status" -eq 0 ]
  [ "$output" = "explicit-from-file" ]
}

@test "cfgfile_parse: AGENT_TYPE maps agent2/agent to the zabbix-agent2/zabbix-agent package name" {
  local f
  f="$(mkcfg 'MODE=agent-only' 'AGENT_TYPE=agent')"
  cprobe 'cfgfile_parse "'"$f"'" && echo "$OPT_AGENT_TYPE"'
  [ "$status" -eq 0 ]
  [ "$output" = "zabbix-agent" ]
}

@test "cfgfile_parse: ASSUME_YES=yes sets the ASSUME_YES global" {
  local f
  f="$(mkcfg 'MODE=express' 'ASSUME_YES=yes')"
  cprobe 'ASSUME_YES=0; cfgfile_parse "'"$f"'" && echo "$ASSUME_YES"'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "cfgfile_parse: GENERATE_PASSWORDS=yes sets OPT_GENPASS, =no leaves it unset" {
  local f
  f="$(mkcfg 'MODE=express' 'GENERATE_PASSWORDS=yes')"
  cprobe 'OPT_GENPASS=0; cfgfile_parse "'"$f"'" && echo "$OPT_GENPASS"'
  [ "$output" = "1" ]
  f="$(mkcfg 'MODE=express' 'GENERATE_PASSWORDS=no')"
  cprobe 'OPT_GENPASS=0; cfgfile_parse "'"$f"'" && echo "$OPT_GENPASS"'
  [ "$output" = "0" ]
}

@test "cfgfile_parse: yes/no-only keys reject any other value" {
  local f
  f="$(mkcfg 'MODE=express' 'OPEN_FIREWALL=sure')"
  cprobe 'cfgfile_parse "'"$f"'" || printf "ERR:%s\n" "$CFGFILE_ERR"'
  [[ "$output" == *"invalid value for OPEN_FIREWALL: 'sure'"* ]]
}

@test "cfgfile_parse: free-form keys (CREDS_FILE, PHP_TZ, ZBX_SERVER_IP) pass through verbatim" {
  local f
  f="$(mkcfg 'MODE=agent-only' 'CREDS_FILE=none' 'PHP_TZ=Europe/Berlin' 'ZBX_SERVER_IP=10.0.0.5')"
  cprobe 'cfgfile_parse "'"$f"'" && printf "%s|%s|%s\n" "$OPT_CREDS_FILE" "$OPT_TZ" "$OPT_SERVER_IP"'
  [ "$status" -eq 0 ]
  [ "$output" = "none|Europe/Berlin|10.0.0.5" ]
}

@test "cfgfile_parse: a config file mode other than 0600 warns but does not fail" {
  local f
  f="$(mkcfg 'MODE=express')"
  chmod 644 "$f"
  cprobe 'core_log_init; cfgfile_parse "'"$f"'"; echo "rc=$?"; cat "$LOG_FILE"'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"not 600"* ]]
}
