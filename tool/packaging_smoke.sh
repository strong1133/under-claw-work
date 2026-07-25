#!/usr/bin/env bash
set -euo pipefail

release="${1:-}"
[[ -d "$release" ]] || {
  echo "Usage: packaging_smoke.sh <extracted-release-directory>" >&2; exit 64;
}
release="$(cd "$release" && pwd)"
temp="$(mktemp -d)"
cleanup() { rm -rf "$temp"; }
trap cleanup EXIT
export HOME="$temp/home"
export XDG_DATA_HOME="$temp/data"
export UNDER_CLAW_WORK_HOME="$temp/install"
export UNDER_CLAW_HOSTS=none
mkdir -p "$HOME"

refresh_manifest() {
  local target="$1"
  (
    cd "$target"
    find . -type f ! -path './release-manifest.tsv' -print |
      LC_ALL=C sort |
      while IFS= read -r path; do
        clean="${path#./}"
        if command -v shasum >/dev/null 2>&1; then
          hash="$(shasum -a 256 "$clean" | awk '{print $1}')"
        else
          hash="$(sha256sum "$clean" | awk '{print $1}')"
        fi
        printf '%s\t%s\t%s\n' "$hash" \
          "$(wc -c < "$clean" | tr -d '[:space:]')" "$clean"
      done > release-manifest.tsv
  )
}
tree_state() {
  local target="$1"
  if command -v shasum >/dev/null 2>&1; then
    find "$target" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
  else
    find "$target" -type f -exec sha256sum {} \; | LC_ALL=C sort
  fi
}
manifest_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1/release-manifest.tsv" | awk '{print $1}'
  else
    sha256sum "$1/release-manifest.tsv" | awk '{print $1}'
  fi
}

missing_manifest="$temp/missing-manifest"
cp -R "$release" "$missing_manifest"
rm "$missing_manifest/release-manifest.tsv"
if bash "$missing_manifest/packaging/install.sh" "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then
  echo "Packaged installation without a manifest was accepted" >&2
  exit 1
fi
[[ ! -e "$UNDER_CLAW_WORK_HOME" ]]

missing_marker="$temp/missing-marker"
cp -R "$release" "$missing_marker"
rm "$missing_marker/app/.under-claw-app-health"
refresh_manifest "$missing_marker"
if bash "$missing_marker/packaging/install.sh" "$(manifest_digest "$missing_marker")" >/dev/null 2>&1; then
  echo "Initial install without app health marker was accepted" >&2
  exit 1
fi
[[ ! -e "$UNDER_CLAW_WORK_HOME" ]]

corrupt_initial="$temp/corrupt-initial"
cp -R "$release" "$corrupt_initial"
printf 'corrupt\n' >> "$corrupt_initial/UNSIGNED-NOTICE.txt"
if bash "$corrupt_initial/packaging/install.sh" "$(manifest_digest "$release")" >/dev/null 2>&1; then
  echo "Corrupt initial installation was accepted" >&2
  exit 1
fi
[[ ! -e "$UNDER_CLAW_WORK_HOME/bin/worklog" ]]

# A host ownership collision must be discovered before touching install_root.
export UNDER_CLAW_HOSTS=codex
export CODEX_HOME="$temp/preflight-codex"
export UNDER_CLAW_WORK_HOME="$temp/preflight-install"
mkdir -p "$CODEX_HOME/skills/under-claw-meta-prompt" "$UNDER_CLAW_WORK_HOME"
printf 'user owned\n' > "$CODEX_HOME/skills/under-claw-meta-prompt/SKILL.md"
printf 'unchanged\n' > "$UNDER_CLAW_WORK_HOME/sentinel.txt"
if command -v shasum >/dev/null 2>&1; then
  before_preflight="$(find "$UNDER_CLAW_WORK_HOME" -type f \
    -exec shasum -a 256 {} \; | LC_ALL=C sort)"
else
  before_preflight="$(find "$UNDER_CLAW_WORK_HOME" -type f \
    -exec sha256sum {} \; | LC_ALL=C sort)"
fi
if bash "$release/packaging/install.sh" "$(manifest_digest "$release")" >/dev/null 2>&1; then
  echo "Ownership collision was accepted" >&2
  exit 1
fi
if command -v shasum >/dev/null 2>&1; then
  after_preflight="$(find "$UNDER_CLAW_WORK_HOME" -type f \
    -exec shasum -a 256 {} \; | LC_ALL=C sort)"
else
  after_preflight="$(find "$UNDER_CLAW_WORK_HOME" -type f \
    -exec sha256sum {} \; | LC_ALL=C sort)"
fi
[[ "$before_preflight" == "$after_preflight" ]]

