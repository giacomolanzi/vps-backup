#!/bin/bash
# =============================================================================
# Backup configuration — copy to config.sh (NOT committed) and customize
# Goes in the same folder as backup.sh/restore.sh
# =============================================================================

# Local backups — how many archives to keep before rotating
KEEP_BACKUPS=7

# Where to write the final archives, if different from this folder — e.g. to
# keep them off a small root partition. Leave empty/unset for the default
# (archives next to backup.sh). Does NOT affect DOCKER_DIR, which stays
# relative to backup.sh's own location.
ARCHIVE_DIR=""

# Google Cloud Storage (leave GCS_BUCKET empty to disable upload)
GCS_BUCKET="gs://your-bucket"
# The service account key must be saved as gcs-key.json in the same folder
# as this file — do NOT commit it to git (see .gitignore)

# Discord notifications (leave empty to disable)
DISCORD_WEBHOOK=""

# PostgreSQL — leave both empty if this host doesn't run Postgres in Docker
PG_CONTAINER=""
PG_USER=""

# Paths to exclude from the tar, relative to the "docker" folder
# (e.g. Postgres data already covered by pg_dumpall, to avoid duplication)
# NOTE: .cache/.npm/node_modules/__pycache__/.venv are already excluded
# everywhere automatically by backup.sh (DEFAULT_EXCLUDE_PATTERNS) — only
# host-specific exclusions belong here.
DOCKER_EXCLUDES=(
    # "postgres/postgres-data"
)

# External Docker networks to (re)create during restore
DOCKER_NETWORKS=(
    # "homedeb_net"
)

# Optional encryption of the final archive (requires the "age" binary — if
# not installed, backup.sh warns and proceeds WITHOUT encrypting). Leave
# empty to disable. The recipient is an age public key, not a file:
#   age-keygen -o key.txt   # prints "Public key: age1..." — use that here
#                            # and keep key.txt (private) OFF this host
ENCRYPT_RECIPIENT=""
