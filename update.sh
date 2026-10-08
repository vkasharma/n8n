#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# n8n Update Script
# Backs up, pulls the image for N8N_VERSION (default: stable)
# and recreates the containers. Expect ~1 minute of downtime.
# ─────────────────────────────────────────────

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"

echo "▸ Updating n8n..."

cd "${INSTALL_DIR}"
OLD_VERSION=$(docker exec n8n n8n --version 2>/dev/null || echo "unknown")
echo "  Current version: ${OLD_VERSION}"

# Run backup first
if [[ -f "${SCRIPT_DIR}/backup.sh" ]]; then
    echo "  Running backup before update..."
    bash "${SCRIPT_DIR}/backup.sh"
    echo ""
fi

echo "  Pulling latest images..."
docker compose pull

echo "  Restarting containers..."
docker compose up -d

echo "  Waiting for n8n to become ready..."
for i in $(seq 1 90); do
    if curl -sf http://127.0.0.1:5678/healthz &>/dev/null; then
        echo "  ✓ n8n is healthy"
        break
    fi
    if [[ $i -eq 90 ]]; then
        echo "  ⚠ n8n did not respond within 3 minutes — check logs:"
        echo "    docker compose logs n8n"
        exit 1
    fi
    sleep 2
done

echo "  Removing old images..."
docker image prune -f >/dev/null

NEW_VERSION=$(docker exec n8n n8n --version 2>/dev/null || echo "unknown")
echo ""
echo "✓ Update complete: ${OLD_VERSION} → ${NEW_VERSION}"
