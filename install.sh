#!/usr/bin/env bash
# install.sh — tiny bootstrap, safe to pipe: curl -fsSL .../install.sh | bash
#
# Does exactly the four things SPEC §6 asks of it, nothing more (kept
# trivial enough to audit at a glance before you pipe it into a shell):
#   1. curl | bash consumes stdin — reattach /dev/tty if one exists.
#   2. If there's truly no terminal, only an explicit non-interactive mode
#      (--config/--express/--agent-only/--uninstall/--detect-only) plus
#      --yes may proceed; anything else would hang on a prompt forever, so
#      bail out now instead.
#   3. Fetch the latest GitHub Release build (default), or build from the
#      unreleased main branch unchecksummed (--dev — dist/ isn't tracked in
#      git, so main is built locally from source, not fetched pre-built).
#   4. Verify the checksum (release channel only) and re-exec with the
#      original arguments.
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO="momen-f/zbx-install"

# 1.
if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
  exec </dev/tty
fi

# 2.
if [[ ! -t 0 ]]; then
  unattended=0 has_yes=0
  for a in "$@"; do
    case "$a" in
      --config | --express | --agent-only | --uninstall | --detect-only) unattended=1 ;;
      --yes) has_yes=1 ;;
    esac
  done
  if [[ "$unattended" != "1" || "$has_yes" != "1" ]]; then
    printf 'No terminal available: re-run with --yes plus one of --config FILE, --express, --agent-only, --uninstall, --detect-only.\n' >&2
    exit 2
  fi
fi

dev=0
args=()
for a in "$@"; do
  if [[ "$a" == "--dev" ]]; then
    dev=1
  else
    args+=("$a")
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 3. + 4.
if [[ "$dev" == "1" ]]; then
  printf 'Warning: --dev builds the unreleased main branch, unchecksummed. Do not use this in production.\n' >&2
  curl -fsSL -o "$tmp/main.tar.gz" "https://codeload.github.com/$REPO/tar.gz/refs/heads/main"
  tar -xzf "$tmp/main.tar.gz" -C "$tmp"
  (cd "$tmp/${REPO#*/}-main" && ./build.sh)
  cp "$tmp/${REPO#*/}-main/dist/zbx-install.sh" "$tmp/zbx-install.sh"
else
  base="https://github.com/$REPO/releases/latest/download"
  curl -fsSL -o "$tmp/zbx-install.sh" "$base/zbx-install.sh"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
  (cd "$tmp" && sha256sum -c SHA256SUMS)
fi

chmod +x "$tmp/zbx-install.sh"
exec bash "$tmp/zbx-install.sh" ${args[@]+"${args[@]}"}
