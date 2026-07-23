#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli="$repo_root/build/cli/bundle/bin/worklog"
[[ -x "$cli" ]] || { echo "Build CLI first: dart build cli -o build/cli" >&2; exit 66; }

smoke_root="$(mktemp -d)"
cleanup() { rm -rf "$smoke_root"; }
trap cleanup EXIT
export HOME="$smoke_root/home"
mkdir -p "$HOME"

workspace="$smoke_root/workspace"
"$cli" initialize "$workspace" smoke >/dev/null
printf 'corrupt projection' > "$workspace/.worklog/projection.sqlite3"
"$cli" task-list "$workspace" >/dev/null

legacy="$smoke_root/legacy"
mkdir -p "$legacy"
printf '[완료] <PT-smoke>\n**요구사항**\nsmoke migration\n' > "$legacy/source.md"
import_output="$("$cli" migrate-import "$workspace" "$legacy" DOM-smoke MLS-smoke ENV-smoke --approve)"
import_id="$(printf '%s' "$import_output" | sed -n 's/^import=\([^ ]*\).*/\1/p')"
[[ -n "$import_id" ]] || { echo "Migration import id missing." >&2; exit 1; }
! grep -R -F "$legacy" "$workspace/.worklog/migrations"
"$cli" migrate-rollback "$workspace" "$import_id" >/dev/null

make_manifest() {
  local root="$1"
  mkdir -p "$root/bin" "$root/lib"
  cp "$cli" "$root/bin/worklog"
  printf 'runtime\n' > "$root/lib/runtime"
  {
    printf 'manifest_version\t2\n'
    printf 'install_root\t%s\n' "$root"
  } > "$root/install-manifest.tsv"
}

app_root="$smoke_root/app-install"
make_manifest "$app_root"
UNDER_CLAW_WORK_HOME="$app_root" "$repo_root/packaging/uninstall.sh" --mode app >/dev/null
[[ ! -e "$app_root/bin/worklog" && -e "$app_root/lib/runtime" ]]
UNDER_CLAW_WORK_HOME="$app_root" "$repo_root/packaging/uninstall.sh" --mode runtime >/dev/null
[[ ! -e "$app_root" ]]

runtime_root="$smoke_root/runtime-install"
make_manifest "$runtime_root"
UNDER_CLAW_WORK_HOME="$runtime_root" "$repo_root/packaging/uninstall.sh" --mode runtime >/dev/null
[[ ! -e "$runtime_root" ]]

clone="$smoke_root/owned-clone"
mkdir -p "$clone/.worklog"
printf '{"clone_owned":true}\n' > "$clone/.worklog/setup.json"
full_root="$smoke_root/full-install"
make_manifest "$full_root"
UNDER_CLAW_WORK_HOME="$full_root" "$repo_root/packaging/uninstall.sh" \
  --mode full --workspace "$clone" --confirm-full "$clone" >/dev/null
[[ ! -e "$clone" && ! -e "$full_root" ]]

echo "round5_smoke=ok"
