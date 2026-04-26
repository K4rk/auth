#!/bin/bash
set -euo pipefail

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  err "Run as root on Proxmox host"
fi

apply_sysctl_host() {
  log "Applying sysctl on Proxmox host..."

  cat > /etc/sysctl.d/99-keycloak-udp.conf <<EOF
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=2621440
net.core.wmem_default=2621440
EOF

  sysctl -w net.core.rmem_max=33554432
  sysctl -w net.core.wmem_max=33554432
  sysctl -w net.core.rmem_default=2621440
  sysctl -w net.core.wmem_default=2621440

  sysctl --system >/dev/null
}


apply_sysctl_host

log "Done"