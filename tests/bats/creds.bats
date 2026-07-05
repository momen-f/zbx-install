#!/usr/bin/env bats
# Unit tests for creds.sh (§10). Sourcing happens inside `bash -c` subshells
# (see redact.bats for why core.sh is never sourced into the bats shell).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
CREDS="${BATS_TEST_DIRNAME}/../../src/lib/creds.sh"

cprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$RECOMMEND"'"; source "'"$CREDS"'"; '"$1"
}

@test "creds_collect is a no-op when the plan has no server component" {
  cprobe 'PLAN_COMPONENTS=frontend,agent; creds_collect; printf "[%s]" "$ZBX_DB_PASSWORD"'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "creds_collect auto-generates under UNATTENDED without prompting" {
  cprobe 'PLAN_COMPONENTS=server,agent; UNATTENDED=1; creds_collect; printf "%s" "${#ZBX_DB_PASSWORD}"'
  [ "$status" -eq 0 ]
  [ "$output" -ge 12 ]
}

@test "creds_collect auto-generates when --generate-passwords is set" {
  cprobe 'PLAN_COMPONENTS=server,agent; UNATTENDED=0; OPT_GENPASS=1; creds_collect; printf "%s" "${#ZBX_DB_PASSWORD}"'
  [ "$status" -eq 0 ]
  [ "$output" -ge 12 ]
}

@test "creds_write_summary is a no-op when PLAN_CREDS_FILE is none" {
  cprobe 'PLAN_CREDS_FILE=none; creds_write_summary; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

@test "creds_write_summary is a no-op under DRY_RUN (does not touch disk)" {
  cprobe 'core_color_init; core_log_init; DRY_RUN=1; PLAN_CREDS_FILE="'"$BATS_TEST_TMPDIR"'/creds-dryrun.txt"; creds_write_summary'
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/creds-dryrun.txt" ]
}

@test "creds_write_summary writes the password in cleartext with 600 perms, but never the admin password" {
  local f="$BATS_TEST_TMPDIR/creds-real.txt"
  cprobe 'core_color_init; core_log_init; DRY_RUN=0;
    PLAN_CREDS_FILE="'"$f"'"; PLAN_DB_ENGINE=mariadb;
    ZBX_DB_PASSWORD="s3cr3t-zbx-pass"; ZBX_DB_ADMIN_PASSWORD="s3cr3t-admin-pass";
    creds_write_summary'
  [ "$status" -eq 0 ]
  [ -f "$f" ]
  run find "$f" -perm 600
  [[ "$output" == *"creds-real.txt"* ]]
  run cat "$f"
  [[ "$output" == *"s3cr3t-zbx-pass"* ]]
  [[ "$output" != *"s3cr3t-admin-pass"* ]]
  [[ "$output" == *"Database engine:   mariadb"* ]]
  [[ "$output" == *"Database name:     zabbix"* ]]
  [[ "$output" == *"Database user:     zabbix"* ]]
}

# Regression test: creds_write_summary used to crash the whole install (via
# set -e on a bare redirection) when the target path isn't writable — now it
# must warn and continue instead.
@test "creds_write_summary degrades gracefully when the path is unwritable" {
  cprobe 'core_color_init; core_log_init; DRY_RUN=0;
    PLAN_CREDS_FILE="/nonexistent-dir-xyz/creds.txt"; PLAN_DB_ENGINE=mariadb;
    ZBX_DB_PASSWORD="pw"; creds_write_summary; echo "survived"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"survived"* ]]
}
