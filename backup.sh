#!/bin/bash
# =============================================================================
# Server Backup Script — generico e portabile
#
# Va posizionato in una cartella "backups" affiancata a una cartella "docker"
# (es. /opt/backups + /opt/docker, oppure ~/srv/backups + ~/srv/docker).
# Nessun path assoluto da configurare: la cartella da backuppare viene dedotta
# dalla posizione di questo script.
#
# Covers: PostgreSQL (opzionale), directory Docker (tutti gli stack, a
#         qualsiasi profondità), SSH, Fail2ban (opzionale), UFW (opzionale),
#         Docker named volumes, audit dei bind mount esterni non coperti,
#         checksum + verifica integrità, cifratura opzionale, alert su
#         anomalie di dimensione
# Usage: ./backup.sh [--no-volumes] [--dry-run]
#                     [--keep-backups=N] [--archive-dir=PATH] [--gcs-bucket=URL]
#                     [--discord-webhook=URL] [--pg-container=NAME] [--pg-user=NAME]
# I flag di override sostituiscono il valore corrispondente in config.sh solo
# per questa run (non lo modificano su disco). Omessi, resta il valore di
# config.sh.
# =============================================================================
set -euo pipefail
umask 077

usage() {
    grep '^# ' "${BASH_SOURCE[0]}" | head -15 | sed 's/^# \{0,1\}//'
}

DRY_RUN=false
NO_VOLUMES=false
for ARG in "$@"; do
    case "${ARG}" in
        --dry-run) DRY_RUN=true ;;
        --no-volumes) NO_VOLUMES=true ;;
        --help|-h) usage; exit 0 ;;
        --keep-backups=*) OVERRIDE_KEEP_BACKUPS="${ARG#*=}" ;;
        --archive-dir=*) OVERRIDE_ARCHIVE_DIR="${ARG#*=}" ;;
        --gcs-bucket=*) OVERRIDE_GCS_BUCKET="${ARG#*=}" ;;
        --discord-webhook=*) OVERRIDE_DISCORD_WEBHOOK="${ARG#*=}" ;;
        --pg-container=*) OVERRIDE_PG_CONTAINER="${ARG#*=}" ;;
        --pg-user=*) OVERRIDE_PG_USER="${ARG#*=}" ;;
        --*) echo "ERROR: opzione sconosciuta: ${ARG} (--help per l'elenco)" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/../docker" && pwd)"

# Carica configurazione specifica dell'host
if [ ! -f "${SCRIPT_DIR}/config.sh" ]; then
    echo "ERROR: config.sh non trovato in ${SCRIPT_DIR} (copia config.example.sh)" >&2
    exit 1
fi
source "${SCRIPT_DIR}/config.sh"

# Gli override da riga di comando vincono su config.sh, solo per questa run.
# "${VAR+x}" (non "-n") per distinguere "flag non passato" da "flag passato
# con valore vuoto" (es. --gcs-bucket= per disabilitare l'upload per un run).
[ "${OVERRIDE_KEEP_BACKUPS+x}" ] && KEEP_BACKUPS="${OVERRIDE_KEEP_BACKUPS}"
[ "${OVERRIDE_ARCHIVE_DIR+x}" ] && ARCHIVE_DIR="${OVERRIDE_ARCHIVE_DIR}"
[ "${OVERRIDE_GCS_BUCKET+x}" ] && GCS_BUCKET="${OVERRIDE_GCS_BUCKET}"
[ "${OVERRIDE_DISCORD_WEBHOOK+x}" ] && DISCORD_WEBHOOK="${OVERRIDE_DISCORD_WEBHOOK}"
[ "${OVERRIDE_PG_CONTAINER+x}" ] && PG_CONTAINER="${OVERRIDE_PG_CONTAINER}"
[ "${OVERRIDE_PG_USER+x}" ] && PG_USER="${OVERRIDE_PG_USER}"

GCS_KEY="${SCRIPT_DIR}/gcs-key.json"

