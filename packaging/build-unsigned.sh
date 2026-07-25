#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
os=""
output="$root/build/distribution"
revision="ab3e169f26aea433e4d25709e42a05e74324700b"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) os="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done
case "$os" in macos|windows|linux) ;; *) echo "--os must be macos, windows or linux" >&2; exit 64 ;; esac
[[ "$output" = /* ]] || output="$root/$output"
case "$output" in /|"$HOME"|"${HOME}/"|"") echo "Unsafe output path" >&2; exit 64 ;; esac

head_revision="$(git -C "$root" rev-parse HEAD)"
source_revision="${UNDER_CLAW_SOURCE_REVISION:-$head_revision}"
[[ "$source_revision" == "$head_revision" ]] || {
  echo "Source revision override must equal the checked-out HEAD" >&2; exit 65;
}
if [[ -n "$(git -C "$root" status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to package an uncommitted source tree" >&2
  exit 65
fi

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
release="$stage/under-claw-work-$os-unsigned"
mkdir -p "$release/build/cli" "$release/packaging" "$release/skills" \
  "$release/bundled-skills" "$release/personas"
[[ -f "$root/build/cli/bundle/bin/worklog" ||
  -f "$root/build/cli/bundle/bin/worklog.exe" ]] || {
    echo "Missing precompiled CLI" >&2; exit 66;
  }
cli_name=worklog
[[ ! -f "$root/build/cli/bundle/bin/worklog.exe" ]] || cli_name=worklog.exe
cp -RL "$root/build/cli/bundle" "$release/build/cli/bundle"
cp "$root/packaging/install.sh" "$root/packaging/update.sh" \
  "$root/packaging/rollback.sh" "$root/packaging/auto-meta-watch.sh" \
  "$root/packaging/install-auto-meta-service.sh" \
  "$root/packaging/uninstall.sh" "$root/packaging/verify-release.sh" \
  "$release/packaging/"
cp -RL "$root/skills/under-claw-work-plan" "$root/skills/under-claw-work" \
  "$release/skills/"
cp "$root/skills/bundle.lock.yaml" "$release/skills/"
cp -RL "$root/personas/." "$release/personas/"

case "$os" in
  macos)
    app="$root/build/macos/Build/Products/Release/under_claw_work.app"
    ;;
  windows)
    app="$root/build/windows/x64/runner/Release"
    ;;
  linux)
    app="$root/build/linux/x64/release/bundle"
    ;;
esac
[[ -e "$app" ]] || { echo "Missing $os application build: $app" >&2; exit 66; }
mkdir -p "$release/app"
cp -RL "$app" "$release/app/"

source_repo="${UNDER_CLAW_SKILL_SOURCE:-}"
if [[ -z "$source_repo" ]]; then
  source_repo="$stage/upstream"
  # Skill lock hashes are defined over the upstream Git bytes. Prevent a
  # Windows checkout from rewriting LF to CRLF before verification.
  git -c core.autocrlf=false clone --quiet \
    https://github.com/strong1133/under-claw-jarvis-plan.git "$source_repo"
  git -C "$source_repo" checkout --quiet "$revision"
fi
[[ "$(git -C "$source_repo" rev-parse HEAD)" == "$revision" ]] || {
  echo "Skill source revision mismatch" >&2; exit 65;
}
mkdir -p "$release/bundled-skills/upstream"
for directory in skills commands; do
  [[ -d "$source_repo/$directory" ]] &&
    cp -RL "$source_repo/$directory" "$release/bundled-skills/upstream/"
done
printf '%s\n' "$revision" > "$release/bundled-skills/upstream/REVISION"

mkdir -p "$release/licenses"
find "$root" -maxdepth 3 -type f \
  \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname '*licenses*' \) \
  -not -path "$root/build/*" -print0 |
  while IFS= read -r -d '' file; do
    target="${file#"$root/"}"
    mkdir -p "$release/licenses/$(dirname "$target")"
    cp "$file" "$release/licenses/$target"
  done
cat > "$release/UNSIGNED-NOTICE.txt" <<'EOF'
This archive is unsigned. SHA-256 entries detect accidental corruption only;
they do not establish publisher identity or authenticity. Obtain releases from
a trusted channel and compare an independently published digest.
EOF
cat > "$release/ACCEPTED-RUNTIMES.txt" <<'EOF'
Production runtime descriptors bundled by this unsigned release: 0.
Agent execution remains fail-closed until a reviewed local descriptor is
registered explicitly:
  worklog runtime-register <workspace> <descriptor-json>
Inspect registrations with:
  worklog runtime-list <workspace>
EOF
printf '%s\n' "${UNDER_CLAW_RELEASE_VERSION:-0.1.0-mvp}" \
  > "$release/RELEASE-VERSION.txt"
printf '%s\n' "$source_revision" > "$release/SOURCE-REVISION.txt"
cat > "$release/README.txt" <<EOF
Under Claw Work unsigned $os package

Install: bash packaging/install.sh
CLI after installation: bin/$cli_name --help
This package is unsigned; read UNSIGNED-NOTICE.txt before use.
EOF
touch "$release/app/.under-claw-app-health"

checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
(
  cd "$release"
  find . -type f ! -path './release-manifest.tsv' -print |
    LC_ALL=C sort |
    while IFS= read -r path; do
      clean="${path#./}"
      printf '%s\t%s\t%s\n' "$(checksum "$clean")" \
        "$(wc -c < "$clean" | tr -d ' ')" "$clean"
    done > release-manifest.tsv
)

echo "release_manifest_sha256=$(checksum "$release/release-manifest.tsv")"

mkdir -p "$output"
archive="$output/under-claw-work-$os-unsigned.tar.gz"
if tar --version 2>/dev/null | grep -q GNU; then
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$stage" -cf - "$(basename "$release")" | gzip -n > "$archive"
else
  COPYFILE_DISABLE=1 tar -C "$stage" -cf - "$(basename "$release")" |
    gzip -n > "$archive"
fi
echo "$archive"
