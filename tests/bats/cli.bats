#!/usr/bin/env bats
# End-to-end tests of the built artifact: --dry-run --express --yes must render
# a full, sane plan (Phase 2 acceptance, §18).
#
# Determinism: the host must not leak into the plan (a dev Mac has psql, CI
# runners have mysql). Each test runs the bundle with PATH pointing at a
# symlink farm of only the tools detect.sh legitimately needs, plus fixture
# overrides for os-release and meminfo. The interpreter is resolved before the
# PATH is trimmed.

setup() {
  DIST="${BATS_TEST_DIRNAME}/../../dist/zbx-install.sh"
  FIX="${BATS_TEST_DIRNAME}/../fixtures"
  BASH_BIN="$(command -v bash)"
  TOOLDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TOOLDIR"
  local t src
  for t in date awk sed grep df uname head tail tr cut cat sleep tput; do
    src="$(command -v "$t" 2>/dev/null || true)"
    if [[ -n "$src" ]]; then ln -sf "$src" "$TOOLDIR/$t"; fi
  done
}

# zx OSR MEM ARGS... — run the bundle in the trimmed environment.
zx() {
  local osr="$1" mem="$2"
  shift 2
  run env -i PATH="$TOOLDIR" HOME="$BATS_TEST_TMPDIR" \
    OS_RELEASE_FILE="$FIX/$osr" MEMINFO_FILE="$FIX/$mem" DETECT_SKIP_NET=1 \
    "$BASH_BIN" "$DIST" --no-color --log-file "$BATS_TEST_TMPDIR/zbx.log" "$@"
}

# zxn OSR MEM ARGS... — like zx but with the network probe live (no
# DETECT_SKIP_NET), so the guard_network branches are reachable.
zxn() {
  local osr="$1" mem="$2"
  shift 2
  run env -i PATH="$TOOLDIR" HOME="$BATS_TEST_TMPDIR" \
    OS_RELEASE_FILE="$FIX/$osr" MEMINFO_FILE="$FIX/$mem" \
    "$BASH_BIN" "$DIST" --no-color --log-file "$BATS_TEST_TMPDIR/zbx.log" "$@"
}

# fake TOOL BODY — drop an executable fake into the tool farm (replaces the
# real symlink if setup made one). Lets tests stub host probes: a fake
# systemctl fabricates existing Zabbix units, a fake uname forces an arch,
# a failing curl forces DETECT_NET_OK=no.
fake() {
  rm -f "$TOOLDIR/$1"
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$TOOLDIR/$1"
  chmod +x "$TOOLDIR/$1"
}

# row LABEL VALUE — assert one exact ui_row line (anchors both ends, so
# "Components: agent" cannot pass on "server,frontend,agent").
row() {
  grep -qxF "$(printf '  %-16s %s' "$1" "$2")" <<<"$output"
}

# step N ID DESC_PREFIX — assert pipeline-preview step N (exact number + id
# column, description prefix).
step() {
  grep -qF "$(printf '  %d. %-9s %s' "$1" "$2" "$3")" <<<"$output"
}

@test "express dry-run: ubuntu 24.04 / 4GiB -> full sane plan" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan summary (DRY-RUN)"* ]]
  [[ "$output" == *"7.0 (LTS)"* ]]
  [[ "$output" == *"Components:"*"server,frontend,agent"* ]]
  [[ "$output" == *"mariadb (new install)"* ]]
  [[ "$output" == *"Web server:"*"apache"* ]]
  [[ "$output" == *"Sizing preset:"*"medium"* ]]
  [[ "$output" == *"Timezone:"*"UTC"* ]]
  [[ "$output" == *"Update system:"*"no"* ]]
  [[ "$output" == *"zabbix-server-mysql zabbix-sql-scripts zabbix-frontend-php zabbix-apache-conf zabbix-agent2 mariadb-server apache2"* ]]
  [[ "$output" == *"auto-confirmed"* ]]
  # Pipeline preview: the full stack renders repo/packages/db/.../health in
  # order (no update step, no firewall step — none active in the trimmed env).
  step 1 repo "add the Zabbix 7.0 repository for ubuntu 24.04"
  step 2 packages "install: zabbix-server-mysql"
  step 3 db "provision mariadb, create zabbix DB/user, import schema"
  step 4 config "render server/agent/web configs"
  step 5 services "enable & start: DB -> zabbix-server -> web -> agent"
  step 6 health "run the 9 post-install checks"
  [[ "$output" == *"DRY-RUN: no commands were executed"* ]]
}

