#!/usr/bin/env bats
# Unit tests for core.sh redaction (§10) and the exit-code table (§14).
#
# NOTE: core.sh defines a run() function that would shadow bats's built-in
# `run`, so we never source it into the bats shell. Each test sources core.sh
# inside a `bash -c` subshell and captures the output via bats's run.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"

@test "core_redact masks a registered secret" {
  run bash -c 'source "'"$CORE"'"; core_register_secret "s3cr3t-pass"; printf "DBPassword=s3cr3t-pass\n" | core_redact'
  [ "$status" -eq 0 ]
  [ "$output" = "DBPassword=********" ]
}

@test "core_redact passes non-secret text unchanged" {
  run bash -c 'source "'"$CORE"'"; printf "just a line\n" | core_redact'
  [ "$status" -eq 0 ]
  [ "$output" = "just a line" ]
}

@test "core_redact ignores empty secrets" {
  run bash -c 'source "'"$CORE"'"; core_register_secret ""; printf "hello\n" | core_redact'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

# Regression test: run() used to redact only the announced command line,
# piping the command's OWN stdout/stderr straight to the log file. A command
# that echoes a secret back (e.g. a DB client's syntax error naming the bad
# value) would leak it into the log unredacted — a real risk once Phase 4
# starts running mysql/psql commands near real passwords.
@test "run() redacts the invoked command's own output, not just the announced line" {
  run bash -c '
    source "'"$CORE"'"
    core_color_init
    core_log_init
    core_register_secret "s3cr3t-pass"
    fake_cmd() { printf "error: bad value s3cr3t-pass\n"; return 1; }
    run fake_cmd || true
    cat "$LOG_FILE"
  '
  [[ "$output" == *"error: bad value ********"* ]]
  [[ "$output" != *"s3cr3t-pass"* ]]
}

@test "run() still returns the invoked command's real exit status" {
  run bash -c '
    source "'"$CORE"'"
    core_color_init
    core_log_init
    fake_ok() { return 0; }
    fake_fail() { return 7; }
    rc=0; run fake_ok || rc=$?; echo "ok=$rc"
    rc=0; run fake_fail || rc=$?; echo "fail=$rc"
  '
  [[ "$output" == *"ok=0"* ]]
  [[ "$output" == *"fail=7"* ]]
}

@test "core_exit_code_for maps steps to Appendix B codes" {
  run bash -c 'source "'"$CORE"'"; for s in detect network repo packages health db other; do core_exit_code_for "$s"; done | paste -sd" " -'
  [ "$status" -eq 0 ]
  [ "$output" = "3 4 5 5 6 8 7" ]
}

@test "core_exit_code_for: config/firewall/services also map to 5, like repo/packages" {
  run bash -c 'source "'"$CORE"'"; for s in config firewall services; do core_exit_code_for "$s"; done | paste -sd" " -'
  [ "$status" -eq 0 ]
  [ "$output" = "5 5 5" ]
}

# Regression test for Phase 6 (§13/§14): health's error menu has no "back to
# plan" option (unlike the generic config/firewall/services fallback) and
# uses different wording for retry/skip ("re-run checks" / "continue to
# summary anyway (degraded)", not the generic "Retry"/"Skip").
@test "_errmenu_opts_for health omits back-to-plan; other steps still get it" {
  run bash -c 'source "'"$CORE"'"; _errmenu_opts_for health'
  [ "$output" = "rls" ]
  run bash -c 'source "'"$CORE"'"; _errmenu_opts_for config'
  [ "$output" = "rlsb" ]
}

@test "_errmenu_print_options renders health-specific labels, generic labels for other steps" {
  run bash -c 'source "'"$CORE"'"; _errmenu_print_options health rls'
  [[ "$output" == *"Re-run checks"* ]]
  [[ "$output" == *"Continue to summary anyway (degraded)"* ]]
  [[ "$output" != *"[b] Back to plan"* ]]
  [[ "$output" != *"[r] Retry"* ]]
  [[ "$output" != *"[s] Skip*"* ]]

  run bash -c 'source "'"$CORE"'"; _errmenu_print_options config rlsb'
  [[ "$output" == *"[r] Retry"* ]]
  [[ "$output" == *"[s] Skip*"* ]]
  [[ "$output" == *"[b] Back to plan"* ]]
  [[ "$output" != *"Re-run checks"* ]]
  [[ "$output" != *"Continue to summary anyway"* ]]
}
