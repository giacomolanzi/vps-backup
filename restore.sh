#!/bin/bash
# =============================================================================
# Server Restore Script — generico, legge config.sh dalla stessa cartella
#
# PREREQUISITI:
#   apt update && apt install -y docker.io docker-compose-plugin curl
#   systemctl enable --now docker
#
# UTILIZZO:
#   tar xzf <host>_backup_*.tar.gz
#   cd .work_*/
#   sudo bash restore.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/docker"

# Carica configurazione
if [ ! -f "${SCRIPT_DIR}/config.sh" ]; then
    echo "ERROR: config.sh non trovato in ${SCRIPT_DIR}" >&2
    exit 1
fi
source "${SCRIPT_DIR}/config.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()     { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

if [ "$EUID" -ne 0 ]; then
    err "Eseguire come root: sudo bash restore.sh"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║           RESTORE - AVVIO PROCEDURA           ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
[ -f "${SCRIPT_DIR}/MANIFEST.txt" ] && head -5 "${SCRIPT_DIR}/MANIFEST.txt" && echo ""
log "La cartella docker verrà ripristinata in: ${DOCKER_DIR}"

read -rp "Procedere con il restore? Sovrascriverà la configurazione esistente. [y/N] " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { log "Annullato."; exit 0; }

# =============================================================================
section "Verifica prerequisiti"
MISSING=()
for cmd in docker tar gzip curl; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    err "Comandi mancanti: ${MISSING[*]}"
    err "Installa con: apt update && apt install -y docker.io docker-compose-plugin curl"
    exit 1
fi
log "Prerequisiti OK"

# =============================================================================
section "1/6 Ripristino SSH + Fail2ban"
SSH_DIR="${SCRIPT_DIR}/ssh"