@test "express dry-run: rocky 9 uses httpd, not apache2" {
  zx os-release.rocky9 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"mariadb-server httpd"* ]]
  [[ "$output" != *"apache2"* ]]
}

@test "express dry-run: leap 15.6 / 16GiB -> large preset, apache2" {
  zx os-release.leap156 meminfo.16gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sizing preset:"*"large"* ]]
  [[ "$output" == *"mariadb-server apache2"* ]]
}

@test "express dry-run: 1GiB RAM -> agent-only suggestion with warning" {
  zx os-release.debian12 meminfo.1gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  row "Components:" "agent"
  [[ "$output" != *"zabbix-server-mysql"* ]]
  [[ "$output" == *"full stack not recommended"* ]]
}

@test "overrides: --db pgsql --web nginx --zabbix-version 7.4 --update" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes \
    --db pgsql --web nginx --zabbix-version 7.4 --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"7.4 (current stable)"* ]]
  [[ "$output" == *"pgsql (new install)"* ]]
  [[ "$output" == *"zabbix-server-pgsql"* ]]
  [[ "$output" == *"zabbix-nginx-conf"* ]]
  [[ "$output" == *"postgresql nginx"* ]]
  [[ "$output" == *"Update system:"*"yes"* ]]
  [[ "$output" == *"update"*"full system update"* ]]
}

@test "express dry-run: sles 15 SP5 -> supported, mariadb + apache2 plan" {
  zx os-release.sles15sp5 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan summary (DRY-RUN)"* ]]
  [[ "$output" == *"7.0 (LTS)"* ]]
  row "Target OS:" "SUSE Linux Enterprise Server 15 SP5"
  [[ "$output" == *"mariadb-server apache2"* ]]
  [[ "$output" == *"DRY-RUN: no commands were executed"* ]]
}

@test "agent-only dry-run: mode dispatch, Server IP row, agent-only packages" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --agent-only --yes
  [ "$status" -eq 0 ]
  row "Mode:" "agent-only"
  row "Components:" "agent"
  row "Server IP:" "127.0.0.1"
  row "Packages:" "zabbix-agent2"
  [[ "$output" != *"DB engine:"* ]]
  [[ "$output" != *"provision"* ]]
  [[ "$output" == *"DRY-RUN: no commands were executed"* ]]
}

@test "overrides: --components agent skips db step in the pipeline" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes --components agent
  [ "$status" -eq 0 ]
  [[ "$output" == *"Components:"*"agent"* ]]
  [[ "$output" != *"provision"* ]]
}

@test "detect-only still works and reports supported" {
  zx os-release.ubuntu2404 meminfo.4gb --detect-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"Supported:       yes"* ]]
  [[ "$output" == *"Zabbix offered:  7.0 7.4"* ]]
}

@test "unsupported OS in unattended mode exits 3" {
  zx os-release.ubuntu2004 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 3 ]
}

# Regression test for a confirmed Phase 2 bug: guard_tty's [[ -r/-w /dev/tty ]]
# fallback only checks permission bits on the special file — true even with NO
# controlling terminal at all — so a genuinely headless `--yes` (no --express/
# --config) silently fell through to the interactive mode menu, whose failed
# /dev/tty read then defaulted to option 1 (express) and "confirmed" via
# --yes, installing unattended without ever hitting the required exit 2 (§6.2).
# setsid actually detaches the controlling terminal, unlike closing stdin.
@test "headless bare --yes (no mode flag, no TTY) exits 2, never silently installs" {
  command -v setsid >/dev/null 2>&1 || skip "no setsid on this platform"
  local rcfile="$BATS_TEST_TMPDIR/rc"
  setsid bash -c '
    env -i PATH="'"$TOOLDIR"'" OS_RELEASE_FILE="'"$FIX"'/os-release.ubuntu2404" \
      MEMINFO_FILE="'"$FIX"'/meminfo.4gb" DETECT_SKIP_NET=1 \
      "'"$BASH_BIN"'" "'"$DIST"'" --yes --dry-run --no-color \
      --log-file "'"$BATS_TEST_TMPDIR"'/zbx-headless.log" \
      >"'"$BATS_TEST_TMPDIR"'/out" 2>&1 </dev/null
    echo $? >"'"$rcfile"'"
  ' </dev/null
  run cat "$rcfile"
  [ "$output" = "2" ]
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"No TTY available"* ]]
  [[ "$output" != *"Plan summary"* ]]
}

