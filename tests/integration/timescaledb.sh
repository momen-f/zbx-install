#!/usr/bin/env bash
# Full install inside a disposable Ubuntu 24.04 systemd container, also used by CI.
set -Eeuo pipefail
version="${1:-7.0}"
case "$version" in 7.0 | 8.0) ;; *) exit 2 ;; esac
trap 'rc=$?; if ((rc != 0)); then tail -n 100 /tmp/timescale-install.out /var/log/zbx-timescale.log /var/log/zabbix/zabbix_server.log 2>/dev/null || true; fi' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg postgresql-16
curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
  https://packagecloud.io/timescale/timescaledb/gpgkey -o /tmp/timescaledb.key
gpg --dearmor --yes -o /usr/share/keyrings/timescaledb.gpg /tmp/timescaledb.key
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ noble main' \
  >/etc/apt/sources.list.d/timescaledb.list
# Pin a release supported by both tested Zabbix versions; installation is the installer's job.
cat >/etc/apt/preferences.d/timescaledb <<'PINS'
Package: timescaledb-2-postgresql-16 timescaledb-2-loader-postgresql-16
Pin: version 2.29.2*
Pin-Priority: 1001
PINS
apt-get update -qq
systemctl enable --now postgresql
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'"
systemctl restart postgresql
if dpkg-query -W -f='${Status}' timescaledb-2-postgresql-16 2>/dev/null | grep -q 'install ok installed'; then exit 1; fi

cat >/tmp/timescale.conf <<'CONFIG'
MODE=custom
COMPONENTS=server,frontend,agent
DB_ENGINE=pgsql
TIMESCALEDB=yes
GENERATE_PASSWORDS=yes
ASSUME_YES=yes
CONFIG
# The 7.0 row exercises the default, rather than explicitly selecting it.
if [[ "$version" != 7.0 ]]; then printf 'ZBX_VERSION=%s\n' "$version" >>/tmp/timescale.conf; fi
chmod 600 /tmp/timescale.conf
bash dist/zbx-install.sh --config /tmp/timescale.conf --yes --no-color \
  --log-file /var/log/zbx-timescale.log >/tmp/timescale-install.out 2>&1
grep -q 'All checks passed' /tmp/timescale-install.out
zabbix_server --version | head -n 1 | grep -F "$version."
dpkg-query -W -f='${Status}\n' timescaledb-2-postgresql-16 | grep -qx 'install ok installed'
test "$(sudo -u postgres psql -X -d zabbix -tAc "SELECT extversion FROM pg_extension WHERE extname='timescaledb'")" = 2.29.2
# Buffer tuning is saved for the next restart, as reported by the installer.
test "$(sudo -u postgres psql -X -tAc "SELECT COUNT(*) FROM pg_file_settings WHERE name='shared_buffers' AND sourcefile LIKE '%/postgresql.auto.conf' AND setting IN ('128MB','512MB','1GB','2GB')")" = 1
libraries="$(sudo -u postgres psql -X -tAc 'SHOW shared_preload_libraries')"
[[ "$libraries" == *pg_stat_statements* && "$libraries" == *timescaledb* ]]
test "$(sudo -u zabbix psql -X -d zabbix -tAc "SELECT COUNT(*) FROM timescaledb_information.hypertables WHERE hypertable_name IN ('history','history_uint','trends','trends_uint')")" = 4
if [[ "$version" == 7.0 ]]; then
  test "$(sudo -u zabbix psql -X -d zabbix -tAc 'SELECT db_extension,compression_status,compress_older FROM config')" = 'timescaledb|1|7d'
else
  test "$(sudo -u zabbix psql -X -d zabbix -tAc "SELECT value_str FROM settings WHERE name='db_extension'")" = timescaledb
  test "$(sudo -u zabbix psql -X -d zabbix -tAc "SELECT value_int FROM settings WHERE name='compression_status'")" = 1
fi
sudo -u zabbix psql -X -v ON_ERROR_STOP=1 -d zabbix <<'SQL'
INSERT INTO history_uint (itemid,clock,value,ns)
  SELECT itemid,extract(epoch FROM now())::integer,42,0 FROM items LIMIT 1;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM history_uint WHERE value=42) THEN
    RAISE EXCEPTION 'history write was not readable';
  END IF;
END $$;
SQL
test "$(sudo -u zabbix psql -X -d zabbix -tAc "SELECT COUNT(*) FROM timescaledb_information.chunks WHERE hypertable_name='history_uint'")" -gt 0
systemctl is-active --quiet zabbix-server
ss -ltnH 'sport = :10051' | grep -q .
curl -fsSL http://127.0.0.1/zabbix/ -o /tmp/zabbix-frontend.html
grep -qi zabbix /tmp/zabbix-frontend.html
if grep -qi 'database error' /tmp/zabbix-frontend.html; then exit 1; fi
api="$(curl -fsS -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
  http://127.0.0.1/zabbix/api_jsonrpc.php)"
[[ "$api" == *'"result":"'"$version."* ]]
printf 'Zabbix %s + PostgreSQL 16 + TimescaleDB 2.29.2: hypertables, compression settings, writes and services passed\n' "$version"
