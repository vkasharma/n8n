#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# n8n Backup Script
# Run manually or via cron
# ─────────────────────────────────────────────

# Root is needed to read n8n-data (owned by uid 1000, mode 600 files)
[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
BACKUP_DIR="${INSTALL_DIR}/backups"
RETENTION_DAYS=30
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Backups contain the encryption key and all credentials
umask 077
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

echo "▸ Backing up n8n (${TIMESTAMP})..."

# Load env
set -a
source "${INSTALL_DIR}/.env"
set +a

cd "${INSTALL_DIR}"

# ── Database dump ──
# Written to a temp name first so a failed dump never looks like a good backup
echo "  Dumping PostgreSQL..."
DB_FILE="${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
docker compose exec -T postgres pg_dump \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    --no-owner \
    --clean \
    --if-exists \
    | gzip > "${DB_FILE}.partial"
mv "${DB_FILE}.partial" "${DB_FILE}"

echo "  ✓ Database backed up"

# ── n8n data directory ──
echo "  Archiving n8n data..."
tar -czf "${BACKUP_DIR}/n8n-data_${TIMESTAMP}.tar.gz" \
    -C "${INSTALL_DIR}" n8n-data/ local-files/

echo "  ✓ n8n data backed up"

# ── Env file ──
cp "${INSTALL_DIR}/.env" "${BACKUP_DIR}/env_${TIMESTAMP}.bak"

# ── Prune old backups ──
echo "  Pruning backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -mtime +"${RETENTION_DAYS}" -delete

echo ""
echo "✓ Backup complete → ${BACKUP_DIR}/"
ls -lh "${BACKUP_DIR}/"*"${TIMESTAMP}"* 2>/dev/null || true
