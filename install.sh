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

# verify_sha256 DIR SUMSFILE — GNU coreutils has sha256sum; stock macOS ships
# only shasum (perl). Both accept the same "HASH  FILE" SHA256SUMS format.
verify_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$1" && sha256sum -c "$2")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$1" && shasum -a 256 -c "$2")
  else
    printf 'Neither sha256sum nor shasum found: cannot verify the download.\n' >&2
    return 1
  fi
}

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
  verify_sha256 "$tmp" SHA256SUMS
fi

chmod +x "$tmp/zbx-install.sh"

# The installer proper needs bash >= 4 (§3). macOS ships 3.2 at /bin/bash, so if
# this bootstrap is running under an old bash, hand off to a newer one (Homebrew
# installs one). On Darwin with no modern bash anywhere, stop with exact
# instructions now — clearer than letting the bundle's version guard fire.
# ZBX_BOOTSTRAP_BASH_MAJOR is a test seam (bats runs under bash >= 4, so the
# old-bash branch is unreachable without it), mirroring detect.sh's ZBX_UNAME_S.
sh_bin="bash"
if [[ "${ZBX_BOOTSTRAP_BASH_MAJOR:-${BASH_VERSINFO:-0}}" -lt 4 ]]; then
  # If brew is missing its candidate degenerates to "/bin/bash" (3.2), so each
  # candidate must also prove it really is bash >= 4 before we hand off to it.
  for cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$(brew --prefix 2>/dev/null || true)/bin/bash"; do
    if [[ -x "$cand" ]] && "$cand" -c '((BASH_VERSINFO >= 4))' 2>/dev/null; then
      sh_bin="$cand"
      break
    fi
  done
  if [[ "$sh_bin" == "bash" && "$(uname -s)" == "Darwin" ]]; then
    printf 'This installer needs bash >= 4; macOS ships 3.2.\n' >&2
    printf 'Install a modern bash first:  brew install bash\n' >&2
    printf '(no Homebrew? https://brew.sh) then re-run this one-liner.\n' >&2
    exit 3
  fi
fi
exec "$sh_bin" "$tmp/zbx-install.sh" ${args[@]+"${args[@]}"}
