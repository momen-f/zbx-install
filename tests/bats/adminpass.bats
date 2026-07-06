#!/usr/bin/env bats
# Unit tests for adminpass.sh (§15 gotcha 8): the optional post-install
# frontend Admin password change via the Zabbix JSON-RPC API. Sourcing
# happens inside `bash -c` subshells (see redact.bats for why); a small
# fake-tool PATH stands in for curl, built fresh per test.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
CREDS="${BATS_TEST_DIRNAME}/../../src/lib/creds.sh"
ADMINPASS="${BATS_TEST_DIRNAME}/../../src/lib/adminpass.sh"

aprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$RECOMMEND"'"; source "'"$CREDS"'"; source "'"$ADMINPASS"'"; '"$1"
}

fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

# fake_curl DIR MODE — a fake curl distinguishing user.login (argv -d, its
# JSON body is a literal argument)/user.logout (same) from user.update (its
# body goes over stdin via -d @-, §10: never argv for the new secret) by
# checking argv first, then falling back to reading stdin.
#   MODE good      — login/update/logout all succeed.
#   MODE badlogin  — login itself returns a JSON-RPC error (bad/already-
#                    changed default credentials).
#   MODE badupdate — login succeeds, user.update returns a JSON-RPC error
#                    with a "data" field.
fake_curl() {
  local dir="$1" mode="${2:-good}"
  fake_tool "$dir" curl '
call=""
for a in "$@"; do
  case "$a" in
    *user.login*) call="login" ;;
    *user.logout*) call="logout" ;;
  esac
done
if [[ -z "$call" ]]; then
  stdin_body="$(cat)"
  case "$stdin_body" in
    *user.update*) call="update" ;;
  esac
