# Sistema di Backup — portabile

## Idea di base

Due script generici (`backup.sh` e `restore.sh`) più un file di configurazione
minimo (`config.sh`) per host. Zero path assoluti hardcoded: lo script deduce
cosa backuppare dalla propria posizione.

**Convenzione:** metti la cartella `backups` (il contenuto di questo repo)
affiancata a una cartella `docker` (dove vivono i tuoi `compose.yml` e i loro
bind-mount):

```
/opt/
  backups/     ← questo repo
    backup.sh
    restore.sh
    config.sh          (creato da te, non in git)
    gcs-key.json        (copiato a mano, non in git)
  docker/
    homeassistant/
      compose.yml
      ...
    n8n/
      compose.yml
      ...
```

Funziona identico se lo metti sotto `/opt`, `~/srv`, o qualsiasi altra root —
`backup.sh` risolve `../docker` relativo a se stesso.

**Stack annidati a qualsiasi profondità:** dentro `docker/` puoi organizzare
gli stack come preferisci, anche in sottocartelle su più livelli (es.
`docker/clienti/acme/n8n/compose.yml`). Sia `backup.sh` (che archivia
l'intera cartella `docker/` con `tar`, che ricorre sempre in ogni sottolivello)
sia `restore.sh` (che cerca ogni `compose.yml`/`docker-compose.yml` con `find`,
non con un semplice `docker/*/compose.yml`) coprono qualunque profondità, non
solo un livello sotto `docker/`.

**Volumi esterni: monta i dati dentro la cartella dello stack.** Se un
container ha bisogno di un bind-mount per dati persistenti, fallo puntare
dentro la cartella dello stack stesso — non altrove sul filesystem:

```
docker/n8n/
  compose.yml
  data/            ← bind-mount: "./data:/home/node/.n8n"  ✅ backuppato
```

```
# ❌ evita:
#   "/mnt/altrove/n8n-data:/home/node/.n8n"
# non essendo dentro "docker/", questo mount NON finisce nel tar.
```

I **named Docker volume** (quelli "virtuali", gestiti da Docker e non da un
path del filesystem) sono invece sempre inclusi automaticamente, ovunque siano
usati — vedi step 5 sotto. La regola sui bind-mount vale solo per i mount con
un path host esplicito.

`backup.sh` rileva comunque, ad ogni run, eventuali bind-mount di container
attivi che puntano fuori da `docker/` e li segnala (log + `MANIFEST.txt`),
escludendo i mount di introspezione tipici di tool di monitoring (Glances su
`/`, Diun sul `docker.sock`, `/proc`, `/sys`, `/etc`, ...). Se compare un
avviso per un mount che contiene dati veri, spostalo dentro lo stack.

```
ogni notte alle 02:00
    → backup.sh  (legge config.sh)
        1. pg_dumpall + dump individuali DB (solo se PG_CONTAINER è impostato)
        2. tar della cartella "docker" (tutti gli stack, qualsiasi profondità;
           esclude cache/.npm/node_modules/.venv/__pycache__ automaticamente,
           più eventuali DOCKER_EXCLUDES specifiche dell'host)
        3. SSH + Fail2ban
        4. UFW (solo se installato)
        5. Named Docker volumes (tutti quelli sull'host, non solo quelli usati
           dagli stack sotto "docker/")
        → <hostname>_backup_YYYY-MM-DD_HH-MM.tar.gz
        → upload su Google Cloud Storage (se configurato)
        → notifica Discord (se configurato)
        → rotazione locale (KEEP_BACKUPS giorni)
```

---

## Setup su un host nuovo

```bash
# 1. Clona (o copia) questo repo in <root>/backups
git clone <repo-url> /opt/backups
cd /opt/backups

# 2. Crea la config specifica dell'host
cp config.example.sh config.sh
nano config.sh   # bucket GCS, webhook Discord, eventuale Postgres, reti da ricreare

# 3. Copia la chiave GCS (non in git, va trasferita a mano/scp)
#    /opt/backups/gcs-key.json

chmod +x backup.sh restore.sh
chmod 600 gcs-key.json

# 4. Cron
(crontab -l 2>/dev/null; echo '0 2 * * * /opt/backups/backup.sh >> /opt/backups/backup.log 2>&1') | crontab -

# 5. Sudo passwordless scoped (necessario per la copia di sshd_config nel cron)
sudo visudo -f /etc/sudoers.d/<utente>-backup
```
Contenuto del file sudoers (adatta `<utente>` e la porzione di path se hai
messo `backups` altrove):
```
<utente> ALL=(root) NOPASSWD: /usr/bin/cp /etc/ssh/sshd_config /opt/backups/.work_*/ssh/
<utente> ALL=(root) NOPASSWD: /usr/bin/chown -R <utente> /opt/backups/.work_*/ssh/
```

```bash
# 6. Test manuale
bash /opt/backups/backup.sh
tail -f /opt/backups/backup.log
```

---

## Cosa include ogni backup

| Cartella nell'archivio | Contenuto |
|---|---|
| `postgres/pg_dumpall.sql.gz` | Dump completo (solo se `PG_CONTAINER` impostato) |
| `postgres/<nome>.dump` | Dump individuale per DB, formato custom `pg_restore` |
| `docker.tar.gz` | L'intera cartella `docker` affiancata: compose files, dati bind-mount |
| `ssh/` | `sshd_config`, `authorized_keys`, nome utente SSH |
| `fail2ban/` | Configurazione fail2ban (se presente) |
| `ufw/` | Regole firewall UFW (se installato) |
| `docker_volumes/` | Tutti i named Docker volumes (`docker volume ls`) |
| `config.sh` | Configurazione di questo host, inclusa nel backup per il restore |
| `restore.sh` | Copia dello script di restore |
| `MANIFEST.txt` | Riepilogo: hostname, OS, servizi attivi al momento del backup |

> Se usi Postgres, escludi la sua directory dati dal tar via `DOCKER_EXCLUDES`
> in `config.sh` (es. `"postgres/postgres-data"`) — viene già coperta da
> `pg_dumpall`, evitando di duplicarla e rischiare corruzione da file aperti.

> **Esclusioni automatiche:** `.cache`, `.npm`, `node_modules`, `__pycache__`,
> `.venv` vengono esclusi dal tar ovunque si trovino sotto `docker/`, su ogni
> host, senza bisogno di configurazione (pattern `DEFAULT_EXCLUDE_PATTERNS` in
> `backup.sh`). Usa `DOCKER_EXCLUDES` in `config.sh` solo per casi specifici
> dell'host che non rientrano in questi pattern.

> Servizi **non containerizzati** (es. un processo nativo via systemd) non
> sono coperti automaticamente: se hanno dati importanti, mettili comunque
> dentro la cartella `docker` (il nome è solo convenzionale, `backup.sh` tarra
> tutto quello che trova lì) o aggiungi un passo manuale.

---

## Operazioni comuni

```bash
# Backup manuale in foreground
bash /opt/backups/backup.sh

# In background (consigliato per backup grandi)
nohup bash /opt/backups/backup.sh >> /opt/backups/backup.log 2>&1 &
tail -f /opt/backups/backup.log

# Verifica backup locali
ls -lh /opt/backups/*_backup_*.tar.gz

# Log del cron
tail -100 /opt/backups/backup.log

# Ispeziona un archivio senza estrarlo
tar tzf /opt/backups/<host>_backup_YYYY-MM-DD_HH-MM.tar.gz

# Vedere i backup su GCS
docker run --rm \
  -v /opt/backups/gcs-key.json:/key.json:ro \
  google/cloud-sdk:alpine \
  sh -c "gcloud auth activate-service-account --key-file=/key.json -q \
         && gsutil ls -lh <GCS_BUCKET>/"
```

---

## Ripristino completo su host fresco

```bash
apt update && apt install -y docker.io docker-compose-plugin curl
systemctl enable --now docker

# Recupera l'archivio (da GCS o scp), poi:
mkdir -p /opt/restore && cd /opt/restore
tar xzf <host>_backup_YYYY-MM-DD_HH-MM.tar.gz
cd .work_YYYY-MM-DD_HH-MM/
sudo bash restore.sh
```

`restore.sh` ricrea `docker/` accanto a se stesso rispettando la stessa
convenzione di `backup.sh` — se lo esegui da `/opt/restore/.work_.../`, la
cartella Docker finisce in `/opt/docker` (il path assoluto originale, salvato
dentro il tar). Se vuoi un'altra posizione, sposta prima la cartella estratta
dove desideri che finisca `docker/` come sibling.

### Cosa fa, in ordine

1. **SSH + Fail2ban** — ripristina `sshd_config`, `authorized_keys`. Chiede
   conferma che SSH funzioni prima di continuare.
2. **UFW** — solo se presente nel backup.
3. **Docker dir** — estrae l'intero tar.
4. **Reti Docker** — crea quelle elencate in `DOCKER_NETWORKS`.
5. **Named volumes** — ripristina tutti i volumi Docker.
6. **Servizi** — avvia Postgres (se configurato) e attende sia pronto,
   ripristina i DB, poi avvia dinamicamente ogni `compose.yml` trovato nella
   cartella Docker.

### Dopo il restore

- Verifica ogni servizio nel browser
- `docker logs <container>` per eventuali errori
- Riconfigura token/secret di terze parti
- Ripristina manualmente eventuali servizi non-Docker (es. systemd nativi)

---

## Retention

| Posizione | Retention | Gestione |
|---|---|---|
| Locale (`backups/`) | `KEEP_BACKUPS` giorni | Rotazione automatica in `backup.sh` |
| GCS | Dipende dal bucket | Lifecycle rule impostata sul bucket stesso |

---

## Aggiungere o rimuovere servizi Docker

**Nessuna modifica necessaria.** Il sistema è dinamico:

- Nuovo servizio in `docker/<nome>/compose.yml` (o annidato più in profondità) → incluso automaticamente
- Nuovo database PostgreSQL → incluso automaticamente in `pg_dumpall`
- Nuovo named volume → incluso automaticamente da `docker volume ls`, ovunque sia usato
- Nuova cache (`.cache`, `.npm`, `node_modules`, ...) → esclusa automaticamente dal tar

---

## Note su Diun

I `compose.yml` in questo tipo di setup portano tipicamente una label
`diun.metadata.compose_path=<path assoluto del compose.yml>`, usata da
[Diun](https://github.com/crazy-max/diun) per le notifiche di aggiornamento
immagini e per sapere dove si trova il file da cui è stato lanciato il
servizio. Non ha alcun ruolo nel backup stesso.
