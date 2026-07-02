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

@test "core_exit_code_for maps steps to Appendix B codes" {
  run bash -c 'source "'"$CORE"'"; for s in detect network repo packages health db other; do core_exit_code_for "$s"; done | paste -sd" " -'
  [ "$status" -eq 0 ]
  [ "$output" = "3 4 5 5 6 8 7" ]
}
