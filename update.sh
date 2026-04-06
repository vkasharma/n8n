#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# n8n Update Script
# Pulls latest image and restarts with zero downtime
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"

echo "▸ Updating n8n..."

# Run backup first
if [[ -f "${SCRIPT_DIR}/backup.sh" ]]; then
    echo "  Running backup before update..."
    bash "${SCRIPT_DIR}/backup.sh"
    echo ""
fi

cd "${INSTALL_DIR}"

echo "  Pulling latest images..."
docker compose pull

echo "  Restarting containers..."
docker compose up -d

echo "  Waiting for n8n to become ready..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:5678/healthz &>/dev/null; then
        echo "  ✓ n8n is healthy"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "  ⚠ n8n did not respond within 60s — check logs:"
        echo "    docker compose logs n8n"
        exit 1
    fi
    sleep 2
done

echo ""
echo "  Current version:"
docker exec n8n n8n --version 2>/dev/null || echo "  (could not determine version)"
echo ""
echo "✓ Update complete"
