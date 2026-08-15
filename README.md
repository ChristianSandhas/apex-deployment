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

## Deployment

```bash
# compose.yaml, overrides/ und example.env auf den Server kopieren, dann:
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
