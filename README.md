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
compose.yaml           kompletter Stack; die Datenbank wird über
                       COMPOSE_PROFILES in der .env gewählt
example.env            Vorlage für .env (echte .env nie einchecken)
apps.json + build.sh   manueller Image-Build (Fallback)
```

Beide Datenbank-Services (MariaDB und Postgres) stehen in derselben Datei;
aktiv ist immer nur der, dessen Profil über `COMPOSE_PROFILES` gewählt ist
(`mariadb` = Produktions-Standard, `postgres` = Prüfstand für die
DB-Neutralität des apex-Codes). Beide sind im Netzwerk als `db` erreichbar.
Die Wahl **immer in der `.env` treffen**, nicht über `docker compose
--profile` — die Setup-Kommandos lesen dieselbe Variable, um DB-Port und
`bench new-site`-Flags zu bestimmen.

## Systemvoraussetzungen

- Linux-Server, **x86_64/amd64** (das Image wird nur für diese Architektur
  gebaut), z.B. Ubuntu 22.04/24.04 LTS
- **Docker Engine ab Version 24 mit Compose-Plugin v2** (mindestens
  Compose **2.23.1**, wegen der Inline-Configs in der compose.yaml;
  Installation: https://docs.docker.com/engine/install/ — prüfen mit
  `docker compose version`)
- mind. **2 CPU-Kerne und 4 GB RAM** (Frappe-Worker + Datenbank + Redis),
  **20 GB freier Plattenplatz** für Images, Volumes und Backups
- Netzzugriff auf `ghcr.io` (Image-Registry); bei privatem Image ein
  GitHub-Token mit `read:packages` für `docker login ghcr.io`
- ein Reverse-Proxy mit TLS davor (z.B. Nginx Proxy Manager) — der Stack
  selbst spricht nur HTTP auf `HTTP_PORT`

## Herunterladen

Auf dem Server werden nur `compose.yaml` und `example.env` gebraucht.
Am einfachsten das ganze Repo als Archiv ziehen:

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
cp example.env .env   # COMPOSE_PROFILES, Passwörter, Site-Namen anpassen
docker login ghcr.io  # falls Image privat
docker compose up -d
```

Beim ersten Start legt `create-site` die Site an und installiert apex.
Erreichbar unter Port `HTTP_PORT` (Standard 8080) — davor gehört ein
Reverse-Proxy mit TLS (z.B. der vorhandene Nginx Proxy Manager).

**Eine Datenbank pro Deployment:** Die Site im `sites`-Volume ist fest an die
beim Anlegen gewählte Datenbank gebunden. `COMPOSE_PROFILES` später zu ändern
ist also kein Umschalten, sondern bräuchte eine neue Site (Volumes entfernen
oder besser ein eigenes Compose-Projekt starten). Beide Varianten parallel
auf einem Host:

```bash
COMPOSE_PROFILES=postgres HTTP_PORT=8081 docker compose -p apex-pg up -d
```

`-p` gibt dem zweiten Stack einen eigenen Projektnamen und damit eigene
Volumes und Netzwerke; Variablen auf der Kommandozeile übersteuern die
`.env` (andere Ports wählen, damit sich die Stacks nicht beißen).

## Update auf neue Version

```bash
# Neues Release im apex-Repo taggen (Actions baut und pusht das Image), dann:
# APEX_VERSION in .env anheben
docker compose pull
docker compose up -d
docker compose exec backend bench --site <sitename> migrate
```

## Betrieb & Diagnose

### „Process Not Found" im System Health Report

Der System Health Report (`/app/system-health-report`) meldet im Container-Betrieb
dauerhaft `Process Not Found` für den Scheduler — **auch wenn dieser einwandfrei
läuft**. Das ist erwartet und kein Ausfall.

Grund: Frappe erkennt den laufenden Scheduler nicht am Prozess, sondern an einer
Lock-Datei unter `frappe-bench/config/scheduler_process`. Der Stack teilt zwischen
den Containern aber nur das `sites`-Volume; `config/` kommt aus dem Image und ist
in jedem Container eine eigene Kopie. Der `scheduler`-Container hält die Sperre
damit in seinem eigenen Dateisystem, während der `backend`-Container — der den
Report rendert — auf eine andere, ungesperrte Datei schaut.

`config/` als geteiltes Volume nachzurüsten behebt zwar die Anzeige, ist die
Nebenwirkung aber nicht wert: Ein Named Volume wird nur beim ersten Start aus dem
Image befüllt und bekäme bei Image-Updates keine neuen Configs mehr.

Der tatsächliche Zustand wird stattdessen so geprüft:

```bash
docker compose ps scheduler            # Container up? bench schedule ist dessen Hauptprozess
docker compose logs --tail=50 scheduler
docker compose exec backend bench --site <sitename> scheduler status
```

Der letzte Befehl ist wichtig, weil der Report seine Prüfungen in fester Reihenfolge
abarbeitet: Die Prozess-Erkennung greift **vor** der Statusprüfung, `Process Not Found`
überdeckt also ein eventuelles `Inactive`. Ein für die Site pausierter oder
abgeschalteter Scheduler (`pause_scheduler` nach einem abgebrochenen `migrate`,
`disable_scheduler`) wäre in der Oberfläche schlicht nicht zu sehen. Bei Bedarf mit
`bench --site <sitename> scheduler resume` bzw. `enable` reaktivieren.

Als inhaltliche Gegenprobe, ob wirklich Jobs abgearbeitet werden:

