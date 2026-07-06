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
  for t in date awk sed grep df uname head tail tr cut cat sleep tput wc mktemp chmod; do
    src="$(command -v "$t" 2>/dev/null || true)"
    if [[ -n "$src" ]]; then ln -sf "$src" "$TOOLDIR/$t"; fi
  done
  # config.sh's real-run tests need config.sh's hard-required paths
  # (zabbix_server.conf, web/, the agent conf, the proxy conf §15.9 stretch)
  # to exist somewhere writable — ZBX_ETC_DIR (config.sh) redirects them here
  # instead of the real /etc/zabbix.
  ETCDIR="$BATS_TEST_TMPDIR/etc-zabbix"
  mkdir -p "$ETCDIR/web"
  : >"$ETCDIR/zabbix_server.conf"
  : >"$ETCDIR/zabbix_agent2.conf"
  : >"$ETCDIR/zabbix_agentd.conf"
  : >"$ETCDIR/zabbix_proxy.conf"
}

# _pkgmgr_fake_for OSR — the package manager a real host with this fixture
# would have on PATH. A trimmed test harness has none of apt-get/dnf/zypper
# (unlike a real target), so repo.sh/pkg.sh's DETECT_PKGMGR dispatch needs a
# stub present to reach their (DRY_RUN no-op) success path at all.
_pkgmgr_fake_for() {
  case "$1" in
    *ubuntu* | *debian* | *mint*) echo apt-get ;;
    *rocky* | *alma* | *rhel* | *centos* | *fedora*) echo dnf ;;
    *sles* | *leap*) echo zypper ;;
    *) echo "" ;;
  esac
}

# zx OSR MEM ARGS... — run the bundle in the trimmed environment.
#
# STATE_FILE points at a per-test tmpdir path, never the real
# /var/lib/zbx-install/state: every test used to rely on that real path
# being unwritable by a non-root test runner (a silent, accidental "state
# never persists" — core_state_init's mkdir/touch failures are swallowed by
# design, §14) which would have broken the moment tests ran as root. Each
# test gets a fresh, empty, but real and write able state file instead,
# matching the ZBX_ETC_DIR override pattern already used for config.sh.
zx() {
  local osr="$1" mem="$2" pm
  shift 2
  pm="$(_pkgmgr_fake_for "$osr")"
  # Only auto-fake if the test didn't already drop its own fake for this
  # binary (e.g. a recording fake) — never clobber a test's own setup.
  [[ -n "$pm" && ! -e "$TOOLDIR/$pm" ]] && fake "$pm" 'exit 0'
  run env -i PATH="$TOOLDIR" HOME="$BATS_TEST_TMPDIR" \
    OS_RELEASE_FILE="$FIX/$osr" MEMINFO_FILE="$FIX/$mem" DETECT_SKIP_NET=1 \
    ZBX_ETC_DIR="$ETCDIR" STATE_FILE="${STATEFILE:-$BATS_TEST_TMPDIR/state}" \
    "$BASH_BIN" "$DIST" --no-color --log-file "$BATS_TEST_TMPDIR/zbx.log" "$@"
}

# zxn OSR MEM ARGS... — like zx but with the network probe live (no
# DETECT_SKIP_NET), so the guard_network branches are reachable.
zxn() {
  local osr="$1" mem="$2" pm
  shift 2
  pm="$(_pkgmgr_fake_for "$osr")"
  # Only auto-fake if the test didn't already drop its own fake for this
  # binary (e.g. a recording fake) — never clobber a test's own setup.
  [[ -n "$pm" && ! -e "$TOOLDIR/$pm" ]] && fake "$pm" 'exit 0'
  run env -i PATH="$TOOLDIR" HOME="$BATS_TEST_TMPDIR" \
    OS_RELEASE_FILE="$FIX/$osr" MEMINFO_FILE="$FIX/$mem" \
    ZBX_ETC_DIR="$ETCDIR" STATE_FILE="${STATEFILE:-$BATS_TEST_TMPDIR/state}" \
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

# Regression coverage for the plan_report "Admin login:" row (recommend.sh) —
# exercises the real resolve_plan -> creds_collect_admin_pass -> plan_report
# path end to end (not a hand-copied condition), catching e.g. a typo in the
# row text or the condition checking the wrong variable.
@test "--admin-pass shows the Admin-login-will-change row in the plan summary; absent by default" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes --admin-pass
  [ "$status" -eq 0 ]
  row "Admin login:" "will be changed after install (§15 gotcha 8)"
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"Admin login:"* ]]
}

