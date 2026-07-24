#!/usr/bin/env bash
# Font provenance / integrity gate.
#
# Re-computes the SHA-256 of every shipped font asset and compares it to the
# expected hash recorded in assets/fonts/PROVENANCE.md. Any mismatch, missing
# file, or missing manifest entry exits non-zero, so this can gate CI exactly
# like tool/secret_scan.sh and prove no font binary was swapped for an
# un-audited one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fonts_dir="$repo_root/assets/fonts"
manifest="$fonts_dir/PROVENANCE.md"

[[ -f "$manifest" ]] || { echo "Missing manifest: $manifest" >&2; exit 1; }

# The set of assets that must be audited and present.
files=(D2Coding.ttf D2Coding-Bold.ttf OFL.txt)

# Portable SHA-256: prefer shasum, fall back to sha256sum.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

status=0
for f in "${files[@]}"; do
  path="$fonts_dir/$f"
  if [[ ! -f "$path" ]]; then
    echo "MISSING  $f (declared in manifest but not on disk)" >&2
    status=1
    continue
  fi
  # Pull the expected hash from the manifest table row `| `<file>` | `<hash>` |`.
  expected="$(grep -E "\`$f\`" "$manifest" \
    | grep -oE '[0-9a-f]{64}' | head -n1 || true)"
  if [[ -z "$expected" ]]; then
    echo "NO-HASH  $f (no expected SHA-256 recorded in PROVENANCE.md)" >&2
    status=1
    continue
  fi
  actual="$(sha256_of "$path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "MISMATCH $f" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    status=1
  else
    echo "OK       $f  $actual"
  fi
done

if [[ "$status" -ne 0 ]]; then
  echo "Font provenance check FAILED." >&2
  exit 1
fi
echo "Font provenance check passed."
