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

# Regression test: run() built its log line with the global IFS=$'\n\t', so
# the bare "$*" joined argv with NEWLINES. One command became one log line
# per argument, only the first of them timestamped — the "RUN:" entries were
# ungreppable and core_tail_log showed argv fragments instead of the command
# and the error under it. run() now pins a local IFS=' ' first.
@test "run() logs the whole command on one line, not one line per argument" {
  run bash -c '
    source "'"$CORE"'"
    core_color_init
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/ifs.log"
    core_log_init
    fake_cmd() { :; }
    run fake_cmd --assume-yes install zabbix-server-mysql
    cat "$LOG_FILE"
  '
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"[INFO] RUN: fake_cmd --assume-yes install zabbix-server-mysql"* ]]
}

# Same IFS bug seen from the terminal instead of the log: --dry-run's
# preview printf'd the same newline-joined "$*", so every argument after the
# first landed on its own line with no "  + " in front of it.
@test "run()'s DRY_RUN preview is a single '  + cmd args' line" {
  run bash -c '
    source "'"$CORE"'"
    core_color_init
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/dry.log"
    core_log_init
    DRY_RUN=1
    run apt-get --assume-yes install zabbix-server-mysql
  '
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "  + apt-get --assume-yes install zabbix-server-mysql" ]
}

