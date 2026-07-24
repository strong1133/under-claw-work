#!/usr/bin/env bash
set -euo pipefail

release="${1:-}"
install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
[[ -d "$release" && -f "$release/release-manifest.tsv" ]] || {
  echo "Usage: update.sh <extracted-release-directory>" >&2; exit 64;
}
[[ "$release" = /* && "$install_root" = /* ]] || {
  echo "Release and install roots must be absolute" >&2; exit 64;
}
case "$install_root" in /|"$HOME"|"${HOME}/"|"") echo "Unsafe install root" >&2; exit 64 ;; esac
installed_cli="$install_root/bin/worklog"
[[ -x "$installed_cli" ]] || installed_cli="$install_root/bin/worklog.exe"
[[ -x "$installed_cli" ]] || { echo "Existing installation not found" >&2; exit 66; }
bash "$release/packaging/verify-release.sh" "$release"

parent="$(dirname "$install_root")"
mkdir -p "$parent"
candidate="$(mktemp -d "$parent/.under-claw-update.XXXXXX")"
backup="$parent/.under-claw-backup.$$"
cleanup() {
  if [[ -d "$candidate" ]]; then rm -rf "$candidate"; fi
  return 0
}
trap cleanup EXIT
cp -R "$install_root/." "$candidate/"
cli_source="$release/build/cli/bundle/bin/worklog"
[[ -f "$cli_source" ]] || cli_source="$release/build/cli/bundle/bin/worklog.exe"
[[ -f "$cli_source" ]] || { echo "Release CLI is missing" >&2; exit 65; }
cli_name="$(basename "$cli_source")"
rm -f "$candidate/bin/worklog" "$candidate/bin/worklog.exe"
install -m 0755 "$cli_source" "$candidate/bin/$cli_name"
rm -rf "$candidate/lib"
[[ ! -d "$release/build/cli/bundle/lib" ]] ||
  cp -R "$release/build/cli/bundle/lib" "$candidate/lib"
for directory in app packaging bundled-skills skills; do
  rm -rf "$candidate/$directory"
  cp -RL "$release/$directory" "$candidate/$directory"
done
for file in UNSIGNED-NOTICE.txt ACCEPTED-RUNTIMES.txt RELEASE-VERSION.txt \
  README.txt release-manifest.tsv; do
  cp "$release/$file" "$candidate/$file"
done

health="${UNDER_CLAW_UPDATE_HEALTH_COMMAND:-\"$candidate/bin/$cli_name\" --help}"
if [[ ! -f "$candidate/app/.under-claw-app-health" ]] ||
  ! UNDER_CLAW_WORK_HOME="$candidate" sh -c "$health" >/dev/null 2>&1; then
  echo "Updated runtime failed health check; existing installation preserved" >&2
  exit 70
fi

mv "$install_root" "$backup"
if mv "$candidate" "$install_root"; then
  rm -rf "$backup"
  echo "Under Claw Work updated from an unsigned archive."
  echo "Manifest hashes provide integrity, not publisher authenticity."
else
  mv "$backup" "$install_root"
  echo "Update swap failed; previous installation restored" >&2
  exit 71
fi
