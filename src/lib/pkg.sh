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
# EL8 note (verified live 2026-07-05):
# Zabbix 7.0/7.4 frontends now require PHP >= 8.0.0, but RHEL 8's own
# AppStream tops out at php:7.4 — there is no native php:8.0+ stream, so
# SPEC.md's assumed "dnf module enable php:8.0" (§15.2) would fail outright.
# Getting PHP 8+ on EL8 needs a third-party repo (Remi) — too large a trust
# decision to make automatically. So pkg_install does NOT attempt any module
# switch; it lets dnf's real dependency resolution be authoritative (an
# environment with Remi already configured just works), and only adds the
# Remi hint to the error message if a frontend install on EL8 actually fails.

# --- PHP version floor for the frontend ---------------------------------------
# A Zabbix frontend enforces a PHP minimum at RUN time that its packages do
# NOT declare: the RPMs require only php-mysqlnd, so dnf installs happily
# against a too-old PHP and every page then answers HTTP 200 with the plain
# text "Minimum required PHP version is 8.2.0." — correct content type HTML,
# clean web-server logs, services all active. Found on rocky 9 + Zabbix 8.0
# (CI, 2026-11-08), where the symptom was an API that simply never answered.
#
# _zbx_php_min_version and _ver_ge live in detect.sh, next to the version
# arrays: the plan-time warning (recommend.sh) needs them as well, and
# detect.sh is loaded before both.

