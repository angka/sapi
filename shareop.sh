#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# ShareOp — Auto Installer
# Ubuntu 24.04 LTS
# Run: curl -sSL https://raw.githubusercontent.com/angka/shareop/main/install.sh | bash
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()   { echo -e "${RED}[ERR]${NC}   $1"; exit 1; }

# ── Guard ───────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash install.sh"; }

info "ShareOp — Auto Installer"
echo ""

# --- set local time ---------------------------------------------------------
sudo timedatectl set-timezone Asia/Jakarta

# ── Detect ─────────────────────────────────────────────────────────────────
SUDO_USER="${SUDO_USER:-$(who am i | awk '{print $1}')}"
HOME_DIR=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
[[ -z "$HOME_DIR" ]] && HOME_DIR="/home/$SUDO_USER"

GIT_REPO="https://github.com/angka/shareop.git"
APP_DIR="/home/$SUDO_USER/shareop"
SERVICE_NAME="shareop"
PORT=3000

# ── Banner ─────────────────────────────────────────────────────────────────
cat << 'EOF'
  ╔════════════════════════════════════════════╗
  ║        ShareOp — Auto Installer           ║
  ║        Ubuntu 24.04 LTS                   ║
  ╚════════════════════════════════════════════╝
EOF
echo ""
info "Repo    : $GIT_REPO"
info "Dir     : $APP_DIR"
info "Port    : $PORT"
info "User    : $SUDO_USER ($HOME_DIR)"
echo ""

# ── 1. System update ────────────────────────────────────────────────────────
info "Updating package index..."
apt-get update -qq
ok "Package index updated"

# ── 2. Install base packages ────────────────────────────────────────────────
info "Installing base packages..."
apt-get install -y -qq curl git ufw nginx unzip
ok "Base packages installed"

# ── 3. Node.js 22 LTS ──────────────────────────────────────────────────────
info "Installing Node.js 22 LTS..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
apt-get install -y -qq nodejs
NODE_VER=$(node -v)
NPM_VER=$(npm -v)
ok "Node.js $NODE_VER / npm $NPM_VER installed"

# ── 4. Firewall ─────────────────────────────────────────────────────────────
info "Configuring UFW firewall..."
ufw allow OpenSSH 2>/dev/null || true
ufw allow "${PORT}/tcp" comment 'ShareOp' 2>/dev/null || true
ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
ufw --force enable 2>/dev/null || true
ufw status numbered | grep -q "active" && ok "UFW firewall active" || warn "UFW enable skipped"
systemctl is-active --quiet ufw 2>/dev/null && ok "UFW running" || true

# ── 5. Ensure app user exists ────────────────────────────────────────────────
info "Ensuring user '$SUDO_USER' exists..."
id "$SUDO_USER" &>/dev/null || useradd -r -s /bin/bash -d "$HOME_DIR" -m "$SUDO_USER"
ok "User '$SUDO_USER' ready"

# ── 6. Clone repo ───────────────────────────────────────────────────────────
info "Cloning repository..."
if [[ -d "$APP_DIR/.git" ]]; then
  info "Repo exists — pulling latest..."
  sudo -u "$SUDO_USER" git -C "$APP_DIR" pull origin main 2>/dev/null || \
    sudo -u "$SUDO_USER" git -C "$APP_DIR" pull
else
  rm -rf "$APP_DIR"
  sudo -u "$SUDO_USER" git clone "$GIT_REPO" "$APP_DIR"
fi
ok "Repository at $APP_DIR"

# Check repo structure
if [[ -d "$APP_DIR/shareop" ]]; then
  CODE_DIR="$APP_DIR/shareop"
elif [[ -d "$APP_DIR/server.js" ]] || [[ -f "$APP_DIR/package.json" ]]; then
  CODE_DIR="$APP_DIR"
else
  err "Cannot find app code. Repo structure may be wrong."
fi
ok "App code at $CODE_DIR"

# ── 7. Install dependencies ─────────────────────────────────────────────────
info "Installing Node.js dependencies..."
cd "$CODE_DIR"
sudo -u "$SUDO_USER" npm install --omit=dev --silent 2>&1 | tail -2
ok "Dependencies installed"

# Ensure correct ownership (before service starts)
chown -R "$SUDO_USER:$SUDO_USER" "$APP_DIR"
ok "Ownership set to $SUDO_USER"

# ── 8. .env file ────────────────────────────────────────────────────────────
ENV_FILE="$CODE_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  info "Creating .env file..."
  cat > "$ENV_FILE" << 'ENVEOF'
# ── Telegram Bot ────────────────────────────────────────────
# Token bot dari @BotFather
TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN_HERE

# Chat ID grup Telegram tujuan
TELEGRAM_CHAT_ID=YOUR_CHAT_ID_HERE

# ── Server ───────────────────────────────────────────────────
PORT=3000
ENVEOF
  chown "$SUDO_USER:$SUDO_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok ".env created — edit it: sudo nano $ENV_FILE"
else
  ok ".env already exists"
fi

# ── 9. Systemd service ─────────────────────────────────────────────────────
info "Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=ShareOp — Jadwal Operasi & Telegram Bot
After=network.target

[Service]
Type=simple
User=$SUDO_USER
Group=$SUDO_USER
WorkingDirectory=$CODE_DIR
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=false
ProtectTmp=no
ProtectKernelTunables=yes
PrivateTmp=true
ReadWritePaths=$CODE_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
ok "Systemd service enabled"

# ── 10. Nginx reverse proxy ─────────────────────────────────────────────────
info "Configuring Nginx reverse proxy..."
cat > "/etc/nginx/sites-available/shareop" << EOF
server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/shareop_access.log;
    error_log  /var/log/nginx/shareop_error.log;

    client_max_body_size 10M;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/shareop /etc/nginx/sites-enabled/shareop
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t > /dev/null 2>&1 && ok "Nginx config valid" || { err "Nginx config error"; }
systemctl reload nginx
systemctl enable nginx
ok "Nginx reverse proxy active on port 80"

# ── 11. Start app ────────────────────────────────────────────────────────────
info "Starting ShareOp..."
systemctl start "$SERVICE_NAME"
sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "ShareOp service running"
else
  err "Service failed. Check: journalctl -u $SERVICE_NAME -n 20 --no-pager"
fi

# ── 12. IP detection ────────────────────────────────────────────────────────
IP_ADDR=$(curl -s ifconfig.me 2>/dev/null || \
           curl -s ipinfo.io/ip 2>/dev/null || \
           hostname -I | awk '{print $1}')

# ── 13. Done ────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              Installation Complete!                ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  App URL    : http://${IP_ADDR:-<IP>}             ║"
echo "  ║  Service    : systemctl status $SERVICE_NAME         ║"
echo "  ║  Logs       : journalctl -u $SERVICE_NAME -f         ║"
echo "  ║  Restart    : sudo systemctl restart $SERVICE_NAME  ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  ⚠  IMPORTANT — edit .env before using Telegram:  ║"
echo "  ║     sudo nano $ENV_FILE           ║"
echo "  ║  Then restart: sudo systemctl restart $SERVICE_NAME ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
ok "Done!"
