#!/bin/bash
# =============================================================================
# ShareOp - Installation Script
# Ubuntu 22.04 / 24.04 | User: angka (dengan akses sudo)
# Usage: bash install.sh
# =============================================================================

set -e  # Exit immediately on error

# --- Warna output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔] $1${NC}"; }
warn()   { echo -e "${YELLOW}[!] $1${NC}"; }
error()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }
header() { echo -e "\n${BLUE}========================================${NC}"; \
           echo -e "${BLUE}  $1${NC}"; \
           echo -e "${BLUE}========================================${NC}"; }

# --- Konfigurasi ---
APP_DIR="/home/angka/shareop"
APP_USER="angka"
GITHUB_REPO="https://github.com/angka/shareop.git"
NODE_VERSION="20"
SERVICE_NAME="shareop"
APP_PORT="3000"

# =============================================================================
# 0. Cek user dan sudo
# =============================================================================
header "Memeriksa Hak Akses"
if [ "$EUID" -eq 0 ]; then
  error "Jangan jalankan sebagai root. Cukup: bash install.sh"
fi
if [ "$(whoami)" != "$APP_USER" ]; then
  error "Script ini harus dijalankan sebagai user '${APP_USER}', bukan '$(whoami)'"
fi
warn "Meminta password sudo untuk perintah yang memerlukan hak admin..."
sudo true  # Minta password sudo di awal sekaligus, berlaku untuk sesi ini
log "Berjalan sebagai user '${APP_USER}' dengan akses sudo"

# =============================================================================
# 1. Update sistem
# =============================================================================
header "Update Sistem"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
log "Sistem diperbarui"

# =============================================================================
# 2. Install dependensi sistem
# =============================================================================
header "Instalasi Dependensi Sistem"
sudo apt-get install -y -qq \
  curl \
  git \
  build-essential \
  python3 \
  python3-pip \
  libsqlite3-dev \
  ufw \
  unzip \
  ca-certificates \
  gnupg

log "Dependensi sistem terinstal"

# =============================================================================
# 3. Install Node.js via NodeSource
# =============================================================================
header "Instalasi Node.js v${NODE_VERSION}"
if command -v node &> /dev/null; then
  CURRENT_NODE=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
  if [ "$CURRENT_NODE" -ge "$NODE_VERSION" ]; then
    log "Node.js $(node -v) sudah terinstal, melewati..."
  else
    warn "Node.js versi lama ditemukan, mengupgrade ke v${NODE_VERSION}..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
else
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
log "Node.js $(node -v) siap"
log "npm $(npm -v) siap"

# =============================================================================
# 4. Install PM2 (process manager - auto restart on reboot)
# =============================================================================
header "Instalasi PM2"
if command -v pm2 &> /dev/null; then
  log "PM2 sudah terinstal, melewati..."
else
  sudo npm install -g pm2
  log "PM2 terinstal"
fi

# =============================================================================
# 5. Clone / Update repo dari GitHub
# =============================================================================
header "Mengambil Kode dari GitHub"
if [ -d "$APP_DIR/.git" ]; then
  warn "Direktori ${APP_DIR} sudah ada, melakukan git pull..."
  cd "$APP_DIR"
  git pull origin main || git pull origin master
  log "Kode diperbarui dari GitHub"
else
  if [ -d "$APP_DIR" ]; then
    warn "Direktori ${APP_DIR} ada tapi bukan git repo, menghapus dan clone ulang..."
    rm -rf "$APP_DIR"
  fi
  git clone "$GITHUB_REPO" "$APP_DIR"
  log "Repo berhasil di-clone ke ${APP_DIR}"
fi

# =============================================================================
# 6. Install npm dependencies
# =============================================================================
header "Instalasi npm Dependencies"
cd "$APP_DIR"
npm install --omit=dev
log "npm dependencies terinstal"

# =============================================================================
# 7. Buat direktori data yang dibutuhkan
# =============================================================================
header "Membuat Direktori Data"
mkdir -p "$APP_DIR/auth"     # Sesi Baileys WhatsApp
mkdir -p "$APP_DIR/data"     # Database SQLite
mkdir -p "$APP_DIR/logs"     # Log aplikasi
log "Direktori data siap"

# =============================================================================
# 8. Buat file .env jika belum ada
# =============================================================================
header "Konfigurasi Environment"
if [ ! -f "$APP_DIR/.env" ]; then
  cat > "$APP_DIR/.env" << EOF
# ShareOp Environment Configuration
NODE_ENV=production
PORT=${APP_PORT}

