#!/bin/bash
set -e

echo "=== PROXY-SAMBA SETUP (Samba + Nginx) ==="

read -p "WEB1 IP (python http.server:8000): " WEB1_IP
read -p "WEB2 IP (python http.server:8000): " WEB2_IP

# STEP 1: Install packages  
echo "Install samba/nginx if not installed"

if ! dpkg -l | grep -q "^ii  samba "; then
  sudo apt update
  sudo apt install -y samba
else
  echo "Samba already installed -> skip"
fi

if ! dpkg -l | grep -q "^ii  nginx "; then
  sudo apt update
  sudo apt install -y nginx
else
  echo "Nginx already installed -> skip"
fi

# Create user  
echo "Create user smbuser if not exists"

if id smbuser >/dev/null 2>&1; then
  echo "User smbuser already exists -> skip"
else
  sudo useradd -m -s /bin/bash smbuser
  echo "User smbuser created"
fi

# Set Samba password  
echo "Set Samba password for smbuser (only if not exists in Samba DB)"

if sudo pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "smbuser"; then
  echo "Samba user smbuser already exists -> skip"
else
  sudo smbpasswd -a smbuser
fi

# Configure Samba 
echo "Configure /etc/samba/smb.conf"

if [ ! -f /etc/samba/smb.conf.backup ]; then
  sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
fi

# security = user (requirement)
if ! sudo grep -q "security = user" /etc/samba/smb.conf; then
  # add right after [global]
  sudo sed -i '/^\[global\]/a\   security = user' /etc/samba/smb.conf
else
  echo "security = user already in smb.conf -> skip"
fi

# Add share block only if not exists
if sudo grep -q "^\[smbuser\]" /etc/samba/smb.conf; then
  echo "Share [smbuser] already exists -> skip"
else
  sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

# ==== LAB SHARE (home of smbuser) ====
[smbuser]
   path = /home/smbuser
   valid users = smbuser
   guest ok = no
   read only = yes
EOF
fi

sudo testparm
sudo systemctl restart smbd

# Configure Nginx LB  
echo "Configure Nginx in /etc/nginx/sites-available/proxy.conf"

sudo tee /etc/nginx/sites-available/proxy.conf > /dev/null <<EOF
upstream backend {
    server ${WEB1_IP}:8000;
    server ${WEB2_IP}:8000;
}

server {
    listen 80;
    server_name _;

    location / {
        add_header X-Upstream \$upstream_addr always;
        proxy_pass http://backend;
    }

    # Extra task: direct to конкретный backend
    location /web1/ {
        add_header X-Backend web1 always;
        proxy_pass http://${WEB1_IP}:8000/;
    }

    location /web2/ {
        add_header X-Backend web2 always;
        proxy_pass http://${WEB2_IP}:8000/;
    }
}
EOF

# Enable site
if [ -L /etc/nginx/sites-enabled/proxy.conf ]; then
  echo "Symlink already exists -> skip"
else
  sudo ln -s /etc/nginx/sites-available/proxy.conf /etc/nginx/sites-enabled/proxy.conf
fi

# disable default
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
sudo systemctl reload nginx

echo "DONE."
echo "Test:"
echo "curl -v http://127.0.0.1/ 2>&1 | grep -Ei '^<\\s*X-Upstream:'"