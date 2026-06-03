#!/bin/bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENV_FILE="$SCRIPT_DIR/keycloak/.env"
LOCAL_KEYCLOAK_DIR="$SCRIPT_DIR/keycloak"

USER="root"
REPO_BASE_DIR="/root"

NODES=(
  "10.31.31.14"
  "10.31.31.15"
  "10.31.31.16"
)

POSTGRES_PRIMARY="10.31.31.14"
KEYCLOAK_CLUSTER_HOSTS="10.31.31.14[7800],10.31.31.15[7800],10.31.31.16[7800]"

PATRONI_SCOPE="keycloak-pg"
ETCD_INITIAL_CLUSTER_TOKEN="patroni-etcd"
SPILO_PROVIDER="local"
PGVERSION="16"
ETCD3_HOSTS="10.31.31.14:2379,10.31.31.15:2379,10.31.31.16:2379"

TRAEFIK_REPO_URL="https://github.com/K4rk/traefik.git"

require_cmd sshpass
require_cmd ssh
require_cmd scp
require_cmd tar

[[ -f "$LOCAL_ENV_FILE" ]] || err "Missing local .env at: $LOCAL_ENV_FILE"
[[ -d "$LOCAL_KEYCLOAK_DIR" ]] || err "Missing local keycloak directory at: $LOCAL_KEYCLOAK_DIR"

node_slug() {
  echo "${1//./-}"
}

build_etcd_initial_cluster() {
  local cluster=""
  local host slug

  for host in "${NODES[@]}"; do
    slug="$(node_slug "$host")"
    cluster+="etcd-${slug}=http://${host}:2380,"
  done

  echo "${cluster%,}"
}

build_etcd_hosts_yaml() {
  local host
  for host in "${NODES[@]}"; do
    printf '          - %s:2379\n' "$host"
  done
}

ETCD_INITIAL_CLUSTER="$(build_etcd_initial_cluster)"

ssh_run() {
  local HOST="$1"
  sshpass -p "$SSHPASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$USER@$HOST" bash -s
}

copy_env_to_host() {
  local HOST="$1"
  sshpass -p "$SSHPASS" scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$LOCAL_ENV_FILE" \
    "$USER@$HOST:$REPO_BASE_DIR/.env"
}

append_node_env() {
  local HOST="$1"
  local NODE_IP="$2"
  local NODE_SLUG
  NODE_SLUG="$(node_slug "$NODE_IP")"

  ssh_run "$HOST" <<EOF
set -euo pipefail

tmp="\$(mktemp)"
grep -Ev '^(NODE_IP|POSTGRES_PRIMARY_HOST|KEYCLOAK_CLUSTER_HOSTS|PATRONI_SCOPE|PATRONI_NODE_NAME|ETCD_NODE_NAME|ETCD_INITIAL_CLUSTER|ETCD_INITIAL_CLUSTER_TOKEN|SPILO_PROVIDER|PGVERSION|ETCD3_HOSTS)=' \
  "$REPO_BASE_DIR/.env" > "\$tmp" || true

cat >>"\$tmp" <<ENVVARS

NODE_IP=$NODE_IP
POSTGRES_PRIMARY_HOST=$POSTGRES_PRIMARY
KEYCLOAK_CLUSTER_HOSTS=$KEYCLOAK_CLUSTER_HOSTS
PATRONI_SCOPE=$PATRONI_SCOPE
PATRONI_NODE_NAME=pg-$NODE_SLUG
ETCD_NODE_NAME=etcd-$NODE_SLUG
ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER
ETCD_INITIAL_CLUSTER_TOKEN=$ETCD_INITIAL_CLUSTER_TOKEN
SPILO_PROVIDER=$SPILO_PROVIDER
PGVERSION=$PGVERSION
ETCD3_HOSTS=$ETCD3_HOSTS
ENVVARS

mv "\$tmp" "$REPO_BASE_DIR/.env"
EOF
}

sync_dir_to_host() {
  local SRC="$1"
  local HOST="$2"
  local DEST="$3"

  [[ -d "$SRC" ]] || err "Source directory does not exist: $SRC"

  ssh_run "$HOST" <<EOF
set -euo pipefail
rm -rf "$DEST"
mkdir -p "$DEST"
EOF

  (
    cd "$SRC"
    tar \
      --exclude='.git' \
      --exclude='.env' \
      -cf - .
  ) | sshpass -p "$SSHPASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$USER@$HOST" "tar -xf - -C '$DEST'"
}