@test "--admin-pass shows no Admin-login row for an agent-only plan (no frontend to log into)" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --agent-only --yes --admin-pass
  [ "$status" -eq 0 ]
  [[ "$output" != *"Admin login:"* ]]
}

# --- real (non-dry-run) repo+package execution, verified via recording fakes ---
# These exercise the ACTUAL command construction (not just dry-run text) by
# faking curl/dpkg/apt-get/apt-cache to record their argv and succeed, so the
# real repo_install/pkg_install code paths run for real without touching the
# network or a real package manager.
# FAKE_SYSTEMCTL_IS_ACTIVE — shared "is-active" whitelist body: only the
# units services_start actually polls report active. Checking every
# remaining arg (not a fixed position) matters because callers differ —
# detect_firewall() calls "is-active --quiet firewalld" (unit is $3),
# _services_wait_active calls "is-active UNIT" (unit is $2). Anything else
# (notably "firewalld" itself) correctly reports inactive, so
# detect_firewall() doesn't get a false "firewalld is running" positive.
read -r -d '' FAKE_SYSTEMCTL_IS_ACTIVE <<'EOF' || true
    is-active)
      shift
      for a in "$@"; do
        case "$a" in
          mariadb | postgresql | zabbix-server | apache2 | nginx | zabbix-agent2 | zabbix-agent | php*-fpm | php-fpm)
            echo active
            exit 0
            ;;
        esac
      done
      exit 3
      ;;
EOF

# fake_db_mysql_success — a real (non-dry-run) express run now continues past
# packages into db_mysql_provision and (Phase 5) services_start; fake
# systemctl for unit detection+enable, and "is-active" so
# _services_wait_active returns immediately instead of polling the real 15s.
# mysql itself is deliberately NOT faked into existence up front — see
# MYSQL_APPEARS_ON_INSTALL below.
fake_db_mysql_success() {
  fake systemctl "case \"\$1\" in
    list-unit-files) echo \"mariadb.service enabled\" ;;
$FAKE_SYSTEMCTL_IS_ACTIVE
    esac
    exit 0"
}

# mysql_appears_on_install — echoes a snippet for a test's own apt-get fake
# body: drops a working mysql client into the tool farm as a side effect of
# apt-get being invoked. Faking mysql as present from the start would
# corrupt detect_existing()'s pre-install scan into finding an "existing"
# engine and suppressing mariadb-server from the plan — on a real target the
# client genuinely doesn't exist until the package installs it, i.e. strictly
# after detect ran and before db_mysql_provision needs it. A function (not a
# plain variable) because $TOOLDIR is only set inside setup(), per test.
# Echoes "1" (not just exit 0) so health.sh's schema-present COUNT(*) query
# (Phase 6) reads back a row count >= 1, not an empty string.
mysql_appears_on_install() {
  printf 'printf "#!/bin/bash\\necho 1\\nexit 0\\n" > "%s/mysql"; chmod +x "%s/mysql"; ' "$TOOLDIR" "$TOOLDIR"
}

# fake_ss_ports — health.sh's port checks (§13) just need ss to print more
# than its own header line; the exact port isn't asserted by these tests.
fake_ss_ports() {
  fake ss 'printf "Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0  128   0.0.0.0:0        0.0.0.0:*\n"'
}

# FAKE_CURL_FRONTEND_200 — snippet answering health.sh's frontend HTTP check
# (§13) with "200" on 127.0.0.1/zabbix; spliced into each test's own curl
# fake body ahead of its existing behavior (logging, recording, etc.), which
# still runs for every other invocation.
read -r -d '' FAKE_CURL_FRONTEND_200 <<'EOF' || true
    case "$*" in *127.0.0.1/zabbix*) printf 200; exit 0 ;; esac
EOF

@test "real run: the resolved Zabbix repo URL is actually fetched" {
  fake curl "$FAKE_CURL_FRONTEND_200"'
    echo "$*" >>"'"$BATS_TEST_TMPDIR"'/curl.log"; exit 0'
  fake dpkg 'exit 0'
  fake apt-get "$(mysql_appears_on_install)exit 0"
  fake apt-cache 'exit 0'
  fake_db_mysql_success
  fake_ss_ports
  zx os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/curl.log"
  [[ "$output" == *"https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb"* ]]
}