if [ -f "${SSH_DIR}/sshd_config" ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_restore
    cp "${SSH_DIR}/sshd_config" /etc/ssh/sshd_config
fi
[ -d "${SSH_DIR}/sshd_config.d" ] && cp -r "${SSH_DIR}/sshd_config.d/"* /etc/ssh/sshd_config.d/ 2>/dev/null || true

SSH_USER=$(cat "${SSH_DIR}/ssh_user.txt" 2>/dev/null || echo "")
[ -z "${SSH_USER}" ] && read -rp "   Nome utente SSH: " SSH_USER

if ! id "${SSH_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${SSH_USER}"
    log "   Utente ${SSH_USER} creato"
fi
if ! grep -q "${SSH_USER}" /etc/sudoers.d/* 2>/dev/null; then
    echo "${SSH_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${SSH_USER}"
    chmod 440 "/etc/sudoers.d/${SSH_USER}"
fi
if [ -f "${SSH_DIR}/authorized_keys" ]; then
    mkdir -p "/home/${SSH_USER}/.ssh"
    cp "${SSH_DIR}/authorized_keys" "/home/${SSH_USER}/.ssh/authorized_keys"
    chmod 700 "/home/${SSH_USER}/.ssh"
    chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"
    chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
fi
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

if [ -d "${SCRIPT_DIR}/fail2ban/etc_fail2ban" ]; then
    apt-get install -y fail2ban >/dev/null 2>&1 || true
    cp -r "${SCRIPT_DIR}/fail2ban/etc_fail2ban/"* /etc/fail2ban/
    systemctl enable --now fail2ban 2>/dev/null || systemctl restart fail2ban
    log "   Fail2ban ripristinato"
fi

SSH_PORT=$(grep '^Port' "${SSH_DIR}/sshd_config" 2>/dev/null | awk '{print $2}' || echo "22")
log "   SSH porta ${SSH_PORT} — verifica la connessione prima di continuare"
read -rp "   Premi INVIO quando hai verificato che SSH funziona..." _

# =============================================================================
section "2/6 Ripristino UFW"
if [ -d "${SCRIPT_DIR}/ufw/etc_ufw" ]; then
    apt-get install -y ufw >/dev/null 2>&1 || true
    [ -d /etc/ufw ] && cp -r /etc/ufw /etc/ufw.bak_restore 2>/dev/null || true
    cp -r "${SCRIPT_DIR}/ufw/etc_ufw/"* /etc/ufw/
    ufw --force enable && ufw reload
    log "   UFW ripristinato"
else
    warn "Cartella UFW non presente nel backup (host senza UFW), saltato"
fi

# =============================================================================
section "3/6 Ripristino directory Docker"
if [ ! -f "${SCRIPT_DIR}/docker.tar.gz" ]; then
    err "docker.tar.gz non trovato!"
    exit 1
fi
mkdir -p "$(dirname "${DOCKER_DIR}")"
tar xzf "${SCRIPT_DIR}/docker.tar.gz" -C /
chown -R "${SSH_USER}:${SSH_USER}" "${DOCKER_DIR}" 2>/dev/null || true
log "   Ripristinato: ${DOCKER_DIR}"

# =============================================================================
section "4/6 Reti Docker"
for NET in "${DOCKER_NETWORKS[@]:-}"; do
    [ -z "${NET}" ] && continue
    docker network create "${NET}" 2>/dev/null \
        && log "   Rete creata: ${NET}" \
        || log "   Rete esistente: ${NET}"
done

# =============================================================================
section "5/6 Named Docker volumes"
VOL_COUNT=0
for VOL_ARCHIVE in "${SCRIPT_DIR}/docker_volumes/"*.tar.gz; do
    [ -f "${VOL_ARCHIVE}" ] || continue
    VOL_NAME=$(basename "${VOL_ARCHIVE}" .tar.gz)
    docker volume create "${VOL_NAME}" >/dev/null
    docker run --rm \
        -v "${VOL_NAME}:/vol_data" \
        -v "${SCRIPT_DIR}/docker_volumes:/backup:ro" \
        alpine tar xzf "/backup/$(basename "${VOL_ARCHIVE}")" -C /vol_data
    VOL_COUNT=$((VOL_COUNT + 1))
    log "   Ripristinato: ${VOL_NAME:0:16}..."
done
log "   Volumi ripristinati: ${VOL_COUNT}"

# =============================================================================
section "6/6 Avvio servizi Docker"

if [ -n "${PG_CONTAINER:-}" ] && [ -d "${DOCKER_DIR}/postgres" ]; then
    log "   Avvio PostgreSQL..."
    cd "${DOCKER_DIR}/postgres" && docker compose up -d

    log "   Attendo PostgreSQL..."
    for i in $(seq 1 60); do
        docker exec "${PG_CONTAINER}" pg_isready -U "${PG_USER}" >/dev/null 2>&1 && break
        [ "$i" -eq 60 ] && { err "PostgreSQL non si è avviato. Controlla: docker logs ${PG_CONTAINER}"; exit 1; }
        sleep 1
    done
    log "   PostgreSQL pronto"

    if [ -f "${SCRIPT_DIR}/postgres/pg_dumpall.sql.gz" ]; then
        log "   Ripristino database..."
        gunzip -c "${SCRIPT_DIR}/postgres/pg_dumpall.sql.gz" \
            | docker exec -i "${PG_CONTAINER}" psql -U "${PG_USER}" -q
        log "   Database ripristinati"
    fi
else
    log "   PostgreSQL non configurato, salto"
fi

while IFS= read -r COMPOSE_FILE; do
    DIR="$(dirname "${COMPOSE_FILE}")"
    NAME="$(basename "${DIR}")"
    [ "${NAME}" = "postgres" ] && continue
    cd "${DIR}"
    docker compose up -d 2>/dev/null \
        && log "   Avviato: ${NAME} (${COMPOSE_FILE#"${DOCKER_DIR}"/})" \
        || warn "   Errore: ${NAME} (controlla manualmente)"
done < <(find "${DOCKER_DIR}" -mindepth 1 \( -name 'compose.yml' -o -name 'docker-compose.yml' \) | sort)

# =============================================================================
echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║             RESTORE COMPLETATO                ║"
echo "╚════════════════════════════════════════════════╝"
echo ""
docker ps --format "  ✓ {{.Names}}: {{.Status}}" | sort
echo ""
log "Prossimi passi:"
echo "  1. Verifica ogni servizio nel browser"
echo "  2. Controlla i log: docker logs <container>"
echo "  3. Riconfigura eventuali token/secret di terze parti"
echo "  4. Servizi non-Docker (es. systemd nativi) vanno ripristinati manualmente"
echo ""
