#!/usr/bin/env bats
# Unit tests for recommend.sh: §9 rules, override resolution, package mapping.
#
# Sourcing happens inside `bash -c` subshells (see redact.bats for why). The
# detect.sh defaults give every DETECT_* var a value; tests override the ones
# each function reads.

CORE="${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
DETECT="${BATS_TEST_DIRNAME}/../../src/lib/detect.sh"
REC="${BATS_TEST_DIRNAME}/../../src/lib/recommend.sh"

# rprobe SNIPPET — run SNIPPET with all three libs sourced.
rprobe() {
  run bash -c 'source "'"$CORE"'"; source "'"$DETECT"'"; source "'"$REC"'"; '"$1"
}

# --- rule 1+labels -------------------------------------------------------------
@test "rec_zbx_version defaults to the LTS release" {
  rprobe 'rec_zbx_version'
  [ "$output" = "7.0" ]
}

@test "rec_version_label distinguishes LTS from current stable" {
  rprobe 'printf "%s|%s" "$(rec_version_label 7.0)" "$(rec_version_label 7.4)"'
  [ "$output" = "LTS|current stable" ]
}

# --- rule 2: DB engine -----------------------------------------------------------
@test "rec_db_engine: nothing installed -> mariadb default" {
  rprobe 'rec_db_engine none'
  [ "$output" = "mariadb" ]
}

@test "rec_db_engine: pgsql present wins over mysql family" {
  rprobe 'rec_db_engine "mariadb,mysql,pgsql"'
  [ "$output" = "pgsql" ]
}

@test "rec_db_engine: mariadb preferred over generic mysql" {
  rprobe 'rec_db_engine "mariadb,mysql"'
  [ "$output" = "mariadb" ]
}

@test "rec_db_engine: plain mysql reused" {
  rprobe 'rec_db_engine "mysql"'
  [ "$output" = "mysql" ]
}

# --- rule 3: web server -----------------------------------------------------------
@test "rec_web_server: apache is the default" {
  rprobe 'printf "%s|%s|%s" "$(rec_web_server none)" "$(rec_web_server apache)" "$(rec_web_server "apache,nginx")"'
  [ "$output" = "apache|apache|apache" ]
}

@test "rec_web_server: nginx only when alone" {
  rprobe 'rec_web_server nginx'
  [ "$output" = "nginx" ]
}

# --- rules 4+5: components and sizing ---------------------------------------------
@test "rec_components: <2GiB suggests agent-only" {
  rprobe 'printf "%s|%s" "$(rec_components 1024)" "$(rec_components 2048)"'
  [ "$output" = "agent|server,frontend,agent" ]
}

@test "rec_sizing_preset boundaries" {
  rprobe 'for m in 1024 2048 4095 4096 8192 8193; do rec_sizing_preset "$m"; printf " "; done'
  [ "$output" = "warn small small medium medium large " ]
}

@test "rec_sizing_values returns the medium tuple" {
  rprobe 'rec_sizing_values medium'
  [ "$output" = "1G 1G 128M 256M" ]
}

# --- validation helpers ------------------------------------------------------------
@test "_valid_zbx_version accepts offered, rejects others" {
  rprobe '_valid_zbx_version 7.0 && _valid_zbx_version 7.4 && ! _valid_zbx_version 6.0 && echo ok'
  [ "$output" = "ok" ]
}

@test "_valid_components accepts good lists, rejects bad tokens and empty" {
  rprobe '_valid_components server,frontend,agent && _valid_components agent && ! _valid_components server,db && ! _valid_components "" && echo ok'
  [ "$output" = "ok" ]
}

# --- resolve_plan overrides -----------------------------------------------------------
@test "resolve_plan: --db pgsql overrides a mariadb recommendation" {
  rprobe 'REC_ZBX_VERSION=7.0 REC_DB_ENGINE=mariadb REC_WEB_SERVER=apache REC_COMPONENTS=server,frontend,agent REC_SIZING=medium REC_TZ="";
    OPT_DB=pgsql; resolve_plan; printf "%s" "$PLAN_DB_ENGINE"'
  [ "$output" = "pgsql" ]
}

@test "resolve_plan: --db mysql keeps an existing mysql-family engine" {
  rprobe 'REC_ZBX_VERSION=7.0 REC_DB_ENGINE=mariadb REC_WEB_SERVER=apache REC_COMPONENTS=agent REC_SIZING=small REC_TZ="";
    OPT_DB=mysql; resolve_plan; printf "%s" "$PLAN_DB_ENGINE"'
  [ "$output" = "mariadb" ]
}

