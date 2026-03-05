#!/usr/bin/env bash
set -euo pipefail

SMB_USER="smbuser"
SMB_PATH="/home/${SMB_USER}"
NGINX_SITE="/etc/nginx/sites-available/proxy.conf"
NGINX_LINK="/etc/nginx/sites-enabled/proxy.conf"

# ----- helpers -----
log(){ echo -e "\n==> $*"; }
have_pkg(){ dpkg -s "$1" &>/dev/null; }
have_user(){ id "$1" &>/dev/null; }

read_nonempty() {
  local prompt="$1" v=""
  while [[ -z "$v" ]]; do read -r -p "$prompt" v; done
  echo "$v"
}

read_secret() {
  local prompt="$1" v1="" v2=""
  while true; do
    read -r -s -p "$prompt" v1; echo
    read -r -s -p "Repeat: " v2; echo
    [[ -n "$v1" && "$v1" == "$v2" ]] && { echo "$v1"; return 0; }
    echo "Passwords do not match / empty. Try again."
  done
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

ensure_user_and_home() {
  if have_user "$SMB_USER"; then
    echo "[SKIP] user $SMB_USER already exists"
  else
    log "Creating user $SMB_USER"
    useradd -m -s /bin/bash "$SMB_USER"
  fi
  if [[ ! -d "$SMB_PATH" ]]; then
    log "Creating home dir $SMB_PATH"
    mkdir -p "$SMB_PATH"
    chown "$SMB_USER:$SMB_USER" "$SMB_PATH"
  fi
}

ensure_samba_password() {
  # Check if samba user exists in passdb
  if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$SMB_USER"; then
    echo "[SKIP] Samba account for $SMB_USER already exists (pdbedit)"
  else
    log "Setting Samba password for $SMB_USER"
    local pw
    pw="$(read_secret "Enter Samba password for smbuser: ")"
    # -s reads password from stdin (silent)
    printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -a -s "$SMB_USER"
  fi
}

ensure_smb_conf() {
  local conf="/etc/samba/smb.conf"
  log "Configuring Samba: $conf"

  [[ -f "${conf}.bak" ]] || cp -a "$conf" "${conf}.bak"

  # Ensure security = user in [global]
  if grep -Eq '^\s*security\s*=' "$conf"; then
    # normalize to "security = user"
    sed -i 's/^\s*security\s*=.*$/   security = user/I' "$conf"
  else
    # insert after [global]
    sed -i '/^\[global\]\s*$/a\   security = user' "$conf"
  fi

  # Ensure share block exists and matches requirements (idempotent replace)
  if grep -q '^\[smbuser\]' "$conf"; then
    # remove existing [smbuser] block
    awk '
      BEGIN{del=0}
      /^\[smbuser\]/{del=1; next}
      /^\[.*\]/{if(del==1){del=0}}
      {if(del==0) print}
    ' "$conf" > "${conf}.tmp"
    mv "${conf}.tmp" "$conf"
  fi

  cat >> "$conf" <<EOF

# ==== LAB SHARE (home of smbuser) ====
[smbuser]
   path = ${SMB_PATH}
   valid users = ${SMB_USER}
   guest ok = no
   read only = yes
EOF

  testparm -s >/dev/null
  systemctl restart smbd
  systemctl enable smbd >/dev/null 2>&1 || true
}

ensure_nginx_lb() {
  log "Configuring Nginx load balancer"

  local web1 web2
  web1="$(read_nonempty "Enter WEB1 IP (python http.server:8000): ")"
  web2="$(read_nonempty "Enter WEB2 IP (python http.server:8000): ")"

  # Write/overwrite config (safe + deterministic)
  cat > "$NGINX_SITE" <<EOF
upstream backend {
    server ${web1}:8000;
    server ${web2}:8000;
}

server {
    listen 80;
    server_name _;

    location / {
        add_header X-Upstream \$upstream_addr always;
        proxy_pass http://backend;
    }

    # Optional (extra task): direct to specific backend
    location /web1/ {
        add_header X-Backend web1 always;
        proxy_pass http://${web1}:8000/;
    }

    location /web2/ {
        add_header X-Backend web2 always;
        proxy_pass http://${web2}:8000/;
    }
}
EOF

  ln -sf "$NGINX_SITE" "$NGINX_LINK"
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl reload nginx
  systemctl enable nginx >/dev/null 2>&1 || true
}

main() {
  need_root
  ensure_pkg samba
  ensure_pkg nginx
  ensure_user_and_home
  ensure_samba_password
  ensure_smb_conf
  ensure_nginx_lb

  log "DONE (proxy-samba)"
  echo "Test:"
  echo "  curl -v http://127.0.0.1/ 2>&1 | grep -Ei '^<\\s*X-Upstream:'"
}

main "$@"