# pkg_php_module_enable — on RHEL-family, switch to a native php module stream
# new enough for the planned frontend, BEFORE the packages are installed.
# Same call as db_mysql_module_enable: selecting a stream from the distro's
# own AppStream is routine. This is deliberately not the EL8/Remi case below —
# that needs a THIRD-PARTY repo, which stays a hint rather than an action.
# A no-op when the enabled stream is already new enough, when the distro
# ships no new-enough stream (EL8), or off RHEL entirely.
pkg_php_module_enable() {
  [[ "$DETECT_PKGMGR" == "dnf" ]] || return 0
  plan_has frontend || return 0
  local want enabled stream best=""
  want="$(_zbx_php_min_version "$PLAN_ZBX_VERSION")"
  enabled="$(dnf module list --enabled php 2>/dev/null | awk '$1 == "php" {print $2; exit}' || true)"
  if [[ -n "$enabled" ]] && _ver_ge "$enabled" "$want"; then
    log INFO "php module stream $enabled already satisfies Zabbix $PLAN_ZBX_VERSION (needs >= $want)"
    return 0
  fi
  # Lowest available stream that clears the floor: newer than required is a
  # bigger change to the user's system than the job calls for.
  while read -r stream; do
    [[ -n "$stream" ]] || continue
    _ver_ge "$stream" "$want" || continue
    if [[ -z "$best" ]] || ! _ver_ge "$stream" "$best"; then best="$stream"; fi
  done < <(dnf module list php 2>/dev/null | awk '$1 == "php" {print $2}' || true)
  if [[ -z "$best" ]]; then
    # EL8 lands here: no native stream >= 8.0. Leave it to dnf and to
    # _pkg_failure_hint, which already names Remi.
    log WARN "no native php module stream >= $want is available — the Zabbix $PLAN_ZBX_VERSION frontend needs PHP >= ${want}.0 and may refuse to run"
    return 0
  fi
  log INFO "enabling php module stream $best (Zabbix $PLAN_ZBX_VERSION frontend needs PHP >= ${want}.0, enabled stream: ${enabled:-distro default})"
  run dnf module reset php -y || true
  run dnf module enable "php:${best}" -y || true
}

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
#
# dnf-only: refresh the metadata cache first. Rocky/RHEL's AppStream can
# resolve a package to a NEVRA whose modular metadata (modules.yaml) isn't
# in the locally cached repodata yet, and dnf then refuses the whole
# transaction with "No available modular metadata for modular package ...,
# it cannot be installed on the system" even though the package is really
# available — hit for real, intermittently, in CI on Rocky 9's
# mariadb-server (a modular package, but the underlying mechanism isn't
# package-specific). A cache refresh immediately before the transaction
# resolves the mismatch; best-effort, since a transient failure here
# shouldn't preempt the real install attempt or its own error message.
# This is a distinct issue from the mariadb module-stream ambiguity that
# db_mysql_module_enable() guards against (see that function's header) —
# that one isn't a cache-staleness problem at all, a fresh cache resolves
# to the broken stream just as reliably as a stale one.
_pkg_install_cmd() {
  case "$DETECT_PKGMGR" in
    apt) run apt-get install -y "$@" ;;
    dnf)
      run dnf makecache --refresh || true
      run dnf install -y "$@"
      ;;
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
    local want
    want="$(_zbx_php_min_version "${PLAN_ZBX_VERSION:-$ZBX_DEFAULT_VERSION}")"
    printf 'package transaction failed — likely cause: RHEL 8'\''s native PHP tops out at 7.4, but this Zabbix frontend needs PHP >= %s. Add the Remi repository first (https://rpms.remirepo.net) and enable a php:remi-%s+ stream, then retry.' "$want" "$want"
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

# --- schema files shipped by zabbix-sql-scripts -------------------------------
# The layout is NOT stable across majors, and a hardcoded path fails LATE: on
# Zabbix 8.0 the packages installed, the database was created, and only then
# did the import die with "schema file not found" (CI, 2026-11-08) — three
# steps after the thing that actually moved. So resolve it at run time.
#
# zbx_schema_file ENGINE BASE... — print the first schema file that exists for
# ENGINE (mysql|postgresql), trying each BASE in order. Non-zero if none is
# found. Order of resort: the historical path (cheap, and right on 7.x), then
# the package manager's own file list (authoritative), then a bounded search.
zbx_schema_file() {
  local engine="$1"
  shift
  local base p listed=""
  for base in "$@"; do
    p="/usr/share/zabbix-sql-scripts/${engine}/${base}"
    [[ -f "$p" ]] && {
      printf '%s' "$p"
      return 0
    }
  done
  if command -v dpkg >/dev/null 2>&1; then
    listed="$(dpkg -L zabbix-sql-scripts 2>/dev/null || true)"
  elif command -v rpm >/dev/null 2>&1; then
    listed="$(rpm -ql zabbix-sql-scripts 2>/dev/null || true)"
  fi
  if [[ -n "$listed" ]]; then
    for base in "$@"; do
      while IFS= read -r p; do
        [[ "$p" == *"/${engine}/${base}" && -f "$p" ]] && {
          printf '%s' "$p"
          return 0
        }
      done <<<"$listed"
    done
  fi
  for base in "$@"; do
    # `|| true`: head exits early, so find takes SIGPIPE and pipefail would
    # make this assignment fail the ERR trap — the same trap that used to
    # abort the whole install over a cosmetic df probe.
    p="$(find /usr/share -path "*/${engine}/${base}" -type f 2>/dev/null | head -n 1 || true)"
    [[ -n "$p" ]] && {
      printf '%s' "$p"
      return 0
    }
  done
  return 1
}

# zbx_schema_missing_hint ENGINE — log what the package DID install, so a
# future relayout is diagnosable from the log instead of needing a CI probe.
zbx_schema_missing_hint() {
  local engine="$1" listed=""
  if command -v dpkg >/dev/null 2>&1; then
    listed="$(dpkg -L zabbix-sql-scripts 2>/dev/null || true)"
  elif command -v rpm >/dev/null 2>&1; then
    listed="$(rpm -ql zabbix-sql-scripts 2>/dev/null || true)"
  fi
  if [[ -n "$listed" ]]; then
    log INFO "zabbix-sql-scripts installed these ${engine} files: $(printf '%s' "$listed" | grep -i "$engine" | tr '\n' ' ')"
  else
    log INFO "zabbix-sql-scripts does not appear to be installed"
  fi
}