# Path database SQLite
DB_PATH=./data/shareop.db

# Path sesi Baileys
BAILEYS_AUTH_PATH=./auth

# Nama grup WhatsApp tujuan (isi setelah scan QR)
# Format: 628xxxxxxxxxx-xxxxxxxxxx@g.us
WA_GROUP_ID=

# Log level: error | warn | info | debug
LOG_LEVEL=info
EOF
  warn "File .env dibuat di ${APP_DIR}/.env"
  warn "Silakan edit WA_GROUP_ID setelah bot terhubung ke WhatsApp"
else
  log "File .env sudah ada, melewati..."
fi

# =============================================================================
# 9. Konfigurasi PM2 dan setup autostart
# =============================================================================
header "Konfigurasi PM2 Autostart"

cat > "$APP_DIR/ecosystem.config.js" << EOF
module.exports = {
  apps: [
    {
      name: '${SERVICE_NAME}',
      script: 'server.js',
      cwd: '${APP_DIR}',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      restart_delay: 5000,
      env: {
        NODE_ENV: 'production',
        PORT: ${APP_PORT}
      },
      log_file: '${APP_DIR}/logs/combined.log',
      out_file: '${APP_DIR}/logs/out.log',
      error_file: '${APP_DIR}/logs/error.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      merge_logs: true
    }
  ]
}
EOF
log "ecosystem.config.js dibuat"

# Jalankan app via PM2
pm2 start "$APP_DIR/ecosystem.config.js"
log "Aplikasi dijalankan via PM2"

# Setup PM2 agar otomatis start saat reboot
# pm2 startup mencetak perintah sudo yang harus dieksekusi
STARTUP_CMD=$(pm2 startup systemd | grep "sudo env" | tail -1)
if [ -n "$STARTUP_CMD" ]; then
  eval "$STARTUP_CMD"
else
  sudo env PATH=$PATH:/usr/bin \
    $(which pm2) startup systemd -u "$APP_USER" --hp "/home/$APP_USER"
fi
log "PM2 startup systemd dikonfigurasi"

# Simpan daftar proses PM2
pm2 save
log "PM2 process list disimpan"

# =============================================================================
# 10. Konfigurasi Firewall (UFW)
# =============================================================================
header "Konfigurasi Firewall"
sudo ufw allow OpenSSH
sudo ufw allow "${APP_PORT}/tcp" comment "ShareOp Web App"
sudo ufw --force enable
log "Firewall dikonfigurasi (SSH + port ${APP_PORT} dibuka)"

# =============================================================================
# 11. Selesai
# =============================================================================
header "Instalasi Selesai!"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}ShareOp berhasil diinstal!${NC}"
echo ""
echo -e "  Direktori Aplikasi : ${YELLOW}${APP_DIR}${NC}"
echo -e "  Akses Web          : ${YELLOW}http://${SERVER_IP}:${APP_PORT}${NC}"
echo -e "  Log                : ${YELLOW}${APP_DIR}/logs/${NC}"
echo -e "  Environment        : ${YELLOW}${APP_DIR}/.env${NC}"
echo ""
echo -e "${YELLOW}==== LANGKAH SELANJUTNYA — Scan QR WhatsApp ====${NC}"
echo ""
echo -e "  1. Lihat log untuk QR code:"
echo -e "     ${BLUE}pm2 logs ${SERVICE_NAME}${NC}"
echo ""
echo -e "  2. Scan QR code dengan WhatsApp di HP"
echo -e "     (Settings > Linked Devices > Link a Device)"
echo ""
echo -e "  3. Setelah terhubung, catat Group ID dari log,"
echo -e "     lalu edit file .env:"
echo -e "     ${BLUE}nano ${APP_DIR}/.env${NC}"
echo -e "     Isi WA_GROUP_ID= dengan ID grup tujuan"
echo ""
echo -e "  4. Restart aplikasi setelah edit .env:"
echo -e "     ${BLUE}pm2 restart ${SERVICE_NAME}${NC}"
echo ""
echo -e "${YELLOW}Perintah PM2 berguna:${NC}"
echo -e "  Status  : ${BLUE}pm2 status${NC}"
echo -e "  Log     : ${BLUE}pm2 logs ${SERVICE_NAME}${NC}"
echo -e "  Restart : ${BLUE}pm2 restart ${SERVICE_NAME}${NC}"
echo -e "  Stop    : ${BLUE}pm2 stop ${SERVICE_NAME}${NC}"
echo ""
