#!/usr/bin/env bats
# Unit tests for detect.sh OS parsing, family mapping, support matrix (§4, §8)
# and the host probes (RAM/CPU, disk, listening ports, macOS orchestration).
#
# The pure OS functions read only OS_RELEASE_FILE, so every support-matrix entry
# is exercised here via fixtures — no container needed. The host probes shell
# out to sysctl/df/ss/lsof/pkgutil, so those run against a sealed PATH holding
# only stubs (a plain PATH prepend cannot hide a real `ss` on a Linux CI box,
# which would make the lsof fallback unreachable). core.sh is sourced alongside
# detect.sh inside `bash -c` subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DETECT="${BATS_TEST_DIRNAME}/../../src/lib/detect.sh"
FIX="${BATS_TEST_DIRNAME}/../fixtures"

# probe FIXTURE — sets $output to "ID MAJOR FAMILY SUPPORTED".
# ZBX_UNAME_S=Linux keeps detect_os on the os-release path even when the suite
# runs on a Mac (where `uname -s` is Darwin).
probe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    ZBX_UNAME_S=Linux OS_RELEASE_FILE="'"$FIX"'/'"$1"'";
    detect_os; detect_family; detect_supported;
    printf "%s %s %s %s\n" "$DETECT_OS_ID" "$DETECT_OS_MAJOR" "$DETECT_FAMILY" "$DETECT_SUPPORTED"'
}

# --- PATH sandbox for the host probes ----------------------------------------
# Every host probe in detect.sh gates on `command -v`, so these tests need a
# PATH they own completely: a Linux CI box really does have ss, and the macOS
# case ("no ss — use lsof") cannot be reached by merely prepending a directory
# of fakes. $BIN is therefore the ONLY entry on PATH inside dprobe: fakes get in
# via stub(), the handful of genuine utilities the probes shell out to via
# real(). Nothing else is reachable, so the host cannot colour the result.
setup() {
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
}

# stub NAME BODY — write an executable fake NAME into $BIN.
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

# real TOOL... — expose the host's own TOOL inside the sealed $BIN.
real() {
  local t
  for t in "$@"; do ln -sf "$(command -v "$t")" "$BIN/$t"; done
}

# dprobe SCRIPT — same `bash -c` subshell pattern as probe() above (core.sh
# defines run(), which must never reach the bats shell), with PATH pinned to
# $BIN. detect_run makes most DETECT_* readonly, so each probe needs its own
# subshell anyway — never two in one.
dprobe() {
  run bash -c 'export PATH="'"$BIN"'"; source "'"$CORE"'"; source "'"$DETECT"'"; '"$1"
}

# hwprobe OS_ID — detect_hw for that DETECT_OS_ID, with the Linux seam pinned to
# the 4 GiB fixture plus a stubbed 2-core nproc. Those are deliberately readable
# and deliberately DIFFERENT from what the sysctl stubs report, so a Darwin
# branch that failed to take precedence shows up as the old Linux-only answer
# ("4096 2") instead of silently matching whatever the real host has.
hwprobe() {
  stub nproc 'echo 2'
  real awk
  dprobe 'DETECT_OS_ID='"$1"' MEMINFO_FILE="'"$FIX"'/meminfo.4gb"; detect_hw;
    printf "%s %s\n" "$DETECT_RAM_MB" "$DETECT_CPU"'
}

# --- support matrix: the 7 smoke images + SLES (all supported) ---------------
@test "ubuntu 22.04 -> supported debian" {
  probe os-release.ubuntu2204
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu 22 debian yes" ]
}

@test "ubuntu 24.04 -> supported debian" {
  probe os-release.ubuntu2404
  [ "$output" = "ubuntu 24 debian yes" ]
}

@test "debian 12 -> supported debian" {
  probe os-release.debian12
  [ "$output" = "debian 12 debian yes" ]
}

@test "debian 13 -> supported debian" {
  probe os-release.debian13
  [ "$output" = "debian 13 debian yes" ]
}