@test "real run: apt-get install receives the exact planned package list" {
  fake curl "$FAKE_CURL_FRONTEND_200"'
    exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get "$(mysql_appears_on_install)"'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/aptget.log"; exit 0'
  fake_db_mysql_success
  fake_ss_ports
  zx os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 0 ]
  run grep '^install -y' "$BATS_TEST_TMPDIR/aptget.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zabbix-server-mysql"* ]]
  [[ "$output" == *"zabbix-sql-scripts"* ]]
  [[ "$output" == *"zabbix-frontend-php"* ]]
  [[ "$output" == *"zabbix-apache-conf"* ]]
  [[ "$output" == *"zabbix-agent2"* ]]
  [[ "$output" == *"mariadb-server"* ]]
  [[ "$output" == *"apache2"* ]]
}

@test "real run: a failing package transaction reaches the packages error menu and exits 5 unattended" {
  fake curl 'exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  # apt-get update (repo_install) must still succeed; only install (pkg_install) fails.
  fake apt-get 'case "$1" in install) exit 1 ;; *) exit 0 ;; esac'
  zx os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 5 ]
  [[ "$output" == *"package transaction failed"* ]]
}

# Regression/acceptance test for Phase 6 (§13/§14): health is a distinct
# error-menu context from repo/packages (exit 6, not 5) and, unlike those
# two, never blocks earlier real work from completing — agent-only here
# genuinely installs and starts the agent for real, then fails specifically
# because the agent never reports active.
@test "real run: a failing health check exits 6 unattended (agent-only)" {
  fake curl 'exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get 'exit 0'
  fake systemctl 'exit 3'
  fake ss 'printf "header only, no listener\n"'
  zx os-release.ubuntu2404 meminfo.4gb --agent-only --yes
  [ "$status" -eq 6 ]
  [[ "$output" == *"checks failed"* ]]
  [[ "$output" == *"journalctl -u zabbix-agent2"* ]]
}

# Acceptance test for the optional post-Phase-8 --admin-pass feature (§15.8):
# a full unattended express install that also logs into the frontend API and
# changes the Admin password, end to end through the real bundled artifact.
#
# Deliberately NOT reusing FAKE_CURL_FRONTEND_200 here: its *127.0.0.1/zabbix*
# match is broad enough to also match .../zabbix/api_jsonrpc.php (same URL
# prefix), which would intercept every admin-pass API call before this test's
# own JSON-RPC handling ever ran. The three JSON-RPC calls admin_pass_update
# makes are checked FIRST instead, the same way adminpass.bats's own fake
# does: user.login/user.logout show up directly in argv (curl -d '...'),
# user.update's body only ever reaches stdin (-d @-, §10: the new password is
# a secret, never argv) — only once none of those three match does the
# frontend HTTP check's plain http://127.0.0.1/zabbix/ get a look-in.
@test "real run: --admin-pass changes the frontend Admin password; the new password reaches stdin only, never argv or the log" {
  fake curl '
    call=""
    for a in "$@"; do
      case "$a" in *user.login*) call=login ;; *user.logout*) call=logout ;; esac
    done
    if [[ -z "$call" ]]; then
      case "$*" in *api_jsonrpc.php*) call=update ;; esac
    fi
    case "$call" in
      login) printf "{\"jsonrpc\":\"2.0\",\"result\":\"tok123\"}"; exit 0 ;;
      update) cat >>"'"$BATS_TEST_TMPDIR"'/adminapi-stdin.log"; printf "{\"jsonrpc\":\"2.0\",\"result\":{\"userids\":[\"1\"]}}"; exit 0 ;;
      logout) printf "{\"jsonrpc\":\"2.0\",\"result\":true}"; exit 0 ;;
    esac
    case "$*" in *http://127.0.0.1/zabbix/*) printf 200; exit 0 ;; esac
    echo "ARGV:$*" >>"'"$BATS_TEST_TMPDIR"'/curl-argv.log"
    exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get "$(mysql_appears_on_install)exit 0"
  fake_db_mysql_success
  fake_ss_ports
  # A deterministic, greppable "generated" password for BOTH the DB and the
  # admin password (both go through ui_gen_password/openssl) — one marker
  # covers checking that neither ever leaked, matching the pgsql test above.
  fake openssl 'printf "E2EADMINMARKERZZ"'
  zx os-release.ubuntu2404 meminfo.4gb --express --yes --admin-pass --generate-passwords
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  [[ "$output" == *"Admin login:"* ]]
  [[ "$output" == *"changed"* ]]
  run cat "$BATS_TEST_TMPDIR/adminapi-stdin.log"
  [[ "$output" == *"E2EADMINMARKERZZ"* ]]
  [[ "$output" == *"current_passwd"* ]]
  run cat "$BATS_TEST_TMPDIR/curl-argv.log"
  [[ "$output" != *"E2EADMINMARKERZZ"* ]]
  run cat "$BATS_TEST_TMPDIR/zbx.log"
  [[ "$output" != *"E2EADMINMARKERZZ"* ]]
}

