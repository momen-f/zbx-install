#!/usr/bin/env bats
# Unit tests for firewall.sh (§12.5). Sourcing happens inside `bash -c`
# subshells (see redact.bats for why core.sh is never sourced into the bats
# shell directly); a small fake-tool PATH is used for firewall-cmd/ufw/
# setsebool, built fresh per test.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
UI="${BATS_TEST_DIRNAME}/../../src/lib/ui.sh"
RECOMMEND="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"
FIREWALL="${BATS_TEST_DIRNAME}/../../src/lib/firewall.sh"

fwprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$UI"'"; source "'"$RECOMMEND"'"; source "'"$FIREWALL"'"; '"$1"
}

fake_tool() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '#!/bin/bash\n%s\n' "$body" >"$dir/$name"
  chmod +x "$dir/$name"
}

# --- firewall_open_ports -------------------------------------------------------------

@test "firewall_open_ports (firewalld, full stack) opens the agent ports and http/https" {
  local d="$BATS_TEST_TMPDIR/t1" log="$BATS_TEST_TMPDIR/t1.log"
  fake_tool "$d" firewall-cmd 'echo "$*" >>"'"$log"'"; exit 0'
  fwprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    DETECT_FIREWALL=firewalld; PLAN_COMPONENTS=server,frontend,agent;
    firewall_open_ports'
  [ "$status" -eq 0 ]
  run cat "$log"
  [[ "$output" == *"--add-port=10050/tcp"* ]]
  [[ "$output" == *"--add-port=10051/tcp"* ]]
  [[ "$output" == *"--add-service=http"* ]]
  [[ "$output" == *"--add-service=https"* ]]
  [[ "$output" == *"--reload"* ]]
}

@test "firewall_open_ports (firewalld, agent-only) opens only the agent ports" {
  local d="$BATS_TEST_TMPDIR/t2" log="$BATS_TEST_TMPDIR/t2.log"
  fake_tool "$d" firewall-cmd 'echo "$*" >>"'"$log"'"; exit 0'
  fwprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    DETECT_FIREWALL=firewalld; PLAN_COMPONENTS=agent;
    firewall_open_ports'
  [ "$status" -eq 0 ]
  run cat "$log"
  [[ "$output" == *"--add-port=10050/tcp"* ]]
  [[ "$output" != *"--add-service"* ]]
}

@test "firewall_open_ports (ufw) allows the agent ports and the web server's app profile" {
  local d="$BATS_TEST_TMPDIR/t3" log="$BATS_TEST_TMPDIR/t3.log"
  fake_tool "$d" ufw 'echo "$*" >>"'"$log"'"; exit 0'
  fwprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    DETECT_FIREWALL=ufw; PLAN_COMPONENTS=server,frontend,agent; PLAN_WEB_SERVER=nginx;
    firewall_open_ports'
  [ "$status" -eq 0 ]
  run cat "$log"
  [[ "$output" == *"10050,10051/tcp"* ]]
  [[ "$output" == *"Nginx Full"* ]]
}

@test "firewall_open_ports (none) just logs — no commands run" {
  fwprobe 'core_color_init; core_log_init; DRY_RUN=0;
    DETECT_FIREWALL=none; PLAN_COMPONENTS=server,frontend,agent;
    firewall_open_ports; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

# --- firewall_selinux_prep ------------------------------------------------------------

@test "firewall_selinux_prep sets the zabbix booleans on RHEL when enforcing" {
  local d="$BATS_TEST_TMPDIR/t4" log="$BATS_TEST_TMPDIR/t4.log"
  fake_tool "$d" setsebool 'echo "$*" >>"'"$log"'"; exit 0'
  fwprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    DETECT_FAMILY=rhel; DETECT_SELINUX=enforcing;
    firewall_selinux_prep'
  [ "$status" -eq 0 ]
  run cat "$log"
  [[ "$output" == *"httpd_can_connect_zabbix on"* ]]
  [[ "$output" == *"zabbix_can_network on"* ]]
}

@test "firewall_selinux_prep is a no-op off RHEL or when not enforcing" {
  fwprobe 'DETECT_FAMILY=debian; DETECT_SELINUX=absent; firewall_selinux_prep; echo ok'
  [[ "$output" == *"ok"* ]]
  fwprobe 'DETECT_FAMILY=rhel; DETECT_SELINUX=permissive; firewall_selinux_prep; echo ok'
  [[ "$output" == *"ok"* ]]
}

# --- firewall_apply orchestration ----------------------------------------------------

@test "firewall_apply skips opening ports when PLAN_OPEN_FIREWALL is no, but still preps SELinux" {
  local d="$BATS_TEST_TMPDIR/t5" log="$BATS_TEST_TMPDIR/t5.log"
  fake_tool "$d" firewall-cmd 'echo "firewall-cmd called" >>"'"$log"'"; exit 0'
  fake_tool "$d" setsebool 'echo "setsebool called" >>"'"$log"'"; exit 0'
  fwprobe 'core_color_init; core_log_init; DRY_RUN=0; PATH="'"$d"':$PATH";
    DETECT_FIREWALL=firewalld; DETECT_FAMILY=rhel; DETECT_SELINUX=enforcing;
    PLAN_OPEN_FIREWALL=no; PLAN_COMPONENTS=server,agent;
    firewall_apply'
  [ "$status" -eq 0 ]
  run cat "$log"
  [[ "$output" != *"firewall-cmd called"* ]]
  [[ "$output" == *"setsebool called"* ]]
}

@test "firewall_apply skips entirely when the state file already marks it done" {
  local log="$BATS_TEST_TMPDIR/skip.log"
  fwprobe 'core_color_init; LOG_FILE="'"$log"'"; core_log_init;
    STATE_FILE="'"$BATS_TEST_TMPDIR"'/state"; : >"$STATE_FILE";
    state_mark_done firewall;
    firewall_apply; echo done'
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  run cat "$log"
  [[ "$output" == *"already applied"* ]]
}