# Regression test: run() wired up `| core_redact >>"$LOG_FILE"` unconditionally.
# When that append failed (disk full, log unlinked under us) core_redact exited
# on its failed redirection, the command took SIGPIPE on its FIRST WRITE, and
# PIPESTATUS[0] handed the caller 141 for a command that had SUCCEEDED — so
# err_menu reported a failure that never happened. run() now checks the log is
# appendable and runs the command unpiped when it is not. Only commands that
# produce output were bitten, hence the chatty fakes; the sleep makes the
# vanished reader a certainty rather than a race.
@test "run() reports the real exit status when the log file can't be appended to" {
  # A plain file mid-path makes the append fail with ENOTDIR even for root,
  # which a mode-0444 file would not.
  : >"$BATS_TEST_TMPDIR/blocked"
  run bash -c '
    source "'"$CORE"'"
    core_color_init
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/blocked/zbx.log"
    chatty_ok()   { sleep 0.2; printf "installing\n"; return 0; }
    chatty_fail() { sleep 0.2; printf "installing\n"; return 9; }
    rc=0; run chatty_ok   || rc=$?; echo "ok=$rc"
    rc=0; run chatty_fail || rc=$?; echo "fail=$rc"
  '
  [[ "$output" == *"ok=0"* ]]
  [[ "$output" == *"fail=9"* ]]
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

# adminpass (§15.8) runs even later than health in the pipeline, so "back to
# plan" makes no more sense for it than it does for health — same rls set,
# but generic Retry/Skip* labels (no health-specific wording).
@test "_errmenu_opts_for adminpass omits back-to-plan and uses generic (not health-specific) labels" {
  run bash -c 'source "'"$CORE"'"; _errmenu_opts_for adminpass'
  [ "$output" = "rls" ]
  run bash -c 'source "'"$CORE"'"; _errmenu_print_options adminpass rls'
  [[ "$output" == *"[r] Retry"* ]]
  [[ "$output" == *"[s] Skip*"* ]]
  [[ "$output" != *"[b] Back to plan"* ]]
  [[ "$output" != *"Re-run checks"* ]]
  [[ "$output" != *"Continue to summary anyway"* ]]
}

# Regression coverage for Phase 7's resume flow (§14/§18): resume_check
# (main.sh) decides interactive-vs-skip purely from these two helpers, so
# their edge cases (missing file, empty file, actually-has-progress) matter
# more than the trivial happy path alone would suggest.
@test "core_state_has_progress is false when the state file doesn't exist yet" {
  run bash -c 'source "'"$CORE"'"; STATE_FILE="'"$BATS_TEST_TMPDIR"'/nope/state"; core_state_has_progress'
  [ "$status" -ne 0 ]
}

@test "core_state_has_progress is false for an empty (freshly-touched) state file" {
  : >"$BATS_TEST_TMPDIR/state"
  run bash -c 'source "'"$CORE"'"; STATE_FILE="'"$BATS_TEST_TMPDIR"'/state"; core_state_has_progress'
  [ "$status" -ne 0 ]
}

@test "core_state_has_progress is true once a step has been marked done" {
  run bash -c '
    source "'"$CORE"'"
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state2"
    core_state_init
    state_mark_done repo
    core_state_has_progress
  '
  [ "$status" -eq 0 ]
}

@test "core_state_clear wipes progress so core_state_has_progress goes false again" {
  run bash -c '
    source "'"$CORE"'"
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state3"
    core_state_init
    state_mark_done repo
    core_state_clear
    core_state_has_progress && echo "still-has-progress" || echo "cleared"
    core_state_is_done repo && echo "repo-still-done" || echo "repo-not-done"
  '
  [[ "$output" == *"cleared"* ]]
  [[ "$output" == *"repo-not-done"* ]]
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

# Regression test: die() printed the same sentence twice — once from
# `log ERROR` (log echoes ERROR lines to stderr) and once from its own ✗
# printf. It now logs LAST with that stderr copy dropped, so a hard stop
# says it once.
@test "die() prints its message exactly once" {
  run bash -c '
    source "'"$CORE"'"
    USE_COLOR=0; core_color_init
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/die-once.log"
    printf "seeded-1\nseeded-2\nseeded-3\n" >"$LOG_FILE"
    ZBX_DIE_TAIL=2
    die "step detect failed: BOOMTOKEN" 3
  '
  [ "$status" -eq 3 ]
  [ "$(grep -c "BOOMTOKEN" <<<"$output")" -eq 1 ]
  # ...and exactly once is not the same as "not at all": the fix moved the
  # log() call to the END of die() with its stderr copy dropped, so the file
  # copy must survive. Without this, a die() that never logged would pass.
  [ "$(grep -c "\[ERROR\].*BOOMTOKEN" "$BATS_TEST_TMPDIR/die-once.log")" -eq 1 ]
}

# Regression test: the ✗ copy interpolated the raw message, bypassing
# core_redact — and err_menu passes die() a step's raw reason, so a DB
# client's "access denied (password: ...)" printed in clear on the terminal
# even though log()'s copy of the same sentence was masked. LOG_FILE is left
# empty so the ✗ line is the only thing on stderr to match against.
@test "die() masks registered secrets in its ✗ line" {
  run bash -c '
    source "'"$CORE"'"
    USE_COLOR=0; core_color_init
    core_register_secret "s3cr3t-pass"
    LOG_FILE=""
    die "step db failed: access denied (password: s3cr3t-pass)" 8
  '
  [ "$status" -eq 8 ]
  [[ "$output" == *"access denied (password: ********)"* ]]
  [[ "$output" != *"s3cr3t-pass"* ]]
  # Pin that the redacted copy is die()'s OWN ✗ line. Without this the test
  # passes just as well against the old code path where log()'s (already
  # redacted) stderr copy was the only line printed.
  [[ "$output" == *"✗ step db failed"* ]]
}

# Regression test: die() printed "See log: <path>" and nothing from the log
# itself, so an unattended hard stop told the user nothing — while err_menu,
# the interactive path, already shows core_tail_log 5 above its menu. Safe to
# print: everything in the log went through core_redact. ZBX_DIE_TAIL keeps
# the tail small here (it defaults to 12).
@test "die() prints the tail of the log, not just its path" {
  run bash -c '
    source "'"$CORE"'"
    USE_COLOR=0; core_color_init
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/die-tail.log"
    printf "seeded-1\nseeded-2\nseeded-3\nseeded-4\nseeded-5\nseeded-6\n" >"$LOG_FILE"
    ZBX_DIE_TAIL=3
    die "step health failed" 6
  '
  [ "$status" -eq 6 ]
  [[ "$output" == *"--- last 3 lines of "*"/die-tail.log ---"* ]]
  [[ "$output" == *"seeded-4"* ]]
  [[ "$output" == *"seeded-6"* ]]
  [[ "$output" != *"seeded-1"* ]] # a tail, not the whole file
  [[ "$output" == *"Full log: "*"/die-tail.log"* ]]
}

# Regression test: the `|| true` on die()'s core_tail_log is load-bearing.
# core_tail_log ends in `[[ -f "$LOG_FILE" ]] && tail`, so a set-but-missing
# log makes it return 1; unguarded under set -Eeuo pipefail that fires the ERR
# trap and exits 1, losing the Appendix B code die() was called with. The
# header assertion also pins the tail itself, which the old "See log:" die()
# never printed.
@test "die() keeps its exit code when LOG_FILE is set but the file is missing" {
  run bash -c '
    source "'"$CORE"'"
    USE_COLOR=0; core_color_init
    core_init_traps
    LOG_FILE="'"$BATS_TEST_TMPDIR"'/never-created.log"
    ZBX_DIE_TAIL=3
    die "step health failed" 6
  '
  [ "$status" -eq 6 ]
  [[ "$output" == *"--- last 3 lines of "*"/never-created.log ---"* ]]
}