# Claude command destinations and ownership markers must never be symlinks,
# including dangling links that `test -e` does not see.
export UNDER_CLAW_HOSTS=claude-code
export CLAUDE_HOME="$temp/preflight-claude"
export UNDER_CLAW_WORK_HOME="$temp/preflight-claude-install"
external_command="$temp/external-command.md"
command_target="$CLAUDE_HOME/commands/under-claw-meta-prompt.md"
mkdir -p "$(dirname "$command_target")" "$UNDER_CLAW_WORK_HOME"
ln -s "$external_command" "$command_target"
touch "$command_target.under-claw-work-owned"
printf 'unchanged\n' > "$UNDER_CLAW_WORK_HOME/sentinel.txt"
if bash "$release/packaging/install.sh" "$(manifest_digest "$release")" >/dev/null 2>&1; then
  echo "Claude command destination symlink was accepted" >&2
  exit 1
fi
[[ ! -e "$external_command" ]]
[[ "$(cat "$UNDER_CLAW_WORK_HOME/sentinel.txt")" == unchanged ]]

export CLAUDE_HOME="$temp/preflight-claude-root-link"
export UNDER_CLAW_WORK_HOME="$temp/preflight-claude-root-install"
external_command_root="$temp/external-command-root"
mkdir -p "$CLAUDE_HOME" "$external_command_root" "$UNDER_CLAW_WORK_HOME"
ln -s "$external_command_root" "$CLAUDE_HOME/commands"
printf 'unchanged\n' > "$UNDER_CLAW_WORK_HOME/sentinel.txt"
if bash "$release/packaging/install.sh" "$(manifest_digest "$release")" >/dev/null 2>&1; then
  echo "Claude command-root symlink was accepted" >&2
  exit 1
fi
[[ -z "$(find "$external_command_root" -mindepth 1 -print -quit)" ]]
[[ "$(cat "$UNDER_CLAW_WORK_HOME/sentinel.txt")" == unchanged ]]

export UNDER_CLAW_HOSTS=none
export UNDER_CLAW_WORK_HOME="$temp/install"
bash "$release/packaging/install.sh" "$(manifest_digest "$release")"
cli="$UNDER_CLAW_WORK_HOME/bin/worklog"
[[ -x "$cli" ]] || cli="$UNDER_CLAW_WORK_HOME/bin/worklog.exe"
[[ -x "$cli" ]]
[[ -f "$UNDER_CLAW_WORK_HOME/app/.under-claw-app-health" ]]
[[ -f "$UNDER_CLAW_WORK_HOME/ACCEPTED-RUNTIMES.txt" ]]
[[ "$(cat "$UNDER_CLAW_WORK_HOME/SOURCE-REVISION.txt")" == \
  "$(cat "$release/SOURCE-REVISION.txt")" ]]
grep -q 'descriptors bundled.*: 0' "$UNDER_CLAW_WORK_HOME/ACCEPTED-RUNTIMES.txt"
if command -v shasum >/dev/null 2>&1; then
  app_hash_before="$(shasum -a 256 \
    "$UNDER_CLAW_WORK_HOME/app/.under-claw-app-health" | awk '{print $1}')"
else
  app_hash_before="$(sha256sum \
    "$UNDER_CLAW_WORK_HOME/app/.under-claw-app-health" | awk '{print $1}')"
fi
printf 'preserve\n' > "$UNDER_CLAW_WORK_HOME/user-owned.txt"

bad_cli="$temp/bad-cli"
cp -R "$release" "$bad_cli"
bad_cli_path="$bad_cli/build/cli/bundle/bin/worklog"
[[ -f "$bad_cli_path" ]] || bad_cli_path="$bad_cli/build/cli/bundle/bin/worklog.exe"
printf '#!/usr/bin/env sh\nexit 1\n' > "$bad_cli_path"
chmod +x "$bad_cli_path"
refresh_manifest "$bad_cli"
before_bad_reinstall="$(tree_state "$UNDER_CLAW_WORK_HOME")"
if bash "$bad_cli/packaging/install.sh" "$(manifest_digest "$bad_cli")" >/dev/null 2>&1; then
  echo "Reinstall with unhealthy CLI was accepted" >&2
  exit 1
fi
after_bad_reinstall="$(tree_state "$UNDER_CLAW_WORK_HOME")"
[[ "$before_bad_reinstall" == "$after_bad_reinstall" ]]
[[ "$(cat "$UNDER_CLAW_WORK_HOME/user-owned.txt")" == preserve ]]

workspace="$temp/workspace"
"$cli" init "$workspace" >/dev/null
[[ -z "$("$cli" runtime-list "$workspace")" ]]

updated="$temp/updated"
cp -R "$release" "$updated"
printf '%s\n' 'smoke-v2' > "$updated/RELEASE-VERSION.txt"
printf '%s\n' 'smoke-v2' > "$updated/app/.under-claw-app-health"
printf '%s\n' 'skill payload v2' \
  > "$updated/bundled-skills/upstream/SMOKE-VERSION.txt"
