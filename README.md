# ApeX Deployment

Docker-Compose-Konfiguration für den Betrieb von ApeX (Frappe v16 + apex).

Das Anwendungs-Image wird **nicht hier** gebaut: Bei jedem Tag-Push (`v*`) im
[apex-Repo](https://github.com/ChristianSandhas/apex) baut GitHub Actions
(`.github/workflows/build-release.yml`) das Image und pusht es nach
`ghcr.io/christiansandhas/apex`. Dieses Repo enthält nur den Betriebs-Stack,
der das fertige Image konsumiert. `build.sh` ist der manuelle Fallback,
falls der Actions-Build einmal nicht verfügbar ist.

## Struktur

```
compose.yaml                     Basis-Stack (Frappe, Redis, Worker) — ohne DB
overrides/compose.mariadb.yaml   MariaDB-Variante (Produktions-Standard)
overrides/compose.postgres.yaml  Postgres-Variante (Prüfstand für DB-Neutralität)
example.env                      Vorlage für .env (echte .env nie einchecken)
apps.json + build.sh             manueller Image-Build (Fallback)
```

Die Basis-Datei allein ist bewusst nicht lauffähig — immer mit genau einem
DB-Override kombinieren.

## Systemvoraussetzungen

- Linux-Server, **x86_64/amd64** (das Image wird nur für diese Architektur
  gebaut), z.B. Ubuntu 22.04/24.04 LTS
- **Docker Engine ab Version 24 mit Compose-Plugin v2**
  (Installation: https://docs.docker.com/engine/install/ — prüfen mit
  `docker compose version`)
- mind. **2 CPU-Kerne und 4 GB RAM** (Frappe-Worker + Datenbank + Redis),
  **20 GB freier Plattenplatz** für Images, Volumes und Backups
- Netzzugriff auf `ghcr.io` (Image-Registry); bei privatem Image ein
  GitHub-Token mit `read:packages` für `docker login ghcr.io`
- ein Reverse-Proxy mit TLS davor (z.B. Nginx Proxy Manager) — der Stack
  selbst spricht nur HTTP auf `HTTP_PORT`

## Herunterladen

Auf dem Server werden nur `compose.yaml`, `overrides/` und `example.env`
gebraucht. Am einfachsten das ganze Repo als Archiv ziehen:

```bash
wget -O apex-deployment.tar.gz \
  https://github.com/ChristianSandhas/apex-deployment/archive/refs/heads/main.tar.gz
tar -xzf apex-deployment.tar.gz
cd apex-deployment-main
```

Alternativ per Git (macht spätere Updates zu einem `git pull`):

```bash
git clone https://github.com/ChristianSandhas/apex-deployment.git
cd apex-deployment
```

Solange das Repo privat ist, funktioniert der anonyme `wget`-Download nicht —
dann stattdessen `gh repo clone ChristianSandhas/apex-deployment`
(nach `gh auth login`) oder das Archiv mit Token laden:

```bash
wget --header="Authorization: Bearer github_pat_xxx" -O apex-deployment.tar.gz \
  https://api.github.com/repos/ChristianSandhas/apex-deployment/tarball/main
```

## Deployment

```bash
cp example.env .env   # Passwörter/Site-Namen anpassen
docker login ghcr.io  # falls Image privat

# MariaDB (Produktion):
docker compose -f compose.yaml -f overrides/compose.mariadb.yaml up -d

# oder Postgres (Prüfstand):
docker compose -f compose.yaml -f overrides/compose.postgres.yaml up -d
```

Beim ersten Start legt `create-site` die Site an und installiert apex.
Erreichbar unter Port `HTTP_PORT` (Standard 8080) — davor gehört ein
Reverse-Proxy mit TLS (z.B. der vorhandene Nginx Proxy Manager).

**Eine Datenbank pro Deployment:** Die Site im `sites`-Volume ist fest an die
beim Anlegen gewählte Datenbank gebunden. Ein Wechsel MariaDB ↔ Postgres ist
kein Umschalten, sondern eine neue Site (Volumes entfernen oder besser ein
eigenes Compose-Projekt starten). Beide Varianten parallel auf einem Host:

```bash
docker compose -p apex-pg -f compose.yaml -f overrides/compose.postgres.yaml up -d
```

`-p` gibt dem zweiten Stack einen eigenen Projektnamen und damit eigene
Volumes und Netzwerke; `HTTP_PORT`/`DB_PORT` in der `.env` dann anpassen,
damit sich die Host-Ports nicht beißen.

## Update auf neue Version

```bash
# Neues Release im apex-Repo taggen (Actions baut und pusht das Image), dann:
# APEX_VERSION in .env anheben
docker compose -f compose.yaml -f overrides/compose.mariadb.yaml pull
docker compose -f compose.yaml -f overrides/compose.mariadb.yaml up -d
docker compose -f compose.yaml -f overrides/compose.mariadb.yaml exec backend \
  bench --site <sitename> migrate
```

## Manueller Image-Build (Fallback)

Braucht einen **read-only GitHub-Token** (Settings → Developer settings →
Fine-grained token, nur Repo `apex`, Permission "Contents: Read"), weil das
Repo privat ist. Achtung: der Token landet in der Git-Remote-URL im Image —
das Image daher nur in eine **private** Registry pushen.

```bash
export GITHUB_PAT=github_pat_xxx
./build.sh v0.1.0

# Push (Token braucht write:packages):
echo $GITHUB_PAT_WRITE | docker login ghcr.io -u ChristianSandhas --password-stdin
docker push ghcr.io/christiansandhas/apex:v0.1.0
docker push ghcr.io/christiansandhas/apex:latest
```

Baut den Stand des übergebenen Versions-Tags (muss gepusht sein) mit
Frappe-Branch `version-16` über den layered Build von
[frappe_docker](https://github.com/frappe/frappe_docker).
