# zbx-install

Bare-OS-to-running-Zabbix installer for Linux, as a single Bash script.

```sh
curl -fsSL https://raw.githubusercontent.com/<org>/zbx-install/main/install.sh | bash
```

> **Status:** early development. Build proceeds phase by phase — see
> [SPEC.md](SPEC.md) §18. Phase 0 (scaffold, core, UI, build, CI) is in place.

## Development

```sh
make lint    # shellcheck src + bundled artifact
make fmt     # shfmt formatting check
make test    # bats unit tests
make build   # bundle src/ -> dist/zbx-install.sh
```

See [SPEC.md](SPEC.md) for the full specification, support matrix, and CLI.
