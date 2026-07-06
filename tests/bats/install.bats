#!/usr/bin/env bats
# End-to-end tests of install.sh, the tiny curl|bash bootstrap (§6). All
# network calls are faked with a recording curl — these tests must never
# touch the real network.

setup() {
  INSTALL="${BATS_TEST_DIRNAME}/../../install.sh"
  BASH_BIN="$(command -v bash)"
  TOOLDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TOOLDIR"
  local t src
  # GNU tar (Linux) shells out to an external gzip for -z (unlike macOS's
  # built-in-zlib bsdtar) — must be on PATH or both the fake tarball-creation
  # step and install.sh's own real extraction fail with "gzip: command not
  # found" (hit for real in CI, not reproducible on a Mac dev machine).
  for t in mktemp chmod rm cp mkdir sha256sum dirname basename cat tar gzip; do
    src="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "$TOOLDIR/$t"
  done
  ln -sf "$BASH_BIN" "$TOOLDIR/bash"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  : >"$CURL_LOG"
  # The stand-in for the real installer once downloaded/built: reports each
  # argument it received on its own ARG<...> line, so tests can verify exact
  # argument boundaries survived (not just that the concatenated text looks
  # right — see the space/metacharacter regression test below).
  printf '%s\n' 'for a in "$@"; do printf "ARG<%s>\n" "$a"; done' \
    >"$BATS_TEST_TMPDIR/argv-reporter.sh"
}

fake() {
  rm -f "$TOOLDIR/$1"
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$TOOLDIR/$1"
  chmod +x "$TOOLDIR/$1"
}

# fake_curl [bad] — records every "URL OUT" pair curl is asked to fetch to
# CURL_LOG.
#   -o .../zbx-install.sh   (release channel) writes the argv-reporter
#                           fixture in place of the real download.
#   -o .../main.tar.gz      (--dev channel) writes a REAL tar.gz containing a
#                           zbx-install-main/build.sh stub (so install.sh's
#                           own real tar -xzf and ./build.sh subshell run for
#                           real) whose only job is to copy the argv-reporter
#                           fixture into dist/zbx-install.sh.
#   -o .../SHA256SUMS       computes a REAL checksum of the zbx-install.sh
#                           already on disk, so sha256sum -c performs genuine
#                           verification rather than being faked itself —
#                           "bad" instead writes a checksum that can never
#                           match, to exercise the failure path.
fake_curl() {
  local mode="${1:-good}"
  fake curl '
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf "%s %s\n" "$url" "$out" >>"'"$CURL_LOG"'"
case "$out" in
  */zbx-install.sh) cp "'"$BATS_TEST_TMPDIR"'/argv-reporter.sh" "$out" ;;
  */main.tar.gz)
    stage="$(mktemp -d)"
    mkdir -p "$stage/zbx-install-main"
    printf "#!/bin/sh\nmkdir -p dist\ncp \"%s\" dist/zbx-install.sh\nchmod +x dist/zbx-install.sh\n" \
      "'"$BATS_TEST_TMPDIR"'/argv-reporter.sh" >"$stage/zbx-install-main/build.sh"
    chmod +x "$stage/zbx-install-main/build.sh"
    (cd "$stage" && tar -czf "$out" zbx-install-main)
    rm -rf "$stage"
    ;;
  */SHA256SUMS)
    if [[ "'"$mode"'" == bad ]]; then
      printf "0000000000000000000000000000000000000000000000000000000000000000  zbx-install.sh\n" >"$out"
    else
      (cd "$(dirname "$out")" && sha256sum zbx-install.sh >"$(basename "$out")")
    fi
    ;;
esac
'
}

run_install() {
  run env -i PATH="$TOOLDIR" "$BASH_BIN" "$INSTALL" "$@" </dev/null
}

# _headless CMD_STRING — runs install.sh fully detached from any controlling
# terminal (setsid, unlike closing stdin, actually achieves this — see
# cli.bats's identical rationale for main.sh's own guard_tty test) and
# leaves the exit code in $BATS_TEST_TMPDIR/rc and combined output in
# $BATS_TEST_TMPDIR/out for the caller to assert on.
_headless() {
  setsid bash -c '
    env -i PATH="'"$TOOLDIR"'" "'"$BASH_BIN"'" "'"$INSTALL"'" '"$1"' \
      >"'"$BATS_TEST_TMPDIR"'/out" 2>&1 </dev/null
    echo $? >"'"$BATS_TEST_TMPDIR"'/rc"
  ' </dev/null
}

@test "no TTY and no unattended flags exits 2, never downloads anything" {
  command -v setsid >/dev/null 2>&1 || skip "no setsid on this platform"
  fake_curl good
  _headless --yes
  run cat "$BATS_TEST_TMPDIR/rc"
  [ "$output" = "2" ]
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"No terminal available"* ]]
  [[ "$output" == *"--agent-only"* ]]
  [ ! -s "$CURL_LOG" ]
}

