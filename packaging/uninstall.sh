#!/usr/bin/env bash
set -euo pipefail

install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
manifest="$install_root/install-manifest.tsv"
mode="runtime"
workspace=""
confirmation=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --workspace) workspace="${2:-}"; shift 2 ;;
    --confirm-full) confirmation="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done
case "$mode" in app|runtime|full) ;; *) echo "Mode must be app, runtime or full." >&2; exit 64 ;; esac
if [[ ! -f "$manifest" ]]; then
  echo "No Under Claw Work install manifest." >&2
  exit 66
fi
case "$install_root" in "$HOME"|"${HOME}/"|"/"|"") echo "Unsafe install root" >&2; exit 65 ;; esac

checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
tree_checksum() {
  local listing
  listing="$(find "$1" -type f ! -name .under-claw-work-owned -print0 |
    sort -z |
    while IFS= read -r -d '' file; do checksum "$file"; done)"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$listing" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$listing" | sha256sum | awk '{print $1}'
  fi
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

remove_owned_host_files() {
  local include_skills="$1"
  while IFS=$'\t' read -r kind host target expected_hash; do
    [[ "$kind" == "owned_command" || ( "$include_skills" == "true" && "$kind" == "owned_skill" ) ]] || continue
    is_registered_target "$host" "$target" || {
      echo "Unsafe manifest target: $target" >&2
      exit 65
    }
    if [[ "$kind" == "owned_skill" ]]; then
      [[ -f "$target/.under-claw-work-owned" ]] || { echo "Ownership marker missing: $target" >&2; exit 73; }
      [[ "$(tree_checksum "$target")" == "$expected_hash" ]] || { echo "Owned skill changed; refusing removal: $target" >&2; exit 73; }
      rm -rf "$target"
    else
      [[ -f "$target.under-claw-work-owned" ]] || { echo "Ownership marker missing: $target" >&2; exit 73; }
      [[ "$(checksum "$target")" == "$expected_hash" ]] || { echo "Owned command changed; refusing removal: $target" >&2; exit 73; }
      rm -f "$target" "$target.under-claw-work-owned"
    fi
  done < "$manifest"
}

if [[ "$mode" == "app" ]]; then
  remove_owned_host_files false
  rm -f "$install_root/bin/worklog" "$install_root/bin/worklog.exe"
  filtered_manifest="$manifest.app-only"
  awk -F '\t' '$1 != "owned_command" { print }' "$manifest" > "$filtered_manifest"
  mv "$filtered_manifest" "$manifest"
  echo "App launchers and command adapters removed; runtime skills and user data preserved."
  exit 0
fi

remove_owned_host_files true
rm -f "$install_root/bin/worklog" "$install_root/bin/worklog.exe"
rm -rf "$install_root/lib"

if [[ "$mode" == "full" ]]; then
  [[ -n "$workspace" ]] || { echo "Full removal requires --workspace <absolute-path>." >&2; exit 64; }
  [[ "$workspace" = /* && "$confirmation" == "$workspace" ]] || {
    echo "Full removal requires --confirm-full with the exact absolute workspace path: $workspace" >&2
    exit 64
  }
  case "$workspace" in "$HOME"|"${HOME}/"|"/"|"$install_root"|"") echo "Unsafe workspace path" >&2; exit 65 ;; esac
  setup_marker="$workspace/.worklog/setup.json"
  [[ -f "$setup_marker" ]] || { echo "Workspace setup marker not found; refusing deletion." >&2; exit 73; }
  if ! grep -Eq '"clone_owned"[[:space:]]*:[[:space:]]*true' "$setup_marker"; then
    echo "Workspace was adopted, not cloned by Under Claw Work; canonical files preserved." >&2
    rm -rf "$workspace/.worklog"
  else
    rm -rf "$workspace"
  fi
fi

rm -f "$manifest"
rmdir "$install_root/bin" "$install_root" 2>/dev/null || true
echo "Under Claw Work $mode removal completed."
echo "Remote repositories and Agent installations were preserved."
