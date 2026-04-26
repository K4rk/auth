#!/bin/bash
set -euo pipefail

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*"; }
err() { echo -e "[ERROR] $*"; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Run as root or with sudo"
  fi
}

install_git() {
  if command -v git >/dev/null 2>&1; then
    log "Git already installed"
    return
  fi

  log "Installing Git..."
  apt update
  apt install -y git
  git config --global credential.helper store
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
    return
  fi

  log "Installing Docker..."

  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_mc() {
  log "Installing MinIO client (mc)..."

  rm -f /usr/bin/mc

  OS=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "Unsupported architecture: $ARCH" ;;
  esac

  curl -fsSL "https://dl.min.io/client/mc/release/${OS}-${ARCH}/mc" \
    -o /usr/local/bin/mc

  chmod +x /usr/local/bin/mc
  ln -sf /usr/local/bin/mc /usr/bin/mc
}

ensure_repo() {
  local repo_url="$1"
  local dir="$2"

  if [[ -d "$dir/.git" ]]; then
    log "Repository '$dir' already exists, updating..."
    git -C "$dir" pull --ff-only || warn "Git pull failed in $dir"
  else
    log "Cloning repository into '$dir'..."
    git clone "$repo_url" "$dir"
  fi
}

setup_network() {
  log "Ensuring Docker network exists..."
  docker network inspect traefik-net >/dev/null 2>&1 || \
    docker network create traefik-net
}

setup_letsencrypt() {
  log "Preparing Let's Encrypt storage..."
  mkdir -p traefik/letsencrypt
  touch traefik/letsencrypt/acme.json
  chmod 600 traefik/letsencrypt/acme.json
}

start_service() {
  local dir="$1"
  log "Starting service in $dir..."
  pushd "$dir" >/dev/null
  docker compose up -d
  popd >/dev/null
}

ask_build_strategy() {
  local service="$1"
  read -rp "Rebuild '$service' without cache? (y/N): " choice

  if [[ "$choice" =~ ^[Yy]$ ]]; then
    docker compose build --no-cache
  fi

  docker compose up -d
}

main() {
  require_root
  install_git
  install_docker
  # Pull latest main branch
  git config --global credential.helper store
  ensure_repo "https://github.com/K4rk/traefik.git" "traefik"
  rm -rf traefik/rules/*

  setup_network
  setup_letsencrypt

  start_service traefik
  start_service keycloak

  log "All services started successfully"
}

main "$@"