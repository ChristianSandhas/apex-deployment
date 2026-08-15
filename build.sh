#!/usr/bin/env bash
# Baut das Produktions-Image (Frappe + apex) über frappe_docker (layered build).
#
# Voraussetzungen:
#   - Docker installiert
#   - GITHUB_PAT gesetzt (read-only Token für das private apex-Repo):
#       export GITHUB_PAT=github_pat_xxx
#
# Aufruf:  ./build.sh v0.1.0
set -euo pipefail

VERSION="${1:?Aufruf: ./build.sh <version-tag, z.B. v0.1.0>}"
: "${GITHUB_PAT:?GITHUB_PAT muss gesetzt sein (read-only PAT fuer das apex-Repo)}"

# Muss zum Frappe-Stand der Entwicklung passen.
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-16}"
IMAGE="${IMAGE:-ghcr.io/christiansandhas/apex}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git clone --depth 1 https://github.com/frappe/frappe_docker "$WORKDIR/frappe_docker"

# Gebaut wird exakt der Stand des übergebenen Versions-Tags (reproduzierbar),
# nicht der aktuelle Branch-Stand. Der Tag muss also gepusht sein.
# apps.json geht als BuildKit-Secret rein (id=apps_json) — so erwartet es
# der aktuelle layered Containerfile von frappe_docker.
sed -e "s|{{PAT}}|$GITHUB_PAT|" -e "s|{{BRANCH}}|$VERSION|" "$SCRIPT_DIR/apps.json" > "$WORKDIR/apps.json"

DOCKER_BUILDKIT=1 docker build \
  --build-arg FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg FRAPPE_BRANCH="$FRAPPE_BRANCH" \
  --build-arg CACHE_BUST="$VERSION" \
  --secret id=apps_json,src="$WORKDIR/apps.json" \
  --tag "$IMAGE:$VERSION" \
  --tag "$IMAGE:latest" \
  --file "$WORKDIR/frappe_docker/images/layered/Containerfile" \
  "$WORKDIR/frappe_docker"

echo
echo "Fertig: $IMAGE:$VERSION"
echo "Push mit:  docker push $IMAGE:$VERSION && docker push $IMAGE:latest"
