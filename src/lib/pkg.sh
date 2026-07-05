# shellcheck shell=bash
# pkg.sh — apt/dnf/zypper abstraction: update, install, remove (§5, §11, §12.2).
#
# Contract:
#   inputs  : DETECT_PKGMGR/DETECT_FAMILY/DETECT_OS_MAJOR (detect.sh),
#             PLAN_UPDATE (recommend.sh), a package list (args).
#   outputs : runs the package manager for real (or previews under DRY_RUN via
#             run()'s own no-op); on failure routes to err_menu('packages', ...)
#             per §14 (retry / view log / exit 5 — no skip, packages can never
#             be skipped).
#
# EL8 note (verified live 2026-07-05, see BUILD_REFERENCE.md Phase 3 entry):
# Zabbix 7.0/7.4 frontends now require PHP >= 8.0.0, but RHEL 8's own
# AppStream tops out at php:7.4 — there is no native php:8.0+ stream, so
# SPEC.md's assumed "dnf module enable php:8.0" (§15.2) would fail outright.
# Getting PHP 8+ on EL8 needs a third-party repo (Remi) — too large a trust
# decision to make automatically. So pkg_install does NOT attempt any module
# switch; it lets dnf's real dependency resolution be authoritative (an
# environment with Remi already configured just works), and only adds the
# Remi hint to the error message if a frontend install on EL8 actually fails.

# --- system update (§11) ------------------------------------------------------
# _pkg_count_installed — best-effort installed-package count, for the log
# (§11). Purely informational: must never fail the update step just because
# dpkg-query/rpm/wc are unavailable — pipefail (core.sh) would otherwise
# propagate a missing-tool failure through the pipe even if wc/tr succeed.
_pkg_count_installed() {
  case "$DETECT_PKGMGR" in
    apt) dpkg-query -f '.\n' -W 2>/dev/null | wc -l | tr -d ' ' ;;
    dnf | zypper) rpm -qa 2>/dev/null | wc -l | tr -d ' ' ;;
    *) echo '?' ;;
  esac
  return 0
}

# _pkg_reboot_needed — warn only, never reboot automatically (§11).
_pkg_reboot_needed() {
  [[ -f /var/run/reboot-required ]] && return 0
  command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1 && return 0
  command -v zypper >/dev/null 2>&1 && zypper ps -s 2>/dev/null | grep -qi 'reboot' && return 0
  return 1
}

# pkg_update — full system update, only when PLAN_UPDATE=yes. §11.
pkg_update() {
  if [[ "${PLAN_UPDATE:-no}" != "yes" ]]; then
    return 0
  fi
  if core_state_is_done update; then
    log INFO "system update already done (state file) — skipping"
    return 0
  fi
  local before after
  before="$(_pkg_count_installed)"
  while true; do
    case "$DETECT_PKGMGR" in
      apt) run apt-get update && run apt-get -y upgrade && break ;;
      dnf) run dnf -y upgrade && break ;;
      zypper) run zypper --non-interactive update && break ;;
    esac
    err_menu packages "system update failed (${DETECT_PKGMGR})"
  done
  after="$(_pkg_count_installed)"
  log INFO "system update: $before -> $after packages installed"
  if _pkg_reboot_needed; then
    log WARN "a reboot appears to be needed after this update (not done automatically)"
  fi
  state_mark_done update
  return 0
}

# --- install (§12.2) -----------------------------------------------------------
# _pkg_install_cmd PACKAGES... — one non-interactive transaction, family-specific.
_pkg_install_cmd() {
  case "$DETECT_PKGMGR" in
    apt) run apt-get install -y "$@" ;;
    dnf) run dnf install -y "$@" ;;
    zypper) run zypper --non-interactive install "$@" ;;
    *) return 1 ;;
  esac
}

# _pkg_failure_hint PACKAGES... — a more specific reason string for the error
# menu when the failing transaction includes the frontend on EL8 (see the
# module header note above); generic otherwise.
_pkg_failure_hint() {
  # Global IFS is $'\n\t' (core.sh) — force a space join for the word match.
  # The frontend package is zabbix-web-mysql/-pgsql on RHEL, not
  # zabbix-frontend-php (that name is apt-only — verified live 2026-07-05).
  local IFS=' '
  if [[ "$DETECT_FAMILY" == "rhel" && "$DETECT_OS_MAJOR" == "8" ]] &&
    [[ " $* " == *" zabbix-web-mysql "* || " $* " == *" zabbix-web-pgsql "* ]]; then
    printf 'package transaction failed — likely cause: RHEL 8'\''s native PHP tops out at 7.4, but this Zabbix frontend needs PHP >= 8.0.0. Add the Remi repository first (https://rpms.remirepo.net) and enable a php:remi-8.x+ stream, then retry.'
  else
    printf 'package transaction failed (%s) — see the log' "$DETECT_PKGMGR"
  fi
}

# pkg_install PACKAGES... — install everything in one transaction; on failure
# open the §14 packages error menu (retry / view log / exit 5).
pkg_install() {
  if core_state_is_done packages; then
    log INFO "packages already installed (state file) — skipping"
    return 0
  fi
  if (($# == 0)); then
    log WARN "pkg_install called with no packages — nothing to do"
    return 0
  fi
  while true; do
    if _pkg_install_cmd "$@"; then
      state_mark_done packages
      log INFO "packages installed: $*"
      return 0
    fi
    err_menu packages "$(_pkg_failure_hint "$@")"
  done
}

# --- remove (Phase 7 uninstall) ------------------------------------------------
# pkg_remove PACKAGES... — best-effort removal; used by --uninstall (Phase 7).
pkg_remove() {
  (($# == 0)) && return 0
  case "$DETECT_PKGMGR" in
    apt) run apt-get remove -y "$@" ;;
    dnf) run dnf remove -y "$@" ;;
    zypper) run zypper --non-interactive remove "$@" ;;
    *) return 1 ;;
  esac
}
