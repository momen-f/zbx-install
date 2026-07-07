# shellcheck shell=bash
# repo.sh — Zabbix repository setup (§12.1).
#
# Contract:
#   inputs  : DETECT_FAMILY/DETECT_OS_ID/DETECT_OS_VERSION/DETECT_OS_MAJOR/
#             DETECT_ARCH (detect.sh), PLAN_ZBX_VERSION (recommend.sh).
#   outputs : installs the zabbix-release package for the family and refreshes
#             package-manager metadata; on failure, routes to err_menu('repo', ...)
#             per §14 (retry / pick a different Zabbix version / view log / exit 5).
#
# VERIFIED LIVE against repo.zabbix.com on 2026-07-05 (SPEC §12.1 says do this
# before hardcoding — the URLs below differ from the URLs SPEC.md itself
# assumed). Two real findings baked into this module:
#   1. Zabbix is mid-migration: version 7.0 is served from a NEW flat layout
#      (no "/release/" path segment, rpm files live under an ARCH-named dir),
#      while 7.4 and 8.0 are still served from the OLD "/release/"-prefixed
#      layout (rpm files live under "noarch/" even though the package is
#      noarch). Both layouts are probed; whichever resolves is used, so a
#      future version flipping the layout again doesn't need a code change.
#   2. SPEC.md's SLES filename suffix was wrong: it's "sles15", not "sl15".

# --- pure URL builders (bats-testable; no I/O) --------------------------------
# _is_raspbian_repo_target OS_ID ARCH — true when Zabbix serves this Debian-
# family host from the raspbian repo rather than debian/ubuntu: os_id=raspbian
# (32-bit Raspberry Pi OS), or os_id=debian on ARM (64-bit Pi OS reports
# ID=debian; Debian-on-arm generally). Zabbix ships all Debian-family ARM
# packages (armhf + arm64) only under /raspbian/ — the /debian/ tree is
# x86-only (verified 2026-07). Ubuntu keeps its own repo on every arch. The
# 7.4-on-arm plan gate (main.sh) keys off the same predicate so it can't drift.
_is_raspbian_repo_target() {
  local os_id="$1" arch="$2"
  [[ "$os_id" == "raspbian" ]] || { [[ "$os_id" == "debian" ]] && _arch_is_arm "$arch"; }
}

# _repo_apt_url LAYOUT OS_ID OS_VERSION ZBX_VERSION ARCH
# raspbian-repo hosts (see above) use the /raspbian/ path with a +debian<ver>
# bootstrap deb; everything else keeps its own os_id path + +<os_id><ver>.
_repo_apt_url() {
  local layout="$1" os_id="$2" os_ver="$3" zv="$4" arch="$5"
  local base="https://repo.zabbix.com/zabbix/${zv}"
  [[ "$layout" == "legacy" ]] && base="${base}/release"
  local path_id="$os_id" sfx_id="$os_id"
  if _is_raspbian_repo_target "$os_id" "$arch"; then
    path_id="raspbian"
    sfx_id="debian"
  fi
  printf '%s/%s/pool/main/z/zabbix-release/zabbix-release_latest_%s+%s%s_all.deb' \
    "$base" "$path_id" "$zv" "$sfx_id" "$os_ver"
}

# _repo_dnf_url LAYOUT OS_ID OS_MAJOR ZBX_VERSION ARCH
# Amazon Linux shares the rhel family/pkgmgr but has its own repo path segment
# (amazonlinux/<ver>) and rpm dist suffix (.amzn<ver>) in place of rhel/.el<major>
# (verified against repo.zabbix.com 2026-07 — 7.0 flat, 7.4 under release/).
_repo_dnf_url() {
  local layout="$1" os_id="$2" major="$3" zv="$4" arch="$5"
  local distro="rhel" sfx="el${major}"
  if [[ "$os_id" == "amzn" ]]; then
    distro="amazonlinux"
    sfx="amzn${major}"
  fi
  if [[ "$layout" == "legacy" ]]; then
    printf 'https://repo.zabbix.com/zabbix/%s/release/%s/%s/noarch/zabbix-release-latest-%s.%s.noarch.rpm' \
      "$zv" "$distro" "$major" "$zv" "$sfx"
  else
    printf 'https://repo.zabbix.com/zabbix/%s/%s/%s/%s/zabbix-release-latest-%s.%s.noarch.rpm' \
      "$zv" "$distro" "$major" "$arch" "$zv" "$sfx"
  fi
}

# _repo_zypper_url LAYOUT ZBX_VERSION ARCH — SLES and openSUSE Leap share this
# path; the filename is always "slesNN" for the SLES major (currently only 15
# has packages), regardless of Leap vs SLES proper or the exact minor/SP (§4).
_repo_zypper_url() {
  local layout="$1" zv="$2" arch="$3"
  if [[ "$layout" == "legacy" ]]; then
    printf 'https://repo.zabbix.com/zabbix/%s/release/sles/15/noarch/zabbix-release-latest-%s.sles15.noarch.rpm' \
      "$zv" "$zv"
  else
    printf 'https://repo.zabbix.com/zabbix/%s/sles/15/%s/zabbix-release-latest-%s.sles15.noarch.rpm' \
      "$zv" "$arch" "$zv"
  fi
}