```bash
docker compose exec backend bench --site <sitename> execute frappe.db.get_all \
  --kwargs '{"doctype":"Scheduled Job Type","fields":["name","method","last_execution"],"order_by":"last_execution desc","limit_page_length":5}'
```

Aktuelle Zeitstempel bedeuten: alles in Ordnung. Einträge mit `last_execution: null`
sind unauffällig (selten laufende oder neu hinzugekommene Jobs) — unter Postgres
sortieren sie bei `DESC` allerdings nach oben, unter MariaDB nach unten.

## Migration MariaDB → PostgreSQL (einmalig)

Der Stack betreibt bewusst nur **eine** Datenbank (beide Services teilen sich den
Netzwerk-Alias `db`). Für den einmaligen Umzug wird deshalb **nicht** das zweite
Profil aktiviert, sondern Postgres läuft für die Dauer der Migration als
Wegwerf-Container daneben — mit demselben Volume, das später der reguläre
`db-postgres`-Service nutzt. Nach dem Umschalten findet er die Daten dort vor.

Die Site behält dabei Ordner, Dateien (Anhänge, `.eml`-Ablage) und
`encryption_key` — nur die Datenbank darunter wird getauscht. Voraussetzung:
ein Image, das `apps/apex/scripts/migrate_mariadb_to_postgres.py` enthält
(sonst das Skript vorab per `docker compose cp` in den backend-Container legen).
Namen von Netzwerk/Volume ggf. mit `docker network ls` / `docker volume ls`
prüfen (Präfix = Ordnername des Stacks).

```bash
# 0. Backup ziehen, Schreibbetrieb anhalten (backend bleibt für Kommandos an)
docker compose exec backend bench --site <sitename> backup
docker compose stop frontend websocket scheduler queue-short queue-long

# 1. Wegwerf-Postgres mit dem Volume des späteren Services starten
docker run -d --name db-migration \
  --network apex-deployment_default \
  -e POSTGRES_PASSWORD=<DB_PASSWORD aus .env> \
  -v apex-deployment_db-postgres-data:/var/lib/postgresql \
  postgres:18

# 2. Im backend-Container: Zielschema durch Frappe anlegen, dann Daten kopieren
docker compose exec backend bash
# --db-port 5432 ist Pflicht: global steht db_port auf 3306 (MariaDB-Profil),
# und new-site wendet den sonst auch auf die Postgres-Verbindung an.
bench new-site migration.tmp --db-type postgres --db-host db-migration --db-port 5432 \
  --db-root-username postgres --db-root-password <DB_PASSWORD> \
  --admin-password egal --install-app apex
# WICHTIG: erst migrate — Custom-Field-Spalten (z. B. auf Communication)
# entstehen erst hier; das Skript prueft das und bricht sonst ab.
bench --site migration.tmp migrate
./env/bin/python apps/apex/scripts/migrate_mariadb_to_postgres.py \
  --source-site <sitename> --target-site migration.tmp --dry-run
./env/bin/python apps/apex/scripts/migrate_mariadb_to_postgres.py \
  --source-site <sitename> --target-site migration.tmp
# Die encryption_key-Warnung des Skripts ist in DIESEM Ablauf unkritisch:
# die echte Site behält ihren Ordner samt Key, nur die DB wird untergeschoben.

# 3. Echte Site auf die neue DB zeigen lassen: in sites/<sitename>/site_config.json
#    db_type, db_name, db_password und db_user aus sites/migration.tmp/site_config.json
#    übernehmen (ein alter MariaDB-db_user fuehrt sonst zu "password authentication
#    failed"). db_host NICHT übernehmen (global bleibt "db"), encryption_key
#    und alles andere unangetastet lassen.

# 4. Temp-Site-Ordner entfernen — NICHT "bench drop-site", die DB gehört jetzt
#    der echten Site!
rm -rf sites/migration.tmp
exit

# 5. Umschalten
docker rm -f db-migration
# in .env: COMPOSE_PROFILES=postgres (und ein evtl. gesetztes DB_PORT=3306 entfernen)
docker compose down && docker compose up -d
docker compose exec backend bench --site <sitename> migrate   # Sanity-Check
docker compose exec backend bench --site <sitename> clear-cache
```

Danach anmelden und stichprobenartig prüfen (Mails samt Anhängen, Zeiterfassung,
Nummernkreise). **Rückweg**, falls etwas klemmt: `site_config.json` zurückdrehen,
`COMPOSE_PROFILES=mariadb`, `docker compose down && up -d` — das MariaDB-Volume
bleibt so lange unangetastet liegen, bis man es bewusst löscht.

**Warnung — COMPOSE_PROFILES ist ein Einzelwert:** `mariadb` **oder** `postgres`,
niemals beide (`mariadb,postgres`). Ein Mischwert startet beide Datenbanken: Der
geteilte Netzwerk-Alias `db` ist dann doppelt vergeben (Verbindungen landen zufällig
mal hier, mal dort), und die Setup-Kommandos erkennen den Postgres-Modus nur am
exakten Wert — sie setzen sonst den falschen globalen DB-Port. Symptome: Web geht
„irgendwie", Hintergrund-Jobs scheitern reihenweise. Erkennen: `docker compose ps`
zeigt zwei db-Container. Beheben: `.env` korrigieren, dann
`docker compose --profile mariadb down` (ein nach der Korrektur inaktives Profil
braucht den expliziten `--profile`-Zusatz, sonst läuft sein Container einfach
weiter) und `docker compose up -d`.

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