@test "real run: --db pgsql provisions via sudo -u postgres; the generated password reaches stdin only, never argv or the log" {
  fake curl "$FAKE_CURL_FRONTEND_200"'
    exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get 'exit 0'
  # "is-active" -> active (for the right units) so services_start's poll
  # returns immediately instead of spending the real 15s per unit (Phase 5).
  fake systemctl "case \"\$1\" in
$FAKE_SYSTEMCTL_IS_ACTIVE
    esac
    exit 0"
  fake_ss_ports
  # A deterministic, greppable "generated" password (§10 §18 Phase 4
  # acceptance: secrets never in ps/logs — grep the log in the test).
  fake openssl 'printf "E2EMARKERPASSWORDXXXXXXXXXX"'
  # Echoes "1" to stdout (Phase 6): _db_pgsql_schema_present now requires a
  # genuine row count >= 1, not just a successful query, so the fake needs a
  # numeric answer for its "already present" resume-guard and health.sh's
  # own DB checks to see a pass here — same reasoning as mysql's "echo 1".
  fake sudo 'echo "ARGV:$*" >>"'"$BATS_TEST_TMPDIR"'/sudo.log"; cat >>"'"$BATS_TEST_TMPDIR"'/sudo-stdin.log"; echo 1; exit 0'
  zx os-release.ubuntu2404 meminfo.4gb --express --yes --db pgsql --generate-passwords
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  run cat "$BATS_TEST_TMPDIR/sudo-stdin.log"
  [[ "$output" == *"ALTER USER zabbix PASSWORD 'E2EMARKERPASSWORD"* ]]
  run cat "$BATS_TEST_TMPDIR/sudo.log"
  [[ "$output" != *"E2EMARKERPASSWORD"* ]]
  run cat "$BATS_TEST_TMPDIR/zbx.log"
  [[ "$output" != *"E2EMARKERPASSWORD"* ]]
}

@test "real run: a repo probe failure exits 5 unattended with a repo-context message" {
  fake curl 'exit 1'
  zx os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 5 ]
  [[ "$output" == *"step 'repo' failed"* ]]
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
  zx os-release.ubuntu2404 meminfo.4gb --proxy-only --agent-only
  [ "$status" -eq 2 ]
  [[ "$output" == *"Modes are mutually exclusive"* ]]
}

@test "--db rejects a value that is not mysql/pgsql/sqlite3" {
  zx os-release.ubuntu2404 meminfo.4gb --db bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"--db must be mysql, pgsql, or sqlite3"* ]]
}

# Proxy exclusivity (§15.9): proxy is its own mode, never mixed into a
# server/frontend plan — a mixed --components list collides destructively.
@test "--components rejects proxy mixed with other components" {
  zx os-release.ubuntu2404 meminfo.4gb --express --yes --dry-run --components server,proxy
  [ "$status" -eq 2 ]
  [[ "$output" == *"--components must be"* ]]
}

# sqlite3 is a proxy-only backend (§7, §15.9): a server plan with --db sqlite3
# would hard-fail deep in DB provisioning, so it is rejected up front.
@test "--db sqlite3 for a (default) server plan is rejected as proxy-only" {
  zx os-release.ubuntu2404 meminfo.4gb --express --yes --dry-run --db sqlite3
  [ "$status" -eq 2 ]
  [[ "$output" == *"only valid for a proxy install"* ]]
}

# --yes always implies UNATTENDED=1 (§14), so creds_collect always
# auto-generates here regardless of --generate-passwords — there is no way
# to interactively prompt in an unattended run. --creds-file only changes
# the summary file path.
@test "credentials row reflects auto-generation under --yes, and --creds-file" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes --generate-passwords
  [ "$status" -eq 0 ]
  row "Credentials:" "auto-generated; summary file: /root/zbx-install-credentials.txt"
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --express --yes --creds-file /tmp/creds.txt
  [ "$status" -eq 0 ]
  row "Credentials:" "auto-generated; summary file: /tmp/creds.txt"
}

