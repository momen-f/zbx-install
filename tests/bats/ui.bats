#!/usr/bin/env bats
# Unit tests for ui.sh pure helpers. Sourcing happens inside `bash -c`
# subshells (see redact.bats for why core.sh is never sourced into bats).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"

uprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; '"$1"
}

# Regression test for a confirmed Phase 2 bug: the global IFS=$'\n\t' (core.sh)
# has no space, so an unquoted split on space-substituted commas silently
# collapsed every multi-selection into one non-numeric token that matched
# nothing — ask_multi could never select more than one option.
@test "_ask_multi_tokens splits a multi-selection reply correctly" {
  uprobe '_ask_multi_tokens "1,3" postgresql mongodb mssql'
  [ "$status" -eq 0 ]
  [ "$output" = "postgresql,mssql" ]
}

@test "_ask_multi_tokens accepts space-separated replies too" {
  uprobe '_ask_multi_tokens "1 2" postgresql mongodb mssql'
  [ "$output" = "postgresql,mongodb" ]
}

@test "_ask_multi_tokens: a single selection still works" {
  uprobe '_ask_multi_tokens "2" postgresql mongodb mssql'
  [ "$output" = "mongodb" ]
}

@test "_ask_multi_tokens: empty reply selects nothing" {
  uprobe '_ask_multi_tokens "" postgresql mongodb mssql'
  [ "$output" = "" ]
}

@test "_ask_multi_tokens: out-of-range and non-numeric tokens are ignored" {
  uprobe '_ask_multi_tokens "1,9,x,2" postgresql mongodb mssql'
  [ "$output" = "postgresql,mongodb" ]
}
