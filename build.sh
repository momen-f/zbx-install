#!/usr/bin/env bash
# build.sh — bundle src/ into a single distributable dist/zbx-install.sh.
#
# Concatenates the libs in a fixed dependency order, strips per-file shebangs
# and every '# @dev-source' line, and prepends a header carrying the version
# and build date. Missing modules (not yet written in early phases) are skipped.
# SPEC §5 bundling rule.

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/zbx-install.sh"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_DATE="$(date +%Y-%m-%d)"

# Fixed concatenation order (core first, main last). SPEC §5.
ORDER=(
  lib/core.sh
  lib/ui.sh
  lib/detect.sh
  lib/recommend.sh
  lib/creds.sh
  lib/configfile.sh
  lib/repo.sh
  lib/pkg.sh
  lib/db_mysql.sh
  lib/db_pgsql.sh
  lib/config.sh
  lib/firewall.sh
  lib/services.sh
  lib/health.sh
  main.sh
)

mkdir -p "$OUT_DIR"

{
  printf '#!/usr/bin/env bash\n'
  printf '# zbx-install — bundled single-file build. DO NOT edit by hand.\n'
  printf '# version: %s   build: %s\n' "$VERSION" "$BUILD_DATE"
  printf 'ZBX_BUILD_VERSION="%s"\n' "$VERSION"
  printf 'ZBX_BUILD_DATE="%s"\n\n' "$BUILD_DATE"
} >"$OUT"

for rel in "${ORDER[@]}"; do
  file="$SRC/$rel"
  [[ -f "$file" ]] || continue
  {
    printf '# ===== %s =====\n' "$rel"
    # Drop a leading shebang line and all dev-source lines.
    awk 'NR==1 && /^#!/ {next} /# @dev-source/ {next} {print}' "$file"
    printf '\n'
  } >>"$OUT"
done

chmod +x "$OUT"
printf 'Built %s (version %s, %s)\n' "$OUT" "$VERSION" "$BUILD_DATE"