fi
case "$call/'"$mode"'" in
  login/badlogin) printf "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"Invalid params.\",\"data\":\"Login name or password is incorrect.\"},\"id\":1}" ;;
  login/*) printf "{\"jsonrpc\":\"2.0\",\"result\":\"tok123\",\"id\":1}" ;;
  update/badupdate) printf "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"Invalid params.\",\"data\":\"Incorrect current password.\"},\"id\":2}" ;;
  update/*) printf "{\"jsonrpc\":\"2.0\",\"result\":{\"userids\":[\"1\"]},\"id\":2}" ;;
  logout/*) printf "{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":3}" ;;
esac
'
}

# --- pure helpers -------------------------------------------------------------

@test "_adminpass_json_escape backslash-escapes backslashes and double quotes" {
  aprobe '_adminpass_json_escape '\''back\slash and "quote"'\'''
  [ "$status" -eq 0 ]
  [ "$output" = 'back\\slash and \"quote\"' ]
}

@test "_adminpass_json_escape leaves an ordinary password untouched" {
  aprobe '_adminpass_json_escape "PlainPassw0rd123"'
  [ "$status" -eq 0 ]
  [ "$output" = "PlainPassw0rd123" ]
}

# A stronger check than the two string-equality tests above: embed the
# escaped output in a real JSON body and decode it with a real JSON parser,
# for a password with a backslash and a quote directly adjacent — the exact
# shape where getting the escaping order wrong (quote before backslash, or a
# refactor that handles them independently instead of sequentially) would
# produce a body that still *looks* plausible but decodes to the wrong
# string or fails to parse, without necessarily failing a hardcoded
# string-equality assertion.
@test "_adminpass_json_escape's output round-trips through a real JSON parser (backslash+quote adjacency)" {
  command -v python3 >/dev/null 2>&1 || skip "no python3 on this platform"
  export ADMTEST_PW='a\"b'
  aprobe 'esc="$(_adminpass_json_escape "$ADMTEST_PW")"; printf "{\"passwd\":\"%s\"}" "$esc"'
  [ "$status" -eq 0 ]
  local body="$output"
  run python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.stdin.read())["passwd"])' <<<"$body"
  [ "$status" -eq 0 ]
  [ "$output" = "$ADMTEST_PW" ]
}

@test "_adminpass_json_field extracts a plain-string result (user.login's shape)" {
  aprobe '_adminpass_json_field "{\"jsonrpc\":\"2.0\",\"result\":\"tok123\",\"id\":1}" result'
  [ "$status" -eq 0 ]
  [ "$output" = "tok123" ]
}

@test "_adminpass_json_field extracts a nested error field without needing real JSON nesting awareness" {
  aprobe '_adminpass_json_field "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"data\":\"Incorrect current password.\"}}" data'
  [ "$status" -eq 0 ]
  [ "$output" = "Incorrect current password." ]
}

@test "_adminpass_json_field returns empty for a field that is not a plain string (e.g. an object-valued result)" {
  aprobe '_adminpass_json_field "{\"jsonrpc\":\"2.0\",\"result\":{\"userids\":[\"1\"]}}" result'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- admin_pass_update orchestration -----------------------------------------

@test "admin_pass_update is a no-op when the feature wasn't requested (ZBX_ADMIN_PASSWORD empty)" {
  aprobe 'PLAN_COMPONENTS=server,frontend,agent; admin_pass_update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "admin_pass_update is a no-op for an agent-only plan even with a password resolved" {
  local d="$BATS_TEST_TMPDIR/t1"
  fake_curl "$d" good
  aprobe 'PATH="'"$d"':$PATH"; PLAN_COMPONENTS=agent; ZBX_ADMIN_PASSWORD=newpw; admin_pass_update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

# Regression test: a frontend-only plan (e.g. pointing at a remote/
# pre-existing DB) has no guarantee the known Admin/zabbix default applies —
# admin_pass_update must gate on BOTH plan_has frontend and plan_has server,
# not frontend alone (a real gap an adversarial review caught: without the
# plan_has server check, this used to attempt a pointless local API login
# and creds_write_summary would print a misleading DB engine/blank-password
# pair for a plan that never provisioned any DB at all).
@test "admin_pass_update is a no-op for a frontend-only plan (no server) even with a password resolved" {
  local d="$BATS_TEST_TMPDIR/t1b"
  fake_curl "$d" good
  aprobe 'PATH="'"$d"':$PATH"; PLAN_COMPONENTS=frontend,agent; ZBX_ADMIN_PASSWORD=newpw; admin_pass_update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "admin_pass_update does nothing under DRY_RUN" {
  local d="$BATS_TEST_TMPDIR/t2"
  fake_curl "$d" good
  aprobe 'PATH="'"$d"':$PATH"; PLAN_COMPONENTS=server,frontend,agent; ZBX_ADMIN_PASSWORD=newpw; DRY_RUN=1; admin_pass_update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "admin_pass_update skips entirely when the state file already marks it done" {
  local d="$BATS_TEST_TMPDIR/t3" s="$BATS_TEST_TMPDIR/state3"
  printf 'adminpass=done\n' >"$s"
  aprobe 'PLAN_COMPONENTS=server,frontend,agent; ZBX_ADMIN_PASSWORD=newpw; DRY_RUN=0; STATE_FILE="'"$s"'"; admin_pass_update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "admin_pass_update logs in, changes the password, logs out, and marks the state file on success" {
  local d="$BATS_TEST_TMPDIR/t4" s="$BATS_TEST_TMPDIR/state4"
  fake_curl "$d" good
  aprobe 'PATH="'"$d"':$PATH"; core_color_init; core_log_init; PLAN_COMPONENTS=server,frontend,agent;
    PLAN_CREDS_FILE=none; PLAN_DB_ENGINE=mariadb; ZBX_ADMIN_PASSWORD=newpw; DRY_RUN=0; STATE_FILE="'"$s"'";
    admin_pass_update; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  run grep -qxF "adminpass=done" "$s"
  [ "$status" -eq 0 ]
}

@test "admin_pass_update never puts the new password in curl's argv (only over stdin)" {
  local d="$BATS_TEST_TMPDIR/t5" s="$BATS_TEST_TMPDIR/state5"
  fake_tool "$d" curl '
for a in "$@"; do
  case "$a" in *super-secret-newpass*) echo "LEAKED IN ARGV" >&2 ;; esac
done
call=""
for a in "$@"; do
  case "$a" in *user.login*) call="login" ;; *user.logout*) call="logout" ;; esac
done
if [[ -z "$call" ]]; then cat >/dev/null; call="update"; fi
case "$call" in
  login) printf "{\"jsonrpc\":\"2.0\",\"result\":\"tok123\"}" ;;
  update) printf "{\"jsonrpc\":\"2.0\",\"result\":{\"userids\":[\"1\"]}}" ;;
  logout) printf "{\"jsonrpc\":\"2.0\",\"result\":true}" ;;
esac
'
  aprobe 'PATH="'"$d"':$PATH"; core_color_init; core_log_init; PLAN_COMPONENTS=server,frontend,agent;
    PLAN_CREDS_FILE=none; PLAN_DB_ENGINE=mariadb; ZBX_ADMIN_PASSWORD="super-secret-newpass"; DRY_RUN=0; STATE_FILE="'"$s"'";
    admin_pass_update'
  [ "$status" -eq 0 ]
  [[ "$output" != *"LEAKED IN ARGV"* ]]
}

@test "admin_pass_update fails cleanly (no crash) when the default Admin/zabbix login itself fails" {
  local d="$BATS_TEST_TMPDIR/t6" s="$BATS_TEST_TMPDIR/state6"
  fake_curl "$d" badlogin
  aprobe 'PATH="'"$d"':$PATH"; core_color_init; core_log_init; PLAN_COMPONENTS=server,frontend,agent;
    ZBX_ADMIN_PASSWORD=newpw; DRY_RUN=0; STATE_FILE="'"$s"'";
    admin_pass_update'
  [ "$status" -eq 1 ]
  # Not marked done — whether that's because the file was never even
  # created (login failed before state_mark_done) or exists without the
  # line doesn't matter, so don't pin grep's exact not-found exit code.
  ! grep -qxF "adminpass=done" "$s" 2>/dev/null
}

@test "admin_pass_update fails cleanly and surfaces the API's error message when user.update itself fails" {
  local d="$BATS_TEST_TMPDIR/t7" s="$BATS_TEST_TMPDIR/state7"
  fake_curl "$d" badupdate
  aprobe 'PATH="'"$d"':$PATH"; LOG_FILE="'"$BATS_TEST_TMPDIR"'/t7.log"; core_color_init; core_log_init;
    PLAN_COMPONENTS=server,frontend,agent; ZBX_ADMIN_PASSWORD=newpw; DRY_RUN=0; STATE_FILE="'"$s"'";
    admin_pass_update'
  [ "$status" -eq 1 ]
  run cat "$BATS_TEST_TMPDIR/t7.log"
  [[ "$output" == *"Incorrect current password."* ]]
}
