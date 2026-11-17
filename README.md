# zbx-install

[![Latest release](https://img.shields.io/github/v/release/momen-f/zbx-install)](https://github.com/momen-f/zbx-install/releases/latest)

A single Bash script that takes a bare Linux server to a fully running,
verified [Zabbix](https://www.zabbix.com/) stack — interactively or fully
unattended. Agents install on macOS too, and on Windows via a native
PowerShell one-liner.

```sh
# Linux and macOS:
curl -fsSL https://raw.githubusercontent.com/momen-f/zbx-install/main/install.sh | bash
```

```powershell
# Windows (elevated PowerShell) — agent only:
irm https://github.com/momen-f/zbx-install/releases/latest/download/install.ps1 | iex
```

It detects your OS, recommends a stack (Zabbix version, database, web
server, sizing), and prints a plan for you to confirm — nothing is installed
before you approve it. Then it adds the Zabbix repo, installs packages,
provisions the database and imports the schema, renders configs, opens the
firewall, starts services, and runs 9 post-install health checks.

## What it installs

- Zabbix server + frontend + agent, or agent-only for monitored hosts
- A standalone Zabbix proxy (`--proxy-only`), SQLite3 or MySQL/MariaDB backed
- MariaDB (default), MySQL, or PostgreSQL (+ optional TimescaleDB), schema
  imported automatically
- Apache or Nginx, pre-configured to skip the setup wizard
- firewalld/ufw rules and RHEL SELinux booleans, opened for you
- Optionally, a changed frontend Admin password instead of the `zabbix`
  default (`--admin-pass`)
- A final report: frontend URL, login status, config/log paths, and an
  uninstall one-liner

## Modes

| Mode | What it does |
|---|---|
| *(none)* | interactive menu: express / custom / agent-only / proxy-only |
| `--express` | accept the recommended stack, minimal prompts |
| `--agent-only` | install and configure only the agent |
| `--proxy-only` | install a standalone Zabbix proxy (`--db sqlite3` or mysql) |
| `--config FILE` | fully unattended, answers read from `FILE` |
| `--detect-only` | print the environment report and exit |
| `--uninstall` | remove Zabbix (asks about data/config retention) |

Every prompt has a flag or config-file equivalent, so any run can be made
unattended with `--yes`. Run `zbx-install.sh --help` for the full flag list,
or see [SPEC.md](SPEC.md) §7 (CLI) and Appendix A (`--config` file format).

## Support matrix

| Family | Versions | Package manager |
|---|---|---|
| Debian | 12, 13 | apt |
| Ubuntu | 22.04, 24.04 | apt |
| RHEL-like (RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux) | 8, 9 | dnf |
| Amazon Linux | 2023 | dnf |
| SUSE (SLES, openSUSE Leap) | SLES 15 SP5+, Leap 15.6 | zypper |
| macOS (Apple Silicon) | agent only (7.0 / 7.4) | .pkg |
| Windows (10 / Server 2016+) | agent only (7.0 / 7.4), via `install.ps1` | MSI |

The Bash installer offers Zabbix `7.0` (LTS, default), `7.4`, and `8.0` (LTS).
Select 8.0 with `--zabbix-version 8.0`; the default remains 7.0. Full detail
in [SPEC.md](SPEC.md) §4.

### TimescaleDB

For PostgreSQL, enable TimescaleDB in custom mode or set `TIMESCALEDB=yes`
in an unattended config. Configure the TimescaleDB repository first, with
a release supported by your Zabbix version; the installer does not add this
third-party repository. It selects a package for the running PostgreSQL major,
preserves other preloaded extensions, restarts PostgreSQL when needed, and
imports Zabbix's TimescaleDB schema. Setup failures stop database provisioning.

CI tests Ubuntu 24.04 with PostgreSQL 16 and TimescaleDB 2.29.2 against both
the default Zabbix 7.0 and opt-in 8.0, including hypertables, compression settings,
history writes, and the running server/frontend. See
[Zabbix's TimescaleDB requirements](https://www.zabbix.com/documentation/7.0/en/manual/installation/requirements#database-management-system)
when choosing a repository version.

## Other ways to run it

### Small Ubuntu 24.04 demo

For a fresh Ubuntu 24.04 VPS with 1GB RAM, the
[small-demo recipe](examples/ubuntu-24.04-small-demo.sh) adds a persistent 2GB
swap file when needed, installs Zabbix 7.0 with PostgreSQL and Nginx, and reduces
server caches, worker counts, and PHP's simultaneous requests. It generates
database and Admin passwords and saves backups before tuning. Existing swap
is retained; an existing Zabbix server installation is refused.

This is for one user and a few monitored hosts. Other applications on the VPS
consume the same limited memory; swap does not replace RAM for a busy server.
The installer default remains 7.0.

```sh
curl -fsSL https://raw.githubusercontent.com/momen-f/zbx-install/v0.4.3/examples/ubuntu-24.04-small-demo.sh -o /tmp/zabbix-demo.sh
sudo bash /tmp/zabbix-demo.sh
```

Open `http://YOUR_VPS_IP/zabbix/` and use `Admin` with the generated password
in `/root/zbx-install-credentials.txt`. Use an SSH tunnel or HTTPS for remote
login rather than sending that password over public HTTP.

### Development and direct downloads

```sh
# Track the unreleased main branch instead of the latest release
# (unchecksummed — for development only):
curl -fsSL https://raw.githubusercontent.com/momen-f/zbx-install/main/install.sh | bash -s -- --dev

# Download a release and run it directly, no bootstrap:
curl -fsSLO https://github.com/momen-f/zbx-install/releases/latest/download/zbx-install.sh
chmod +x zbx-install.sh
./zbx-install.sh
```

### Windows agent (`install.ps1`)

`iex` can't forward parameters — to pass any, wrap the download in a
scriptblock (or download the file first and run it):

```powershell
& ([scriptblock]::Create((irm https://github.com/momen-f/zbx-install/releases/latest/download/install.ps1))) -Server 192.0.2.10 -Yes
```

| Parameter | What it does |
|---|---|
| `-Server IP` | Zabbix server the agent reports to (default `127.0.0.1`) |
| `-ZbxVersion 7.0\|7.4` | Zabbix major version (default `7.0` LTS) |
| `-Agent2` | install Zabbix agent 2 instead of the classic `zabbix_agentd` |
| `-Uninstall` | remove a previously installed agent |
| `-Yes` | skip the confirmation prompt |
| `-DryRun` | print the plan and every action without changing anything |

The MSI comes straight from `cdn.zabbix.com` and is refused unless its
Authenticode signature is valid and issued to Zabbix.

## Development

```sh
make lint    # shellcheck src + bootstrap + bundled artifact
make fmt     # shfmt formatting check
make test    # bats unit tests
make build   # bundle src/ -> dist/zbx-install.sh
```

See [SPEC.md](SPEC.md) for the full specification.

### Resuming a partial Linux installation

Repeat the original installation command, adding `--resume` to skip the
resume prompt. Unattended runs resume automatically. The installer saves the
confirmed plan and generated DB/Admin passwords in
`/var/lib/zbx-install/state.plan` (owner-only mode `0600`) before changing the
host. This private recovery copy is separate from `--creds-file`, including
when that option is `none`; do not share it or include it in support logs.
Changed versions, components, database choices or supplied credentials are
rejected rather than applied to completed steps. Uninstall or an interactive
“start fresh” clears the recovery copy. Old progress files without this
metadata cannot be resumed automatically; inspect the existing installation
and recover its credentials before choosing a fresh run.
