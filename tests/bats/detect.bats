#!/usr/bin/env bats
# Unit tests for detect.sh OS parsing, family mapping, and support matrix (§4, §8).
#
# The pure OS functions read only OS_RELEASE_FILE, so every support-matrix entry
# is exercised here via fixtures — no container needed. core.sh is sourced
# alongside detect.sh inside `bash -c` subshells (see redact.bats for why).

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DETECT="${BATS_TEST_DIRNAME}/../../src/lib/detect.sh"
FIX="${BATS_TEST_DIRNAME}/../fixtures"

# probe FIXTURE — sets $output to "ID MAJOR FAMILY SUPPORTED".
probe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    OS_RELEASE_FILE="'"$FIX"'/'"$1"'";
    detect_os; detect_family; detect_supported;
    printf "%s %s %s %s\n" "$DETECT_OS_ID" "$DETECT_OS_MAJOR" "$DETECT_FAMILY" "$DETECT_SUPPORTED"'
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

@test "_osr_get strips quotes and preserves inner spaces" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    _osr_get PRETTY_NAME "'"$FIX"'/os-release.debian12"'
  [ "$output" = "Debian GNU/Linux 12 (bookworm)" ]
}

@test "missing os-release file -> unknown, non-fatal" {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'";
    OS_RELEASE_FILE="/nonexistent/os-release"; detect_os || true;
    detect_family; printf "%s %s\n" "$DETECT_OS_ID" "$DETECT_FAMILY"'
  [ "$status" -eq 0 ]
  [ "$output" = "unknown unknown" ]
}