@test "resolve_plan: --db mysql over a pgsql recommendation falls to mariadb" {
  rprobe 'REC_ZBX_VERSION=7.0 REC_DB_ENGINE=pgsql REC_WEB_SERVER=apache REC_COMPONENTS=agent REC_SIZING=small REC_TZ="";
    OPT_DB=mysql; resolve_plan; printf "%s" "$PLAN_DB_ENGINE"'
  [ "$output" = "mariadb" ]
}

@test "resolve_plan: version/web/components overrides apply verbatim" {
  rprobe 'REC_ZBX_VERSION=7.0 REC_DB_ENGINE=mariadb REC_WEB_SERVER=apache REC_COMPONENTS=server,frontend,agent REC_SIZING=medium REC_TZ="";
    OPT_ZBX_VERSION=7.4 OPT_WEB=nginx OPT_COMPONENTS=agent; resolve_plan;
    printf "%s %s %s" "$PLAN_ZBX_VERSION" "$PLAN_WEB_SERVER" "$PLAN_COMPONENTS"'
  [ "$output" = "7.4 nginx agent" ]
}

@test "resolve_plan: firewall opens by default only when one is active" {
  rprobe 'REC_ZBX_VERSION=7.0 REC_DB_ENGINE=mariadb REC_WEB_SERVER=apache REC_COMPONENTS=agent REC_SIZING=small REC_TZ="";
    DETECT_FIREWALL=firewalld; resolve_plan; printf "%s" "$PLAN_OPEN_FIREWALL";
    DETECT_FIREWALL=none; resolve_plan; printf " %s" "$PLAN_OPEN_FIREWALL"'
  [ "$output" = "yes no" ]
}

# --- plan_packages (§12.2) ----------------------------------------------------------------
@test "plan_packages: full stack on enforcing RHEL, nothing preinstalled" {
  rprobe 'DETECT_FAMILY=rhel DETECT_DB_PRESENT=none DETECT_WEB_PRESENT=none DETECT_SELINUX=enforcing;
    PLAN_COMPONENTS=server,frontend,agent PLAN_DB_ENGINE=mariadb PLAN_WEB_SERVER=apache;
    plan_packages; printf "%s" "$PLAN_PACKAGES"'
  [ "$output" = "zabbix-server-mysql zabbix-sql-scripts zabbix-frontend-php zabbix-apache-conf zabbix-agent2 zabbix-selinux-policy mariadb-server httpd" ]
}

@test "plan_packages: pgsql on RHEL adds postgresql-server" {
  rprobe 'DETECT_FAMILY=rhel DETECT_DB_PRESENT=none DETECT_WEB_PRESENT=none DETECT_SELINUX=absent;
    PLAN_COMPONENTS=server,agent PLAN_DB_ENGINE=pgsql PLAN_WEB_SERVER=apache;
    plan_packages; printf "%s" "$PLAN_PACKAGES"'
  [ "$output" = "zabbix-server-pgsql zabbix-sql-scripts zabbix-agent2 postgresql postgresql-server" ]
}

@test "plan_packages: agent-only is just the agent" {
  rprobe 'DETECT_FAMILY=debian DETECT_DB_PRESENT=none DETECT_WEB_PRESENT=none DETECT_SELINUX=absent;
    PLAN_COMPONENTS=agent PLAN_DB_ENGINE=mariadb PLAN_WEB_SERVER=apache;
    plan_packages; printf "%s" "$PLAN_PACKAGES"'
  [ "$output" = "zabbix-agent2" ]
}

@test "plan_packages: existing engine and web are not reinstalled" {
  rprobe 'DETECT_FAMILY=debian DETECT_DB_PRESENT=mariadb,mysql DETECT_WEB_PRESENT=apache DETECT_SELINUX=absent;
    PLAN_COMPONENTS=server,frontend,agent PLAN_DB_ENGINE=mariadb PLAN_WEB_SERVER=apache;
    plan_packages; printf "%s" "$PLAN_PACKAGES"'
  [ "$output" = "zabbix-server-mysql zabbix-sql-scripts zabbix-frontend-php zabbix-apache-conf zabbix-agent2" ]
}

@test "plan_packages: nginx frontend, agent2 plugins, tools" {
  rprobe 'DETECT_FAMILY=suse DETECT_DB_PRESENT=none DETECT_WEB_PRESENT=none DETECT_SELINUX=absent;
    PLAN_COMPONENTS=frontend,agent PLAN_DB_ENGINE=mariadb PLAN_WEB_SERVER=nginx;
    PLAN_AGENT_PLUGINS=postgresql,mssql PLAN_TOOLS=yes;
    plan_packages; printf "%s" "$PLAN_PACKAGES"'
  [ "$output" = "zabbix-frontend-php zabbix-nginx-conf zabbix-agent2 zabbix-agent2-plugin-postgresql zabbix-agent2-plugin-mssql zabbix-get zabbix-sender nginx" ]
}
