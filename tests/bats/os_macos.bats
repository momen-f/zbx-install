#!/usr/bin/env bats
# Unit tests for os_macos.sh: the pure helpers (agent arch map + release URL
# builder, verified live against cdn.zabbix.com 2026-07) and the execute path —
# download retries, the package-body check and the signature gate, driven with
# DRY_RUN=0 against a PATH-shadowing tool farm. Sourced inside a `bash -c`
# subshell (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
CONFIG="${BATS_TEST_DIRNAME}/../../src/lib/config.sh"
HEALTH="${BATS_TEST_DIRNAME}/../../src/lib/health.sh"
MACOS="${BATS_TEST_DIRNAME}/../../src/lib/os_macos.sh"

mprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$MACOS"'"; '"$1"
}

# dprobe SNIPPET — sources the modules the macOS execute path touches, with
# DRY_RUN=1 and a throwaway LOG_FILE, then runs SNIPPET. run() prints "  + cmd"
# to stdout under DRY_RUN, so $output carries the commands that would run.
dprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$CONFIG"'"; source "'"$HEALTH"'"; source "'"$MACOS"'";
    DRY_RUN=1 LOG_FILE="$(mktemp)"; '"$1"
}

# fake_tool DIR NAME BODY — a PATH-shadowing stub (same helper as db_pgsql.bats).
fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

# rprobe DIR SNIPPET — the NON-dry-run probe: DRY_RUN=0 with DIR first on
# PATH, so the fakes in DIR shadow curl/mktemp/pkgutil/installer/sleep. Every
# other execute-path test here runs under dprobe, and the package-body and
# signature gates sit behind `if [[ "$DRY_RUN" != "1" ]]` — this is the only
# way to execute them outside the CI macOS job's single happy path. The log
# lands at $BATS_TEST_TMPDIR/rprobe.log, for the INFO lines log() keeps off
# stderr; WARN/ERROR reach $output on their own.
rprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$MACOS"'";
    core_color_init; LOG_FILE="'"$BATS_TEST_TMPDIR"'/rprobe.log"; core_log_init;
    DRY_RUN=0; PLAN_ZBX_VERSION=7.4; PATH="'"$1"':$PATH"; '"$2"
}

# tool_farm DIR BASE — the stubs macos_agent_install reaches once DRY_RUN=0.
# mktemp is pinned to BASE so a test controls (and knows) the temp FILENAME.
# sleep is a no-op so the 3s retry backoff costs nothing. pkgutil and
# installer record every call, so a test can assert a step was never reached.
# The default curl downloads a well-formed flat package (a xar archive) in one
# go and honours -o; tests overwrite curl/pkgutil afterwards to shape the case.
tool_farm() {
  local dir="$1" base="$2"
  fake_tool "$dir" mktemp 'printf "%s\n" "'"$base"'"; : >"'"$base"'"'
  fake_tool "$dir" sleep 'exit 0'
  fake_tool "$dir" pkgutil 'echo "$*" >>"'"$dir"'/pkgutil.calls"; exit 0'
  fake_tool "$dir" installer 'echo "$*" >>"'"$dir"'/installer.calls"; exit 0'
  fake_tool "$dir" curl 'out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    echo "$*" >>"'"$dir"'/curl.calls"
    printf "xar!fake flat package body\n" >>"$out"
    exit 0'
}

# pkgutil_signed_by DIR SIGNER — a --check-signature report shaped like the
# real one: the .pkg PATH on the first line (the stub reads it from its own
# $2), the signer in the certificate chain BELOW it. That split is
# load-bearing — see the temp-filename test.
pkgutil_signed_by() {
  local dir="$1" signer="$2"
  fake_tool "$dir" pkgutil 'echo "$*" >>"'"$dir"'/pkgutil.calls"
    printf "Package \"%s\":\n" "$2"
    printf "   Status: signed by a developer certificate issued by Apple\n"
    printf "   Certificate Chain:\n"
    printf "    1. Developer ID Installer: '"$signer"'\n"
    exit 0'
}

