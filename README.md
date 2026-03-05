# samba-autofs-nginx-lab

## Overview
This repository contains Bash scripts to deploy a 3-VM lab:
- **VM1 (proxy-samba)**: Samba file server (CIFS/SMB share) + Nginx reverse proxy load balancer
- **VM2 (web1)** and **VM3 (web2)**: CIFS automount via **autofs** + simple web server via `python3 -m http.server`

The goal is to:
1) Publish files on the Samba server (read-only for clients)
2) Automount the share on web nodes (on-demand, not permanently)
3) Serve the mounted directory over HTTP (port **8000**)
4) Proxy and balance HTTP requests via Nginx (port **80**)

---

## Topology
- **proxy-samba (VM1)**
  - Samba share: `//proxy-samba/smbuser` → `/home/smbuser`
  - Access: `valid users = smbuser`, `guest ok = no`, `read only = yes`
  - Nginx: balances requests to `web1:8000` and `web2:8000`
  - Debug header: `X-Upstream: <ip:port>`

- **web1 (VM2)** and **web2 (VM3)**
  - Automount point: `/mnt/smb/smbuser`
  - Tools: `cifs-utils`, `autofs`
  - Web server: `python3 -m http.server 8000 --directory /mnt/smb/smbuser`
  - Service: `python-webshare.service` (systemd)

---

## Requirements
- Ubuntu/Debian-based VMs
- Network connectivity between all VMs
- `sudo` privileges

---

## Quick Start

### 1) VM1 — proxy-samba
```bash
chmod +x setup_proxy_samba_idem.sh
sudo ./setup_proxy_samba_idem.sh

The script will:
- install samba and nginx
- create Linux user smbuser (if missing)
- ask for the Samba password and create the Samba account
- configure /etc/samba/smb.conf (share + security = user)
- ask for web1 and web2 IPs and configure Nginx load balancing

### 2) VM2/VM3 — web nodes (run on both web1 and web2)
```bash
chmod +x setup_web_node_idem.sh
sudo ./setup_web_node_idem.sh

The script will:
- install cifs-utils, autofs, python3
- ask for proxy-samba IP and Samba password
- create a root-only credentials file (chmod 600)
- configure autofs maps and mount point
- enable and start python-webshare.service

## Validation
### Check automount (on web1/web2)
```bash
cd /mnt/smb/smbuser
mount | grep cifs
ls -la
touch testfile  # should return Permission denied (read-only)

### Check python web server (on web1/web2)
```bash
curl http://127.0.0.1:8000/

### Check load balancing (from any VM) 
```bash
curl -v http://<PROXY_IP>/ 2>&1 | grep -Ei '^<\s*X-Upstream:'

### Extra task: target a specific backend
If enabled in Nginx config:
```bash
curl -v http://<PROXY_IP>/web1/ 2>&1 | grep -Ei '^<\s*X-Backend:'
curl -v http://<PROXY_IP>/web2/ 2>&1 | grep -Ei '^<\s*X-Backend:'

## Notes (Security)
- CIFS credentials are stored on web nodes in a root-only file (chmod 600)
- Do not commit any credentials files to the repository
- Use a strong Samba password in real environments

### Files

- setup_proxy_samba_idem.sh — VM1 setup (Samba + Nginx LB)
- setup_web_node_idem.sh — VM2/VM3 setup (autofs + CIFS + Python server)