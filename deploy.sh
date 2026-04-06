#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# n8n Deployment Script
# Deploys n8n + PostgreSQL via Docker Compose
# with nginx reverse proxy (SSL terminated upstream)
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"

echo "══════════════════════════════════════════════"
echo "  n8n Self-Hosted Deployment"
echo "══════════════════════════════════════════════"
echo ""

# ── Collect configuration ──────────────────────────────────
read -rp "Enter your domain for n8n (e.g. n8n.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Error: Domain is required." && exit 1
fi

# Generate secure passwords
POSTGRES_PASSWORD=$(openssl rand -hex 32)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

echo ""
echo "Domain:  ${DOMAIN}"
echo ""
read -rp "Continue? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 1

# ── Pre-flight checks ─────────────────────────────────────
echo ""
echo "▸ Running pre-flight checks..."

# Docker
if ! command -v docker &>/dev/null; then
    echo "  ✗ Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo "  ✓ Docker installed"
else
    echo "  ✓ Docker found"
fi

# Docker Compose (v2 plugin)
if ! docker compose version &>/dev/null; then
    echo "  ✗ Docker Compose plugin not found. Installing..."
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    echo "  ✓ Docker Compose installed"
else
    echo "  ✓ Docker Compose found"
fi

# Nginx
if ! command -v nginx &>/dev/null; then
    echo "  ✗ Nginx not found — this script expects nginx already installed."
    exit 1
else
    echo "  ✓ Nginx found"
fi

# ── Create directories ────────────────────────────────────
echo ""
echo "▸ Setting up ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/n8n-data"
mkdir -p "${INSTALL_DIR}/postgres-data"
mkdir -p "${INSTALL_DIR}/local-files"

# n8n container runs as user 'node' (uid 1000)
chown -R 1000:1000 "${INSTALL_DIR}/n8n-data"

# ── Write .env ─────────────────────────────────────────────
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    cat > "${INSTALL_DIR}/.env" <<EOF
# n8n Environment Configuration
# Generated on $(date -Iseconds)

# ── Domain & Protocol ──
DOMAIN_NAME=${DOMAIN}
N8N_PROTOCOL=https
N8N_HOST=${DOMAIN}
WEBHOOK_URL=https://${DOMAIN}/

# ── Encryption ──
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# ── Database ──
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

# ── n8n Settings ──
N8N_PORT=5678
N8N_METRICS=true
GENERIC_TIMEZONE=UTC
N8N_LOG_LEVEL=info
N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false

# ── Execution Settings ──
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EOF

    chmod 600 "${INSTALL_DIR}/.env"
    echo "  ✓ .env created (credentials auto-generated)"
else
    echo "  ✓ .env already exists (keeping existing)"
fi

# Load env
set -a
source "${INSTALL_DIR}/.env"
set +a

# ── Write docker-compose.yml ──────────────────────────────
cat > "${INSTALL_DIR}/docker-compose.yml" <<'COMPOSE'
services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-internal

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_LOG_LEVEL=${N8N_LOG_LEVEL}
      - N8N_METRICS=${N8N_METRICS}
      - N8N_DIAGNOSTICS_ENABLED=${N8N_DIAGNOSTICS_ENABLED}
      - N8N_PERSONALIZATION_ENABLED=${N8N_PERSONALIZATION_ENABLED}
      - EXECUTIONS_DATA_PRUNE=${EXECUTIONS_DATA_PRUNE}
      - EXECUTIONS_DATA_MAX_AGE=${EXECUTIONS_DATA_MAX_AGE}
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - ./n8n-data:/home/node/.n8n
      - ./local-files:/files
    networks:
      - n8n-internal

networks:
  n8n-internal:
    driver: bridge
COMPOSE

echo "  ✓ docker-compose.yml created"

# ── Write nginx config ─────────────────────────────────────
NGINX_CONF="/etc/nginx/sites-available/n8n"

cat > "${NGINX_CONF}" <<NGINX
# ─────────────────────────────────────────────
# n8n reverse proxy — managed by deploy.sh
# SSL terminated upstream (LB / Cloudflare)
# ─────────────────────────────────────────────

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Request size (for file uploads in n8n)
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:5678;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (required for n8n editor)
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;

        # Timeouts for long-running workflows
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
        proxy_connect_timeout 60s;

        # Disable buffering for streaming
        proxy_buffering off;
        proxy_cache off;
    }
}
NGINX

echo "  ✓ Nginx config written to ${NGINX_CONF}"

# Enable the site
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/n8n
echo "  ✓ Nginx site enabled"

# Test and reload nginx
nginx -t && systemctl reload nginx
echo "  ✓ Nginx reloaded"

# ── Start n8n ──────────────────────────────────────────────
echo ""
echo "▸ Starting n8n..."
cd "${INSTALL_DIR}"
docker compose pull
docker compose up -d

# Wait for healthy
echo "  Waiting for n8n to become ready..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:5678/healthz &>/dev/null; then
        echo "  ✓ n8n is running!"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "  ⚠ n8n did not respond within 60s — check logs:"
        echo "    docker compose logs n8n"
    fi
    sleep 2
done

# ── Print summary ──────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  Deployment Complete!"
echo "══════════════════════════════════════════════"
echo ""
echo "  URL:       https://${DOMAIN}"
echo "  Install:   ${INSTALL_DIR}"
echo "  Env:       ${INSTALL_DIR}/.env"
echo ""
echo "  ── Credentials (save these!) ──"
echo "  Postgres password: ${POSTGRES_PASSWORD}"
echo "  Encryption key:    ${N8N_ENCRYPTION_KEY}"
echo ""
echo "  ── Useful Commands ──"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose logs -f        # view logs"
echo "  docker compose restart n8n    # restart n8n"
echo "  docker compose down           # stop everything"
echo ""
echo "  Open https://${DOMAIN} to set up your admin account."
echo "══════════════════════════════════════════════"