@test "_macos_arch maps uname arch to Zabbix macOS tokens" {
  mprobe 'for a in arm64 aarch64 x86_64 amd64; do _macos_arch "$a"; echo; done | paste -sd" " -'
  [ "$output" = "arm64 arm64 amd64 amd64" ]
}

@test "_macos_arch fails on an unsupported arch" {
  mprobe 'if _macos_arch i386; then echo yes; else echo no; fi'
  [ "$output" = "no" ]
}

@test "zbx_macos_agent_url: 7.4 arm64 openssl (self-updating latest pointer, default)" {
  mprobe 'zbx_macos_agent_url 7.4 arm64'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64-openssl.pkg" ]
}

@test "zbx_macos_agent_url: no-encryption drops the suffix" {
  mprobe 'zbx_macos_agent_url 7.4 arm64 none'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64.pkg" ]
}

@test "zbx_macos_agent_url: gnutls variant" {
  mprobe 'zbx_macos_agent_url 7.4 arm64 gnutls'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64-gnutls.pkg" ]
}

@test "zbx_macos_agent_url: 7.0 LTS also offers the arm64 latest pkg" {
  mprobe 'zbx_macos_agent_url 7.0 arm64 openssl'
  [ "$output" = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/latest/zabbix_agent-7.0-latest-macos-arm64-openssl.pkg" ]
}

# --- execute path (dry-run) ---------------------------------------------------
@test "macos_agent_install (dry-run) fetches the arm64 latest .pkg and runs installer" {
  dprobe 'PLAN_ZBX_VERSION=7.4; macos_agent_install'
  [ "$status" -eq 0 ]
  [[ "$output" == *"cdn.zabbix.com/zabbix/binaries/stable/7.4/latest/zabbix_agent-7.4-latest-macos-arm64-openssl.pkg"* ]]
  # run() prints each arg on its own line (global IFS=$'\n\t'), so match the
  # command token, not "installer -pkg".
  [[ "$output" == *"+ installer"* ]]
}

@test "macos_agent_config (dry-run) points the agent at the server, writes nothing" {
  dprobe 'PLAN_ZBX_SERVER_IP=192.0.2.10; macos_agent_config'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Server/ServerActive=192.0.2.10"* ]]
}

@test "macos_agent_run (dry-run) completes install -> config -> service -> health" {
  dprobe 'PLAN_ZBX_VERSION=7.4 PLAN_ZBX_SERVER_IP=192.0.2.10; macos_agent_run'
  [ "$status" -eq 0 ]
}

@test "macos_agent_uninstall (dry-run) unloads the daemon and removes the files" {
  dprobe 'macos_agent_uninstall'
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ launchctl"* ]]
  [[ "$output" == *"com.zabbix.zabbix_agentd.plist"* ]]
  [[ "$output" == *"+ rm"* ]]
  [[ "$output" == *"Removed the Zabbix macOS agent"* ]]
}

# --- curl exit-code → human reason -------------------------------------------
# Regression test: there was no reason map. A failed download reported curl's
# numeric exit code and nothing else, so a DNS failure, a TLS-intercepting
# middlebox and a 404 on the CDN all read identically on the console — which
# is exactly why the macOS 26 report was undiagnosable.
@test "_macos_curl_reason turns curl's exit codes into sentences a human can act on" {
  mprobe 'for rc in 6 7 18 22 23 28 35 60 77 56; do _macos_curl_reason "$rc"; echo; done'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"DNS lookup for cdn.zabbix.com failed"* ]]
  [[ "${lines[1]}" == *"could not connect to cdn.zabbix.com"* ]]
  [[ "${lines[2]}" == *"transfer ended early"* ]]
  [[ "${lines[3]}" == *"HTTP error"* ]]
  [[ "${lines[4]}" == *"could not write the downloaded file to disk"* ]]
  [[ "${lines[5]}" == *"timed out"* ]]
  # 35/60/77 are three distinct curl TLS failures that mean the same thing here.
  [[ "${lines[6]}" == *"TLS handshake failed"* ]]
  [[ "${lines[7]}" == *"TLS handshake failed"* ]]
  [[ "${lines[8]}" == *"TLS handshake failed"* ]]
  [[ "${lines[9]}" == *"connection was reset"* ]]
}