# Regression test: main.sh's own guard_tty (src/main.sh) accepts headless
# --agent-only/--uninstall + --yes too, not just --config/--express (§7 lists
# --agent-only as a first-class mode, and cloud-init-style unattended
# agent-only bootstraps are a core use case) — install.sh's own pre-flight
# guard must recognize the same set, or it wrongly blocks a valid headless
# run before main.sh ever gets a chance to accept it.
@test "no TTY but --agent-only --yes proceeds past the guard (matches main.sh's guard_tty)" {
  command -v setsid >/dev/null 2>&1 || skip "no setsid on this platform"
  fake_curl good
  _headless "--agent-only --yes"
  run cat "$BATS_TEST_TMPDIR/rc"
  [ "$output" = "0" ]
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"ARG<--agent-only>"* ]]
  [[ "$output" == *"ARG<--yes>"* ]]
}

@test "no TTY, --config FILE without --yes still exits 2" {
  command -v setsid >/dev/null 2>&1 || skip "no setsid on this platform"
  fake_curl good
  _headless "--config $BATS_TEST_TMPDIR/some.conf"
  run cat "$BATS_TEST_TMPDIR/rc"
  [ "$output" = "2" ]
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"No terminal available"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "no TTY, --config FILE --yes proceeds past the guard" {
  command -v setsid >/dev/null 2>&1 || skip "no setsid on this platform"
  fake_curl good
  _headless "--config $BATS_TEST_TMPDIR/some.conf --yes"
  run cat "$BATS_TEST_TMPDIR/rc"
  [ "$output" = "0" ]
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"ARG<--config>"* ]]
  [[ "$output" == *"ARG<$BATS_TEST_TMPDIR/some.conf>"* ]]
  [[ "$output" == *"ARG<--yes>"* ]]
}

@test "--dev builds from the main branch tarball, skips the checksum, and execs with --dev stripped" {
  fake_curl good
  run_install --dev --express --yes --foo bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: --dev builds the unreleased main branch, unchecksummed"* ]]
  [[ "$output" == *"ARG<--express>"* ]]
  [[ "$output" == *"ARG<--yes>"* ]]
  [[ "$output" == *"ARG<--foo>"* ]]
  [[ "$output" == *"ARG<bar>"* ]]
  [[ "$output" != *"ARG<--dev>"* ]]
  grep -qF "https://codeload.github.com/momen-f/zbx-install/tar.gz/refs/heads/main" "$CURL_LOG"
  ! grep -qF "SHA256SUMS" "$CURL_LOG"
}

@test "default channel fetches the latest release asset, verifies checksum, and execs with args" {
  fake_curl good
  run_install --express --yes --foo bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG<--express>"* ]]
  [[ "$output" == *"ARG<--yes>"* ]]
  [[ "$output" == *"ARG<--foo>"* ]]
  [[ "$output" == *"ARG<bar>"* ]]
  grep -qF "https://github.com/momen-f/zbx-install/releases/latest/download/zbx-install.sh" "$CURL_LOG"
  grep -qF "https://github.com/momen-f/zbx-install/releases/latest/download/SHA256SUMS" "$CURL_LOG"
}

# Regression test: an arg containing a space (or another word-splitting
# hazard) must survive as ONE argument through args+=("$a") / exec ... ${args[@]+"${args[@]}"} —
# this project's IFS=$'\n\t' convention has broken exactly this class of
# thing multiple times before (see health.sh/uninstall_run's history).
@test "an argument containing a space survives as a single argument through the final exec" {
  fake_curl good
  run_install --express --yes --creds-file "/tmp/my file.txt" --db "a;b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG<--creds-file>"* ]]
  [[ "$output" == *"ARG</tmp/my file.txt>"* ]]
  [[ "$output" == *"ARG<--db>"* ]]
  [[ "$output" == *"ARG<a;b>"* ]]
  # If word-splitting had corrupted the space-containing arg, it would show
  # up as two separate ARG<> lines instead of one.
  [[ "$output" != *"ARG</tmp/my>"* ]]
}

@test "default channel aborts with sha256sum's own failure code and never execs when the checksum does not match" {
  fake_curl bad
  run_install --express --yes
  [ "$status" -eq 1 ]
  [[ "$output" != *"ARG<"* ]]
}

@test "a curl failure (network down) aborts immediately with curl's own exit code and never execs" {
  fake curl 'exit 7'
  run_install --express --yes
  [ "$status" -eq 7 ]
  [[ "$output" != *"ARG<"* ]]
}
