# Backup System — portable

## Requirements

- A Linux host running Docker + Docker Compose
- (optional) PostgreSQL running as one of the Docker services, for automatic DB dumps
- (optional) A Google Cloud Storage bucket, for offsite upload

## Basic idea

Two generic scripts (`backup.sh` and `restore.sh`) plus a minimal
per-host config file (`config.sh`). Zero hardcoded absolute paths: the
script figures out what to back up based on its own location.

**Convention:** place the `backups` folder (the contents of this repo)
alongside a `docker` folder (where your `compose.yml` files and their
bind-mounts live):

```
/opt/
  backups/     ← this repo
    backup.sh
    restore.sh
    config.sh          (created by you, not in git)
    gcs-key.json        (copied by hand, not in git)
  docker/
    homeassistant/
      compose.yml
      ...
    n8n/
      compose.yml
      ...
```

Works identically whether you place it under `/opt`, `~/srv`, or any
other root — `backup.sh` resolves `../docker` relative to itself.

**Stacks nested at any depth:** inside `docker/` you can organize
stacks however you like, including multi-level subfolders (e.g.
`docker/clients/acme/n8n/compose.yml`). Both `backup.sh` (which
archives the entire `docker/` folder with `tar`, always recursing into
every sublevel) and `restore.sh` (which looks for every
`compose.yml`/`docker-compose.yml` with `find`, not a plain
`docker/*/compose.yml`) cover any depth, not just one level below
`docker/`.

**External volumes: mount data inside the stack's own folder.** If a
container needs a bind-mount for persistent data, point it inside the
stack's own folder — not elsewhere on the filesystem:

```
docker/n8n/
  compose.yml
  data/            ← bind-mount: "./data:/home/node/.n8n"  ✅ backed up
```

```
# ❌ avoid:
#   "/mnt/elsewhere/n8n-data:/home/node/.n8n"
# since it's not inside "docker/", this mount does NOT end up in the tar.
```

**Named Docker volumes** (the "virtual" ones, managed by Docker rather
than a filesystem path) are instead always included automatically,
wherever they're used — see step 5 below. The bind-mount rule only
applies to mounts with an explicit host path.

On every run, `backup.sh` still detects any bind-mounts of running
containers that point outside `docker/` and flags them (log +
`MANIFEST.txt`), excluding the typical introspection mounts used by
monitoring tools (Glances on `/`, Diun on `docker.sock`, `/proc`,
`/sys`, `/etc`, ...). If a warning shows up for a mount that holds real
data, move it inside the stack.

```
every night at 02:00
    → backup.sh  (reads config.sh)
        1. pg_dumpall + individual DB dumps (only if PG_CONTAINER is set)
        2. tar of the "docker" folder (all stacks, any depth;
           automatically excludes cache/.npm/node_modules/.venv/__pycache__,
           plus any host-specific DOCKER_EXCLUDES)
        3. SSH + Fail2ban
        4. UFW (only if installed)
        5. Named Docker volumes (all of them on the host, not just the
           ones used by stacks under "docker/")
        → <hostname>_backup_YYYY-MM-DD_HH-MM.tar.gz  (permissions 600 —
          umask 077)
        → integrity check (tar tzf) BEFORE rotating or uploading anything
        → optional encryption (age), if ENCRYPT_RECIPIENT is set
        → sha256 checksum saved alongside the archive
        → upload to Google Cloud Storage (if configured, archive + checksum)
        → Discord notification (if configured), with an alert if the size
          is anomalous compared to the last successful backup (>2× or <0.5×)
        → local rotation (KEEP_BACKUPS days)
```

---

## Setup on a new host

