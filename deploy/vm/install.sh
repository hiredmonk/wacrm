#!/usr/bin/env bash
# Install or update wacrm on an Ubuntu VM that already runs nginx.
#
#   sudo bash deploy/vm/install.sh [--ref main] [--skip-tls]
#
# Idempotent: rerun it to deploy a new commit or apply config changes.
# First run writes /etc/wacrm/wacrm.env and stops so you can fill it in.
#
# What it touches, and nothing else:
#   - a system user `wacrm` (no login shell, no sudo)
#   - /opt/wacrm            (Node runtime, git checkout, releases)
#   - /etc/wacrm            (config + secrets)
#   - wacrm.service, wacrm-cron.service, wacrm-cron.timer
#   - /etc/nginx/sites-available/wacrm.conf (+ its sites-enabled link)
#   - a Let's Encrypt certificate for WACRM_DOMAIN (via certbot --nginx)
# Other nginx sites, services and accounts are left alone.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

REPO_URL="https://github.com/hiredmonk/wacrm.git"
ref="main" skip_tls=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --skip-tls) skip_tls=1; shift ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "run with sudo"
command -v systemctl >/dev/null || die "systemd is required"
command -v nginx >/dev/null || die "nginx is required (it serves the other sites on this VM)"
for bin in git curl tar xz openssl runuser ss; do
  command -v "$bin" >/dev/null || die "missing $bin (apt-get install -y $bin)"
done

# ---- 1. Config ---------------------------------------------------------
install -d -m 0750 -o root -g root "$WACRM_ETC"
if ! id "$WACRM_USER" >/dev/null 2>&1; then
  log "creating system user $WACRM_USER"
  useradd --system --home-dir "$WACRM_HOME" --shell /usr/sbin/nologin --user-group "$WACRM_USER"
fi
chgrp "$WACRM_USER" "$WACRM_ETC"

if [[ ! -f "$WACRM_ENV" ]]; then
  install -m 0640 -o root -g "$WACRM_USER" "$here/wacrm.env.example" "$WACRM_ENV"
  sed -i \
    -e "s/^ENCRYPTION_KEY=$/ENCRYPTION_KEY=$(openssl rand -hex 32)/" \
    -e "s/^AUTOMATION_CRON_SECRET=$/AUTOMATION_CRON_SECRET=$(openssl rand -hex 32)/" \
    "$WACRM_ENV"
  [[ -f "$WACRM_MIGRATE_ENV" ]] ||
    install -m 0600 -o root -g root "$here/migrate.env.example" "$WACRM_MIGRATE_ENV"
  log "wrote $WACRM_ENV with fresh ENCRYPTION_KEY and AUTOMATION_CRON_SECRET."
  log "Back up ENCRYPTION_KEY now: losing it orphans every stored WhatsApp token."
  log "Fill in the CHANGE_ME / your-* values (sudo nano $WACRM_ENV) and rerun."
  exit 2
fi
chown root:"$WACRM_USER" "$WACRM_ENV"
chmod 0640 "$WACRM_ENV"

load_env_file "$WACRM_ENV"
for v in WACRM_DOMAIN WACRM_PORT NEXT_PUBLIC_SITE_URL NEXT_PUBLIC_SUPABASE_URL \
  NEXT_PUBLIC_SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY ENCRYPTION_KEY \
  AUTOMATION_CRON_SECRET; do
  require_var "$v"
done
[[ "$ENCRYPTION_KEY" =~ ^[0-9a-fA-F]{64}$ ]] || die "ENCRYPTION_KEY must be 64 hex characters"
[[ "$WACRM_PORT" =~ ^[0-9]+$ ]] || die "WACRM_PORT must be a number"
[[ "$NEXT_PUBLIC_SITE_URL" == "https://$WACRM_DOMAIN" ]] ||
  die "NEXT_PUBLIC_SITE_URL must be https://$WACRM_DOMAIN"
[[ -n "${META_APP_SECRET:-}" ]] ||
  warn "META_APP_SECRET is empty: the WhatsApp webhook will reject every request until you set it"

# The secret header for the cron timer, kept out of argv.
umask 027
printf 'x-cron-secret: %s\n' "$AUTOMATION_CRON_SECRET" >"$WACRM_ETC/cron-header"
chown root:"$WACRM_USER" "$WACRM_ETC/cron-header"
chmod 0640 "$WACRM_ETC/cron-header"
umask 022

# The port must be free, or already ours.
holder="$(ss -Hltnp "sport = :$WACRM_PORT" 2>/dev/null || true)"
if [[ -n "$holder" ]] && ! systemctl is-active --quiet wacrm; then
  die "port $WACRM_PORT is already in use: $holder"
fi

