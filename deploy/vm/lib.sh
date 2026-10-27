# Shared helpers for the VM deploy scripts. Sourced, never executed.
# shellcheck shell=bash disable=SC2034  # constants are read by the sourcing scripts

WACRM_HOME=/opt/wacrm
WACRM_USER=wacrm
WACRM_ETC=/etc/wacrm
WACRM_ENV="$WACRM_ETC/wacrm.env"
WACRM_MIGRATE_ENV="$WACRM_ETC/migrate.env"

NODE_VERSION=v22.23.3
# From https://nodejs.org/dist/v22.23.3/SHASUMS256.txt
NODE_SHA256_arm64=a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f
NODE_SHA256_x64=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de

log() { printf '\033[1;34m[wacrm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[wacrm] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[wacrm] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

node_arch() {
  case "$(uname -m)" in
    aarch64 | arm64) echo arm64 ;;
    x86_64 | amd64) echo x64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
}

node_dir() { echo "$WACRM_HOME/node-$NODE_VERSION-linux-$(node_arch)"; }

# Export KEY=VALUE lines from an env file literally. Unlike `source`, this
# never expands `$`, backticks or globs, so a password containing `$` or a
# percent-encoded URL survives intact. Blank lines and `#` comments are
# skipped; one pair of surrounding single or double quotes is stripped,
# matching how systemd's EnvironmentFile reads the same file.
load_env_file() {
  local file="$1" line key value
  [[ -r "$file" ]] || die "cannot read $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "$file: not a KEY=VALUE line: ${line%%=*}"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    export "$key=$value"
  done <"$file"
}

# Fail if a variable is empty or still holds an example placeholder.
require_var() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || die "$name is empty in $WACRM_ENV"
  [[ "$value" != *your-* && "$value" != *CHANGE_ME* ]] ||
    die "$name still holds the example placeholder in $WACRM_ENV"
}
