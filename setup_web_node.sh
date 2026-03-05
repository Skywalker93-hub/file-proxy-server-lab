#!/usr/bin/env bash
set -euo pipefail

SMB_USER="smbuser"
MOUNT_ROOT="/mnt/smb"
MAP_FILE="/etc/auto.cifs"
MASTER_FILE="/etc/auto.master.d/cifs.autofs"
CRED_FILE="/etc/cifs-${SMB_USER}.cred"
PY_UNIT="/etc/systemd/system/python-webshare.service"
PY_PORT="8000"

log(){ echo -e "\n==> $*"; }
have_pkg(){ dpkg -s "$1" &>/dev/null; }
file_has(){ grep -Fqx "$1" "$2" 2>/dev/null; }

read_nonempty() {
  local prompt="$1" v=""
  while [[ -z "$v" ]]; do read -r -p "$prompt" v; done
  echo "$v"
}

read_secret_once() {
  local prompt="$1" v=""
  while [[ -z "$v" ]]; do
    read -r -s -p "$prompt" v; echo
  done
  echo "$v"
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

ensure_pkg() {
  local p="$1"
  if have_pkg "$p"; then
    echo "[SKIP] package $p already installed"
  else
    log "Installing package: $p"
    apt-get update -y
    apt-get install -y "$p"
  fi
}

ensure_dirs() {
  if [[ -d "$MOUNT_ROOT" ]]; then
    echo "[SKIP] $MOUNT_ROOT exists"
  else
    log "Creating $MOUNT_ROOT"
    mkdir -p "$MOUNT_ROOT"
  fi
}

ensure_master_map() {
  log "Configuring autofs master snippet: $MASTER_FILE"
  # Always write deterministic content (safe)
  cat > "$MASTER_FILE" <<EOF
${MOUNT_ROOT}   ${MAP_FILE}   --timeout=60 --browse
EOF
}

ensure_creds() {
  if [[ -f "$CRED_FILE" ]]; then
    echo "[SKIP] credentials file exists: $CRED_FILE"
  else
    log "Creating credentials file: $CRED_FILE"
    local pw
    pw="$(read_secret_once "Enter Samba password for smbuser (from proxy-samba): ")"
    cat > "$CRED_FILE" <<EOF
username=${SMB_USER}
password=${pw}
EOF
    chmod 600 "$CRED_FILE"
  fi
}

ensure_map_file() {
  local proxy_ip="$1"
  log "Configuring autofs map: $MAP_FILE"
  cat > "$MAP_FILE" <<EOF
${SMB_USER}  -fstype=cifs,credentials=${CRED_FILE},vers=3.1.1,uid=0,gid=0,dir_mode=0755,file_mode=0755  ://${proxy_ip}/${SMB_USER}
EOF
  chmod 600 "$MAP_FILE"
}

restart_autofs() {
  log "Restarting autofs"
  systemctl restart autofs
  systemctl enable autofs >/dev/null 2>&1 || true
}

ensure_python_service() {
  # Minimal unit; safe to overwrite
  log "Configuring systemd unit: python-webshare.service"
  cat > "$PY_UNIT" <<EOF
[Unit]
Description=Python HTTP server for CIFS share
After=network-online.target autofs.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${MOUNT_ROOT}/${SMB_USER}
ExecStart=/usr/bin/python3 -m http.server ${PY_PORT} --directory ${MOUNT_ROOT}/${SMB_USER}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now python-webshare.service
}

test_mount() {
  log "Testing automount (trigger by cd)"
  cd "${MOUNT_ROOT}/${SMB_USER}"
  mount | grep -E 'type cifs|type autofs' || true
  ls -la | head || true
}

main() {
  need_root
  ensure_pkg cifs-utils
  ensure_pkg autofs
  ensure_pkg python3

  local proxy_ip
  proxy_ip="$(read_nonempty "Enter PROXY-SAMBA IP: ")"

  ensure_dirs
  ensure_master_map
  ensure_creds
  ensure_map_file "$proxy_ip"
  restart_autofs
  ensure_python_service

  test_mount

  log "DONE (web node)"
  echo "Quick checks:"
  echo "  curl http://127.0.0.1:${PY_PORT}/"
  echo "  touch ${MOUNT_ROOT}/${SMB_USER}/testfile  # should be Permission denied"
}

main "$@"