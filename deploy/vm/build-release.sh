#!/usr/bin/env bash
# Build one immutable release of wacrm and point `current` at it.
#
# Runs as the unprivileged service user (install.sh calls it through
# runuser). Never needs root, so it can also be exercised on a dev box:
#
#   build-release.sh --src <git checkout> --ref <branch|tag|sha> \
#     --env <wacrm.env> --root <dir holding releases/ and current> \
#     --node <node install dir>
#
# Prints the release directory (and nothing else) on stdout.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

src="" ref="main" env_file="" root="" node=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) src="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --env) env_file="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --node) node="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$src" && -n "$env_file" && -n "$root" && -n "$node" ]] ||
  die "usage: build-release.sh --src DIR --ref REF --env FILE --root DIR --node DIR"
[[ "$(id -u)" -ne 0 ]] || die "refusing to build as root"

# Progress goes to stderr so the caller sees it; stdout carries only the
# release path.
exec 3>&1 1>&2

export PATH="$node/bin:$PATH"
export NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production
# A build on a small production box must not starve the live services.
export NODE_OPTIONS="--max-old-space-size=2048"

load_env_file "$env_file"
require_var NEXT_PUBLIC_SUPABASE_URL
require_var NEXT_PUBLIC_SUPABASE_ANON_KEY
require_var NEXT_PUBLIC_SITE_URL

log "fetching $ref"
git -C "$src" fetch --quiet --tags origin
if git -C "$src" rev-parse --verify --quiet "origin/$ref^{commit}" >/dev/null; then
  git -C "$src" checkout --quiet --detach "origin/$ref"
else
  git -C "$src" checkout --quiet --detach "$ref"
fi
sha="$(git -C "$src" rev-parse HEAD)"
log "building $sha with node $(node -v)"

cd "$src"
# Dev dependencies are needed to build (typescript, tailwind).
NODE_ENV=development nice -n 19 npm ci --no-audit --no-fund --loglevel=error
nice -n 19 npm run build

release="$root/releases/${sha:0:12}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$release"
# Same layout as the Dockerfile's runtime stage.
cp -a .next/standalone/. "$release/"
mkdir -p "$release/.next"
cp -a .next/static "$release/.next/static"
cp -a public "$release/public"
printf '%s\n' "$sha" >"$release/REVISION"

# Atomic switch: a new symlink renamed over the old one.
ln -sfn "$release" "$root/current.tmp"
mv -T "$root/current.tmp" "$root/current"

# Keep the three newest releases for rollback.
find "$root/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
  sort -rn | tail -n +4 | cut -d' ' -f2- | while IFS= read -r old; do
    [[ "$old" == "$(readlink -f "$root/current")" ]] || rm -rf -- "$old"
  done

log "release ready: $release"
echo "$release" >&3