@test "rocky 9 -> supported rhel" {
  probe os-release.rocky9
  [ "$output" = "rocky 9 rhel yes" ]
}

@test "almalinux 8 -> supported rhel" {
  probe os-release.almalinux8
  [ "$output" = "almalinux 8 rhel yes" ]
}

@test "amazon linux 2023 -> supported rhel" {
  probe os-release.amzn2023
  [ "$output" = "amzn 2023 rhel yes" ]
}

@test "macOS (Darwin) -> macos family, supported (agent-only, no os-release)" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    ZBX_UNAME_S=Darwin; detect_os; detect_family; detect_supported;
    printf "%s %s %s\n" "$DETECT_OS_ID" "$DETECT_FAMILY" "$DETECT_SUPPORTED"'
  [ "$status" -eq 0 ]
  [ "$output" = "macos macos yes" ]
}

@test "detect_arch on macOS: arm64 is supported, Intel x86_64 is not (no upstream amd64 artifacts)" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    DETECT_OS_ID=macos ZBX_UNAME_M=arm64;  detect_arch; a="$DETECT_ARCH_OK";
    DETECT_OS_ID=macos ZBX_UNAME_M=x86_64; detect_arch; b="$DETECT_ARCH_OK";
    echo "$a $b"'
  [ "$output" = "yes no" ]
}

@test "opensuse leap 15.6 -> supported suse" {
  probe os-release.leap156
  [ "$output" = "opensuse-leap 15 suse yes" ]
}

@test "sles 15 SP5 -> supported suse" {
  probe os-release.sles15sp5
  [ "$output" = "sles 15 suse yes" ]
}

# --- unsupported / edge cases ------------------------------------------------
@test "ubuntu 20.04 -> debian family but unsupported version" {
  probe os-release.ubuntu2004
  [ "$output" = "ubuntu 20 debian no" ]
}

@test "fedora 40 -> rhel family but unsupported version" {
  probe os-release.fedora40
  [ "$output" = "fedora 40 rhel no" ]
}

@test "arch -> unknown family, unsupported" {
  probe os-release.arch
  # VERSION_ID absent => empty major; assert family + support only.
  [[ "$output" == "arch "*" unknown no" ]]
}

@test "linuxmint -> family via ID_LIKE fallback (debian), unsupported" {
  probe os-release.mint
  [ "$output" = "linuxmint 21 debian no" ]
}

# --- pure helpers ------------------------------------------------------------
@test "_arch_class classifies architectures" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    for a in x86_64 amd64 aarch64 arm64 armv7l; do _arch_class "$a"; done | paste -sd" " -'
  [ "$output" = "yes yes maybe maybe no" ]
}

@test "_arch_confirmed_for_os: only Amazon Linux 2023 promotes arm" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    chk() { DETECT_OS_ID="$1" DETECT_OS_MAJOR="$2"; if _arch_confirmed_for_os; then echo -n y; else echo -n n; fi; }
    chk amzn 2023; chk amzn 2; chk debian 12; chk rocky 9; echo'
  [ "$output" = "ynnn" ]
}

@test "_osr_get strips quotes and preserves inner spaces" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    _osr_get PRETTY_NAME "'"$FIX"'/os-release.debian12"'
  [ "$output" = "Debian GNU/Linux 12 (bookworm)" ]
}

@test "detect_hw honors the MEMINFO_FILE fixture override" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    MEMINFO_FILE="'"$FIX"'/meminfo.4gb"; detect_hw; printf "%s" "$DETECT_RAM_MB"'
  [ "$status" -eq 0 ]
  [ "$output" = "4096" ]
}

@test "missing os-release file -> unknown, non-fatal" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    ZBX_UNAME_S=Linux OS_RELEASE_FILE="/nonexistent/os-release"; detect_os || true;
    detect_family; printf "%s %s\n" "$DETECT_OS_ID" "$DETECT_FAMILY"'
  [ "$status" -eq 0 ]
  [ "$output" = "unknown unknown" ]
}

