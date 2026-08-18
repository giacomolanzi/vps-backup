#!/bin/bash
# =============================================================================
# Server Backup Script — generico e portabile
#
# Va posizionato in una cartella "backups" affiancata a una cartella "docker"
# (es. /opt/backups + /opt/docker, oppure ~/srv/backups + ~/srv/docker).
# Nessun path assoluto da configurare: la cartella da backuppare viene dedotta
# dalla posizione di questo script.
#
# Covers: PostgreSQL (opzionale), directory Docker, SSH, Fail2ban (opzionale),
#         UFW (opzionale), Docker named volumes
# Usage: ./backup.sh [--no-volumes]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/../docker" && pwd)"

# Carica configurazione specifica dell'host
if [ ! -f "${SCRIPT_DIR}/config.sh" ]; then
    echo "ERROR: config.sh non trovato in ${SCRIPT_DIR} (copia config.example.sh)" >&2
    exit 1
fi
source "${SCRIPT_DIR}/config.sh"

GCS_KEY="${SCRIPT_DIR}/gcs-key.json"

BACKUP_DATE=$(date +%Y-%m-%d_%H-%M)
BACKUP_BASE="${SCRIPT_DIR}"
WORK_DIR="${BACKUP_BASE}/.work_${BACKUP_DATE}"
ARCHIVE="${BACKUP_BASE}/$(hostname)_backup_${BACKUP_DATE}.tar.gz"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }

discord() {
    [ -z "${DISCORD_WEBHOOK:-}" ] && return 0
    local color="$1" title="$2" message="$3"
    curl -s -o /dev/null -X POST "${DISCORD_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${message}\",\"color\":${color}}]}"
}

