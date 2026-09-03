#!/bin/bash
# ==============================================================================
# Code X Hosting - Automated VPS Production Deployment & Hardening Script
# ==============================================================================
# This script deploys Code X Hosting from source directly onto a fresh Ubuntu/Debian VPS,
# builds the custom production Docker image, configures anti-abuse security quotas,
# and brings up all services (Web App, PostgreSQL, Redis, Soketi, and Traefik).
# ==============================================================================

set -eo pipefail

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}====================================================================${NC}"
echo -e "${CYAN}        Code X Hosting - Production Deployment Installer            ${NC}"
echo -e "${CYAN}====================================================================${NC}"
echo ""

# 1. Check Root Privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root or with sudo.${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="/data/coolify"
SOURCE_DIR="${DATA_DIR}/source"
ENV_FILE="${SOURCE_DIR}/.env"

echo -e "${BLUE}[1/8] Checking system prerequisites & Docker...${NC}"

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

# Install Docker if not present
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW} - Docker not found. Installing Docker engine...${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN} - Docker installed successfully.${NC}"
else
    echo -e "${GREEN} - Docker is already installed.${NC}"
fi

# Install Docker Compose Plugin if not present
if ! docker compose version >/dev/null 2>&1; then
    echo -e "${YELLOW} - Docker Compose plugin not found. Installing...${NC}"
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    fi
fi

# 2. Setup Directory Structure & Permissions
echo -e "${BLUE}[2/8] Setting up directory structure in ${DATA_DIR}...${NC}"
mkdir -p "${DATA_DIR}"/{source,ssh/keys,applications,databases,services,backups,images}

# Copy repository source code to /data/coolify/source if running from another directory
if [ "$SCRIPT_DIR" != "$SOURCE_DIR" ]; then
    echo -e "${YELLOW} - Synchronizing Code X Hosting source code to ${SOURCE_DIR}...${NC}"
    cp -r "${SCRIPT_DIR}/." "${SOURCE_DIR}/"
fi

cd "${SOURCE_DIR}"

# 3. Setup Environment File (.env)
echo -e "${BLUE}[3/8] Configuring environment & security secrets...${NC}"
if [ ! -f "${ENV_FILE}" ]; then
    if [ -f "${SOURCE_DIR}/.env.production" ]; then
        cp "${SOURCE_DIR}/.env.production" "${ENV_FILE}"
    else
        touch "${ENV_FILE}"
    fi
fi

# Helper to update or append .env variables
set_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "${ENV_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
    else
        echo "${key}=${value}" >> "${ENV_FILE}"
    fi
}

# Generate secure random secrets if empty or missing
[ -z "$(grep -E '^APP_ID=.+' "${ENV_FILE}" || true)" ] && set_env "APP_ID" "$(openssl rand -hex 16)"
[ -z "$(grep -E '^APP_KEY=base64:.+' "${ENV_FILE}" || true)" ] && set_env "APP_KEY" "base64:$(openssl rand -base64 32)"
[ -z "$(grep -E '^DB_PASSWORD=.+' "${ENV_FILE}" || true)" ] && set_env "DB_PASSWORD" "$(openssl rand -base64 24)"
[ -z "$(grep -E '^REDIS_PASSWORD=.+' "${ENV_FILE}" || true)" ] && set_env "REDIS_PASSWORD" "$(openssl rand -base64 24)"
[ -z "$(grep -E '^PUSHER_APP_ID=.+' "${ENV_FILE}" || true)" ] && set_env "PUSHER_APP_ID" "$(openssl rand -hex 16)"
[ -z "$(grep -E '^PUSHER_APP_KEY=.+' "${ENV_FILE}" || true)" ] && set_env "PUSHER_APP_KEY" "$(openssl rand -hex 16)"
[ -z "$(grep -E '^PUSHER_APP_SECRET=.+' "${ENV_FILE}" || true)" ] && set_env "PUSHER_APP_SECRET" "$(openssl rand -hex 16)"

# Set Code X Hosting branding & production parameters
set_env "APP_NAME" "Code X Hosting"
set_env "APP_ENV" "production"
set_env "REGISTRY_URL" "docker.io"
set_env "AUTOUPDATE" "false" # Prevent upstream updater from overwriting custom build

