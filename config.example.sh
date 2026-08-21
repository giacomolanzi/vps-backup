#!/bin/bash
# =============================================================================
# Configurazione backup — copia in config.sh (NON committato) e personalizza
# Va posizionato nella stessa cartella di backup.sh/restore.sh
# =============================================================================

# Backup locale — quanti archivi tenere prima di ruotare
KEEP_BACKUPS=7

# Google Cloud Storage (lascia GCS_BUCKET vuoto per disabilitare l'upload)
GCS_BUCKET="gs://il-tuo-bucket"
# La chiave del service account va salvata come gcs-key.json nella stessa
# cartella di questo file — NON va committata in git (vedi .gitignore)

# Notifiche Discord (lascia vuoto per disabilitare)
DISCORD_WEBHOOK=""

# PostgreSQL — lascia entrambi vuoti se questo host non usa Postgres in Docker
PG_CONTAINER=""
PG_USER=""

# Percorsi da escludere dal tar, relativi alla cartella "docker"
# (es. dati Postgres già coperti da pg_dumpall, per evitare doppioni)
# NB: .cache/.npm/node_modules/__pycache__/.venv sono già esclusi ovunque
# automaticamente da backup.sh (DEFAULT_EXCLUDE_PATTERNS) — qui vanno solo
# esclusioni specifiche di questo host.
DOCKER_EXCLUDES=(
    # "postgres/postgres-data"
)

# Reti Docker esterne da (ri)creare in fase di restore
DOCKER_NETWORKS=(
    # "homedeb_net"
)