# --- host probes: hardware on Darwin (the macOS 26 report) -------------------
# Regression test: detect_hw had only the /proc/meminfo + nproc path, so on a
# Mac (no /proc, no nproc) it left DETECT_RAM_MB/DETECT_CPU at their initialized
# 0 and the report printed "RAM / CPU: 0 MB / 0 vCPU" as if it were a reading.
# The Linux half of this test pins the other direction: the new Darwin branch
# returns early, so the /proc path has to keep working for everyone else.
@test "detect_hw: Darwin branch reads sysctl (memsize is BYTES), Linux branch unchanged" {
  stub sysctl 'case "$2" in
  hw.memsize) echo 17179869184 ;;
  hw.logicalcpu) echo 10 ;;
  *) exit 1 ;;
esac'
  hwprobe macos
  [ "$status" -eq 0 ]
  [ "$output" = "16384 10" ] # 16 GiB in bytes -> MB, not the 4096/2 fixture

  hwprobe ubuntu
  [ "$status" -eq 0 ]
  [ "$output" = "4096 2" ]
}

# Regression test: hw.logicalcpu is the count Zabbix sizing cares about, but it
# is not guaranteed to exist — the branch has to fall through to hw.ncpu rather
# than give up and leave the old 0.
@test "detect_hw on macOS falls back to hw.ncpu when hw.logicalcpu is unavailable" {
  stub sysctl 'case "$2" in
  hw.memsize) echo 8589934592 ;;
  hw.ncpu) echo 4 ;;
  *) exit 1 ;;
esac'
  hwprobe macos
  [ "$status" -eq 0 ]
  [ "$output" = "8192 4" ]
}

# Regression test (the other failure mode of the same fix): a sysctl that is
# missing, or that answers with an error string on stdout, must leave the
# counters at 0 — assigning the text would make $(( )) choke and would print
# garbage in the RAM/CPU row.
@test "detect_hw on macOS leaves RAM/CPU at 0 when sysctl is missing or non-numeric" {
  # sysctl absent from the sealed PATH entirely
  hwprobe macos
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]

  # sysctl present, but answering "unknown oid" rather than a number
  stub sysctl 'echo "sysctl: unknown oid"'
  hwprobe macos
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

# --- host probes: disk --------------------------------------------------------
# Regression test: _disk_avail_gb read the Available column as a fixed $4 on
# line NR==2. df wraps a long device name onto a line of its own, which pushes
# the numbers down to the next line — the old awk then read the device-name
# line, where $4 is empty, and reported 0 GiB free. Counting back from the end
# of the first row that actually has fields gives the same answer either way.
@test "_disk_avail_gb reads Available from the end of the row, wrapped device name or not" {
  real awk
  stub df 'printf "%s\n" \
  "Filesystem 1024-blocks Used Available Capacity Mounted on" \
  "/dev/sda1 103080160 41063268 56752860 42% /"'
  dprobe '_disk_avail_gb /var'
  [ "$status" -eq 0 ]
  [ "$output" = "54" ]

  stub df 'printf "%s\n" \
  "Filesystem 1024-blocks Used Available Capacity Mounted on" \
  "/dev/mapper/an--extremely--long--volume--group--name-root" \
  "            103080160 41063268 56752860 42% /"'
  dprobe '_disk_avail_gb /var'
  [ "$status" -eq 0 ]
  [ "$output" = "54" ]
}