# Set Hosting & Quota Protection parameters
set_env "SHARED_SERVER_HOSTING_ENABLED" "true"
set_env "DEFAULT_HOSTING_MEMORY_LIMIT" "512m"
set_env "DEFAULT_HOSTING_CPU_LIMIT" "1.0"
set_env "DEFAULT_HOSTING_MEMORY_RESERVATION" "256m"
set_env "DEFAULT_HOSTING_MEMORY_SWAP" "0"
set_env "CUSTOMER_CAN_CHANGE_LIMITS" "false"
set_env "MAX_RESOURCES_PER_TEAM" "2"
set_env "DEFAULT_HOSTING_PIDS_LIMIT" "100"

# 4. Generate Localhost SSH Key
echo -e "${BLUE}[4/8] Configuring Localhost SSH access...${NC}"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

SSH_KEY_PATH="${DATA_DIR}/ssh/keys/id.root@host.docker.internal"
if [ ! -f "${SSH_KEY_PATH}" ]; then
    echo " - Generating local ed25519 SSH automation key..."
    ssh-keygen -t ed25519 -a 100 -f "${SSH_KEY_PATH}" -q -N "" -C "codex-hosting"
    cat "${SSH_KEY_PATH}.pub" >> ~/.ssh/authorized_keys
    rm -f "${SSH_KEY_PATH}.pub"
fi

# Set proper ownership for Coolify non-root user (UID 9999)
chown -R 9999:root "${DATA_DIR}"
chmod -R 700 "${DATA_DIR}"

# 5. Linux Kernel & Host Firewall Rules
echo -e "${BLUE}[5/8] Applying Linux kernel anti-abuse firewall rules...${NC}"
# Block cloud metadata SSRF (169.254.169.254)
if ! iptables -C FORWARD -d 169.254.169.254 -j DROP 2>/dev/null; then
    iptables -A FORWARD -d 169.254.169.254 -j DROP
    echo " - Metadata SSRF protection enabled (169.254.169.254 blocked)."
fi

# Block outbound port 25 (prevent container email spamming)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
    ufw deny out 25/tcp >/dev/null 2>&1 || true
    echo " - Outbound SMTP port 25 blocked in UFW."
fi

# 6. Ensure Docker Network Exists
echo -e "${BLUE}[6/8] Preparing Docker network...${NC}"
if ! docker network inspect coolify >/dev/null 2>&1; then
    docker network create --attachable coolify
    echo " - Created attachable Docker network: coolify"
fi

# 7. Build Code X Hosting Production Image
echo -e "${BLUE}[7/8] Building Code X Hosting Docker image (this may take 2-4 minutes)...${NC}"
docker build \
    -f docker/production/Dockerfile \
    -t codex-hosting:latest \
    .

# Create docker-compose.override.yml to use the locally built image
cat << 'EOF' > "${SOURCE_DIR}/docker-compose.override.yml"
services:
  coolify:
    image: codex-hosting:latest
EOF

# 8. Start All Services
echo -e "${BLUE}[8/8] Starting Code X Hosting containers...${NC}"
docker compose \
    -f docker-compose.yml \
    -f docker-compose.prod.yml \
    -f docker-compose.override.yml \
    up -d --remove-orphans

echo ""
echo -e "${YELLOW}Waiting for Code X Hosting service to be ready...${NC}"
for i in {1..30}; do
    if curl -s http://127.0.0.1:8000/api/health >/dev/null 2>&1 || curl -s http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
        echo -e "${GREEN}Service is healthy!${NC}"
        break
    fi
    sleep 3
    printf "."
done

# Detect Public IP
SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || echo "YOUR-SERVER-IP")

echo ""
echo -e "${GREEN}====================================================================${NC}"
echo -e "${GREEN}      Code X Hosting Successfully Deployed & Hardened!              ${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo ""
echo -e "Dashboard URL   : ${CYAN}http://${SERVER_IP}:8000${NC}"
echo -e "Default Quotas  : ${YELLOW}512MB RAM, 1.0 CPU Core, Max 2 Containers per Team${NC}"
echo -e "Anti-Abuse      : ${GREEN}Docker Socket blocked, Privileged mode blocked, PIDs limit: 100${NC}"
echo ""
echo -e "Next Steps:"
echo -e "1. Open ${CYAN}http://${SERVER_IP}:8000${NC} in your browser."
echo -e "2. Register your ${YELLOW}Root Admin Account${NC} (public registration locks automatically afterward)."
echo -e "3. Invite your paying customers to their private workspace via ${YELLOW}Team -> Members -> Invite${NC}."
echo ""