@test "credentials row: agent-only mode needs no database credentials" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --agent-only --yes
  [ "$status" -eq 0 ]
  row "Credentials:" "not needed (no database in this plan); summary file: /root/zbx-install-credentials.txt"
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

# --- §18 Phase 7: --config, --uninstall, resume -------------------------------

@test "real run: --config drives a full unattended install with zero prompts" {
  fake curl "$FAKE_CURL_FRONTEND_200"'
    exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get "$(mysql_appears_on_install)"'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/aptget.log"; exit 0'
  fake_db_mysql_success
  fake_ss_ports
  cat >"$BATS_TEST_TMPDIR/answers.conf" <<'EOF'
MODE=express
DB_ENGINE=mariadb
WEB_SERVER=apache
GENERATE_PASSWORDS=yes
EOF
  chmod 600 "$BATS_TEST_TMPDIR/answers.conf"
  # No --yes: --config alone is unattended by definition (§7) — this is the
  # acceptance test itself (§18: "config-file install with zero prompts").
  zx os-release.ubuntu2404 meminfo.4gb --config "$BATS_TEST_TMPDIR/answers.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  run grep '^install -y' "$BATS_TEST_TMPDIR/aptget.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zabbix-server-mysql"* ]]
  [[ "$output" == *"zabbix-apache-conf"* ]]
}

@test "--config with an unknown key exits 2 naming the file, line, and key" {
  cat >"$BATS_TEST_TMPDIR/bad.conf" <<'EOF'
MODE=express
BOGUS=yes
EOF
  chmod 600 "$BATS_TEST_TMPDIR/bad.conf"
  zx os-release.ubuntu2404 meminfo.4gb --config "$BATS_TEST_TMPDIR/bad.conf"
  [ "$status" -eq 2 ]
  [[ "$output" == *":2: unknown key 'BOGUS'"* ]]
}

@test "--config MODE=agent-only wires ZBX_SERVER_IP/AGENT_TYPE from the file" {
  cat >"$BATS_TEST_TMPDIR/agent.conf" <<'EOF'
MODE=agent-only
ZBX_SERVER_IP=10.0.0.9
AGENT_TYPE=agent
EOF
  chmod 600 "$BATS_TEST_TMPDIR/agent.conf"
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --config "$BATS_TEST_TMPDIR/agent.conf"
  [ "$status" -eq 0 ]
  row "Mode:" "agent-only"
  row "Server IP:" "10.0.0.9"
  row "Packages:" "zabbix-agent"
}

@test "real run: --uninstall discovers and removes only zabbix-* packages, keeps DB engine and web server" {
  fake dpkg-query 'case "$*" in *zabbix*) printf "zabbix-agent2\nzabbix-server-mysql\n" ;; esac'
  fake apt-get 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/aptget-remove.log"; exit 0'
  zx os-release.ubuntu2404 meminfo.4gb --uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing: zabbix-agent2 zabbix-server-mysql"* ]]
  [[ "$output" == *"Kept: database engine, web server"* ]]
  [[ "$output" == *"Kept: zabbix database/user"* ]]
  run cat "$BATS_TEST_TMPDIR/aptget-remove.log"
  [[ "$output" == *"remove -y zabbix-agent2 zabbix-server-mysql"* ]]
  [[ "$output" != *"mariadb"* ]]
  [[ "$output" != *"apache"* ]]
}

@test "real run: --uninstall with nothing installed reports nothing to remove" {
  fake dpkg-query 'exit 1' # real dpkg-query exits nonzero on no match
  zx os-release.ubuntu2404 meminfo.4gb --uninstall --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Zabbix packages found — nothing to remove."* ]]
}

# --- proxy (§15.9 stretch) ---------------------------------------------------------

@test "proxy-only dry-run (sqlite3): mode dispatch, packages, proxy hostname row, registration warning" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --proxy-only --yes --db sqlite3 --proxy-hostname branch-1
  [ "$status" -eq 0 ]
  row "Mode:" "proxy-only"
  row "Components:" "proxy"
  row "Proxy hostname:" "branch-1"
  row "Packages:" "zabbix-proxy-sqlite3"
  [[ "$output" == *"sqlite3 (embedded, created automatically)"* ]]
  [[ "$output" == *"registered as a matching Proxy object"* ]]
  row "Credentials:" "not needed (no database in this plan); summary file: /root/zbx-install-credentials.txt"
  [[ "$output" == *"DRY-RUN: no commands were executed"* ]]
}