# zbx_release_url LAYOUT FAMILY OS_ID OS_VERSION OS_MAJOR ZBX_VERSION ARCH
# Pure dispatcher: one deterministic URL for a given (layout, family, ...).
zbx_release_url() {
  local layout="$1" family="$2" os_id="$3" os_ver="$4" major="$5" zv="$6" arch="$7"
  case "$family" in
    debian) _repo_apt_url "$layout" "$os_id" "$os_ver" "$zv" "$arch" ;;
    rhel) _repo_dnf_url "$layout" "$os_id" "$major" "$zv" "$arch" ;;
    suse) _repo_zypper_url "$layout" "$zv" "$arch" ;;
    *) return 1 ;;
  esac
}

# --- resolution (impure: one HEAD probe to pick the live layout) -------------
# repo_resolve_url — try "flat" then "legacy"; echo the first URL that exists.
# Skips the probe under DRY_RUN (or if curl is unavailable), returning the
# flat guess unverified: guard_network (main.sh) already establishes that a
# dry-run must tolerate having no network at all (warn and continue, never
# fail) — probing here would contradict that by letting a dry-run abort at
# the repo step the moment connectivity or the flat layout isn't available.
# The trade-off: a dry-run preview may show a guessed URL that a real run
# would resolve differently (e.g. today, 7.4 actually needs the legacy
# layout) — an accepted limitation of previewing without requiring network.
repo_resolve_url() {
  local flat legacy
  flat="$(zbx_release_url flat "$DETECT_FAMILY" "$DETECT_OS_ID" "$DETECT_OS_VERSION" \
    "$DETECT_OS_MAJOR" "$PLAN_ZBX_VERSION" "$DETECT_ARCH")" || return 1
  if [[ "$DRY_RUN" == "1" ]] || ! command -v curl >/dev/null 2>&1; then
    printf '%s' "$flat"
    return 0
  fi
  if curl -fsSIL --max-time 10 "$flat" >/dev/null 2>&1; then
    printf '%s' "$flat"
    return 0
  fi
  legacy="$(zbx_release_url legacy "$DETECT_FAMILY" "$DETECT_OS_ID" "$DETECT_OS_VERSION" \
    "$DETECT_OS_MAJOR" "$PLAN_ZBX_VERSION" "$DETECT_ARCH")" || return 1
  if curl -fsSIL --max-time 10 "$legacy" >/dev/null 2>&1; then
    printf '%s' "$legacy"
    return 0
  fi
  return 1
}

# --- install + probe (§12.1) --------------------------------------------------
# repo_probe — verify the repo actually resolves a real Zabbix package before
# continuing, per family.
repo_probe() {
  case "$DETECT_PKGMGR" in
    apt) run apt-cache policy zabbix-agent2 ;;
    dnf) run dnf info zabbix-agent2 ;;
    zypper) run zypper info zabbix-agent2 ;;
    *) return 1 ;;
  esac
}

# _repo_install_once URL — one attempt: download + install the release package
# + refresh metadata, family-specific. Returns non-zero on any failure.
_repo_install_once() {
  local url="$1" tmp
  case "$DETECT_PKGMGR" in
    apt)
      tmp="$(mktemp -t zbx-release.XXXXXX.deb)"
      ZBX_TEMPFILES+=("$tmp")
      run curl -fsSLo "$tmp" "$url" &&
        run dpkg -i "$tmp" &&
        run apt-get update
      ;;
    dnf)
      run rpm -Uvh --force "$url" &&
        run dnf clean all &&
        run dnf makecache
      ;;
    zypper)
      run rpm -Uvh --force "$url" &&
        run zypper --gpg-auto-import-keys refresh
      ;;
    *) return 1 ;;
  esac
}

# repo_install — resolve the URL, install, probe; on any failure open the §14
# repo error menu (retry / pick a different Zabbix version / view log / exit 5).
# Idempotent via the state file so a resumed run skips a completed repo setup.
repo_install() {
  if core_state_is_done repo; then
    log INFO "repo already set up (state file) — skipping"
    return 0
  fi
  local url
  while true; do
    # `|| true`: a failing resolve must fall into the empty-url check below,
    # not abort the script here (set -e treats this bare assignment as a
    # simple command, unlike a command substitution used in a condition).
    url="$(repo_resolve_url)" || true
    if [[ -z "$url" ]]; then
      err_menu repo "no Zabbix ${PLAN_ZBX_VERSION} repo found for ${DETECT_OS_ID} ${DETECT_OS_VERSION} (checked both known URL layouts)"
      continue
    fi
    log INFO "repo URL: $url"
    # No special dry-run branch: run() itself prints-and-skips each real
    # command when DRY_RUN=1, so this always "succeeds" and previews cleanly.
    if _repo_install_once "$url" && repo_probe; then
      state_mark_done repo
      log INFO "repo set up successfully"
      return 0
    fi
    err_menu repo "installing or probing the Zabbix repo failed (url: $url) — see the log"
  done
}