@test "usage errors exit 2" {
  zx os-release.ubuntu2404 meminfo.4gb --db oracle
  [ "$status" -eq 2 ]
  zx os-release.ubuntu2404 meminfo.4gb --zabbix-version 6.0
  [ "$status" -eq 2 ]
  zx os-release.ubuntu2404 meminfo.4gb --components server,db
  [ "$status" -eq 2 ]
  zx os-release.ubuntu2404 meminfo.4gb --express --detect-only
  [ "$status" -eq 2 ]
}

@test "value-taking flags with a missing value exit 2" {
  zx os-release.ubuntu2404 meminfo.4gb --db
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing value for --db"* ]]
  zx os-release.ubuntu2404 meminfo.4gb --zabbix-version
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing value for --zabbix-version"* ]]
  zx os-release.ubuntu2404 meminfo.4gb --config
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing value for --config"* ]]
  zx os-release.ubuntu2404 meminfo.4gb --creds-file
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing value for --creds-file"* ]]
}

@test "unknown option and stray positional argument exit 2" {
  zx os-release.ubuntu2404 meminfo.4gb --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --bogus"* ]]
  zx os-release.ubuntu2404 meminfo.4gb install
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unexpected argument: install"* ]]
}

@test "mode flags are mutually exclusive in every combination" {
  zx os-release.ubuntu2404 meminfo.4gb --agent-only --uninstall
  [ "$status" -eq 2 ]
  [[ "$output" == *"Modes are mutually exclusive"* ]]
  zx os-release.ubuntu2404 meminfo.4gb --config /tmp/a.conf --express
  [ "$status" -eq 2 ]
  zx os-release.ubuntu2404 meminfo.4gb --detect-only --agent-only
  [ "$status" -eq 2 ]
}

@test "credentials row reflects --generate-passwords and --creds-file" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes --generate-passwords
  [ "$status" -eq 0 ]
  row "Credentials:" "auto-generate; summary file: /root/zbx-install-credentials.txt"
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes --creds-file /tmp/creds.txt
  [ "$status" -eq 0 ]
  row "Credentials:" "prompt at install (Phase 4); summary file: /tmp/creds.txt"
}

@test "unattended existing-Zabbix guard exits 3 (fake systemctl reports units)" {
  fake systemctl 'if [ "${1:-}" = list-unit-files ]; then echo "zabbix-server.service enabled"; exit 0; fi; exit 3'
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"existing Zabbix detected"* ]]
}

@test "unattended unsupported arch (armv7l) exits 3" {
  fake uname 'echo armv7l'
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"unsupported architecture: armv7l"* ]]
}

@test "aarch64 (arch class maybe) continues with a repo-coverage warning" {
  fake uname 'echo aarch64'
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"arch aarch64: Zabbix repo coverage varies"* ]]
  [[ "$output" == *"DRY-RUN: no commands were executed"* ]]
}

@test "network guard: unattended without dry-run exits 4 when curl fails" {
  fake curl 'exit 1'
  zxn os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 4 ]
  [[ "$output" == *"cannot reach https://repo.zabbix.com/"* ]]
}

@test "network guard: dry-run continues with a warning when curl fails" {
  fake curl 'exit 1'
  zxn os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo.zabbix.com unreachable"* ]]
  [[ "$output" == *"Plan summary (DRY-RUN)"* ]]
}

@test "--config stub exits 2 with a Phase 7 pointer" {
  zx os-release.ubuntu2404 meminfo.4gb --config /tmp/answers.conf
  [ "$status" -eq 2 ]
  [[ "$output" == *"Phase 7"* ]]
}

@test "--uninstall stub exits 0 with a Phase 7 pointer" {
  zx os-release.ubuntu2404 meminfo.4gb --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Phase 7"* ]]
}