wait_for_tcp() {
  local HOST="$1"
  local PORT="$2"
  local LABEL="${3:-service}"

  for _ in $(seq 1 60); do
    if bash -c "exec 3<>/dev/tcp/$HOST/$PORT" >/dev/null 2>&1; then
      exec 3>&- 3<&- || true
      return 0
    fi
    sleep 2
  done

  err "$LABEL not reachable on $HOST:$PORT"
}

install_base() {
  local HOST="$1"

  log "Installing base packages on $HOST"

  ssh_run "$HOST" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  git \
  tar

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker

mkdir -p /root
EOF
}

setup_network() {
  local HOST="$1"

  ssh_run "$HOST" <<'EOF'
set -euo pipefail
docker network inspect traefik-net >/dev/null 2>&1 || docker network create traefik-net
EOF
}

setup_letsencrypt() {
  local HOST="$1"

  ssh_run "$HOST" <<'EOF'
set -euo pipefail
mkdir -p /root/traefik/letsencrypt
touch /root/traefik/letsencrypt/acme.json
chmod 600 /root/traefik/letsencrypt/acme.json
EOF
}

deploy_traefik() {
  local HOST="$1"

  log "Deploying Traefik on $HOST"

  ssh_run "$HOST" <<EOF
set -euo pipefail

cd "$REPO_BASE_DIR"

if [ -d "traefik/.git" ]; then
  git -C traefik pull --ff-only || true
else
  rm -rf traefik
  git clone "$TRAEFIK_REPO_URL" traefik
fi

cd traefik
git checkout main || true
git pull --ff-only || true

bash replace-identifier.sh auth || true

mkdir -p /root/traefik/letsencrypt
touch /root/traefik/letsencrypt/acme.json
chmod 600 /root/traefik/letsencrypt/acme.json

cp "$REPO_BASE_DIR/.env" "$REPO_BASE_DIR/traefik/.env" || true

docker network inspect traefik-net >/dev/null 2>&1 || docker network create traefik-net

docker compose up -d --remove-orphans
EOF
}

deploy_patroni_etcd() {
  local HOST="$1"
  local NODE_IP="$2"
  local NODE_SLUG
  NODE_SLUG="$(node_slug "$NODE_IP")"

  log "Deploying Patroni + etcd on $HOST"

  ssh_run "$HOST" <<EOF
set -euo pipefail

if [ -f "$REPO_BASE_DIR/.env" ]; then
  set -a
  . "$REPO_BASE_DIR/.env"
  set +a
fi

mkdir -p /root/postgres-ha
cd /root/postgres-ha

cp "$REPO_BASE_DIR/.env" "$REPO_BASE_DIR/postgres-ha/.env" || true

cat >docker-compose.yml <<COMPOSE
services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.13
    container_name: etcd-${NODE_SLUG}
    network_mode: host
    restart: unless-stopped
    volumes:
      - etcd_data:/etcd-data
    entrypoint: ["/usr/local/bin/etcd"]
    command:
      - --name
      - etcd-${NODE_SLUG}
      - --data-dir
      - /etcd-data
      - --listen-peer-urls
      - http://0.0.0.0:2380
      - --listen-client-urls
      - http://0.0.0.0:2379,http://127.0.0.1:2379
      - --advertise-client-urls
      - http://${NODE_IP}:2379
      - --initial-advertise-peer-urls
      - http://${NODE_IP}:2380
      - --initial-cluster
      - ${ETCD_INITIAL_CLUSTER}
      - --initial-cluster-token
      - ${ETCD_INITIAL_CLUSTER_TOKEN}
      - --initial-cluster-state
      - new

  patroni:
    image: ghcr.io/zalando/spilo-16:3.3-p3
    container_name: patroni-${NODE_SLUG}
    network_mode: host
    restart: unless-stopped
    depends_on:
      - etcd
    environment:
      SPILO_PROVIDER: ${SPILO_PROVIDER}
      PGVERSION: ${PGVERSION}
      SCOPE: ${PATRONI_SCOPE}
      ETCD3_HOSTS: ${ETCD3_HOSTS}
      RESTAPI_CONNECT_ADDRESS: ${NODE_IP}:8008
      PATRONI_CONFIGURATION: |
        postgresql:
          connect_address: ${NODE_IP}:5432
      PGUSER_SUPERUSER: \${POSTGRESQL_USER}
      PGPASSWORD_SUPERUSER: \${POSTGRESQL_PASS}
      PGUSER_STANDBY: \${POSTGRESQL_USER}
      PGPASSWORD_STANDBY: \${POSTGRESQL_PASS}

volumes:
  etcd_data:
  patroni_data:
COMPOSE

docker compose up -d --remove-orphans
EOF
}

