#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# n8n Backup Script
# Run manually or via cron
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
BACKUP_DIR="${INSTALL_DIR}/backups"
RETENTION_DAYS=30
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "${BACKUP_DIR}"

echo "▸ Backing up n8n (${TIMESTAMP})..."

# Load env
set -a
source "${INSTALL_DIR}/.env"
set +a

# ── Database dump ──
echo "  Dumping PostgreSQL..."
docker exec n8n-postgres pg_dump \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    --no-owner \
    --clean \
    --if-exists \
    | gzip > "${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"

echo "  ✓ Database backed up"

# ── n8n data directory ──
echo "  Archiving n8n data..."
tar -czf "${BACKUP_DIR}/n8n-data_${TIMESTAMP}.tar.gz" \
    -C "${INSTALL_DIR}" n8n-data/

echo "  ✓ n8n data backed up"

# ── Env file ──
cp "${INSTALL_DIR}/.env" "${BACKUP_DIR}/env_${TIMESTAMP}.bak"
chmod 600 "${BACKUP_DIR}/env_${TIMESTAMP}.bak"

# ── Prune old backups ──
echo "  Pruning backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -mtime +${RETENTION_DAYS} -delete

echo ""
echo "✓ Backup complete → ${BACKUP_DIR}/"
ls -lh "${BACKUP_DIR}/"*"${TIMESTAMP}"* 2>/dev/null || true