# Guard on the contract the NF-2 rewrite had to preserve: when df cannot answer
# at all, _disk_avail_gb prints NOTHING (an int() of an empty field would be a
# plausible-looking 0), and detect_disk's `: "${VAR:=0}"` is what supplies the
# zero.
#
# Regression test: _disk_avail_gb used to propagate df's exit status, so on a
# host where df fails (a restricted container, an unreadable mount table) the
# command substitution in detect_disk failed, fired the ERR trap and aborted
# the whole install over a cosmetic probe. It must now succeed, mark the
# measurement unknown, and NOT raise a low-disk warning against a number that
# was never read.
@test "_disk_avail_gb survives a failing df; detect_disk marks it unknown" {
  real awk
  stub df 'exit 1'
  dprobe 'if _disk_avail_gb /var; then printf "rc=0 [%s]\n" ""; else printf "rc=%s\n" "$?"; fi'
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0 []" ]

  dprobe 'detect_disk;
    printf "%s %s %s %s\n" "$DETECT_DISK_VAR_GB" "$DETECT_DISK_ROOT_GB" \
      "$DETECT_DISK_WARN" "$DETECT_DISK_OK"'
  [ "$status" -eq 0 ]
  # 0 0 for the numbers, but WARN stays "no": an unmeasured disk is not a
  # low disk, and DISK_OK=no is what the report renders as "unknown".
  [ "$output" = "0 0 no no" ]
}

# A real measurement below the 10 GiB floor must still warn — the guard above
# must not have disabled the warning outright.
@test "detect_disk still warns when df reports a genuinely low /var" {
  real awk
  stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\n"
    printf "/dev/sda1 100000000 90000000 5242880 95%% /\n"'
  dprobe 'detect_disk;
    printf "%s %s %s\n" "$DETECT_DISK_VAR_GB" "$DETECT_DISK_WARN" "$DETECT_DISK_OK"'
  [ "$status" -eq 0 ]
  [ "$output" = "5 yes yes" ]
}

# --- host probes: listening ports --------------------------------------------
# Regression test: _port_listening did not exist — detect_ports ran ss inline.
# Extracting it must not change ss's invocation on Linux, so this asserts the
# original `ss -ltnH "sport = :$p"` argv as well as the yes/no answer.
@test "_port_listening uses ss with the original sport filter when ss exists" {
  real grep
  stub ss 'printf "%s\n" "$@" >>"'"$BATS_TEST_TMPDIR"'/ss.argv"
[[ "$2" == "sport = :10051" ]] && echo "LISTEN 0 128 0.0.0.0:10051 0.0.0.0:*"
exit 0'
  dprobe '_port_listening 10051 && echo listening || echo free'
  [ "$output" = "listening" ]

  dprobe '_port_listening 10050 && echo listening || echo free'
  [ "$output" = "free" ]

  [[ "$(cat "$BATS_TEST_TMPDIR/ss.argv")" == *"-ltnH"*"sport = :10051"* ]]
}

# Regression test: macOS has no ss, and the old `if ! command -v ss` guard gave
# up with DETECT_PORT_CONFLICTS=unknown there — on a probe that is perfectly
# answerable, since lsof ships with macOS (os_macos.sh's health check uses it).
@test "detect_ports falls back to lsof on a host with no ss" {
  # The stub matches the FULL argv, not just the port: -sTCP:LISTEN is
  # load-bearing. Without it lsof also matches ESTABLISHED sockets, so
  # detect_ports would report phantom conflicts from ordinary outbound
  # connections — on exactly the macOS path this fallback exists for.
  stub lsof 'a="$*"
    [[ "$a" == "-nP -iTCP:443 -sTCP:LISTEN" || "$a" == "-nP -iTCP:3306 -sTCP:LISTEN" ]]'
  dprobe 'detect_ports; printf "%s\n" "$DETECT_PORT_CONFLICTS"'
  [ "$status" -eq 0 ]
  [ "$output" = "443,3306" ]
}

