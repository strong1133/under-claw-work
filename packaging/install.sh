#!/usr/bin/env bash
set -euo pipefail

product_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_root="${UNDER_CLAW_WORK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/under-claw-work}"
hermes_root="${HERMES_HOME:-$HOME/.hermes}"
skill_root="$hermes_root/skills"
source_repo="${UNDER_CLAW_SKILL_SOURCE:-}"
revision="ab3e169f26aea433e4d25709e42a05e74324700b"

case "$install_root" in
  "$HOME"|"${HOME}/"|"/"|"") echo "Unsafe install root" >&2; exit 64 ;;
esac

staging="$(mktemp -d)"
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

if [[ -z "$source_repo" ]]; then
  source_repo="$staging/upstream"
  git clone --quiet https://github.com/strong1133/under-claw-jarvis-plan.git "$source_repo"
  git -C "$source_repo" checkout --quiet "$revision"
fi
if [[ "$(git -C "$source_repo" rev-parse HEAD)" != "$revision" ]]; then
  echo "Skill source revision mismatch" >&2
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
  find "$1" -type f ! -name .under-claw-work-owned -print0 |
    sort -z |
    xargs -0 shasum -a 256 |
    shasum -a 256 |
    awk '{print $1}'
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

mkdir -p "$install_root/bin" "$skill_root"
if [[ -x "$product_root/build/cli/bundle/bin/worklog" ]]; then
  install -m 0755 \
    "$product_root/build/cli/bundle/bin/worklog" \
    "$install_root/bin/worklog"
  if [[ -d "$product_root/build/cli/bundle/lib" ]]; then
    rm -rf "$install_root/lib"
    cp -R "$product_root/build/cli/bundle/lib" "$install_root/lib"
  fi
else
  echo "Required precompiled Core CLI is missing." >&2
  exit 66
fi

for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop under-claw-jarvis-plan under-claw-work-plan; do
  target="$skill_root/$skill"
  if [[ -e "$target" && ! -f "$target/.under-claw-work-owned" ]]; then
    echo "Refusing to overwrite non-owned skill: $target" >&2
    exit 73
  fi
done

for skill in under-claw-meta-prompt under-claw-jarvis-plan-loop under-claw-jarvis-plan; do
  target="$skill_root/$skill"
  rm -rf "$target"
  cp -R "$source_repo/skills/$skill" "$target"
  touch "$target/.under-claw-work-owned"
done

target="$skill_root/under-claw-work-plan"
rm -rf "$target"
cp -R "$product_root/skills/under-claw-work-plan" "$target"
touch "$target/.under-claw-work-owned"

manifest="$install_root/install-manifest.tsv"
{
  echo "manifest_version	1"
  echo "hermes_root	$hermes_root"
  echo "skill_revision	$revision"
  for skill in under-claw-work-plan under-claw-meta-prompt under-claw-jarvis-plan-loop under-claw-jarvis-plan; do
    echo "owned_skill	$skill_root/$skill	$(tree_checksum "$skill_root/$skill")"
  done
} > "$manifest"

echo "Under Claw Work skill environment installed."
echo "Hermes: start a fresh session, then use /under-claw-work-plan."
