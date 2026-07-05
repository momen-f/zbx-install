# shellcheck shell=bash
# firewall.sh — open Zabbix ports + RHEL SELinux booleans (§12.5).
#
# Contract:
#   inputs  : PLAN_OPEN_FIREWALL, PLAN_WEB_SERVER (recommend.sh),
#             DETECT_FIREWALL, DETECT_FAMILY, DETECT_SELINUX (detect.sh).
#   outputs : opens 10050/10051 (+ 80/443 when a frontend is planned) via the
#             detected firewall manager; on RHEL with SELinux enforcing, sets
#             the zabbix booleans. On failure routes to err_menu('firewall',
#             ...) (§14: retry / skip (warn, degraded) / view log / exit 5).
#             Never suggests disabling SELinux.
#
# zabbix-selinux-policy is already in PLAN_PACKAGES and installed by Phase
# 3's pkg_install (recommend.sh adds it automatically for rhel+enforcing) —
# firewall_selinux_prep only sets the booleans, it doesn't install anything
# (pkg_install's own "packages" step is already marked done by this point,
# so a second call here would just no-op-skip, not actually install).

firewall_open_ports() {
  case "$DETECT_FIREWALL" in
    firewalld)
      if plan_has frontend; then
        run firewall-cmd --permanent --add-port={10050,10051}/tcp --add-service={http,https} || return 1
      else
        run firewall-cmd --permanent --add-port={10050,10051}/tcp || return 1
      fi
      run firewall-cmd --reload
      ;;
    ufw)
      run ufw allow 10050,10051/tcp || return 1
      if plan_has frontend; then
        if [[ "$PLAN_WEB_SERVER" == "nginx" ]]; then
          run ufw allow 'Nginx Full' || run ufw allow 80,443/tcp
        else
          run ufw allow 'Apache Full' || run ufw allow 80,443/tcp
        fi
      fi
      ;;
    *)
      local extra_ports=""
      plan_has frontend && extra_ports=", 80/443"
      log INFO "no active firewall detected — nothing to open (ports 10050/10051${extra_ports} are reachable by default)"
      ;;
  esac
}

firewall_selinux_prep() {
  if [[ "$DETECT_FAMILY" != "rhel" || "$DETECT_SELINUX" != "enforcing" ]]; then
    return 0
  fi
  run setsebool -P httpd_can_connect_zabbix on zabbix_can_network on
}

# --- orchestration ---------------------------------------------------------------
firewall_apply() {
  if core_state_is_done firewall; then
    log INFO "firewall/SELinux already applied (state file) — skipping"
    return 0
  fi
  if [[ "$PLAN_OPEN_FIREWALL" == "yes" ]]; then
    firewall_open_ports || return 1
  fi
  firewall_selinux_prep || return 1
  state_mark_done firewall
  log INFO "firewall/SELinux step complete"
}
