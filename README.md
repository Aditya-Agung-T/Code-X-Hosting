<div align="center">

# 🚀 Code X Hosting

**Modern, Multi-Tenant Container PaaS & Managed Hosting Platform**  
*A powerful, self-hostable alternative to Heroku, Render, and Railway with built-in multi-tenant isolation and anti-abuse security.*

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![PHP Version](https://img.shields.io/badge/php-8.4+-8892BF.svg)](https://www.php.net/)
[![Laravel](https://img.shields.io/badge/framework-Laravel%2012-FF2D20.svg)](https://laravel.com)
[![Livewire](https://img.shields.io/badge/frontend-Livewire%203-FB70A9.svg)](https://livewire.laravel.com)
[![Docker](https://img.shields.io/badge/orchestration-Docker%20Compose-2496ED.svg)](https://www.docker.com/)

</div>

---

## 📖 Overview

**Code X Hosting** is an open-source, multi-tenant Platform-as-a-Service (PaaS) built for hosting providers, developers, and agencies. It turns any Linux VPS into an automated, multi-tenant application cloud where customers can deploy applications, databases, and Docker compose stacks into completely isolated private workspaces while sharing server infrastructure efficiently.

### 🌟 Core Capabilities
- **Private Workspaces**: Customers register or receive an invite to their own isolated team/workspace. Projects, environment variables, domains, and credentials are completely private.
- **Shared Server Pool**: Host multiple paying customers on a single managed VPS without granting SSH access or server administration rights.
- **Hardware Quota Enforcement**: Automatically assigns and locks RAM (e.g. 512MB/1GB) and CPU (1.0 Core) limits per container based on the customer's plan.
- **Anti-Abuse & Container Hardening**:
  - Blocked `/var/run/docker.sock` and sensitive host filesystem mounts.
  - Blocked `privileged: true`, `network_mode: host`, and custom root capabilities.
  - Built-in Fork-Bomb mitigation via `pids_limit: 100` per container.
  - Docker stdout log rotation (max 30MB) to prevent disk space exhaustion.
  - Cross-team domain collision detection and control panel hijacking prevention.
- **Automated SSL & Routing**: Dynamic reverse proxying via Traefik/Caddy with automatic Let's Encrypt SSL certificates.
- **One-Click Deployments**: Support for Git repositories (Node.js, Next.js, Laravel, Python, Go, Static), Dockerfiles, Compose stacks, and Databases (PostgreSQL, MySQL, Redis, MongoDB, MariaDB, ClickHouse).

---

## ⚡ Quick Start: Deploy to Your VPS

### 1. Requirements
- **OS**: Ubuntu 22.04 / 24.04 LTS or Debian 12 (64-bit x86_64 or ARM64).
- **Hardware**: Minimum 2 vCPU / 4 GB RAM recommended.
- **Access**: Root or sudo access via SSH.

### 2. Fast Installation (3 Steps)

Connect to your VPS via SSH and run:

```bash
# Step 1: Create target directory
sudo mkdir -p /data/coolify
cd /data/coolify

# Step 2: Clone Code X Hosting
sudo git clone https://github.com/Aditya-Agung-T/Code-X-Hosting.git source
cd source

# Step 3: Run the automated installer
sudo bash scripts/deploy-codex.sh
```

### 3. What the Installer Does Automatically
1. Installs official Docker & Docker Compose if not present.
2. Builds the hardened production Docker image (`codex-hosting:latest`) directly from source.
3. Configures secure random passwords, application keys, and encryption secrets.
4. Enforces Linux kernel firewall rules (blocks cloud metadata SSRF and outbound spam ports).
5. Starts all infrastructure services (Code X Hosting, PostgreSQL, Redis, Soketi, Traefik).

---

## 🌐 Post-Installation & Admin Setup

Once installation completes, access your panel at:
👉 **`http://YOUR-SERVER-IP:8000`**

1. **Register Your Root Admin Account**:
   - The first user to register automatically becomes the **Root Administrator** (Team 0).
   - Public registration locks automatically after the root user is created.
2. **Onboard Your Customers**:
   - Navigate to **Team Settings** -> **Create New Team** (e.g. `Client - Toko Budi`).
   - Go to **Members** -> **Invite Member** -> enter the customer's email.
   - The customer receives an activation link, sets their password, and logs into their private workspace.

---

## ⚙️ Environment Configuration (`.env`)

You can customize your hosting limits at any time in `/data/coolify/source/.env`:

```env
# Shared Server Hosting Engine
SHARED_SERVER_HOSTING_ENABLED=true

# Default Container Quotas for Customers
DEFAULT_HOSTING_MEMORY_LIMIT=512m
DEFAULT_HOSTING_CPU_LIMIT=1.0
DEFAULT_HOSTING_MEMORY_RESERVATION=256m
DEFAULT_HOSTING_MEMORY_SWAP=0

# Lock Resource Limits on Customer UI
CUSTOMER_CAN_CHANGE_LIMITS=false

# Maximum Active Resources (Apps/DBs) per Customer Workspace
MAX_RESOURCES_PER_TEAM=2

# Anti Fork-Bomb Limit (Max processes per container)
DEFAULT_HOSTING_PIDS_LIMIT=100

# Prevent upstream auto-updater from replacing custom build
AUTOUPDATE=false
```

After modifying `.env`, restart the services:
```bash
cd /data/coolify/source
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.override.yml up -d
```

---

## 🔒 Security Architecture

| Vector | Protection Mechanism |
| :--- | :--- |
| **Docker Socket Hijack** | `/var/run/docker.sock` mounts are strictly blocked for all non-admin tenants. |
| **Host System Access** | Dangerous paths (`/etc`, `/root`, `/proc`, `/sys`, `/data/coolify`) cannot be mounted. |
| **Privilege Escalation** | `privileged: true`, `cap_add`, and direct device access are stripped and rejected. |
| **Network Interception** | `network_mode: host` is blocked; customers route exclusively through Traefik/Caddy. |
| **Domain Spoofing** | Global domain conflict checks prevent customers from hijacking admin panel or sibling domains. |
| **Fork Bomb Defense** | `pids_limit: 100` enforces kernel process isolation per container. |
| **Log Flooding** | Docker stdout logs are rotated with `max-size: 10m` and `max-file: 3`. |

---

## 🛠️ Technology Stack

- **Backend**: PHP 8.4+, Laravel 12 (Framework), Laravel Actions
- **Frontend**: Livewire 3, Alpine.js, Tailwind CSS v4
- **Database**: PostgreSQL 15, Redis 7
- **Reverse Proxy**: Traefik v3 / Caddy
- **Real-Time Logs**: Soketi (WebSocket server)
- **Process Supervision**: S6 Overlay, Docker Compose

---

## 📄 License

This project is licensed under the [Apache 2.0 License](LICENSE).