```bash
# 1. Clone (or copy) this repo into <root>/backups
git clone <repo-url> /opt/backups
cd /opt/backups

# 2. Create the host-specific config
cp config.example.sh config.sh
nano config.sh   # GCS bucket, Discord webhook, optional Postgres, networks to recreate

# 3. Copy the GCS key (not in git, transfer it by hand/scp)
#    /opt/backups/gcs-key.json

chmod +x backup.sh restore.sh
chmod 600 gcs-key.json

# 4. Cron
(crontab -l 2>/dev/null; echo '0 2 * * * /opt/backups/backup.sh >> /opt/backups/backup.log 2>&1') | crontab -

# 5. Scoped passwordless sudo (needed to copy sshd_config during the cron run)
sudo visudo -f /etc/sudoers.d/<user>-backup
```
Sudoers file contents (adapt `<user>` and the path portion if you put
`backups` somewhere else):
```
<user> ALL=(root) NOPASSWD: /usr/bin/cp /etc/ssh/sshd_config /opt/backups/.work_*/ssh/
<user> ALL=(root) NOPASSWD: /usr/bin/chown -R <user> /opt/backups/.work_*/ssh/
```

```bash
# 6. Manual test
bash /opt/backups/backup.sh
tail -f /opt/backups/backup.log
```

---

## What each backup includes

| Folder in the archive | Content |
|---|---|
| `postgres/pg_dumpall.sql.gz` | Full dump (only if `PG_CONTAINER` is set) |
| `postgres/<name>.dump` | Individual per-DB dump, `pg_restore` custom format |
| `docker.tar.gz` | The entire sibling `docker` folder: compose files, bind-mount data |
| `ssh/` | `sshd_config`, `authorized_keys`, SSH username |
| `fail2ban/` | fail2ban configuration (if present) |
| `ufw/` | UFW firewall rules (if installed) |
| `docker_volumes/` | All named Docker volumes (`docker volume ls`) |
| `config.sh` | This host's configuration, included in the backup for restore purposes. `DISCORD_WEBHOOK` is **redacted** (emptied) before it ends up in the archive — set it again by hand after a restore |
| `restore.sh` | A copy of the restore script |
| `MANIFEST.txt` | Summary: hostname, OS, services active at backup time |

The final archive is created with `600` permissions (only the owner
can read it — `umask 077` at the top of `backup.sh`), and a
`<archive>.sha256` file is saved alongside it and also uploaded to
GCS, to verify integrity before a restore (see below).

> If you use Postgres, exclude its data directory from the tar via
> `DOCKER_EXCLUDES` in `config.sh` (e.g. `"postgres/postgres-data"`) —
> it's already covered by `pg_dumpall`, avoiding duplication and the
> risk of corruption from open files.

> **Automatic exclusions:** `.cache`, `.npm`, `node_modules`,
> `__pycache__`, `.venv` are excluded from the tar wherever they're
> found under `docker/`, on every host, with no configuration needed
> (the `DEFAULT_EXCLUDE_PATTERNS` pattern in `backup.sh`). Use
> `DOCKER_EXCLUDES` in `config.sh` only for host-specific cases that
> don't fall under these patterns.

> **Non-containerized** services (e.g. a native process via systemd)
> are not covered automatically: if they hold important data, put them
> inside the `docker` folder anyway (the name is purely conventional —
> `backup.sh` tars everything it finds there) or add a manual step.

---

## Common operations

```bash
# Manual backup in the foreground
bash /opt/backups/backup.sh

# In the background (recommended for large backups)
nohup bash /opt/backups/backup.sh >> /opt/backups/backup.log 2>&1 &
tail -f /opt/backups/backup.log

# Check local backups
ls -lh /opt/backups/*_backup_*.tar.gz

# Cron log
tail -100 /opt/backups/backup.log

# Inspect an archive without extracting it
tar tzf /opt/backups/<host>_backup_YYYY-MM-DD_HH-MM.tar.gz

# List backups on GCS
docker run --rm \
  -v /opt/backups/gcs-key.json:/key.json:ro \
  google/cloud-sdk:alpine \
  sh -c "gcloud auth activate-service-account --key-file=/key.json -q \
         && gsutil ls -lh <GCS_BUCKET>/"

# Dry run: preview what would be included/excluded and the estimated size,
# without touching anything
bash /opt/backups/backup.sh --dry-run
```

