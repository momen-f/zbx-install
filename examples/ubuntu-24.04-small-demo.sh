#!/usr/bin/env bash
# Fresh Ubuntu 24.04 demo: 1GB RAM, at least 2GB swap, PostgreSQL, Nginx, Zabbix 7.0.
set -Eeuo pipefail
[[ $EUID == 0 ]] || {
  echo "Run with sudo bash." >&2
  exit 1
}
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || {
  echo "This recipe requires Ubuntu 24.04." >&2
  exit 1
}
[[ ! -e /etc/zabbix/zabbix_server.conf ]] || {
  echo "This recipe requires a fresh Zabbix installation." >&2
  exit 1
}

swap_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
if ((swap_kib < 2097000)); then
  swap_file=/swap-zabbix-demo
  [[ ! -e "$swap_file" && ! -L "$swap_file" ]] || {
    echo "$swap_file already exists; inspect it before continuing." >&2
    exit 1
  }
  install -m 600 /dev/null "$swap_file"
  fallocate -l 2G "$swap_file"
  mkswap "$swap_file"
  swapon "$swap_file"
  if ! awk '$1 == "/swap-zabbix-demo" {found=1} END {exit !found}' /etc/fstab; then
    printf '%s\n' '/swap-zabbix-demo none swap sw 0 0' >>/etc/fstab
  fi
fi

apt-get update -qq
apt-get install -y curl ca-certificates python3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base=https://github.com/momen-f/zbx-install/releases/download/v0.4.3
curl -fsSL "$base/zbx-install.sh" -o "$work/zbx-install.sh"
curl -fsSL "$base/SHA256SUMS" -o "$work/SHA256SUMS"
(cd "$work" && sha256sum -c SHA256SUMS)
bash "$work/zbx-install.sh" --express --zabbix-version 7.0 \
  --components server,frontend,agent --db pgsql --web nginx \
  --generate-passwords --admin-pass --no-update --yes

backup=$(mktemp -d /root/zabbix-demo-backup.XXXXXX)
cp -a /etc/zabbix/zabbix_server.conf "$backup/server.conf"
cp -aL /etc/zabbix/php-fpm.conf "$backup/php-fpm.conf"
pg_data=$(sudo -u postgres psql -XAtc 'SHOW data_directory')
cp -a "$pg_data/postgresql.auto.conf" "$backup/postgresql.auto.conf"
python3 - <<'PYTHON'
from pathlib import Path
import re
p=Path('/etc/zabbix/zabbix_server.conf').resolve()
settings={'CacheSize':'16M','ValueCacheSize':'16M','HistoryCacheSize':'8M',
          'StartPollers':'2','StartPreprocessors':'2','StartTrappers':'2',
          'StartDBSyncers':'2'}
lines=p.read_text().splitlines()
lines=[line for line in lines if not any(re.match(r'^\s*'+re.escape(key)+r'\s*=',line) for key in settings)]
p.write_text('\n'.join(lines)+'\n\n# Small demo: 1GB RAM, one user, a few hosts.\n'+''.join(f'{k}={v}\n' for k,v in settings.items()))
p=Path('/etc/zabbix/php-fpm.conf').resolve()
settings={'pm':'ondemand','pm.max_children':'2','pm.process_idle_timeout':'10s','pm.max_requests':'200'}
lines=p.read_text().splitlines()
lines=[line for line in lines if not any(re.match(r'^\s*'+re.escape(key)+r'\s*=',line) for key in settings)]
p.write_text('\n'.join(lines)+'\n'+''.join(f'{k} = {v}\n' for k,v in settings.items()))
PYTHON
sudo -u postgres psql -X -v ON_ERROR_STOP=1 <<'SQL'
ALTER SYSTEM SET shared_buffers = '128MB';
ALTER SYSTEM SET work_mem = '2MB';
ALTER SYSTEM SET maintenance_work_mem = '32MB';
ALTER SYSTEM SET autovacuum_work_mem = '16MB';
SQL
zabbix_server -T -c /etc/zabbix/zabbix_server.conf
php-fpm8.3 -t
systemctl stop zabbix-server
systemctl restart postgresql php8.3-fpm
systemctl start zabbix-server
systemctl is-active --quiet zabbix-server postgresql php8.3-fpm nginx zabbix-agent2
printf 'Configuration backup: %s\n' "$backup"
curl -fsS http://127.0.0.1/zabbix/ >/dev/null
free -m
printf '%s\n' 'Dashboard: http://YOUR_VPS_IP/zabbix/' 'Login: Admin (password in /root/zbx-install-credentials.txt)'
