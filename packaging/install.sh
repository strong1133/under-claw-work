#!/usr/bin/env bash
set -euo pipefail

product_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_manifest_hash="${1:-}"
install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
source_repo="${UNDER_CLAW_SKILL_SOURCE:-}"
revision="ab3e169f26aea433e4d25709e42a05e74324700b"
manifest="$install_root/install-manifest.tsv"

case "$install_root" in
  "$HOME"|"${HOME}/"|"/"|"") echo "Unsafe install root" >&2; exit 64 ;;
esac
[[ "$install_root" = /* ]] || { echo "Install root must be absolute" >&2; exit 64; }
packaged=0
if [[ -d "$product_root/app" || -d "$product_root/bundled-skills" ||
  -f "$product_root/RELEASE-VERSION.txt" ||
  -f "$product_root/UNSIGNED-NOTICE.txt" ||
  -f "$product_root/ACCEPTED-RUNTIMES.txt" ]]; then
  packaged=1
fi
staging="$(mktemp -d)"
candidate=""
backup=""
cleanup() {
  rm -rf "$staging"
  [[ -z "$candidate" || ! -d "$candidate" ]] || rm -rf "$candidate"
}
trap cleanup EXIT
if [[ "$packaged" == "1" ]]; then
  [[ -f "$product_root/release-manifest.tsv" &&
    -x "$product_root/packaging/verify-release.sh" ]] || {
      echo "Packaged release is missing its manifest or verifier" >&2
      exit 65
    }
  [[ "$expected_manifest_hash" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Install requires the independently obtained release manifest SHA-256" >&2
    exit 65
  }
  release_snapshot="$staging/release"
  mkdir -p "$release_snapshot"
  cp -RP "$product_root/." "$release_snapshot/"
  bash "$product_root/packaging/verify-release.sh" \
    "$release_snapshot" "$expected_manifest_hash"
  product_root="$release_snapshot"
fi

if [[ -z "$source_repo" && -d "$product_root/bundled-skills/upstream/.git" ]]; then
  source_repo="$product_root/bundled-skills/upstream"
elif [[ -z "$source_repo" && -d "$product_root/bundled-skills/upstream/skills" ]]; then
  source_repo="$product_root/bundled-skills/upstream"
elif [[ -z "$source_repo" ]]; then
  source_repo="$staging/upstream"
  git clone --quiet https://github.com/strong1133/under-claw-jarvis-plan.git "$source_repo"
  git -C "$source_repo" checkout --quiet "$revision"
fi
if [[ -d "$source_repo/.git" && "$(git -C "$source_repo" rev-parse HEAD)" != "$revision" ]]; then
  echo "Skill source revision mismatch" >&2
  exit 65
fi
if [[ ! -d "$source_repo/.git" &&
  "$(tr -d '[:space:]' < "$source_repo/REVISION" 2>/dev/null || true)" != "$revision" ]]; then
  echo "Bundled skill revision mismatch" >&2
  exit 65
fi

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

for pair in \
  "under-claw-meta-prompt:ebaf018ff8bf7240115d14bfbf559f0f379971abe30afcd057ad1f6afff1f1a6" \
  "under-claw-jarvis-plan-loop:b99a092f81d3d453e25f888e65203e4c6ad95de54c7a0ac0e45f33b541320799" \
  "under-claw-jarvis-plan:663508d02d39c87c5988fabe891a9f03df0a3a386af0247e36e56dd05390e1cf"; do
  skill="${pair%%:*}"
  expected="${pair#*:}"
  actual="$(checksum "$source_repo/skills/$skill/SKILL.md")"
  [[ "$actual" == "$expected" ]] || {
    echo "Skill checksum mismatch: $skill" >&2
    exit 65
  }
done

requested_hosts="${UNDER_CLAW_HOSTS:-auto}"
host_requested() {
  [[ "$requested_hosts" == "auto" || ",$requested_hosts," == *",$1,"* ]]
}
host_detected() {
  local host="$1" executable="$2" home_path="$3"
  host_requested "$host" || return 1
  if [[ "$requested_hosts" != "auto" ]]; then return 0; fi
  [[ -d "$home_path" ]] || command -v "$executable" >/dev/null 2>&1
}
preflight_skill_tree() {
  local host_home="$1"
  local skill_root="$host_home/skills"
  if [[ -L "$host_home" ]]; then
    echo "Refusing symbolic-link host root: $host_home" >&2
    exit 73
  fi
  if [[ -L "$skill_root" ]]; then
    echo "Refusing symbolic-link skill root: $skill_root" >&2
    exit 73
  fi
  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop \
    under-claw-jarvis-plan under-claw-work-plan under-claw-work; do
    local target="$skill_root/$skill"
    local marker="$target/.under-claw-work-owned"
    if [[ -L "$target" || -L "$marker" ||
      ( -e "$target" && ! -f "$marker" ) ]]; then
      echo "Refusing to overwrite non-owned skill: $target" >&2
      exit 73
    fi
  done
}
hermes_home="${HERMES_HOME:-$HOME/.hermes}"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
if host_detected hermes hermes "$hermes_home"; then
  preflight_skill_tree "$hermes_home"
fi
if host_detected claude-code claude "$claude_home"; then
  preflight_skill_tree "$claude_home"
  command_root="$claude_home/commands"
  if [[ -L "$command_root" ]]; then
    echo "Refusing symbolic-link command root: $command_root" >&2
    exit 73
  fi
  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop \
    under-claw-jarvis-plan under-claw-work-plan under-claw-work; do
    command_target="$claude_home/commands/$skill.md"
    command_marker="$command_target.under-claw-work-owned"
    if [[ -L "$command_target" || -L "$command_marker" ||
      ( -e "$command_target" && ! -f "$command_marker" ) ]]; then
      echo "Refusing to overwrite non-owned command: $command_target" >&2
      exit 73
    fi
  done
fi
if host_detected codex codex "$codex_home"; then
  preflight_skill_tree "$codex_home"
fi

cli_source="$product_root/build/cli/bundle/bin/worklog"
[[ -f "$cli_source" ]] || cli_source="$product_root/build/cli/bundle/bin/worklog.exe"
if [[ ! -f "$cli_source" ]]; then
  echo "Required precompiled Core CLI is missing." >&2
  exit 66
fi
cli_name="$(basename "$cli_source")"

install_parent="$(dirname "$install_root")"
mkdir -p "$install_parent"
candidate="$(mktemp -d "$install_parent/.under-claw-install.XXXXXX")"
if [[ -d "$install_root" ]]; then
  cp -R "$install_root/." "$candidate/"
fi
mkdir -p "$candidate/bin"
rm -f "$candidate/bin/worklog" "$candidate/bin/worklog.exe"
install -m 0755 "$cli_source" "$candidate/bin/$cli_name"
if [[ -d "$product_root/build/cli/bundle/lib" ]]; then
  rm -rf "$candidate/lib"
  cp -R "$product_root/build/cli/bundle/lib" "$candidate/lib"
fi
if [[ "$packaged" == "1" ]]; then
  for directory in app packaging bundled-skills skills personas; do
    rm -rf "$candidate/$directory"
    cp -RL "$product_root/$directory" "$candidate/$directory"
  done
  for file in UNSIGNED-NOTICE.txt ACCEPTED-RUNTIMES.txt RELEASE-VERSION.txt \
    SOURCE-REVISION.txt README.txt release-manifest.tsv; do
    cp "$product_root/$file" "$candidate/$file"
  done
else
  rm -rf "$candidate/packaging"
  cp -RL "$product_root/packaging" "$candidate/packaging"
  printf '%s\n' "$revision" > "$candidate/RELEASE-VERSION.txt"
fi

{
  echo "manifest_version	2"
  echo "install_root	$install_root"
  echo "skill_revision	$revision"
} > "$candidate/install-manifest.tsv"

if [[ "$packaged" == "1" &&
  ! -f "$candidate/app/.under-claw-app-health" ]]; then
  echo "Packaged application health marker is missing" >&2
  exit 70
fi
if ! UNDER_CLAW_WORK_HOME="$candidate" \
  "$candidate/bin/$cli_name" --help >/dev/null 2>&1; then
  echo "Installed CLI failed health check; installation preserved" >&2
  exit 70
fi

install_skill_tree() {
  local host="$1"
  local host_home="$2"
  local skill_root="$host_home/skills"
  if [[ -L "$host_home" ]]; then
    echo "Refusing symbolic-link host root: $host_home" >&2
    return 73
  fi
  if [[ -L "$skill_root" ]]; then
    echo "Refusing symbolic-link skill root: $skill_root" >&2
    return 73
  fi
  mkdir -p "$skill_root"
  echo "host_root	$host	$host_home" >> "$manifest"

  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop \
    under-claw-jarvis-plan under-claw-work-plan under-claw-work; do
    local target="$skill_root/$skill"
    if [[ -e "$target" && ! -f "$target/.under-claw-work-owned" ]]; then
      echo "Refusing to overwrite non-owned skill: $target" >&2
      return 73
    fi
  done

  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop under-claw-jarvis-plan; do
    local target="$skill_root/$skill"
    rm -rf "$target"
    cp -R "$source_repo/skills/$skill" "$target"
    touch "$target/.under-claw-work-owned"
    echo "owned_skill	$host	$target	$(tree_checksum "$target")" >> "$manifest"
  done

  local target="$skill_root/under-claw-work-plan"
  rm -rf "$target"
  cp -R "$product_root/skills/under-claw-work-plan" "$target"
  touch "$target/.under-claw-work-owned"
  echo "owned_skill	$host	$target	$(tree_checksum "$target")" >> "$manifest"

  target="$skill_root/under-claw-work"
  rm -rf "$target"
  cp -R "$product_root/skills/under-claw-work" "$target"
  touch "$target/.under-claw-work-owned"
  echo "owned_skill	$host	$target	$(tree_checksum "$target")" >> "$manifest"
}

install_claude_commands() {
  local claude_home="$1"
  local command_root="$claude_home/commands"
  if [[ -L "$command_root" ]]; then
    echo "Refusing symbolic-link command root: $command_root" >&2
    return 73
  fi
  mkdir -p "$command_root"
  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop under-claw-jarvis-plan; do
    local source="$source_repo/commands/$skill.md"
    [[ -f "$source" ]] || continue
    local target="$command_root/$skill.md"
    local marker="$target.under-claw-work-owned"
    if [[ -L "$target" || -L "$marker" ||
      ( -e "$target" && ! -f "$marker" ) ]]; then
      echo "Refusing to overwrite non-owned command: $target" >&2
      return 73
    fi
    rm -f -- "$target"
    cp "$source" "$target"
    touch "$target.under-claw-work-owned"
    echo "owned_command	claude-code	$target	$(checksum "$target")" >> "$manifest"
  done
  local target="$command_root/under-claw-work-plan.md"
  local marker="$target.under-claw-work-owned"
  if [[ -L "$target" || -L "$marker" ||
    ( -e "$target" && ! -f "$marker" ) ]]; then
    echo "Refusing to overwrite non-owned command: $target" >&2
    return 73
  fi
  rm -f -- "$target"
  cp "$product_root/skills/under-claw-work-plan/SKILL.md" "$target"
  touch "$target.under-claw-work-owned"
  echo "owned_command	claude-code	$target	$(checksum "$target")" >> "$manifest"

  target="$command_root/under-claw-work.md"
  marker="$target.under-claw-work-owned"
  if [[ -L "$target" || -L "$marker" ||
    ( -e "$target" && ! -f "$marker" ) ]]; then
    echo "Refusing to overwrite non-owned command: $target" >&2
    return 73
  fi
  rm -f -- "$target"
  cp "$product_root/skills/under-claw-work/SKILL.md" "$target"
  touch "$target.under-claw-work-owned"
  echo "owned_command	claude-code	$target	$(checksum "$target")" >> "$manifest"
}

host_snapshot="$staging/host-snapshot"
host_snapshot_index="$staging/host-snapshot.tsv"
mkdir -p "$host_snapshot"
snapshot_count=0
snapshot_target() {
  local target="$1"
  local saved="$host_snapshot/$snapshot_count"
  snapshot_count=$((snapshot_count + 1))
  if [[ -e "$target" || -L "$target" ]]; then
    cp -RP "$target" "$saved"
    printf '%s\t%s\t1\n' "$target" "$saved" >> "$host_snapshot_index"
  else
    printf '%s\t%s\t0\n' "$target" "$saved" >> "$host_snapshot_index"
  fi
}
snapshot_skill_tree() {
  local host_home="$1"
  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop \
    under-claw-jarvis-plan under-claw-work-plan under-claw-work; do
    snapshot_target "$host_home/skills/$skill"
  done
}
if host_detected hermes hermes "$hermes_home"; then
  snapshot_skill_tree "$hermes_home"
fi
if host_detected claude-code claude "$claude_home"; then
  snapshot_skill_tree "$claude_home"
  for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop \
    under-claw-jarvis-plan under-claw-work-plan; do
    snapshot_target "$claude_home/commands/$skill.md"
    snapshot_target "$claude_home/commands/$skill.md.under-claw-work-owned"
  done
  snapshot_target "$claude_home/commands/under-claw-work.md"
  snapshot_target \
    "$claude_home/commands/under-claw-work.md.under-claw-work-owned"
fi
if host_detected codex codex "$codex_home"; then
  snapshot_skill_tree "$codex_home"
fi

rollback_install_and_hosts() {
  local status=$?
  trap - ERR
  set +e
  if [[ -f "$host_snapshot_index" ]]; then
    while IFS=$'\t' read -r target saved existed; do
      rm -rf "$target"
      if [[ "$existed" == "1" ]]; then
        mkdir -p "$(dirname "$target")"
        cp -RP "$saved" "$target"
      fi
    done < "$host_snapshot_index"
  fi
  rm -rf "$install_root"
  if [[ "$had_install" == "1" && -d "$backup" ]]; then
    mv "$backup" "$install_root"
  fi
  echo "Agent host installation failed; all installation targets restored" >&2
  exit "$status"
}

had_install=0
if [[ -e "$install_root" ]]; then
  had_install=1
  backup="$install_parent/.under-claw-install-backup.$$"
  mv "$install_root" "$backup"
fi
if ! mv "$candidate" "$install_root"; then
  [[ "$had_install" == "0" ]] || mv "$backup" "$install_root"
  echo "Install swap failed; previous installation restored" >&2
  exit 71
fi
candidate=""
trap rollback_install_and_hosts ERR

connected=0
if host_detected hermes hermes "$hermes_home"; then
  install_skill_tree hermes "$hermes_home"
  connected=$((connected + 1))
fi
if host_detected claude-code claude "$claude_home"; then
  install_skill_tree claude-code "$claude_home"
  install_claude_commands "$claude_home"
  connected=$((connected + 1))
fi
if host_detected codex codex "$codex_home"; then
  install_skill_tree codex "$codex_home"
  connected=$((connected + 1))
fi
trap - ERR
if [[ "$had_install" == "1" && -d "$backup" ]]; then rm -rf "$backup"; fi

echo "Under Claw Work runtime installed: $install_root"
if [[ "$connected" -eq 0 ]]; then
  echo "No Agent host detected; standalone Flutter/CLI management is available."
else
  echo "Connected Agent hosts: $connected"
fi
echo "Next: $install_root/bin/$cli_name initialize <git-path> <environment-name> [remote]"
