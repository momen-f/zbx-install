#!/usr/bin/env bash
# Exercise a real restart after database provisioning, before config writes.
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' dist/zbx-install.sh)
config_apply() { return 1; }
main "$@"
