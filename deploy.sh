#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# n8n Deployment Script
# Deploys n8n + PostgreSQL via Docker Compose behind nginx.
#
# Two access modes:
#   ip      – plain HTTP on the server's public IP (no domain needed)
#   domain  – domain name, SSL terminated upstream (LB / Cloudflare)
# ─────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
ENV_FILE="${INSTALL_DIR}/.env"
NEW_SECRETS=false

echo "══════════════════════════════════════════════"
echo "  n8n Self-Hosted Deployment"
echo "══════════════════════════════════════════════"
echo ""

detect_public_ip() {
    local ip
    for url in https://ifconfig.me https://api.ipify.org https://icanhazip.com; do
        ip=$(curl -fsS -4 -m 5 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    done
    return 1
}

# ── Collect configuration ──────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
    echo "▸ Existing .env found — reusing its configuration."
    set -a; source "${ENV_FILE}"; set +a
    if [[ -z "${ACCESS_MODE:-}" ]]; then
        echo "Error: .env has no ACCESS_MODE (old format). Compare with .env.example." && exit 1
    fi
else
    PUBLIC_IP=$(detect_public_ip || true)
    read -rp "Domain for n8n (leave blank to use the IP address${PUBLIC_IP:+ ${PUBLIC_IP}}): " DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        ACCESS_MODE=ip
        if [[ -z "$PUBLIC_IP" ]]; then
            read -rp "Could not detect public IP. Enter it: " PUBLIC_IP
            [[ -z "$PUBLIC_IP" ]] && echo "Error: IP is required." && exit 1
        fi
        N8N_HOST="${PUBLIC_IP}"
        N8N_PROTOCOL=http
        N8N_SECURE_COOKIE=false
    else
        ACCESS_MODE=domain
        N8N_HOST="${DOMAIN}"
        N8N_PROTOCOL=https
        N8N_SECURE_COOKIE=true
    fi
    WEBHOOK_URL="${N8N_PROTOCOL}://${N8N_HOST}/"

    echo ""
    echo "Mode:  ${ACCESS_MODE}"
    echo "URL:   ${WEBHOOK_URL}"
    echo ""
    read -rp "Continue? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 1
fi

# ── Pre-flight checks ─────────────────────────────────────
echo ""
echo "▸ Running pre-flight checks..."

# Docker (the official script also installs the compose plugin)
if ! command -v docker &>/dev/null; then
    echo "  ✗ Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo "  ✓ Docker installed"
else
    echo "  ✓ Docker found"
fi

if ! docker compose version &>/dev/null; then
    echo "  ✗ Docker Compose plugin not found. Installing..."
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq docker-compose-plugin
    echo "  ✓ Docker Compose installed"
else
    echo "  ✓ Docker Compose found"
fi

# Let the invoking user run docker without sudo
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && ! id -nG "${SUDO_USER}" | grep -qw docker; then
    usermod -aG docker "${SUDO_USER}"
    echo "  ✓ Added ${SUDO_USER} to the docker group (log out/in to take effect)"
fi

# Nginx
if ! command -v nginx &>/dev/null; then
    echo "  ✗ Nginx not found. Installing..."
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq nginx
    echo "  ✓ Nginx installed"
else
    echo "  ✓ Nginx found"
fi
systemctl enable --now nginx >/dev/null 2>&1

# Swap — n8n + Postgres can exceed RAM on small VMs (e.g. 1 GB free tier)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ $MEM_MB -lt 2048 && -z "$(swapon --show --noheadings)" ]]; then
    echo "  ✗ ${MEM_MB} MB RAM and no swap. Creating 2 GB /swapfile..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "  ✓ Swap enabled"
else
    echo "  ✓ Memory OK (${MEM_MB} MB RAM, swap: $(swapon --show --noheadings | wc -l) device(s))"
fi

# Host firewall — Oracle Cloud images ship iptables rules that REJECT
# everything except SSH, so port 80 must be opened explicitly.
HTTP_RULE=(-p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT)
if iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
    if ! iptables -C INPUT "${HTTP_RULE[@]}" 2>/dev/null; then
        REJECT_POS=$(iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" {print $1; exit}')
        iptables -I INPUT "${REJECT_POS}" "${HTTP_RULE[@]}"
    fi
    RULES_V4=/etc/iptables/rules.v4
    if [[ -f "$RULES_V4" ]] && ! grep -qx -- "-A INPUT ${HTTP_RULE[*]}" "$RULES_V4"; then
        sed -i "/^-A INPUT -j REJECT/i -A INPUT ${HTTP_RULE[*]}" "$RULES_V4"
    fi
    echo "  ✓ iptables: port 80 open (persisted in ${RULES_V4})"
fi
if command -v ufw &>/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow 80/tcp >/dev/null
    echo "  ✓ ufw: port 80 open"
fi

# ── Create directories ────────────────────────────────────
echo ""
echo "▸ Setting up ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/n8n-data" "${INSTALL_DIR}/postgres-data" "${INSTALL_DIR}/local-files"

# n8n container runs as user 'node' (uid 1000)
chown -R 1000:1000 "${INSTALL_DIR}/n8n-data" "${INSTALL_DIR}/local-files"

# ── Write .env ─────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
    NEW_SECRETS=true
    HOST_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)

    (
        umask 077
        cat > "${ENV_FILE}" <<EOF
# n8n Environment Configuration
# Generated on $(date -Iseconds)

# ── Version ──
# "stable" tracks the latest stable release; pin e.g. 2.42.5 to freeze
N8N_VERSION=stable

# ── Access ──
ACCESS_MODE=${ACCESS_MODE}
N8N_HOST=${N8N_HOST}
N8N_PROTOCOL=${N8N_PROTOCOL}
WEBHOOK_URL=${WEBHOOK_URL}
N8N_SECURE_COOKIE=${N8N_SECURE_COOKIE}

# ── Encryption (losing this key makes stored credentials unreadable) ──
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# ── Database ──
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n

# ── n8n Settings ──
GENERIC_TIMEZONE=${HOST_TZ:-UTC}
N8N_LOG_LEVEL=info
N8N_METRICS=false
N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false

# ── Execution Settings ──
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EOF
    )
    echo "  ✓ .env created (credentials auto-generated)"
else
    chmod 600 "${ENV_FILE}"
    echo "  ✓ .env already exists (keeping existing)"
fi

# ── Write nginx config ─────────────────────────────────────
NGINX_CONF="/etc/nginx/sites-available/n8n"

if [[ "${ACCESS_MODE}" == "ip" ]]; then
    # Catch-all server: reachable by IP regardless of Host header
    LISTEN_OPTS=" default_server"
    SERVER_NAME="_"
    FORWARDED_PROTO="\$scheme"
    # The stock 'default' site also claims default_server on :80
    rm -f /etc/nginx/sites-enabled/default
else
    LISTEN_OPTS=""
    SERVER_NAME="${N8N_HOST}"
    # Preserve the protocol seen by the upstream SSL terminator
    FORWARDED_PROTO="\$n8n_forwarded_proto"
fi

cat > "${NGINX_CONF}" <<NGINX
# ─────────────────────────────────────────────
# n8n reverse proxy — managed by deploy.sh
# Access mode: ${ACCESS_MODE}
# ─────────────────────────────────────────────

map \$http_upgrade \$n8n_connection_upgrade {
    default upgrade;
    ''      close;
}

map \$http_x_forwarded_proto \$n8n_forwarded_proto {
    default \$http_x_forwarded_proto;
    ''      \$scheme;
}

server {
    listen 80${LISTEN_OPTS};
    listen [::]:80${LISTEN_OPTS};
    server_name ${SERVER_NAME};

    server_tokens off;

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
        proxy_set_header X-Forwarded-Proto ${FORWARDED_PROTO};

        # WebSocket support (required for n8n editor)
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$n8n_connection_upgrade;

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

ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/n8n
nginx -t && systemctl reload nginx
echo "  ✓ Nginx site enabled and reloaded"

# ── Start n8n ──────────────────────────────────────────────
echo ""
echo "▸ Starting n8n..."
cd "${INSTALL_DIR}"
docker compose pull
docker compose up -d

# First start runs DB migrations — can take a few minutes on small VMs
echo "  Waiting for n8n to become ready..."
for i in $(seq 1 90); do
    if curl -sf http://127.0.0.1:5678/healthz &>/dev/null; then
        echo "  ✓ n8n is running! ($(docker exec n8n n8n --version 2>/dev/null || echo 'version unknown'))"
        break
    fi
    if [[ $i -eq 90 ]]; then
        echo "  ⚠ n8n did not respond within 3 minutes — check logs:"
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
echo "  URL:       ${WEBHOOK_URL}"
echo "  Install:   ${INSTALL_DIR}"
echo "  Env:       ${ENV_FILE}"
echo ""
if [[ "${NEW_SECRETS}" == true ]]; then
    echo "  ── Credentials (also stored in .env — back them up!) ──"
    echo "  Postgres password: ${POSTGRES_PASSWORD}"
    echo "  Encryption key:    ${N8N_ENCRYPTION_KEY}"
    echo ""
fi
if [[ "${ACCESS_MODE}" == "ip" ]]; then
    echo "  ── Cloud firewall ──"
    echo "  Also allow inbound TCP 80 in your cloud provider's firewall"
    echo "  (Oracle Cloud: VCN → Security List / NSG → Ingress rule"
    echo "   source 0.0.0.0/0, TCP, destination port 80)."
    echo ""
    echo "  ⚠ Traffic is plain HTTP — passwords travel unencrypted."
    echo ""
fi
echo "  ── Useful Commands ──"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose logs -f        # view logs"
echo "  docker compose restart n8n    # restart n8n"
echo "  docker compose down           # stop everything"
echo ""
echo "  Open ${WEBHOOK_URL} to set up your admin account."
echo "══════════════════════════════════════════════"
