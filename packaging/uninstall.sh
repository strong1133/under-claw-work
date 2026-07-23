#!/usr/bin/env bash
set -euo pipefail

install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
manifest="$install_root/install-manifest.tsv"
if [[ ! -f "$manifest" ]]; then
  echo "No Under Claw Work install manifest." >&2
  exit 66
fi
hermes_root="$(awk -F '\t' '$1 == "hermes_root" {print $2}' "$manifest")"
skill_root="$hermes_root/skills"
[[ -n "$hermes_root" && "$hermes_root" != "/" && "$hermes_root" != "$HOME" ]] || {
  echo "Unsafe Hermes root in manifest" >&2
  exit 65
}
tree_checksum() {
  find "$1" -type f ! -name .under-claw-work-owned -print0 |
    sort -z |
    xargs -0 shasum -a 256 |
    shasum -a 256 |
    awk '{print $1}'
}

while IFS=$'\t' read -r kind target expected_hash; do
  [[ "$kind" == "owned_skill" ]] || continue
  target_parent="$(cd "$(dirname "$target")" && pwd -P)"
  [[ "$target_parent" == "$(cd "$skill_root" && pwd -P)" ]] || {
    echo "Unsafe manifest target: $target" >&2
    exit 65
  }
  case "$(basename "$target")" in under-claw-*) ;; *) exit 65 ;; esac
  if [[ ! -f "$target/.under-claw-work-owned" ]]; then
    echo "Ownership marker missing: $target" >&2
    exit 73
  fi
  [[ "$(tree_checksum "$target")" == "$expected_hash" ]] || {
    echo "Owned skill changed after install; refusing removal: $target" >&2
    exit 73
  }
  rm -rf "$target"
done < "$manifest"

rm -f "$install_root/bin/worklog" "$manifest"
rm -rf "$install_root/lib"
rmdir "$install_root/bin" "$install_root" 2>/dev/null || true
echo "Installer-owned runtime and skills removed; repositories were preserved."
