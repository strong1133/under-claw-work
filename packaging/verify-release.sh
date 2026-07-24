#!/usr/bin/env bash
set -euo pipefail

release="${1:-}"
[[ -n "$release" && "$release" = /* && -d "$release" ]] || {
  echo "Release directory must be an existing absolute path" >&2; exit 64;
}
manifest="$release/release-manifest.tsv"
[[ -f "$manifest" && ! -L "$manifest" ]] || {
  echo "Release manifest is missing or unsafe" >&2; exit 65;
}
if find "$release" -type l -print -quit | grep -q .; then
  echo "Release contains a symbolic link" >&2
  exit 65
fi

checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
listed="$(mktemp)"
cleanup() { rm -f "$listed"; }
trap cleanup EXIT
while IFS=$'\t' read -r expected_hash expected_size path extra; do
  [[ -n "$expected_hash" && "$expected_hash" =~ ^[0-9a-f]{64}$ &&
    "$expected_size" =~ ^[0-9]+$ && -n "$path" && -z "${extra:-}" ]] || {
      echo "Malformed release manifest" >&2; exit 65;
    }
  case "$path" in /*|*\\*|"") echo "Unsafe manifest path: $path" >&2; exit 65 ;; esac
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || {
      echo "Unsafe manifest path component: $path" >&2; exit 65;
    }
  done
  file="$release/$path"
  [[ -f "$file" && ! -L "$file" ]] || {
    echo "Unsafe or missing regular file: $path" >&2; exit 65;
  }
  [[ "$(wc -c < "$file" | tr -d '[:space:]')" == "$expected_size" ]] || {
    echo "Size mismatch: $path" >&2; exit 65;
  }
  [[ "$(checksum "$file")" == "$expected_hash" ]] || {
    echo "Checksum mismatch: $path" >&2; exit 65;
  }
  printf '%s\n' "$path" >> "$listed"
done < "$manifest"

LC_ALL=C sort "$listed" -o "$listed"
listed_count="$(wc -l < "$listed" | tr -d '[:space:]')"
unique_count="$(uniq "$listed" | wc -l | tr -d '[:space:]')"
[[ "$listed_count" == "$unique_count" ]] || {
    echo "Release manifest contains duplicate paths" >&2; exit 65;
  }
actual="$(cd "$release" && find . -type f ! -path './release-manifest.tsv' -print |
  sed 's#^\./##' | LC_ALL=C sort)"
[[ "$actual" == "$(cat "$listed")" ]] || {
  echo "Release manifest must cover every file exactly once" >&2
  exit 65
}