@test "proxy-only dry-run (mysql): db step appears in the pipeline preview targeting zabbix_proxy" {
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --proxy-only --yes --db mysql
  [ "$status" -eq 0 ]
  row "Mode:" "proxy-only"
  [[ "$output" == *"mariadb (new install)"* ]]
  [[ "$output" == *"zabbix-proxy-mysql zabbix-sql-scripts mariadb-server"* ]]
  step 3 db "provision mariadb, create zabbix_proxy DB/user, import schema"
  row "Credentials:" "auto-generated; summary file: /root/zbx-install-credentials.txt"
}

@test "--config MODE=proxy-only wires PROXY_HOSTNAME/DB_ENGINE/ZBX_SERVER_IP from the file" {
  cat >"$BATS_TEST_TMPDIR/proxy.conf" <<'EOF'
MODE=proxy-only
DB_ENGINE=sqlite3
ZBX_SERVER_IP=10.0.0.9
PROXY_HOSTNAME=branch-office-1
EOF
  chmod 600 "$BATS_TEST_TMPDIR/proxy.conf"
  zx os-release.ubuntu2404 meminfo.4gb --dry-run --config "$BATS_TEST_TMPDIR/proxy.conf"
  [ "$status" -eq 0 ]
  row "Mode:" "proxy-only"
  row "Server IP:" "10.0.0.9"
  row "Proxy hostname:" "branch-office-1"
  row "Packages:" "zabbix-proxy-sqlite3"
}

@test "real run: --proxy-only (sqlite3) installs and passes health checks, no DB unit involved" {
  fake curl 'exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get 'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/aptget.log"; exit 0'
  fake mkdir 'exit 0'
  fake chown 'exit 0'
  fake systemctl 'case "$1" in
    is-active) case "$*" in *zabbix-proxy*) echo active; exit 0 ;; esac; exit 3 ;;
    *) exit 0 ;;
  esac'
  fake_ss_ports
  zx os-release.ubuntu2404 meminfo.4gb --proxy-only --yes --db sqlite3
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  run grep '^install -y' "$BATS_TEST_TMPDIR/aptget.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zabbix-proxy-sqlite3"* ]]
  [[ "$output" != *"mariadb-server"* ]]
}

@test "real run: --proxy-only (mysql) provisions zabbix_proxy and passes health checks" {
  fake curl 'exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  fake apt-get "$(mysql_appears_on_install)"'echo "$*" >>"'"$BATS_TEST_TMPDIR"'/aptget.log"; exit 0'
  fake mkdir 'exit 0'
  fake chown 'exit 0'
  fake systemctl 'case "$1" in
    list-unit-files) echo "mariadb.service enabled"; exit 0 ;;
    is-active) case "$*" in *mariadb*|*zabbix-proxy*) echo active; exit 0 ;; esac; exit 3 ;;
    *) exit 0 ;;
  esac'
  fake_ss_ports
  zx os-release.ubuntu2404 meminfo.4gb --proxy-only --yes --db mysql --generate-passwords
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  run grep '^install -y' "$BATS_TEST_TMPDIR/aptget.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zabbix-proxy-mysql"* ]]
  [[ "$output" == *"zabbix-sql-scripts"* ]]
  [[ "$output" == *"mariadb-server"* ]]
}

@test "resume: unattended run picks up after a prior partial failure without needing --resume" {
  local statefile="$BATS_TEST_TMPDIR/shared-state"
  fake curl 'exit 0'
  fake dpkg 'exit 0'
  fake apt-cache 'exit 0'
  # First run: repo succeeds, packages fails — repo=done persists, install stops.
  fake apt-get 'case "$1" in install) exit 1 ;; *) exit 0 ;; esac'
  STATEFILE="$statefile" zx os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 5 ]
  run cat "$statefile"
  [[ "$output" == *"repo=done"* ]]

  # Second run: packages now succeeds. Unattended (--yes, no --resume flag)
  # must still resume on its own — repo_install's own "already done" guard
  # (an INFO line, log-file only, not stdout) is the observable proof
  # repo_install itself was skipped, not re-run.
  fake curl "$FAKE_CURL_FRONTEND_200"'
    exit 0'
  fake apt-get "$(mysql_appears_on_install)exit 0"
  fake_db_mysql_success
  fake_ss_ports
  STATEFILE="$statefile" zx os-release.ubuntu2404 meminfo.4gb --express --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  run cat "$BATS_TEST_TMPDIR/zbx.log"
  [[ "$output" == *"repo already set up (state file) — skipping"* ]]
}
