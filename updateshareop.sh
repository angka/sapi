#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# ShareOp — Update Script (pull from GitHub + restart)
# Run on VPS: sudo bash /opt/shareop/update.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
APP_DIR="/opt/shareop"
SERVICE_NAME="shareop"

[[ $EUID -eq 0 ]] || { echo "[ERR] Run as root: sudo bash update.sh"; exit 1; }

# Detect code dir
if [[ -d "$APP_DIR/shareop" ]]; then
  CODE_DIR="$APP_DIR/shareop"
else
  CODE_DIR="$APP_DIR"
fi

echo "[INFO] Pulling latest from GitHub..."
cd "$APP_DIR"
sudo -u shareop git pull origin main 2>/dev/null || sudo -u shareop git pull

echo "[INFO] Reinstalling dependencies..."
cd "$CODE_DIR"
npm install --omit=dev --silent 2>&1 | tail -1

echo "[INFO] Restarting service..."
systemctl restart "$SERVICE_NAME"
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "[OK] ShareOp updated and running!"
  echo "    Logs: journalctl -u $SERVICE_NAME -f --no-pager"
else
  echo "[ERR] Service failed. Check:"
  echo "    journalctl -u $SERVICE_NAME -n 20 --no-pager"
  exit 1
fi
