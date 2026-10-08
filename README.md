# n8n Self-Hosted Deployment

One-command deployment of [n8n](https://n8n.io) workflow automation with PostgreSQL on a Linux server, using Docker Compose and an nginx reverse proxy. Works with a plain public IP (no domain needed) or with a domain behind upstream SSL termination.

## Architecture

```
IP mode:      Internet → nginx :80 (HTTP) → 127.0.0.1:5678 → n8n container → postgres container
Domain mode:  Internet → LB / Cloudflare (SSL) → nginx :80 → 127.0.0.1:5678 → n8n → postgres
```

- **n8n** runs in Docker, bound to `127.0.0.1:5678` (not exposed directly)
- **PostgreSQL 16** runs in a separate container on an internal Docker network
- **nginx** reverse proxies with WebSocket support for the n8n editor
- **Version**: the `stable` image tag by default (latest stable release; `update.sh` pulls new ones)

## Prerequisites

- Ubuntu/Debian server with sudo access (Docker and nginx are installed if missing)
- Inbound TCP port 80 allowed in your cloud firewall
- Domain mode only: a domain pointing at the server plus SSL termination upstream

### Oracle Cloud

`deploy.sh` opens port 80 in the instance's iptables rules, but you also need an ingress rule in the cloud console:

**Networking → Virtual Cloud Networks → your VCN → Security Lists → Default → Add Ingress Rule**
- Source CIDR `0.0.0.0/0`, IP protocol TCP, destination port `80`

Use a **reserved public IP** if you can. An ephemeral IP can change when the instance is stopped and started; see [Changing the IP](#changing-the-ip) if that happens.

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/n8n.git
cd n8n
./deploy.sh        # re-runs itself with sudo
```

When prompted for a domain, **leave it blank to use the server's public IP**. The script will:
1. Install Docker, Docker Compose and nginx if missing
2. Add a 2 GB swap file on machines with < 2 GB RAM and no swap
3. Open port 80 in the host firewall (iptables / ufw)
4. Generate secure passwords and create `.env`
5. Configure nginx as a reverse proxy with WebSocket support
6. Pull n8n + PostgreSQL and start them

Then open `http://<your-ip>/` and create the owner account.

## Configuration

`deploy.sh` generates `.env`; see `.env.example` for every option.

| Variable | Default | Description |
|----------|---------|-------------|
| `N8N_VERSION` | `stable` | Image tag. Pin e.g. `2.42.5` to freeze the version |
| `ACCESS_MODE` | `ip` / `domain` | Chosen at deploy time |
| `N8N_HOST` / `WEBHOOK_URL` | public IP | Address n8n uses for links and webhook URLs |
| `N8N_SECURE_COOKIE` | `false` in IP mode | Must be `false` over plain HTTP or login fails |
| `GENERIC_TIMEZONE` | host timezone | e.g. `Asia/Kolkata`, used by Schedule triggers |
| `EXECUTIONS_DATA_MAX_AGE` | `168` | Hours to keep execution data (7 days) |
| `N8N_LOG_LEVEL` | `info` | `info`, `debug`, `warn`, `error` |
| `N8N_ENCRYPTION_KEY` | auto-generated | Encrypts stored credentials. **Do not lose it** |
| `POSTGRES_PASSWORD` | auto-generated | PostgreSQL password |

Files that workflows read or write (Read/Write Files node) must live in `local-files/`, which the container sees as `/files`. n8n 2.x blocks every other path.

## What's Included

| File | Purpose |
|------|---------|
| `deploy.sh` | First-time deployment (Docker + nginx + firewall + swap + n8n) |
| `docker-compose.yml` | n8n + PostgreSQL services (reads values from `.env`) |
| `update.sh` | Backup, then pull the latest image and restart |
| `backup.sh` | Dump PostgreSQL + archive n8n data to `backups/` |
| `uninstall.sh` | Stop containers + remove nginx config |

## Usage

### Day-to-day operations

```bash
docker compose logs -f n8n        # n8n logs
docker compose restart n8n        # restart n8n
docker compose ps                 # container status
./update.sh                       # update to the latest stable release
./backup.sh                       # manual backup
./uninstall.sh                    # teardown (keeps data)
```

### Scheduled backups (recommended)

```bash
sudo crontab -e
0 2 * * * /home/ubuntu/n8n/backup.sh >> /var/log/n8n-backup.log 2>&1
```

Backups include a PostgreSQL dump, the n8n data + local-files archive and a copy of `.env`. They are auto-pruned after 30 days. They sit on the same disk, so copy them off the server now and then.

### Restoring a backup

```bash
docker compose stop n8n
gunzip -c backups/db_YYYYMMDD_HHMMSS.sql.gz | docker compose exec -T postgres psql -U n8n -d n8n
sudo tar -xzf backups/n8n-data_YYYYMMDD_HHMMSS.tar.gz -C .
docker compose start n8n
```

The `.env` in use must have the same `N8N_ENCRYPTION_KEY` as the backup, or stored credentials can't be decrypted.

### Configuration changes

Edit `.env`, then recreate the containers:

```bash
docker compose up -d
```

### Changing the IP

If the server's public IP changes, update `N8N_HOST` and `WEBHOOK_URL` in `.env`, then run `docker compose up -d`. nginx needs no change in IP mode.

## Limitations of IP mode (plain HTTP)

- **Traffic is unencrypted.** Your login, session cookie and webhook payloads cross the internet in clear text. Use a strong password and consider HTTPS (below).
- **OAuth integrations** (Google, Microsoft, Slack…) generally need an HTTPS redirect URL on a real hostname, so they won't work on a bare IP. API-key credentials work fine.
- Some browser features (clipboard API, etc.) are restricted on non-HTTPS origins.

**Free HTTPS without buying a domain:** a wildcard-DNS hostname such as `203-0-113-10.sslip.io` resolves to `203.0.113.10` and can get a Let's Encrypt certificate via certbot. Port 443 must be open too.

## Troubleshooting

**Browser times out on `http://<ip>/`**
The cloud firewall (Oracle security list / NSG) isn't allowing TCP 80. Check the server side with `curl -I http://127.0.0.1/` and `sudo iptables -L INPUT -n`.

**Login doesn't stick / "secure cookie" error**
You're on plain HTTP with `N8N_SECURE_COOKIE=true`. Set it to `false` in `.env` and run `docker compose up -d`.

**"Connection lost" in the n8n editor**
WebSocket issue. Verify the nginx config has the `Upgrade` and `Connection` headers (deploy.sh writes them).

**502 Bad Gateway**
n8n isn't running or is still starting (first start runs DB migrations). Check `docker compose logs n8n`.

**n8n gets OOM-killed on a 1 GB VM**
Make sure swap is active (`swapon --show`). deploy.sh creates `/swapfile` automatically.

## Security

- n8n binds to `127.0.0.1` only. PostgreSQL is not exposed at all.
- `.env` and `backups/` are root-only (`600` / `700`) and excluded from git
- Prometheus `/metrics` is disabled (`N8N_METRICS=false`) so it isn't public
- nginx sets X-Frame-Options, X-Content-Type-Options and Referrer-Policy and hides its version

## License

MIT