@test "_macos_curl_reason falls back to a generic sentence on an unmapped code" {
  mprobe '_macos_curl_reason 99'
  [ "$output" = "curl failed" ]
}

# --- execute path (real run: everything behind the DRY_RUN gate) -------------
# Regression test: the download was a bare `curl -fsSL -o ... URL` with no
# bounds and no retry. A middlebox that accepts the connection and then stalls
# hung the installer indefinitely. Pin the timeouts, the resume flag and the
# -w transfer summary in the transcript — and that dry-run still runs no curl.
@test "macos_agent_install (dry-run) shows bounded, resumable curl flags and executes no curl" {
  local d="$BATS_TEST_TMPDIR/dryflags"
  tool_farm "$d" "$BATS_TEST_TMPDIR/dryflags-base"
  dprobe 'PATH="'"$d"':$PATH"; PLAN_ZBX_VERSION=7.4; macos_agent_install'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--connect-timeout 15"* ]]
  [[ "$output" == *"--max-time 900"* ]]
  [[ "$output" == *"-C -"* ]]
  [[ "$output" == *"bytes=%{size_download}"* ]]
  [[ "$output" == *"zabbix_agent-7.4-latest-macos-arm64-openssl.pkg"* ]]
  [ ! -f "$d/curl.calls" ]
}

# Regression test: a failed download returned a bare 1 on the FIRST drop and
# never retried. The macOS 26 user's TLS-inspecting proxy cut the ~12MB
# transfer most times it ran; one attempt was never going to get through, and
# the single `return 1` said nothing about why it did not.
@test "macos_agent_install retries the download 3 times, then fails naming the reason" {
  local d="$BATS_TEST_TMPDIR/dlfail"
  tool_farm "$d" "$BATS_TEST_TMPDIR/dlfail-base"
  # curl 28 = timed out. Every attempt appends a line, so the count is the proof.
  fake_tool "$d" curl 'echo attempt >>"'"$d"'/curl.calls"; exit 28'
  rprobe "$d" 'rc=0; macos_agent_install || rc=$?; echo "rc=$rc"'
  [[ "$output" == *"rc=1"* ]]
  [ "$(wc -l <"$d/curl.calls")" -eq 3 ]
  [[ "$output" == *"attempt 1/3 failed"* ]]
  [[ "$output" == *"attempt 3/3 failed"* ]]
  [[ "$output" == *"downloading the agent package failed"* ]]
  [[ "$output" == *"the download timed out"* ]]
  [[ "$output" == *"curl exit 28"* ]]
  [ ! -f "$d/installer.calls" ]
}

# Regression test (the other half of the retry fix): a transfer that dropped
# part-way was fatal. The stub drops the first two attempts — the first after
# sending a fragment — and sends only the REMAINDER on the third, truncating
# instead of appending if -C - is absent. So this only reaches a valid xar
# archive if the retry loop runs AND curl resumes.
@test "macos_agent_install recovers when the download fails twice and then resumes" {
  local d="$BATS_TEST_TMPDIR/dlretry"
  tool_farm "$d" "$BATS_TEST_TMPDIR/dlretry-base"
  fake_tool "$d" curl 'out=""; prev=""; resume=0
    for a in "$@"; do
      [ "$prev" = "-o" ] && out="$a"
      [ "$a" = "-C" ] && resume=1
      prev="$a"
    done
    echo attempt >>"'"$d"'/curl.calls"
    n=$(wc -l <"'"$d"'/curl.calls")
    [ "$resume" -eq 1 ] || : >"$out"
    [ "$n" -eq 1 ] && { printf "xa" >>"$out"; exit 18; }
    [ "$n" -eq 2 ] && exit 56
    printf "r!fake flat package body\n" >>"$out"
    exit 0'
  pkgutil_signed_by "$d" "Zabbix SIA (A1B2C3D4E5)"
  rprobe "$d" 'macos_agent_install; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [ "$(wc -l <"$d/curl.calls")" -eq 3 ]
  # Attempt 1 wrote 2 bytes and died (18); 2 was reset (56); 3 appended the
  # rest. The install only succeeds if the final file is a valid xar — which
  # it is only because each attempt APPENDED to the partial file rather than
  # restarting it, so `[ "$status" -eq 0 ]` above is what pins `-C -`. This
  # assertion pins the per-attempt WARN that makes the retry visible in the log.
  [[ "$output" == *"attempt 1/3 failed (curl exit 18, 2 bytes so far)"* ]]
  [[ "$(cat "$d/installer.calls")" == *"-pkg"* ]]
}

