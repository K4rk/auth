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
REPO_BASE_DIR="/opt/stack"

NODES=(
  "10.31.31.14"
  "10.31.31.15"
  "10.31.31.16"
)

POSTGRES_PRIMARY="10.31.31.14"
POSTGRES_REPLICA="10.31.31.16"

KEYCLOAK_CLUSTER_HOSTS="10.31.31.14[7800],10.31.31.15[7800],10.31.31.16[7800]"

TRAEFIK_REPO_URL="https://github.com/K4rk/traefik.git"

require_cmd sshpass
require_cmd ssh
require_cmd scp
require_cmd tar

[[ -f "$LOCAL_ENV_FILE" ]] || err "Missing local .env at: $LOCAL_ENV_FILE"
[[ -d "$LOCAL_KEYCLOAK_DIR" ]] || err "Missing local keycloak directory at: $LOCAL_KEYCLOAK_DIR"

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

  ssh_run "$HOST" <<EOF
set -euo pipefail

cat >>"$REPO_BASE_DIR/.env" <<ENVVARS

NODE_IP=$NODE_IP
POSTGRES_PRIMARY_HOST=$POSTGRES_PRIMARY
KEYCLOAK_CLUSTER_HOSTS=$KEYCLOAK_CLUSTER_HOSTS
ENVVARS
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

mkdir -p /opt/stack
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
mkdir -p /opt/stack/traefik/letsencrypt
touch /opt/stack/traefik/letsencrypt/acme.json
chmod 600 /opt/stack/traefik/letsencrypt/acme.json
EOF
}

link_env_files() {
  local HOST="$1"

  ssh_run "$HOST" <<'EOF'
set -euo pipefail

ln -sfn ../.env /opt/stack/traefik/.env || true
ln -sfn ../.env /opt/stack/keycloak/.env || true
ln -sfn ../.env /opt/stack/postgres-primary/.env || true
ln -sfn ../.env /opt/stack/postgres-replica/.env || true
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
  git clone "$TRAEFIK_REPO_URL" traefik
fi

cd traefik
git checkout main || true
git pull --ff-only || true

bash replace-identifier.sh auth || true

mkdir -p /opt/stack/traefik/letsencrypt
touch /opt/stack/traefik/letsencrypt/acme.json
chmod 600 /opt/stack/traefik/letsencrypt/acme.json

ln -sfn ../.env /opt/stack/traefik/.env

docker network inspect traefik-net >/dev/null 2>&1 || docker network create traefik-net

docker compose up -d --remove-orphans
EOF
}

deploy_postgres_primary() {
  local HOST="$1"

  log "Deploying PostgreSQL primary on $HOST"

  ssh_run "$HOST" <<'EOF'
set -euo pipefail

mkdir -p /opt/stack/postgres-primary/initdb
cd /opt/stack/postgres-primary

ln -sfn ../.env .env

cat >docker-compose.yml <<'COMPOSE'
services:
  postgres:
    image: postgres:14
    container_name: postgres-primary
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRESQL_DB}
      POSTGRES_USER: ${POSTGRESQL_USER}
      POSTGRES_PASSWORD: ${POSTGRESQL_PASS}
      POSTGRES_HOST_AUTH_METHOD: md5
      POSTGRES_INITDB_ARGS: "--auth-host=md5 --auth-local=trust"
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d:ro
    command: >
      postgres
      -c wal_level=replica
      -c max_wal_senders=10
      -c max_replication_slots=10
      -c wal_keep_size=256MB
      -c listen_addresses='*'

volumes:
  pgdata:
COMPOSE

cat >initdb/01-replication.sh <<'EOSH'
#!/bin/bash
set -euo pipefail

echo "host replication all all md5" >> "$PGDATA/pg_hba.conf"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
DO $$
BEGIN
  EXECUTE format('ALTER ROLE %I WITH REPLICATION LOGIN', current_user);
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Could not alter role privileges';
END
$$;
SQL
EOSH

chmod +x initdb/01-replication.sh

docker compose up -d --remove-orphans
EOF
}

