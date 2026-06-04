#!/bin/bash
set -euo pipefail

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*"; exit 1; }

USER="root"

NODES=(
  "10.31.31.14"
  "10.31.31.15"
  "10.31.31.16"
)

ssh_run() {
  local HOST="$1"
  sshpass -p "$SSHPASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$USER@$HOST" bash -s
}

confirm() {
  local msg="$1"
  read -r -p "$msg (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

uninstall_on_host() {
  local HOST="$1"
  local REMOVE_PG="$2"
  local REMOVE_TR="$3"
  local REMOVE_KC="$4"

  log "Uninstalling on $HOST"

  ssh_run "$HOST" <<EOF
set -euo pipefail

echo "[INFO] stopping all related containers..."

# ---------------- TRAEFIK ----------------
if [ "$REMOVE_TR" = "y" ]; then
  docker ps -a --format '{{.Names}}' | grep -E 'traefik' | xargs -r docker rm -f || true
  docker compose -f /root/traefik/docker-compose.yml down -v || true
  rm -rf /root/traefik || true
fi

# ---------------- KEYCLOAK ----------------
if [ "$REMOVE_KC" = "y" ]; then
  docker ps -a --format '{{.Names}}' | grep -E 'keycloak' | xargs -r docker rm -f || true
  docker compose -f /root/keycloak/docker-compose.yml down -v || true
  rm -rf /root/keycloak || true
fi

# ---------------- POSTGRES / PATRONI / ETCD ----------------
if [ "$REMOVE_PG" = "y" ]; then
  docker ps -a --format '{{.Names}}' | grep -E 'patroni|etcd' | xargs -r docker rm -f || true
  docker compose -f /root/postgres-ha/docker-compose.yml down -v || true
  rm -rf /root/postgres-ha || true
fi

# ---------------- CLEAN ENV ----------------
rm -f /root/.env || true

echo "[INFO] cleanup done on $HOST"
EOF
}

main() {
  read -s -p "SSH password: " SSHPASS
  echo ""

  confirm "Remove Postgres/Patroni cluster?" && RM_PG="y" || RM_PG="n"
  confirm "Remove Traefik?" && RM_TR="y" || RM_TR="n"
  confirm "Remove Keycloak?" && RM_KC="y" || RM_KC="n"

  for n in "${NODES[@]}"; do
    uninstall_on_host "$n" "$RM_PG" "$RM_TR" "$RM_KC"
  done

  log "Uninstall completed"
}

main "$@"