---

## Optional archive encryption (at rest)

The GCS bucket is already protected (IAM-only access, no public
members), but for extra protection the final archive can be encrypted
with [age](https://github.com/FiloSottile/age) before upload —
opt-in, no impact if left unconfigured:

```bash
# One-time, on a TRUSTED machine (not necessarily the host being backed up):
age-keygen -o key.txt
# prints "Public key: age1..." — that goes into ENCRYPT_RECIPIENT on each host
# key.txt (the PRIVATE key) should be kept off this host, somewhere safe

# On the host to protect:
apt install age   # or the equivalent for your distro
# in config.sh:
ENCRYPT_RECIPIENT="age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

If `ENCRYPT_RECIPIENT` is set but `age` isn't installed, `backup.sh`
warns and proceeds **without** encrypting (it doesn't block the
backup). The encrypted archive gets a `.tar.gz.age` extension instead
of `.tar.gz` — the integrity check (`tar tzf`) still runs before
encryption, on the plaintext tar.

---

## Full restore on a fresh host

```bash
apt update && apt install -y docker.io docker-compose-plugin curl
systemctl enable --now docker

# Fetch the archive AND its <archive>.sha256 (from GCS or scp), then:
mkdir -p /opt/restore && cd /opt/restore
sha256sum -c <host>_backup_YYYY-MM-DD_HH-MM.tar.gz.sha256   # verify integrity

# Only if the archive is encrypted (.tar.gz.age extension, see section above):
age -d -i key.txt -o <host>_backup_YYYY-MM-DD_HH-MM.tar.gz \
    <host>_backup_YYYY-MM-DD_HH-MM.tar.gz.age

tar xzf <host>_backup_YYYY-MM-DD_HH-MM.tar.gz
cd .work_YYYY-MM-DD_HH-MM/
sudo bash restore.sh
```

`restore.sh` recreates `docker/` alongside itself, following the same
convention as `backup.sh` — if you run it from
`/opt/restore/.work_.../`, the Docker folder ends up at `/opt/docker`
(the original absolute path, saved inside the tar). If you want a
different location, move the extracted folder first to wherever you
want `docker/` to end up as a sibling.

### What it does, in order

1. **SSH + Fail2ban** — restores `sshd_config`, `authorized_keys`. Asks
   for confirmation that SSH works before continuing.
2. **UFW** — only if present in the backup.
3. **Docker dir** — extracts the entire tar.
4. **Docker networks** — creates the ones listed in `DOCKER_NETWORKS`.
5. **Named volumes** — restores all Docker volumes.
6. **Services** — starts Postgres (if configured) and waits for it to
   be ready, restores the DBs, then dynamically starts every
   `compose.yml` found in the Docker folder.

### After the restore

- Check every service in the browser
- `docker logs <container>` for any errors
- Reconfigure third-party tokens/secrets
- Manually restore any non-Docker services (e.g. native systemd units)

---

## Retention

| Location | Retention | Managed by |
|---|---|---|
| Local (`backups/`) | `KEEP_BACKUPS` days | Automatic rotation in `backup.sh` |
| GCS | Depends on the bucket | Lifecycle rule set on the bucket itself |

---

## Adding or removing Docker services

**No changes needed.** The system is dynamic:

- New service under `docker/<name>/compose.yml` (or nested deeper) → automatically included
- New PostgreSQL database → automatically included in `pg_dumpall`
- New named volume → automatically included via `docker volume ls`, wherever it's used
- New cache folder (`.cache`, `.npm`, `node_modules`, ...) → automatically excluded from the tar

---

## Note on Diun

Compose files in this kind of setup typically carry a
`diun.metadata.compose_path=<absolute path to compose.yml>` label, used
by [Diun](https://github.com/crazy-max/diun) for image-update
notifications and to know where the file that launched the service
lives. It plays no role in the backup itself.