# Regression test: `curl -f` is satisfied by an HTML error page, a captive-
# portal login and an empty 200 body alike. The old code handed all of them
# to pkgutil, whose "could not open package" went to 2>/dev/null, and told the
# user the package was "not signed by Zabbix" — sending them after a supply-
# chain bug when the real problem was their network. The xar! magic is now
# checked FIRST, and the byte count is in the message.
@test "macos_agent_install rejects a captive-portal HTML body before pkgutil is consulted" {
  local d="$BATS_TEST_TMPDIR/html"
  tool_farm "$d" "$BATS_TEST_TMPDIR/html-base"
  fake_tool "$d" curl 'out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    printf "<html><body>Sign in to the guest network</body></html>\n" >>"$out"
    exit 0'
  rprobe "$d" 'rc=0; macos_agent_install || rc=$?; echo "rc=$rc"'
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"not a macOS package"* ]]
  [[ "$output" == *"55 bytes, magic '<htm'"* ]]
  [[ "$output" != *"not signed by Zabbix"* ]]
  [ ! -f "$d/pkgutil.calls" ]
  [ ! -f "$d/installer.calls" ]
}

# Regression test: the happy path itself still installs — plus the half of it
# that used to be invisible. The old gate ran pkgutil under `2>/dev/null` and
# read it through `grep -q`, so the report was thrown away whichever way the
# check went: nothing in the log said what the package was actually signed
# with. It is captured and logged now.
@test "macos_agent_install installs a package whose signer is Zabbix" {
  local d="$BATS_TEST_TMPDIR/sigok"
  tool_farm "$d" "$BATS_TEST_TMPDIR/sigok-base"
  pkgutil_signed_by "$d" "Zabbix SIA (A1B2C3D4E5)"
  rprobe "$d" 'macos_agent_install; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$(cat "$d/pkgutil.calls")" == *"--check-signature"* ]]
  [[ "$(cat "$d/installer.calls")" == *"-pkg"* ]]
  # the signer that was accepted is on the record (rprobe's log, see above)
  [[ "$(cat "$BATS_TEST_TMPDIR/rprobe.log")" == *"pkgutil --check-signature: Package"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/rprobe.log")" == *"Developer ID Installer: Zabbix SIA"* ]]
}

# Regression test: the rejection stands, but it used to be the whole story —
# a flat "not signed by Zabbix" with pkgutil's own words discarded by
# 2>/dev/null. That is precisely what made the macOS 26 report undiagnosable,
# because a broken DOWNLOAD reached this same sentence. pkgutil's first line
# now rides along in the message.
@test "macos_agent_install refuses a package signed by anyone but Zabbix" {
  local d="$BATS_TEST_TMPDIR/signo"
  tool_farm "$d" "$BATS_TEST_TMPDIR/signo-base"
  pkgutil_signed_by "$d" "Evil Corp Ltd (ZZ9ZZ9ZZ9Z)"
  rprobe "$d" 'rc=0; macos_agent_install || rc=$?; echo "rc=$rc"'
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"not signed by Zabbix"* ]]
  [[ "$output" == *"(pkgutil: Package"* ]]
  [[ "$output" != *"not a macOS package"* ]]
  [ ! -f "$d/installer.calls" ]
}

