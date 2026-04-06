# n8n Self-Hosted Deployment

One-command deployment of [n8n](https://n8n.io) workflow automation with PostgreSQL on a Linux server, using Docker Compose, nginx reverse proxy, and upstream SSL termination.

## Architecture

```
Internet → Load Balancer / Cloudflare (SSL) → nginx (port 80) → localhost:5678 → n8n container → postgres container
```

- **n8n** runs in Docker, bound to `127.0.0.1:5678` (not exposed directly)
- **PostgreSQL 16** runs in a separate container on an internal Docker network
- **nginx** reverse proxies with WebSocket support for the n8n editor
- **SSL** is terminated upstream (load balancer, Cloudflare, etc.)

## Prerequisites

- Linux server (Ubuntu/Debian) with root access
- nginx installed and running
- SSL termination configured upstream (load balancer, Cloudflare, etc.)
- A domain name with DNS pointing to your server
- Port 80 open in your firewall

## Quick Start

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/n8n.git
cd n8n

# Run the deployment
chmod +x *.sh
sudo ./deploy.sh
```

The script will:
1. Check for Docker, Docker Compose, and nginx (installs Docker if missing)
2. Generate secure passwords and create a `.env` file
3. Write `docker-compose.yml` with n8n + PostgreSQL
4. Configure nginx as a reverse proxy with WebSocket support
5. Start n8n and wait for it to be healthy

## Configuration

Copy the example env file and edit it, or let `deploy.sh` generate one for you:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN_NAME` | — | Your domain for n8n |
| `GENERIC_TIMEZONE` | `UTC` | Server timezone (e.g. `America/New_York`) |
| `EXECUTIONS_DATA_MAX_AGE` | `168` | Hours to keep execution data (7 days) |
| `N8N_LOG_LEVEL` | `info` | Log verbosity (`info`, `debug`, `warn`, `error`) |
| `N8N_ENCRYPTION_KEY` | Auto-generated | Encryption key for credentials stored in n8n |
| `POSTGRES_PASSWORD` | Auto-generated | PostgreSQL password |

## What's Included

| File | Purpose |
|------|---------|
| `deploy.sh` | First-time deployment (Docker + nginx + n8n + PostgreSQL) |
| `update.sh` | Pull latest n8n image + restart (runs backup first) |
| `backup.sh` | Dump PostgreSQL + archive n8n data to `backups/` |
| `uninstall.sh` | Stop containers + remove nginx config |

## Usage

### Day-to-day operations

```bash
docker compose logs -f            # view all logs
docker compose logs -f n8n        # n8n logs only
docker compose restart n8n        # restart n8n
./update.sh                       # update to latest version
./backup.sh                       # manual backup
docker compose down               # stop everything
./uninstall.sh                    # full teardown
```

### Scheduled backups (recommended)

```bash
# Add to root's crontab (daily at 2 AM):
crontab -e
0 2 * * * /path/to/n8n/backup.sh >> /var/log/n8n-backup.log 2>&1
```

Backups include a PostgreSQL dump, n8n data archive, and `.env` copy. Auto-pruned after 30 days.

### Configuration changes

Edit `.env` and restart:

```bash
docker compose down && docker compose up -d
```

## Troubleshooting

**"Connection lost" in n8n editor**
WebSocket issue. Verify nginx config has `Upgrade` and `Connection` headers. The deploy script handles this automatically.

**Can't reach n8n after deployment**
Check: DNS points to your server, port 80 is open, nginx is running (`systemctl status nginx`), n8n is running (`docker compose ps`).

**502 Bad Gateway**
n8n container may not be running. Check `docker compose logs n8n`.

## Security

- n8n binds to `127.0.0.1` only — not directly accessible from the internet
- PostgreSQL is on an internal Docker network — not exposed at all
- `.env` file is `chmod 600` and excluded from git
- SSL is enforced upstream (load balancer / Cloudflare)
- Security headers (X-Frame-Options, X-Content-Type-Options, Referrer-Policy) set in nginx

## License

MIT