# Guard on the other half of that fix: "unknown" is still the honest answer when
# NEITHER tool is installed, and must not have been widened into a false "none".
@test "detect_ports reports unknown only when neither ss nor lsof exists" {
  dprobe 'detect_ports; printf "%s\n" "$DETECT_PORT_CONFLICTS"'
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# --- detect_run: the macOS branch --------------------------------------------
# macos_run SCRIPT — detect_run end to end on a stubbed Darwin host (macOS 26,
# 16 GiB, 10 cores, 450 GiB free, something on 10050), then SCRIPT. ZBX_UNAME_M
# keeps detect_arch off the real `uname -m`, and detect_run marks the DETECT_*
# globals readonly, so this is one shot per subshell.
macos_run() {
  real awk grep date
  stub sw_vers 'echo 26.0'
  stub sysctl 'case "$2" in
  hw.memsize) echo 17179869184 ;;
  hw.logicalcpu) echo 10 ;;
  *) exit 1 ;;
esac'
  stub df 'printf "%s\n" \
  "Filesystem 1024-blocks Used Available Capacity Mounted on" \
  "/dev/disk3s5 971350180 102400000 471859200 18% /"'
  stub lsof '[[ "$2" == "-iTCP:10050" ]]'
  dprobe 'ZBX_UNAME_S=Darwin ZBX_UNAME_M=arm64; detect_run; '"$1"
}

# Regression test: detect_run's macOS branch set DETECT_PKGMGR and skipped every
# probe, so detect_report printed detect.sh's initialized defaults — "RAM / CPU:
# 0 MB / 0 vCPU", "Disk /var,/: 0,0 GiB free", "Port conflicts: none" — as if
# they had been measured. That is the undiagnosable macOS 26 report.
@test "detect_run on macOS measures RAM, CPU, disk and ports instead of printing the defaults" {
  stub pkgutil 'printf "%s\n" com.apple.pkg.CLTools_Executables'
  macos_run 'printf "%s %s %s %s %s %s %s\n" "$DETECT_OS_ID" "$DETECT_OS_MAJOR" \
    "$DETECT_RAM_MB" "$DETECT_CPU" "$DETECT_DISK_VAR_GB" "$DETECT_DISK_ROOT_GB" \
    "$DETECT_PORT_CONFLICTS"'
  [ "$status" -eq 0 ]
  [ "$output" = "macos 26 16384 10 450 450 10050" ]
}

# Regression test: an agent installed from the signed .pkg is invisible to
# `command -v zabbix_agentd` (sudo's secure_path excludes /usr/local/sbin) and
# to systemctl, and the macOS branch never called detect_existing anyway — so
# the report said "Existing Zabbix: no" on a Mac that had one. The pkgutil
# receipt is the fact that does exist. The "no" half guards the opposite error.
@test "detect_run on macOS flips Existing Zabbix to yes on a pkgutil receipt, and stays no without one" {
  # The second half also ORs in `-x /usr/local/sbin/zabbix_agentd`, a fixed path
  # no stub can intercept; skip rather than assert something the host decides.
  [ ! -x /usr/local/sbin/zabbix_agentd ] ||
    skip "this host really has /usr/local/sbin/zabbix_agentd"

  stub pkgutil 'printf "%s\n" com.zabbix.pkg.zabbix-agent'
  macos_run 'printf "%s\n" "$DETECT_ZBX_PRESENT"'
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]

  stub pkgutil 'printf "%s\n" com.apple.pkg.CLTools_Executables'
  macos_run 'printf "%s\n" "$DETECT_ZBX_PRESENT"'
  [ "$status" -eq 0 ]
  [ "$output" = "no" ]
}

# Regression test: the macOS branch left DETECT_FIREWALL at its "none" default.
# socketfilterfw and pf are never probed there, so "none" asserted a fact that
# had not been checked; "unknown" is the only honest value. DETECT_PKGMGR is
# asserted alongside it as the one thing the old branch did get right.
@test "detect_run on macOS reports the firewall as unknown, not a never-probed none" {
  stub pkgutil 'printf "%s\n" com.apple.pkg.CLTools_Executables'
  macos_run 'printf "%s %s %s\n" "$DETECT_FIREWALL" "$DETECT_PKGMGR" "$DETECT_PKGMGR_OK"'
  [ "$status" -eq 0 ]
  [ "$output" = "unknown pkg yes" ]
}
