#!/bin/bash
set -e

read -p "PROXY-SAMBA IP: " PROXY_IP
read -p "Samba password for smbuser: " SMB_PASS

# Install packages 
echo "Install cifs-utils/autofs/python3 if not installed"

if ! dpkg -l | grep -q "^ii  cifs-utils "; then
  sudo apt update
  sudo apt install -y cifs-utils
else
  echo "cifs-utils already installed -> skip"
fi

if ! dpkg -l | grep -q "^ii  autofs "; then
  sudo apt update
  sudo apt install -y autofs
else
  echo "autofs already installed -> skip"
fi

if ! command -v python3 >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y python3
else
  echo "python3 already installed -> skip"
fi

# Create mount root 
echo "Create /mnt/smb"
sudo mkdir -p /mnt/smb

#  Create auto.master.d  
echo "Create /etc/auto.master.d/cifs.autofs"
sudo tee /etc/auto.master.d/cifs.autofs > /dev/null <<'EOF'
/mnt/smb   /etc/auto.cifs   --timeout=60 --browse
EOF

# Create a credentials file 
echo "Create credentials file (root-only)"
sudo tee /etc/cifs-smbuser.cred > /dev/null <<EOF
username=smbuser
password=${SMB_PASS}
EOF
sudo chmod 600 /etc/cifs-smbuser.cred

# Create auto.cifs map 
echo "Create /etc/auto.cifs"
sudo tee /etc/auto.cifs > /dev/null <<EOF
smbuser  -fstype=cifs,credentials=/etc/cifs-smbuser.cred,vers=3.1.1  ://${PROXY_IP}/smbuser
EOF
sudo chmod 600 /etc/auto.cifs

# Restart restart autofs 
echo "Restart autofs"
sudo systemctl restart autofs

echo "Test automount:"
echo "cd /mnt/smb/smbuser && ls -la"
echo "mount | grep cifs"

# Create systemd unit for python 
echo "Create python-webshare.service (auto start)"
sudo tee /etc/systemd/system/python-webshare.service > /dev/null <<'EOF'
[Unit]
Description=Python HTTP server for CIFS share
After=network-online.target autofs.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/mnt/smb/smbuser
ExecStart=/usr/bin/python3 -m http.server 8000 --directory /mnt/smb/smbuser
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now python-webshare.service

echo "DONE."
echo "systemctl status python-webshare.service --no-pager"
echo "curl http://127.0.0.1:8000/"