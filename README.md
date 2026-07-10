# zbx-install

[![Latest release](https://img.shields.io/github/v/release/momen-f/zbx-install)](https://github.com/momen-f/zbx-install/releases/latest)

A single Bash script that takes a bare Linux server to a fully running,
verified [Zabbix](https://www.zabbix.com/) stack — interactively or fully
unattended.

```sh
curl -fsSL https://raw.githubusercontent.com/momen-f/zbx-install/main/install.sh | bash
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

Offers Zabbix `7.0` (LTS, default) and `7.4` (current stable). Full detail
in [SPEC.md](SPEC.md) §4.

## Other ways to run it

```sh
# Track the unreleased main branch instead of the latest release
# (unchecksummed — for development only):
curl -fsSL https://raw.githubusercontent.com/momen-f/zbx-install/main/install.sh | bash -s -- --dev

# Download a release and run it directly, no bootstrap:
curl -fsSLO https://github.com/momen-f/zbx-install/releases/latest/download/zbx-install.sh
chmod +x zbx-install.sh
./zbx-install.sh
```

## Development

```sh
make lint    # shellcheck src + bootstrap + bundled artifact
make fmt     # shfmt formatting check
make test    # bats unit tests
make build   # bundle src/ -> dist/zbx-install.sh
```

See [SPEC.md](SPEC.md) for the full specification.