BACKUP_DATE=$(date +%Y-%m-%d_%H-%M)
# La cartella di lavoro temporanea resta sempre accanto allo script: è
# piccola e cancellata subito dopo ogni run, e alcuni file al suo interno
# (ssh/, fail2ban/, ufw/) vengono scritti con "sudo cp"/"sudo chown" tramite
# una regola sudoers NOPASSWD vincolata al path letterale SCRIPT_DIR/.work_*
# — spostarla romperebbe quella regola.
WORK_DIR="${SCRIPT_DIR}/.work_${BACKUP_DATE}"
# ARCHIVE_DIR (opzionale, in config.sh): destinazione dei soli archivi
# finali (quelli che si accumulano fino a KEEP_BACKUPS), se diversa da
# SCRIPT_DIR — utile per tenerli su una partizione diversa da quella di
# root. Se non impostata, comportamento invariato.
ARCHIVE_BASE="${ARCHIVE_DIR:-${SCRIPT_DIR}}"
mkdir -p "${ARCHIVE_BASE}"
ARCHIVE="${ARCHIVE_BASE}/$(hostname)_backup_${BACKUP_DATE}.tar.gz"

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

ARCHIVE_VERIFIED=false
on_error() {
    local line="$1"
    discord 15158332 "❌ Backup fallito — $(hostname)" \
        "Errore alla riga ${line}\\nData: ${BACKUP_DATE}\\nControlla: \`tail -50 ${SCRIPT_DIR}/backup.log\`"
    [ -d "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"
    # Un archivio non ancora verificato con "tar tzf" può essere troncato
    # (es. tar czf interrotto per disco pieno) — non lasciarlo sul disco,
    # altrimenti si accumula senza mai liberare spazio (causa dell'incidente
    # del 2026-09-09: un archivio corrotto mai ripulito ha bloccato la
    # rotazione dei backup successivi).
    if ! ${ARCHIVE_VERIFIED} && [ -n "${ARCHIVE:-}" ] && [ -f "${ARCHIVE}" ]; then
        rm -f "${ARCHIVE}"
    fi
}
trap 'on_error $LINENO' ERR
trap '[ -d "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"' EXIT

# Pattern generici (cache/junk) esclusi automaticamente ovunque, a qualsiasi
# profondità sotto DOCKER_DIR — nessuna config richiesta per il caso comune.
# Per esclusioni specifiche dell'host usa DOCKER_EXCLUDES in config.sh.
DEFAULT_EXCLUDE_PATTERNS=(
    "*/.cache"
    "*/.npm"
    "*/node_modules"
    "*/__pycache__"
    "*/.venv"
)
EXCLUDE_ARGS=()
for PATTERN in "${DEFAULT_EXCLUDE_PATTERNS[@]}"; do
    EXCLUDE_ARGS+=("--exclude=${DOCKER_DIR}/${PATTERN}")
done
for EXCL in "${DOCKER_EXCLUDES[@]:-}"; do
    [ -z "${EXCL}" ] && continue
    EXCLUDE_ARGS+=("--exclude=${DOCKER_DIR}/${EXCL}")
done

# Dimensione dell'ultimo backup riuscito, per l'alert di anomalia più sotto
# (va letta ORA, prima di creare/ruotare qualunque cosa).
PREV_ARCHIVE=$(ls -t "${ARCHIVE_BASE}/$(hostname)_backup_"*.tar.gz* 2>/dev/null | grep -v '\.sha256$' | head -1 || true)
PREV_SIZE_BYTES=0
if [ -n "${PREV_ARCHIVE:-}" ] && [ -f "${PREV_ARCHIVE}" ]; then
    PREV_SIZE_BYTES=$(stat -c%s "${PREV_ARCHIVE}" 2>/dev/null || echo 0)
fi

# Alert precoce se lo spazio libero è sotto ~2x l'ultimo backup, sulle
# partizioni usate da WORK_DIR e dall'archivio finale (possono essere
# diverse se è impostato ARCHIVE_DIR) — così si scopre il rischio prima
# che il backup fallisca a metà, non dal log del mattino dopo.
check_free_space() {
    local path="$1" label="$2"
    local avail_bytes
    avail_bytes=$(df -B1 --output=avail "${path}" 2>/dev/null | tail -1 | tr -d ' ')
    [ -z "${avail_bytes}" ] && return 0
    local threshold=$(( PREV_SIZE_BYTES > 0 ? PREV_SIZE_BYTES * 2 : 1073741824 ))
    if [ "${avail_bytes}" -lt "${threshold}" ]; then
        local avail_human threshold_human
        avail_human=$(numfmt --to=iec "${avail_bytes}" 2>/dev/null || echo "${avail_bytes} bytes")
        threshold_human=$(numfmt --to=iec "${threshold}" 2>/dev/null || echo "${threshold} bytes")
        warn "Spazio libero basso su ${label} (${path}): ${avail_human} disponibili (soglia: ${threshold_human})"
        discord 16776960 "⚠️ Spazio disco basso — $(hostname)" \
            "**${label}:** ${avail_human} disponibili su \`${path}\`\\nSoglia: ${threshold_human} (2x ultimo backup)\\nQuesto backup potrebbe fallire per mancanza di spazio."
    fi
}
check_free_space "${SCRIPT_DIR}" "partizione cartella di lavoro"
[ "${ARCHIVE_BASE}" != "${SCRIPT_DIR}" ] && check_free_space "${ARCHIVE_BASE}" "partizione archivi"

# =============================================================================
# --dry-run: mostra cosa verrebbe fatto, non tocca nulla, non carica nulla.
# =============================================================================
if ${DRY_RUN}; then
    log "=== DRY RUN: nessuna modifica verrà effettuata ==="
    echo
    echo "Stack Docker trovati sotto ${DOCKER_DIR}:"
    find "${DOCKER_DIR}" -mindepth 1 \( -name 'compose.yml' -o -name 'docker-compose.yml' \) 2>/dev/null \
        | sed "s|^${DOCKER_DIR}/||" | sed 's/^/  - /' || true
    echo
    echo "Pattern di esclusione applicati:"
    for PATTERN in "${DEFAULT_EXCLUDE_PATTERNS[@]}"; do echo "  - ${PATTERN} (default)"; done
    for EXCL in "${DOCKER_EXCLUDES[@]:-}"; do [ -z "${EXCL}" ] && continue; echo "  - ${EXCL} (config.sh)"; done
    echo
    echo "Named Docker volumes che verrebbero inclusi:"
    docker volume ls --format '  - {{.Name}}'
    echo
    if [ -n "${PG_CONTAINER:-}" ] && docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
        echo "PostgreSQL: verrebbe dumpato (pg_dumpall + dump individuali) da ${PG_CONTAINER}"
    else
        echo "PostgreSQL: non configurato o non attivo, verrebbe saltato"
    fi
    echo
    # "|| true" sul tar: può uscire non-zero per sottocartelle a permessi
    # ristretti (es. certificati Caddy leggibili solo da root) pur avendo
    # comunque stampato il totale — isolato qui per non far incespicare
    # pipefail sul resto della pipeline (altrimenti, con grep a valle che
    # trova un match valido, sia l'output reale sia un eventuale fallback
    # finirebbero concatenati nella stessa variabile).
    ESTIMATE_BYTES=$({ LC_ALL=C tar cf /dev/null "${EXCLUDE_ARGS[@]}" --totals "${DOCKER_DIR}" 2>&1 >/dev/null || true; } \
        | grep -oE 'written: [0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -z "${ESTIMATE_BYTES}" ] && ESTIMATE_BYTES=0
    echo "Dimensione stimata di docker/ non compressa (esclusioni applicate): $(numfmt --to=iec "${ESTIMATE_BYTES}" 2>/dev/null || echo "${ESTIMATE_BYTES} bytes")"
    [ -n "${PREV_ARCHIVE:-}" ] && echo "Ultimo backup reale: $(basename "${PREV_ARCHIVE}") ($(numfmt --to=iec "${PREV_SIZE_BYTES}" 2>/dev/null || echo "${PREV_SIZE_BYTES} bytes"))"
    echo
    trap - ERR EXIT
    log "=== Fine dry-run — nessun file creato, nessun upload effettuato ==="
    exit 0
fi

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

tar czf "${WORK_DIR}/docker.tar.gz" \
    "${EXCLUDE_ARGS[@]}" \
    --warning=no-file-changed \
    "${DOCKER_DIR}" 2>/dev/null || true
log "   Archiviato: ${DOCKER_DIR} (tutti gli stack, a qualsiasi profondità)"

# Audit: bind mount di container attivi che puntano FUORI da DOCKER_DIR —
# non vengono inclusi né dal tar sopra né dai named volume più sotto.
# Esclude i mount di introspezione host tipici di tool di monitoring
# (Glances/Netdata su "/", Diun sul docker.sock, /proc, /sys, /etc, ...).
EXTERNAL_MOUNTS=$(docker ps -q 2>/dev/null | xargs -r -I{} docker inspect {} \
    --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
    | sort -u | grep -v "^${DOCKER_DIR}" \
    | grep -vE '^(/proc|/sys|/dev|/etc|/var/run|/run)(/|$)|^/$' || true)
if [ -n "${EXTERNAL_MOUNTS}" ]; then
    warn "Bind mount fuori da ${DOCKER_DIR} (NON inclusi nel backup):"
    echo "${EXTERNAL_MOUNTS}" | while read -r MNT; do warn "   - ${MNT}"; done
fi

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
SSH_PORT_LOG=$(grep '^Port' /etc/ssh/sshd_config | awk '{print $2}' || true)
log "   SSH: porta ${SSH_PORT_LOG:-22 (default)}, chiavi salvate"

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
if command -v ufw >/dev/null 2>&1; then
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
if ! ${NO_VOLUMES}; then
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

BIND MOUNT ESTERNI A ${DOCKER_DIR} (NON backuppati)
----------------------------------------------------
$(if [ -n "${EXTERNAL_MOUNTS}" ]; then echo "${EXTERNAL_MOUNTS}" | sed 's/^/  - /'; else echo "  (nessuno)"; fi)

RESTORE
-------
Posiziona questa cartella "backups" affiancata a una cartella "docker" (anche
vuota, verrà creata) ed esegui: sudo bash restore.sh
EOF

# config.sh viene incluso per comodità di restore, ma con il webhook Discord
# redatto: non deve propagarsi in chiaro dentro l'archivio.
sed 's/^DISCORD_WEBHOOK=.*/DISCORD_WEBHOOK=""  # redatto dal backup — reimposta a mano dopo il restore/' \
    "${SCRIPT_DIR}/config.sh" > "${WORK_DIR}/config.sh"
if [ -f "${SCRIPT_DIR}/restore.sh" ]; then
    cp "${SCRIPT_DIR}/restore.sh" "${WORK_DIR}/restore.sh"
    chmod +x "${WORK_DIR}/restore.sh"
fi

# =============================================================================
# Archivio finale + verifica integrità + cifratura opzionale + checksum
# =============================================================================
log "Creazione archivio finale..."
tar czf "${ARCHIVE}" -C "${SCRIPT_DIR}" ".work_${BACKUP_DATE}/"

# Verifica integrità PRIMA di ruotare i backup vecchi: se l'archivio appena
# creato è corrotto, questo comando fallisce, il trap ERR notifica su Discord
# e lo script si interrompe qui — senza cancellare nessun backup precedente.
tar tzf "${ARCHIVE}" >/dev/null
ARCHIVE_VERIFIED=true
log "   Integrità verificata (tar tzf)"

if [ -n "${ENCRYPT_RECIPIENT:-}" ]; then
    if command -v age >/dev/null 2>&1; then
        age -r "${ENCRYPT_RECIPIENT}" -o "${ARCHIVE}.age" "${ARCHIVE}"
        rm -f "${ARCHIVE}"
        ARCHIVE="${ARCHIVE}.age"
        log "   Archivio cifrato (age): $(basename "${ARCHIVE}")"
    else
        warn "ENCRYPT_RECIPIENT impostato ma 'age' non è installato — archivio NON cifrato"
    fi
fi

sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"
log "   Checksum: $(cut -d' ' -f1 "${ARCHIVE}.sha256")"

SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
SIZE_BYTES=$(stat -c%s "${ARCHIVE}" 2>/dev/null || echo 0)
log "=== Backup completato: $(basename "${ARCHIVE}") (${SIZE}) ==="

SIZE_WARNING=""
if [ "${PREV_SIZE_BYTES}" -gt 0 ] && [ "${SIZE_BYTES}" -gt 0 ]; then
    RATIO=$(awk -v a="${SIZE_BYTES}" -v b="${PREV_SIZE_BYTES}" 'BEGIN { printf "%.2f", a/b }')
    if awk -v r="${RATIO}" 'BEGIN { exit !(r > 2 || r < 0.5) }'; then
        PCT=$(awk -v r="${RATIO}" 'BEGIN { printf "%+.0f", (r-1)*100 }')
        PREV_HUMAN=$(numfmt --to=iec "${PREV_SIZE_BYTES}" 2>/dev/null || echo "${PREV_SIZE_BYTES} bytes")
        SIZE_WARNING="\\n⚠️ **Dimensione anomala:** ${SIZE} vs ${PREV_HUMAN} nel backup precedente (${PCT}%) — controlla se è cambiato qualcosa"
        warn "Dimensione anomala rispetto al backup precedente: ${SIZE} vs ${PREV_HUMAN} (${PCT}%)"
    fi
fi

rm -rf "${WORK_DIR}"
trap - EXIT

# =============================================================================
# Rotazione (copre sia .tar.gz che .tar.gz.age, più i rispettivi .sha256)
# =============================================================================
log "Rotazione: mantengo gli ultimi ${KEEP_BACKUPS} backup..."
ls -t "${ARCHIVE_BASE}/$(hostname)_backup_"*.tar.gz* 2>/dev/null | grep -v '\.sha256$' \
    | tail -n "+$((KEEP_BACKUPS + 1))" \
    | while read -r OLD; do rm -f "${OLD}" "${OLD}.sha256"; done
REMAINING=$(ls "${ARCHIVE_BASE}/$(hostname)_backup_"*.tar.gz* 2>/dev/null | grep -v '\.sha256$' | wc -l)
log "Backup disponibili: ${REMAINING}"

# =============================================================================
# Upload GCS (opzionale — salta se GCS_BUCKET o la chiave non sono presenti)
# =============================================================================
GCS_OK=false
if [ -n "${GCS_BUCKET:-}" ] && [ -f "${GCS_KEY}" ]; then
    log "Upload su GCS: ${GCS_BUCKET}..."
    docker run --rm \
        -v "${ARCHIVE}:/data/$(basename "${ARCHIVE}"):ro" \
        -v "${ARCHIVE}.sha256:/data/$(basename "${ARCHIVE}").sha256:ro" \
        -v "${GCS_KEY}:/key.json:ro" \
        google/cloud-sdk:alpine \
        sh -c "gcloud auth activate-service-account --key-file=/key.json -q \
               && gsutil cp '/data/$(basename "${ARCHIVE}")' '/data/$(basename "${ARCHIVE}").sha256' '${GCS_BUCKET}/'" \
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
    "**Data:** ${BACKUP_DATE}\\n**Dimensione:** ${SIZE}\\n**Backup locali:** ${REMAINING}/${KEEP_BACKUPS}\\n${GCS_STATUS}${SIZE_WARNING}"