deploy_postgres_replica() {
  local HOST="$1"

  log "Deploying PostgreSQL replica on $HOST"

  ssh_run "$HOST" <<'EOF'
set -euo pipefail

mkdir -p /opt/stack/postgres-replica
cd /opt/stack/postgres-replica

ln -sfn ../.env .env

cat >docker-compose.yml <<'COMPOSE'
services:
  postgres:
    image: postgres:14
    container_name: postgres-replica
    restart: unless-stopped
    user: root
    environment:
      PRIMARY_HOST: ${POSTGRES_PRIMARY_HOST}
      REPLICATION_USER: ${POSTGRESQL_USER}
      REPLICATION_PASSWORD: ${POSTGRESQL_PASS}
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./start-replica.sh:/start-replica.sh:ro
    entrypoint: ["/bin/bash", "/start-replica.sh"]

volumes:
  pgdata:
COMPOSE

cat >start-replica.sh <<'EOSH'
#!/bin/bash
set -euo pipefail

: "${PRIMARY_HOST:?}"
: "${REPLICATION_USER:?}"
: "${REPLICATION_PASSWORD:?}"

mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA" || true

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$REPLICATION_USER" >/dev/null 2>&1; do
    sleep 2
  done

  export PGPASSWORD="$REPLICATION_PASSWORD"
  find "$PGDATA" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
  gosu postgres pg_basebackup -h "$PRIMARY_HOST" -p 5432 -U "$REPLICATION_USER" -D "$PGDATA" -Fp -Xs -P -R
fi

exec gosu postgres postgres -c hot_standby=on -c listen_addresses='*'
EOSH

chmod +x start-replica.sh

docker compose up -d --remove-orphans
EOF
}

deploy_keycloak() {
  local HOST="$1"
  local NODE_IP="$2"

  log "Deploying Keycloak on $HOST"

  ssh_run "$HOST" <<EOF
set -euo pipefail

if [ -d /opt/stack/keycloak ]; then
  cd /opt/stack/keycloak
  docker compose down || true
fi

rm -rf /opt/stack/keycloak
mkdir -p /opt/stack/keycloak
EOF

  sync_dir_to_host "$LOCAL_KEYCLOAK_DIR" "$HOST" "/opt/stack/keycloak"

  ssh_run "$HOST" <<EOF
set -euo pipefail

cd /opt/stack/keycloak

ln -sfn ../.env .env

cat >docker-compose.override.yml <<'COMPOSE'
services:
  keycloak:
    image: registry2.esadax.org/ironic/keycloak
    build: .
    restart: unless-stopped
    environment:
      KC_DB: postgres
      KC_DB_URL_HOST: ${POSTGRES_PRIMARY_HOST}
      KC_DB_URL_DATABASE: ${POSTGRESQL_DB}
      KC_DB_USERNAME: ${POSTGRESQL_USER}
      KC_DB_PASSWORD: ${POSTGRESQL_PASS}
      KC_HOSTNAME: ${KC_HOSTNAME:-auth2.esadax.org}
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
      - traefik.http.routers.keycloak-24.rule=Host(`auth2.esadax.org`)
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
  for HOST in "${NODES[@]}"; do
    install_base "$HOST"
    copy_env_to_host "$HOST"
    append_node_env "$HOST" "$HOST"
    setup_network "$HOST"
  done

  for HOST in "${NODES[@]}"; do
    setup_letsencrypt "$HOST"
    deploy_traefik "$HOST"
  done

  deploy_postgres_primary "$POSTGRES_PRIMARY"
  wait_for_tcp "$POSTGRES_PRIMARY" 5432 "PostgreSQL primary"

  deploy_postgres_replica "$POSTGRES_REPLICA"
  wait_for_tcp "$POSTGRES_REPLICA" 5432 "PostgreSQL replica"

  for HOST in "${NODES[@]}"; do
    deploy_keycloak "$HOST" "$HOST"
  done

  log "All services deployed successfully"
}

read -s -p "Root SSH password: " SSHPASS
echo

main "$@"