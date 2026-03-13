# Ansible: File Proxy Server Lab

Automates the deployment of a Samba + Nginx + Python HTTP Server infrastructure.

## Architecture

```
                        ┌─────────────────────────────┐
                        │   Proxy Server (smbserver)  │
                        │        10.10.0.106           │
                        │                             │
                        │  ┌───────────┐  ┌────────┐  │
                        │  │   Samba   │  │ Nginx  │  │
                        │  │  (files)  │  │  :80   │  │
                        │  └───────────┘  └───┬────┘  │
                        └────────────────────┼────────┘
                                             │ load balance
               ┌─────────────────────────────┴──────────────────────┐
               │                                                     │
   ┌───────────▼────────────┐                       ┌───────────────▼──────────┐
   │  Web Node 1 (smbclient)│                       │  Web Node 2 (smbclient)  │
   │     10.11.1.74          │                       │     10.12.0.245           │
   │                        │                       │                          │
   │  autofs → /mnt/smb/    │                       │  autofs → /mnt/smb/      │
   │  python3 http.server   │                       │  python3 http.server     │
   │  :8000                 │                       │  :8000                   │
   └────────────────────────┘                       └──────────────────────────┘
```

**Proxy Server** (`smbserver`) — stores files via Samba and load-balances incoming HTTP traffic through Nginx.
**Web Nodes** (`smbclient`) — mount the Samba share via autofs and serve its contents via Python HTTP Server.

## Inventory

| Group       | Host           | IP             | User        |
|-------------|----------------|----------------|-------------|
| smbserver   | s15058038-01   | 10.10.0.106    | s15058038   |
| smbclient   | s15058038-02   | 10.12.0.245    | s15058038   |
| smbclient   | s15058038-03   | 10.11.1.74     | s15058038   |

## Roles

### `samba-server`
Installs and configures a Samba file server on the proxy node.

- Creates system user `smbuser`
- Installs the `samba` package
- Configures a read-only share in `smb.conf`
- Enables and restarts `smbd`

| Variable       | Default   | Description           |
|----------------|-----------|-----------------------|
| `smb_username` | `smbuser` | Samba username        |
| `smb_password` | `1234`    | Samba user password   |

---

### `samba-client`
Configures automatic mounting of the Samba share on web nodes via autofs.

- Installs `cifs-utils` and `autofs`
- Configures automount at `/mnt/smb/smbuser`
- Unmount timeout: 60 seconds

| Variable       | Default   | Description           |
|----------------|-----------|-----------------------|
| `smb_username` | `smbuser` | Samba username        |
| `smb_password` | `1234`    | Samba user password   |

---

### `nginx-proxy`
Installs Nginx and configures it as a reverse proxy with load balancing.

- Installs Nginx
- Deploys `proxy.conf` from `files/`
- Removes the default site and creates a symlink in `sites-enabled`
- Listens on port `80`, proxies to backend servers

| Variable | Default           | Description      |
|----------|-------------------|------------------|
| `one`    | `10.11.1.74:8000` | Backend server 1 |
| `two`    | `10.12.0.245:8000`| Backend server 2 |

---

### `python-server`
Deploys a Python HTTP Server as a systemd service.

- Installs `python3`
- Copies `python-webshare.service` into systemd
- Service runs from `/mnt/smb/smbuser` on port `8000`
- Depends on `autofs.service` (share must be mounted first)

## Project Structure

```
ansible/
├── ansible.cfg              # Ansible settings (roles path)
├── inventory/
│   └── inventory.yml        # Hosts and groups
├── playbooks/
│   └── main.yml             # Main playbook
└── roles/
    ├── samba-server/        # Samba server (proxy node)
    ├── samba-client/        # Samba client + autofs (web nodes)
    ├── nginx-proxy/         # Nginx reverse proxy (proxy node)
    └── python-server/       # Python HTTP Server (web nodes)
```

## Usage

```bash
# Syntax check
ansible-playbook playbooks/main.yml -i inventory/inventory.yml --syntax-check

# Dry run (no changes applied)
ansible-playbook playbooks/main.yml -i inventory/inventory.yml --check

# Full deployment
ansible-playbook playbooks/main.yml -i inventory/inventory.yml
```

Make sure your SSH public key is added to all hosts before running.

## Requirements

- Ansible >= 2.9
- Target hosts: Ubuntu/Debian
- SSH access with `sudo` privileges (`become: true` is used)
