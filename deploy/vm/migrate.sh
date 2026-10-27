#!/usr/bin/env bash
# Apply wacrm's Supabase migrations to the project in /etc/wacrm/migrate.env.
#
#   sudo bash deploy/vm/migrate.sh [--yes]
#
# Uses the migrations from the deployed checkout (/opt/wacrm/src), so run it
# after install.sh. Safe to rerun: Supabase records applied migrations and
# only pushes the new ones. Shows the pending list and asks before applying
# unless --yes is given.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

SUPABASE_CLI_VERSION=2.113.0 # same pin as upstream's migrations CI
assume_yes=0
[[ "${1:-}" == "--yes" ]] && assume_yes=1

[[ "$(id -u)" -eq 0 ]] || die "run with sudo"
[[ -d "$WACRM_HOME/src/supabase/migrations" ]] || die "no checkout at $WACRM_HOME/src; run install.sh first"
load_env_file "$WACRM_MIGRATE_ENV"
[[ -n "${SUPABASE_DB_URL:-}" && "$SUPABASE_DB_URL" != *your-* ]] ||
  die "set SUPABASE_DB_URL in $WACRM_MIGRATE_ENV (Supabase -> Connect -> Session pooler)"

cd "$WACRM_HOME"
node="$(node_dir)"
tools="$WACRM_HOME/tools"
as_wacrm() { runuser -u "$WACRM_USER" -- env HOME="$WACRM_HOME" PATH="$node/bin:$PATH" "$@"; }

cli="$tools/node_modules/.bin/supabase"
pkg="$tools/node_modules/supabase/package.json"
if [[ ! -x "$cli" ]] || ! grep -q "\"version\": \"$SUPABASE_CLI_VERSION\"" "$pkg" 2>/dev/null; then
  log "installing Supabase CLI $SUPABASE_CLI_VERSION"
  install -d -m 0755 -o "$WACRM_USER" -g "$WACRM_USER" "$tools"
  as_wacrm npm install --prefix "$tools" --no-audit --no-fund --loglevel=error \
    "supabase@$SUPABASE_CLI_VERSION"
fi

# The URL is passed as an argument because the CLI has no env-var form for
# it; it is visible in the process list only for the seconds this runs.
push() {
  as_wacrm "$cli" db push --workdir "$WACRM_HOME/src" --db-url "$SUPABASE_DB_URL" "$@"
}

log "pending migrations:"
push --dry-run
if [[ "$assume_yes" -eq 0 ]]; then
  read -r -p "Apply them? [y/N] " answer
  [[ "$answer" == [yY]* ]] || { log "nothing applied"; exit 0; }
fi
push --yes
log "migrations applied"
