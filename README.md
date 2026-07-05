# zbx-install

Bare-OS-to-running-Zabbix installer for Linux, as a single Bash script.

```sh
curl -fsSL https://raw.githubusercontent.com/<org>/zbx-install/main/install.sh | bash
```

> **Status:** early development. Build proceeds phase by phase — see
> [SPEC.md](SPEC.md) §18. Done: Phase 0 (scaffold, core, UI, build, CI),
> Phase 1 (detection, `--detect-only`), Phase 2 (recommendation engine, modes,
> plan summary, confirm), Phase 3 (repo setup + real package install),
> Phase 4 (credentials + MySQL/MariaDB and PostgreSQL provisioning + schema
> import), Phase 5 (config rendering, firewall/SELinux, service start),
> Phase 6 (post-install health checks + summary) — `--express --yes` now
> takes a bare OS all the way to a running, verified Zabbix stack.
> Unattended config files (`--config`), `--uninstall`, and resume still land
> in Phase 7.

## Development

```sh
make lint    # shellcheck src + bundled artifact
make fmt     # shfmt formatting check
make test    # bats unit tests
make build   # bundle src/ -> dist/zbx-install.sh
```

See [SPEC.md](SPEC.md) for the full specification, support matrix, and CLI.