on_error() {
    local line="$1"
    discord 15158332 "❌ Backup fallito — $(hostname)" \
        "Errore alla riga ${line}\\nData: ${BACKUP_DATE}\\nControlla: \`tail -50 ${BACKUP_BASE}/backup.log\`"
    [ -d "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"
}
trap 'on_error $LINENO' ERR
trap '[ -d "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"' EXIT

# =============================================================================
log "=== Backup avviato: ${BACKUP_DATE} (docker dir: ${DOCKER_DIR}) ==="
mkdir -p "${WORK_DIR}"

# =============================================================================
# 1. PostgreSQL (opzionale — salta se PG_CONTAINER non è impostato o non gira)
# =============================================================================
mkdir -p "${WORK_DIR}/postgres"
if [ -n "${PG_CONTAINER:-}" ] && docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
    log "[1/5] Dump PostgreSQL..."
    docker exec "${PG_CONTAINER}" pg_dumpall -U "${PG_USER}" \
        | gzip > "${WORK_DIR}/postgres/pg_dumpall.sql.gz"
    log "   pg_dumpall completato"

    ACTUAL_DBS=$(docker exec "${PG_CONTAINER}" psql -U "${PG_USER}" -d postgres -Atc \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")
    for DB in ${ACTUAL_DBS}; do
        docker exec "${PG_CONTAINER}" pg_dump -U "${PG_USER}" \
            --format=custom --compress=9 \
            "${DB}" > "${WORK_DIR}/postgres/${DB}.dump"
        log "   Dump individuale: ${DB}"
    done
else
    log "[1/5] PostgreSQL non configurato o non attivo, salto"
fi

# =============================================================================
# 2. Directory Docker
# =============================================================================
log "[2/5] Backup directory Docker (${DOCKER_DIR})..."

EXCLUDE_ARGS=()
for EXCL in "${DOCKER_EXCLUDES[@]:-}"; do
    [ -z "${EXCL}" ] && continue
    EXCLUDE_ARGS+=("--exclude=${DOCKER_DIR}/${EXCL}")
done

tar czf "${WORK_DIR}/docker.tar.gz" \
    "${EXCLUDE_ARGS[@]}" \
    --warning=no-file-changed \
    "${DOCKER_DIR}" 2>/dev/null || true
log "   Archiviato: ${DOCKER_DIR}"

# =============================================================================
# 3. SSH + Fail2ban
# =============================================================================
log "[3/5] Backup SSH e Fail2ban..."
mkdir -p "${WORK_DIR}/ssh"
sudo cp /etc/ssh/sshd_config "${WORK_DIR}/ssh/"
sudo cp -r /etc/ssh/sshd_config.d "${WORK_DIR}/ssh/" 2>/dev/null || true
[ -f ~/.ssh/authorized_keys ] && cp ~/.ssh/authorized_keys "${WORK_DIR}/ssh/authorized_keys"
whoami > "${WORK_DIR}/ssh/ssh_user.txt"
sudo chown -R "$(whoami)" "${WORK_DIR}/ssh/"
log "   SSH: porta $(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}'), chiavi salvate"

if [ -d /etc/fail2ban ]; then
    mkdir -p "${WORK_DIR}/fail2ban"
    sudo cp -r /etc/fail2ban "${WORK_DIR}/fail2ban/etc_fail2ban"
    sudo chown -R "$(whoami)" "${WORK_DIR}/fail2ban/"
    log "   Fail2ban: configurazione salvata"
fi

# =============================================================================
# 4. UFW Firewall (opzionale — salta se non installato)
# =============================================================================
log "[4/5] Backup UFW..."
if [ -d /etc/ufw ]; then
    mkdir -p "${WORK_DIR}/ufw"
    sudo cp -r /etc/ufw "${WORK_DIR}/ufw/etc_ufw"
    sudo chown -R "$(whoami)" "${WORK_DIR}/ufw/"
    sudo ufw status verbose > "${WORK_DIR}/ufw/status.txt" 2>/dev/null || true
    log "   UFW: regole salvate"
else
    log "   UFW non installato, salto"
fi

# =============================================================================
# 5. Named Docker volumes
# =============================================================================
if [[ "${1:-}" != "--no-volumes" ]]; then
    log "[5/5] Backup Docker named volumes..."
    mkdir -p "${WORK_DIR}/docker_volumes"
    VOLS=$(docker volume ls -q)
    VOL_COUNT=0
    if [ -n "${VOLS}" ]; then
        for VOL in ${VOLS}; do
            docker run --rm \
                -v "${VOL}:/vol_data:ro" \
                -v "${WORK_DIR}/docker_volumes:/backup" \
                alpine tar czf "/backup/${VOL}.tar.gz" -C /vol_data . 2>/dev/null \
            && VOL_COUNT=$((VOL_COUNT + 1)) \
            || warn "Volume vuoto o errore: ${VOL:0:16}..."
        done
    fi
    log "   Volumi archiviati: ${VOL_COUNT}"
else
    log "[5/5] Named volumes saltati (--no-volumes)"
    mkdir -p "${WORK_DIR}/docker_volumes"
fi

# =============================================================================
# Manifest
# =============================================================================
cat > "${WORK_DIR}/MANIFEST.txt" << EOF
Backup - ${BACKUP_DATE}
==============================
Hostname:        $(hostname)
OS:              $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
Kernel:          $(uname -r)
Docker:          $(docker --version)
Docker dir:      ${DOCKER_DIR}
Backup eseguito: $(date)

SERVIZI IN ESECUZIONE
---------------------
$(docker ps --format "  - {{.Names}}: {{.Image}}")

RETI DOCKER
-----------
$(docker network ls --format "  - {{.Name}} ({{.Driver}})")

RESTORE
-------
Posiziona questa cartella "backups" affiancata a una cartella "docker" (anche
vuota, verrà creata) ed esegui: sudo bash restore.sh
EOF

cp "${SCRIPT_DIR}/config.sh" "${WORK_DIR}/config.sh"
if [ -f "${SCRIPT_DIR}/restore.sh" ]; then
    cp "${SCRIPT_DIR}/restore.sh" "${WORK_DIR}/restore.sh"
    chmod +x "${WORK_DIR}/restore.sh"
fi

# =============================================================================
# Archivio finale
# =============================================================================
log "Creazione archivio finale..."
tar czf "${ARCHIVE}" -C "${BACKUP_BASE}" ".work_${BACKUP_DATE}/"
SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
log "=== Backup completato: $(basename "${ARCHIVE}") (${SIZE}) ==="

rm -rf "${WORK_DIR}"
trap - EXIT

# =============================================================================
# Rotazione
# =============================================================================
log "Rotazione: mantengo gli ultimi ${KEEP_BACKUPS} backup..."
ls -t "${BACKUP_BASE}"/"$(hostname)"_backup_*.tar.gz 2>/dev/null \
    | tail -n "+$((KEEP_BACKUPS + 1))" \
    | xargs -r rm -f
REMAINING=$(ls "${BACKUP_BASE}"/"$(hostname)"_backup_*.tar.gz 2>/dev/null | wc -l)
log "Backup disponibili: ${REMAINING}"

# =============================================================================
# Upload GCS (opzionale — salta se GCS_BUCKET o la chiave non sono presenti)
# =============================================================================
GCS_OK=false
if [ -n "${GCS_BUCKET:-}" ] && [ -f "${GCS_KEY}" ]; then
    log "Upload su GCS: ${GCS_BUCKET}..."
    docker run --rm \
        -v "${ARCHIVE}:/data/$(basename "${ARCHIVE}"):ro" \
        -v "${GCS_KEY}:/key.json:ro" \
        google/cloud-sdk:alpine \
        sh -c "gcloud auth activate-service-account --key-file=/key.json -q \
               && gsutil cp '/data/$(basename "${ARCHIVE}")' '${GCS_BUCKET}/'" \
    && { log "Upload completato: ${GCS_BUCKET}/$(basename "${ARCHIVE}")"; GCS_OK=true; } \
    || warn "Upload GCS fallito — il backup locale è comunque disponibile"
else
    warn "GCS non configurato (bucket o chiave mancante), upload saltato"
fi

# =============================================================================
# Notifica Discord (opzionale)
# =============================================================================
GCS_STATUS=$( $GCS_OK && echo "☁️ GCS: caricato" || echo "⚠️ GCS: upload fallito o non configurato (backup locale OK)" )
discord 3066993 "✅ Backup completato — $(hostname)" \
    "**Data:** ${BACKUP_DATE}\\n**Dimensione:** ${SIZE}\\n**Backup locali:** ${REMAINING}/${KEEP_BACKUPS}\\n${GCS_STATUS}"