# Regression test: the gate used to be
#   pkgutil --check-signature "$pkg" 2>/dev/null | grep -qi zabbix
# grep -q exits the instant it matches. With a report larger than the pipe
# buffer, pkgutil is then killed by SIGPIPE, the pipeline returns 141 under
# core.sh's pipefail, and a CORRECTLY SIGNED package is REJECTED. So the match
# here is early and ~240KB of chain detail follows it — the exact shape that
# tripped the old code. pkgutil's output is now captured into a variable, so
# the size of the report cannot change the verdict.
@test "macos_agent_install accepts a signed package whose pkgutil report dwarfs a pipe buffer" {
  local d="$BATS_TEST_TMPDIR/sigbig"
  tool_farm "$d" "$BATS_TEST_TMPDIR/sigbig-base"
  fake_tool "$d" pkgutil 'printf "Package \"%s\":\n" "$2"
    printf "   Status: signed by a developer certificate issued by Apple\n"
    printf "    1. Developer ID Installer: Zabbix SIA (A1B2C3D4E5)\n"
    i=0
    while [ "$i" -lt 2000 ]; do
      printf "       SHA256 fingerprint: %s\n" \
        "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
      i=$((i + 1))
    done
    exit 0'
  # Sanity: the report really is far past the 64KB a pipe will hold.
  [ "$("$d/pkgutil" --check-signature /x | wc -c)" -gt 200000 ]
  rprobe "$d" 'macos_agent_install; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" != *"not signed by Zabbix"* ]]
  [[ "$(cat "$d/installer.calls")" == *"-pkg"* ]]
}

# Regression test: the match ran over pkgutil's WHOLE output, and pkgutil
# echoes the package path on its first line. A temp file whose name happened
# to contain "zabbix" satisfied the signature check on its own, so an
# unsigned package downloaded to such a path sailed through the gate. The
# match now starts below the first line.
@test "macos_agent_install ignores 'zabbix' in the temp filename when checking the signer" {
  local d="$BATS_TEST_TMPDIR/signame"
  tool_farm "$d" "$BATS_TEST_TMPDIR/zabbix-agent-download"
  pkgutil_signed_by "$d" "Evil Corp Ltd (ZZ9ZZ9ZZ9Z)"
  rprobe "$d" 'rc=0; macos_agent_install || rc=$?; echo "rc=$rc"'
  # the path pkgutil echoed really does carry the bait
  [[ "$(cat "$d/pkgutil.calls")" == *"zabbix-agent-download.pkg"* ]]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"not signed by Zabbix"* ]]
  [ ! -f "$d/installer.calls" ]
}

# Regression test: all three steps returned a bare 1, so macos_agent_run's
# die() said the same sentence whether the CDN was unreachable, the body was
# a login page, or the signer was wrong. Each step now names itself.
@test "macos_agent_install's three failure modes log three different ERRORs" {
  local dl body sig
  local d1="$BATS_TEST_TMPDIR/m1" d2="$BATS_TEST_TMPDIR/m2" d3="$BATS_TEST_TMPDIR/m3"

  # 1. the download never completes
  tool_farm "$d1" "$BATS_TEST_TMPDIR/m1-base"
  fake_tool "$d1" curl 'exit 7'
  rprobe "$d1" 'macos_agent_install || true'
  dl="$output"

  # 2. it completes, but the body is not a package
  tool_farm "$d2" "$BATS_TEST_TMPDIR/m2-base"
  fake_tool "$d2" curl 'out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    printf "not a package\n" >>"$out"; exit 0'
  rprobe "$d2" 'macos_agent_install || true'
  body="$output"

  # 3. it is a package, signed by the wrong developer
  tool_farm "$d3" "$BATS_TEST_TMPDIR/m3-base"
  pkgutil_signed_by "$d3" "Evil Corp Ltd (ZZ9ZZ9ZZ9Z)"
  rprobe "$d3" 'macos_agent_install || true'
  sig="$output"

  [[ "$dl" == *"downloading the agent package failed"* ]]
  [[ "$dl" != *"not a macOS package"* ]]
  [[ "$dl" != *"not signed by Zabbix"* ]]

  [[ "$body" == *"not a macOS package"* ]]
  [[ "$body" != *"downloading the agent package failed"* ]]
  [[ "$body" != *"not signed by Zabbix"* ]]

  [[ "$sig" == *"not signed by Zabbix"* ]]
  [[ "$sig" != *"downloading the agent package failed"* ]]
  [[ "$sig" != *"not a macOS package"* ]]
}