# ---- 2. Node runtime (pinned, checksum-verified) -----------------------
install -d -m 0755 -o "$WACRM_USER" -g "$WACRM_USER" "$WACRM_HOME" "$WACRM_HOME/releases"
# runuser keeps the caller's cwd, which the service user may not be able to read.
cd "$WACRM_HOME"
as_wacrm() { runuser -u "$WACRM_USER" -- env HOME="$WACRM_HOME" "$@"; }
node="$(node_dir)"
if [[ ! -x "$node/bin/node" ]]; then
  arch="$(node_arch)"
  sum_var="NODE_SHA256_$arch"
  tarball="node-$NODE_VERSION-linux-$arch.tar.xz"
  tmp="$(mktemp -d)"
  log "downloading Node $NODE_VERSION ($arch)"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$tarball" -o "$tmp/$tarball"
  echo "${!sum_var}  $tmp/$tarball" | sha256sum -c --quiet - || die "Node tarball checksum mismatch"
  tar -xJf "$tmp/$tarball" -C "$WACRM_HOME"
  chown -R root:root "$node"
  rm -rf "$tmp"
fi

# ---- 3. Source + build (as the service user) ---------------------------
src="$WACRM_HOME/src"
if [[ ! -d "$src/.git" ]]; then
  log "cloning $REPO_URL"
  as_wacrm git clone --quiet "$REPO_URL" "$src"
fi
# The kit itself is run from a separate checkout; build from a private
# copy of it inside the service user's tree.
install -d -m 0755 -o "$WACRM_USER" -g "$WACRM_USER" "$WACRM_HOME/kit"
install -m 0755 -o "$WACRM_USER" -g "$WACRM_USER" "$here/build-release.sh" "$here/lib.sh" "$WACRM_HOME/kit/"

log "building (nice'd; takes a few minutes on a small VM)"
release="$(as_wacrm "$WACRM_HOME/kit/build-release.sh" --src "$src" --ref "$ref" \
  --env "$WACRM_ENV" --root "$WACRM_HOME" --node "$node")"
[[ -d "$release" ]] || die "build did not produce a release"

# ---- 4. systemd --------------------------------------------------------
render() {
  sed -e "s|@USER@|$WACRM_USER|g" -e "s|@HOME@|$WACRM_HOME|g" -e "s|@ENV@|$WACRM_ENV|g" \
    -e "s|@ETC@|$WACRM_ETC|g" -e "s|@NODE@|$node|g" -e "s|@PORT@|$WACRM_PORT|g" \
    -e "s|@DOMAIN@|$WACRM_DOMAIN|g" "$1"
}
for unit in wacrm.service wacrm-cron.service wacrm-cron.timer; do
  render "$here/templates/$unit" >"/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --quiet wacrm.service wacrm-cron.timer
systemctl restart wacrm.service

log "waiting for the app on 127.0.0.1:$WACRM_PORT"
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$WACRM_PORT/login" || true)"
  if [[ "$code" == "200" ]]; then ok=1; break; fi
  sleep 2
done
[[ "$ok" -eq 1 ]] || die "app did not answer on /login; see: journalctl -u wacrm -n 100"
systemctl start wacrm-cron.timer

# ---- 5. nginx ----------------------------------------------------------
site=/etc/nginx/sites-available/wacrm.conf
if [[ -f "$site" ]] && grep -q 'managed by Certbot' "$site"; then
  log "nginx vhost already has TLS from certbot; leaving it as is"
else
  backup=""
  [[ -f "$site" ]] && backup="$(mktemp)" && cp -a "$site" "$backup"
  render "$here/templates/nginx-wacrm.conf" >"$site"
  ln -sfn "$site" /etc/nginx/sites-enabled/wacrm.conf
  if ! nginx -t 2>/dev/null; then
    if [[ -n "$backup" ]]; then mv "$backup" "$site"; else rm -f "$site" /etc/nginx/sites-enabled/wacrm.conf; fi
    nginx -t || true
    die "nginx rejected the wacrm vhost; restored the previous state, nothing reloaded"
  fi
  [[ -n "$backup" ]] && rm -f "$backup"
  systemctl reload nginx
fi

# ---- 6. TLS ------------------------------------------------------------
if [[ "$skip_tls" -eq 0 ]] && ! grep -q 'managed by Certbot' "$site"; then
  command -v certbot >/dev/null || die "certbot missing (apt-get install -y certbot python3-certbot-nginx), or rerun with --skip-tls"
  require_var WACRM_CERTBOT_EMAIL
  getent ahosts "$WACRM_DOMAIN" >/dev/null ||
    die "$WACRM_DOMAIN does not resolve yet; add the DNS A record, or rerun with --skip-tls"
  certbot --nginx --non-interactive --agree-tos --redirect \
    -m "$WACRM_CERTBOT_EMAIL" -d "$WACRM_DOMAIN"
fi

cat <<EOF

wacrm is running: $(cat "$release/REVISION")
  App:            https://$WACRM_DOMAIN
  Meta webhook:   https://$WACRM_DOMAIN/api/whatsapp/webhook
  Logs:           journalctl -u wacrm -f
  Cron:           systemctl list-timers wacrm-cron.timer
  Roll back:      ln -sfn <older dir in $WACRM_HOME/releases> $WACRM_HOME/current && systemctl restart wacrm

If this is the first install, apply the database schema next:
  sudo nano $WACRM_MIGRATE_ENV     # Supabase session-pooler URL
  sudo bash $here/migrate.sh
EOF
