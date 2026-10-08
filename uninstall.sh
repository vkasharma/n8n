#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# n8n Uninstall Script
# ─────────────────────────────────────────────

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"

echo "⚠  This will stop n8n and remove its nginx config."
echo "   Data in ${INSTALL_DIR} will NOT be deleted automatically."
echo ""
read -rp "Are you sure? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

echo "▸ Stopping containers..."
cd "${INSTALL_DIR}" && docker compose down

echo "▸ Removing nginx config..."
rm -f /etc/nginx/sites-enabled/n8n
rm -f /etc/nginx/sites-available/n8n
# deploy.sh disables the stock default site in IP mode; bring it back
if [[ -z "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" && -f /etc/nginx/sites-available/default ]]; then
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi
nginx -t && systemctl reload nginx
echo "  ✓ Nginx config removed"

echo ""
echo "✓ n8n has been stopped and nginx config removed."
echo ""
echo "  Data is still at: ${INSTALL_DIR}"
echo "  To fully remove:  sudo rm -rf ${INSTALL_DIR}"
echo "  To remove images: docker image prune -a"
echo "  Port 80 stays open in iptables (/etc/iptables/rules.v4) — remove the"
echo "  '--dport 80 -j ACCEPT' INPUT rule there if you no longer need it."
