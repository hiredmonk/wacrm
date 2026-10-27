# Deploy wacrm on an Ubuntu VM (systemd + nginx)

Runs wacrm next to the services already on a VM, contained so that a
compromise of this app cannot read other accounts' homes or gain root:

- its own system user `wacrm` (no login shell, no sudo)
- pinned, checksum-verified Node 22 under `/opt/wacrm` (system packages untouched)
- a hardened `wacrm.service`: loopback only, read-only OS, `/home` and
  `/root` hidden, 1 GB memory cap, low CPU weight
- its own nginx vhost and Let's Encrypt certificate; other sites untouched
- cron routes reachable only from the box (`wacrm-cron.timer`, every minute)

## What you need first

| # | Item | Where |
|---|---|---|
| 1 | A **new** Supabase project (not MoneyMistri's), region Mumbai | supabase.com → New project |
| 2 | Its URL, anon/publishable key, service_role/secret key | Project Settings → API |
| 3 | Its **Session pooler** connection string | Connect → Session pooler |
| 4 | A hostname for the CRM, with a DNS **A record** pointing at the VM | your DNS provider |
| 5 | `certbot` + `python3-certbot-nginx` on the VM | `sudo apt-get install -y certbot python3-certbot-nginx` |

Meta details are **not** needed to install; add them afterwards.

## Install

```bash
ssh ubuntu@<vm>
git clone https://github.com/hiredmonk/wacrm.git ~/wacrm-kit && cd ~/wacrm-kit

sudo bash deploy/vm/install.sh       # 1st run: writes /etc/wacrm/wacrm.env, generates secrets, stops
sudo nano /etc/wacrm/wacrm.env       # fill every CHANGE_ME / your-* value
sudo bash deploy/vm/install.sh       # builds, starts, configures nginx + TLS

sudo nano /etc/wacrm/migrate.env     # paste the Session pooler URL
sudo bash deploy/vm/migrate.sh       # shows pending migrations, asks, applies
```

**Back up `ENCRYPTION_KEY`** from `/etc/wacrm/wacrm.env` in your password
manager. Losing it orphans every stored WhatsApp token.

Then in Supabase → **Authentication → URL Configuration**:

- Site URL: `https://<your-domain>`
- Redirect URLs: `https://<your-domain>/**`

Open `https://<your-domain>/signup` and create the owner account.

## Connect WhatsApp (needs your Meta details)

1. Create a Meta for Developers account and a Meta Business portfolio.
   Complete **business verification** to lift messaging limits.
2. My Apps → Create App → **Business** → add the **WhatsApp** product.
3. WhatsApp → API Setup → add your number. It must **not** be registered on
   the WhatsApp or WhatsApp Business phone app (delete it there first), and
   must receive an SMS or call.
4. Note the **Phone number ID** and **WhatsApp Business Account ID**.
5. Business Settings → Users → System users → Add (`wacrm-system-user`,
   Admin). Assign the app and the WABA to it, then generate a token with
   `whatsapp_business_management` and `whatsapp_business_messaging`.
   It is shown **once**.
6. App Settings → Basic → copy **App Secret** and **App ID** into
   `/etc/wacrm/wacrm.env` (`META_APP_SECRET`, `META_APP_ID`), then
   `sudo systemctl restart wacrm`.
7. In wacrm: **Settings → WhatsApp** → Phone number ID, WABA ID, the System
   User token, and a verify token you make up.
8. Meta → WhatsApp → Configuration → Webhook: callback
   `https://<your-domain>/api/whatsapp/webhook`, the same verify token →
   Verify and save. Subscribe to `messages`,
   `message_template_status_update`, `message_template_quality_update`,
   `message_template_components_update`.
9. Add a privacy policy URL and switch the app to **Live**, then send a test
   message and reply from the inbox.

## Operate

| Task | Command |
|---|---|
| Deploy latest `main` | `cd ~/wacrm-kit && git pull && sudo bash deploy/vm/install.sh` |
| Deploy a tag/commit | `sudo bash deploy/vm/install.sh --ref <tag-or-sha>` |
| Logs | `journalctl -u wacrm -f` |
| Cron runs | `systemctl list-timers wacrm-cron.timer`, `journalctl -u wacrm-cron` |
| Roll back | `sudo ln -sfn /opt/wacrm/releases/<older> /opt/wacrm/current && sudo systemctl restart wacrm` |
| New migrations after an update | `sudo bash deploy/vm/migrate.sh` |
| Pull upstream fixes | in a clone: `git fetch upstream && git merge upstream/main`, run `npm audit`, PR to `main` |

`NEXT_PUBLIC_*` values are compiled in: changing one needs `install.sh`
(rebuild). Other values need only `sudo systemctl restart wacrm`.

Once certbot has added TLS to `/etc/nginx/sites-available/wacrm.conf`,
`install.sh` stops rewriting that file. Edit it by hand if the port changes.

## Uninstall

```bash
sudo systemctl disable --now wacrm.service wacrm-cron.timer
sudo rm /etc/systemd/system/wacrm{.service,-cron.service,-cron.timer} \
  /etc/nginx/sites-enabled/wacrm.conf /etc/nginx/sites-available/wacrm.conf
sudo systemctl daemon-reload && sudo nginx -t && sudo systemctl reload nginx
sudo certbot delete --cert-name <your-domain>
sudo rm -rf /opt/wacrm /etc/wacrm && sudo userdel wacrm
```