printf '%s\n' 'packaging payload v2' > "$updated/packaging/SMOKE-VERSION.txt"
verifier_marker="$temp/candidate-verifier-executed"
printf '%s\n' '#!/usr/bin/env bash' "touch '$verifier_marker'" \
  "exec bash '$release/packaging/verify-release.sh' \"\$@\"" \
  > "$updated/packaging/verify-release.sh"
chmod 0755 "$updated/packaging/verify-release.sh"
refresh_manifest "$updated"

bash "$UNDER_CLAW_WORK_HOME/packaging/update.sh" "$updated" "$(manifest_digest "$updated")"
[[ ! -e "$verifier_marker" ]] || {
  echo "Candidate verifier executed before installation" >&2
  exit 1
}
[[ "$(cat "$UNDER_CLAW_WORK_HOME/user-owned.txt")" == preserve ]]
[[ "$(cat "$UNDER_CLAW_WORK_HOME/RELEASE-VERSION.txt")" == smoke-v2 ]]
[[ "$(cat "$UNDER_CLAW_WORK_HOME/app/.under-claw-app-health")" == smoke-v2 ]]
if command -v shasum >/dev/null 2>&1; then
  app_hash_after="$(shasum -a 256 \
    "$UNDER_CLAW_WORK_HOME/app/.under-claw-app-health" | awk '{print $1}')"
else
  app_hash_after="$(sha256sum \
    "$UNDER_CLAW_WORK_HOME/app/.under-claw-app-health" | awk '{print $1}')"
fi
[[ "$app_hash_before" != "$app_hash_after" ]]
[[ -f "$UNDER_CLAW_WORK_HOME/bundled-skills/upstream/SMOKE-VERSION.txt" ]]
[[ -f "$UNDER_CLAW_WORK_HOME/packaging/SMOKE-VERSION.txt" ]]

bash "$UNDER_CLAW_WORK_HOME/packaging/rollback.sh"
[[ "$(cat "$UNDER_CLAW_WORK_HOME/RELEASE-VERSION.txt")" != smoke-v2 ]]
bash "$UNDER_CLAW_WORK_HOME/packaging/rollback.sh"
[[ "$(cat "$UNDER_CLAW_WORK_HOME/RELEASE-VERSION.txt")" == smoke-v2 ]]

update_lock="$(dirname "$UNDER_CLAW_WORK_HOME")/.under-claw-update.lock"
mkdir "$update_lock"
if bash "$UNDER_CLAW_WORK_HOME/packaging/update.sh" "$updated" "$(manifest_digest "$updated")" >/dev/null 2>&1; then
  echo "Concurrent update lock was ignored" >&2
  exit 1
fi
rmdir "$update_lock"

corrupt="$temp/corrupt"
cp -R "$updated" "$corrupt"
printf 'corrupt\n' >> "$corrupt/UNSIGNED-NOTICE.txt"
if bash "$UNDER_CLAW_WORK_HOME/packaging/update.sh" "$corrupt" "$(manifest_digest "$updated")" >/dev/null 2>&1; then
  echo "Corrupt release was accepted" >&2
  exit 1
fi

cli="$UNDER_CLAW_WORK_HOME/bin/worklog"
[[ -x "$cli" ]] || cli="$UNDER_CLAW_WORK_HOME/bin/worklog.exe"
before="$(checksum_path="$cli"; \
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$checksum_path"; \
  else sha256sum "$checksum_path"; fi)"
unhealthy="$temp/unhealthy"
cp -R "$updated" "$unhealthy"
rm "$unhealthy/app/.under-claw-app-health"
refresh_manifest "$unhealthy"
if bash "$UNDER_CLAW_WORK_HOME/packaging/update.sh" "$unhealthy" "$(manifest_digest "$unhealthy")" >/dev/null 2>&1; then
  echo "Failed health check was accepted" >&2
  exit 1
fi
after="$(checksum_path="$cli"; \
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$checksum_path"; \
  else sha256sum "$checksum_path"; fi)"
[[ "$before" == "$after" && -f "$UNDER_CLAW_WORK_HOME/user-owned.txt" ]]

export UNDER_CLAW_HOSTS=codex
export CODEX_HOME="$temp/codex"
mkdir -p "$CODEX_HOME/skills/under-claw-meta-prompt"
printf 'user owned\n' > "$CODEX_HOME/skills/under-claw-meta-prompt/SKILL.md"
if bash "$release/packaging/install.sh" "$(manifest_digest "$release")" >/dev/null 2>&1; then
  echo "Installer overwrote an unowned host skill" >&2
  exit 1
fi
grep -q 'user owned' "$CODEX_HOME/skills/under-claw-meta-prompt/SKILL.md"
echo "Packaging smoke tests passed"
