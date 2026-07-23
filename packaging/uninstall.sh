#!/usr/bin/env bash
set -euo pipefail

install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
manifest="$install_root/install-manifest.tsv"
if [[ ! -f "$manifest" ]]; then
  echo "No Under Claw Work install manifest." >&2
  exit 66
fi

checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
tree_checksum() {
  find "$1" -type f ! -name .under-claw-work-owned -print0 |
    sort -z |
    xargs -0 shasum -a 256 |
    shasum -a 256 |
    awk '{print $1}'
}
is_registered_target() {
  local host="$1" target="$2"
  awk -F '\t' -v host="$host" -v target="$target" '
    $1 == "host_root" && $2 == host {
      root=$3
      if (index(target, root "/skills/") == 1 ||
          index(target, root "/commands/") == 1) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$manifest"
}

while IFS=$'\t' read -r kind host target expected_hash; do
  [[ "$kind" == "owned_skill" || "$kind" == "owned_command" ]] || continue
  is_registered_target "$host" "$target" || {
    echo "Unsafe manifest target: $target" >&2
    exit 65
  }
  if [[ "$kind" == "owned_skill" ]]; then
    [[ -f "$target/.under-claw-work-owned" ]] || {
      echo "Ownership marker missing: $target" >&2
      exit 73
    }
    [[ "$(tree_checksum "$target")" == "$expected_hash" ]] || {
      echo "Owned skill changed; refusing removal: $target" >&2
      exit 73
    }
    rm -rf "$target"
  else
    [[ -f "$target.under-claw-work-owned" ]] || {
      echo "Ownership marker missing: $target" >&2
      exit 73
    }
    [[ "$(checksum "$target")" == "$expected_hash" ]] || {
      echo "Owned command changed; refusing removal: $target" >&2
      exit 73
    }
    rm -f "$target" "$target.under-claw-work-owned"
  fi
done < "$manifest"

rm -f "$install_root/bin/worklog" "$manifest"
rm -rf "$install_root/lib"
rmdir "$install_root/bin" "$install_root" 2>/dev/null || true
echo "Under Claw Work-owned runtime, adapters and skills removed."
echo "Agent installations, repositories and user settings were preserved."