deploy_keycloak() {
  local HOST="$1"
  local NODE_IP="$2"

  log "Deploying Keycloak on $HOST"

  ssh_run "$HOST" <<EOF
set -euo pipefail

if [ -f "$REPO_BASE_DIR/.env" ]; then
  set -a
  . "$REPO_BASE_DIR/.env"
  set +a
fi

if [ -d /root/keycloak ]; then
  cd /root/keycloak
  docker compose down || true
fi

rm -rf /root/keycloak
mkdir -p /root/keycloak
EOF

  sync_dir_to_host "$LOCAL_KEYCLOAK_DIR" "$HOST" "/root/keycloak"

  ssh_run "$HOST" <<EOF
set -euo pipefail

if [ -f "$REPO_BASE_DIR/.env" ]; then
  set -a
  . "$REPO_BASE_DIR/.env"
  set +a
fi

cd /root/keycloak

cp "$REPO_BASE_DIR/.env" "$REPO_BASE_DIR/keycloak/.env" || true

cat >docker-compose.override.yml <<COMPOSE
services:
  keycloak:
    image: registry2.esadax.org/ironic/keycloak
    build: .
    restart: unless-stopped
    environment:
      KC_DB: postgres
      KC_DB_URL_HOST: \${POSTGRES_PRIMARY_HOST}
      KC_DB_URL_DATABASE: \${POSTGRESQL_DB}
      KC_DB_USERNAME: \${POSTGRESQL_USER}
      KC_DB_PASSWORD: \${POSTGRESQL_PASS}
      KC_HOSTNAME: \${KC_HOSTNAME:-auth2.esadax.org}
      KC_HOSTNAME_STRICT: "false"
      KC_HTTP_ENABLED: "true"
      KC_HTTP_PORT: 8080
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
      PROXY_ADDRESS_FORWARDING: "true"
      KC_HEALTH_ENABLED: "true"
      KC_METRICS_ENABLED: "true"
      KC_PROXY: edge
      KC_CACHE: ispn
      KC_CACHE_STACK: tcp
      JAVA_OPTS_APPEND: "-Djgroups.bind_addr=${NODE_IP} -Djgroups.tcpping.initial_hosts=${KEYCLOAK_CLUSTER_HOSTS}"
    ports:
      - "8080:8080"
      - "7800:7800"
    networks:
      - traefik-net
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-net
      - traefik.http.routers.keycloak-24.rule=Host(\`auth2.esadax.org\`)
      - traefik.http.routers.keycloak-24.entrypoints=https
      - traefik.http.routers.keycloak-24.tls=true
      - traefik.http.routers.keycloak-24.tls.certresolver=powerdns
      - traefik.http.routers.keycloak-24.tls.domains[0].main=esadax.com
      - traefik.http.routers.keycloak-24.tls.domains[0].sans=*.esadax.com
      - traefik.http.services.keycloak-24.loadbalancer.server.port=8080

volumes:
  db_data:

networks:
  traefik-net:
    external: true
COMPOSE

docker compose up -d --remove-orphans
EOF
}

main() {
  read -s -p "Root SSH password: " SSHPASS
  echo ""

  log "Installing base on all nodes..."
  for n in "${NODES[@]}"; do
    install_base "$n"
    copy_env_to_host "$n"
    append_node_env "$n" "$n"
    setup_network "$n"
  done

  log "Deploying Traefik..."
  for n in "${NODES[@]}"; do
    setup_letsencrypt "$n"
    deploy_traefik "$n"
  done

  log "Deploying Patroni + etcd cluster..."
  for n in "${NODES[@]}"; do
    deploy_patroni_etcd "$n" "$n"
  done

  for n in "${NODES[@]}"; do
    wait_for_tcp "$n" 2379 "etcd"
    wait_for_tcp "$n" 8008 "patroni"
  done

  log "Deploying Keycloak..."
  for n in "${NODES[@]}"; do
    deploy_keycloak "$n" "$n"
  done

  log "All services deployed successfully"
}

git submodule update --init --recursive || true
git submodule update --remote --merge || true

main "$@"