#!/bin/bash
# ============================================================
#  install-ollama-qwen.sh
#  Install Ollama + Qwen3.5 4B + Open WebUI on Ubuntu 24.04
#  Akses via: http://<IP-SERVER>
#
#  Cara menjalankan (sebagai user biasa yang punya sudo):
#    bash install-ollama-qwen.sh
#
#  - Ollama        : systemd service (auto-start on boot)
#  - Model preload : systemd service (auto-load model on boot)
#  - Open WebUI    : Docker --restart always (auto-start on boot)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header() {
  echo -e "\n${CYAN}========================================${NC}"
  echo -e "${CYAN} $1${NC}"
  echo -e "${CYAN}========================================${NC}"
}

MODEL_NAME="qwen3.5:4b"
CURRENT_USER="${SUDO_USER:-$USER}"   # user asli yang menjalankan script (bukan root)

# ── Pastikan TIDAK dijalankan langsung sebagai root ───────────
# Script ini dirancang untuk user biasa yang punya sudo.
# Menjalankan sebagai root murni (login root) masih bisa,
# tapi SUDO_USER akan kosong — kita tangani di bagian docker group.
if [[ $EUID -eq 0 && -z "$SUDO_USER" ]]; then
  warn "Anda login sebagai root langsung. Script tetap berjalan,"
  warn "tapi sebaiknya jalankan sebagai user biasa dengan: bash $0"
fi

# ── Pastikan sudo tersedia dan bisa dipakai ───────────────────
if ! command -v sudo &>/dev/null; then
  error "sudo tidak ditemukan. Install dulu: apt-get install sudo"
fi

# Minta password sudo sekali di awal, lalu keep-alive agar tidak expired
# di tengah proses install yang panjang.
log "Meminta akses sudo (masukkan password jika diminta)..."
sudo -v
# Loop keep-alive: perbarui timestamp sudo setiap 55 detik di background
( while true; do sudo -n true; sleep 55; done ) &
SUDO_KEEPALIVE_PID=$!
# Pastikan background process mati ketika script selesai atau error
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null; exit' INT TERM EXIT

# ── Deteksi IP Server ─────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
log "IP Server terdeteksi: $SERVER_IP"
log "Menjalankan instalasi sebagai user: ${CURRENT_USER}"

# ============================================================
header "1. Update Sistem"
# ============================================================
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
  curl wget git nano htop \
  ca-certificates gnupg lsb-release \
  ufw net-tools

# ============================================================
header "2. Install Docker"
# ============================================================
if command -v docker &>/dev/null; then
  log "Docker sudah terinstall, lewati..."
else
  log "Menginstall Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker
  log "Docker berhasil diinstall."
fi

# ── Tambahkan user ke group docker (agar bisa pakai docker tanpa sudo) ──
if [[ -n "$CURRENT_USER" && "$CURRENT_USER" != "root" ]]; then
  if ! groups "$CURRENT_USER" | grep -qw docker; then
    sudo usermod -aG docker "$CURRENT_USER"
    log "User '$CURRENT_USER' ditambahkan ke group docker."
    warn "PERHATIAN: Untuk menggunakan docker tanpa sudo, logout lalu login kembali."
    warn "           Selama sesi ini, perintah docker dijalankan via sudo."
  else
    log "User '$CURRENT_USER' sudah ada di group docker."
  fi
fi

# Helper: jalankan docker — pakai sudo jika user belum ada di group docker aktif sesi ini
run_docker() {
  if id -nG "$CURRENT_USER" 2>/dev/null | grep -qw docker && [[ "$(id -gn)" == "docker" || $(groups) == *docker* ]]; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

# ============================================================
header "3. Install Ollama"
# ============================================================
if command -v ollama &>/dev/null; then
  log "Ollama sudah terinstall, lewati..."
else
  log "Menginstall Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  log "Ollama berhasil diinstall."
fi

# ── Konfigurasi Ollama agar listen ke semua interface ────────
log "Mengkonfigurasi Ollama service..."

sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_ORIGINS=*"
Restart=always
RestartSec=5
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl restart ollama
log "Ollama berjalan di port 11434 dan dikonfigurasi auto-restart."

# ============================================================
header "4. Download Model ${MODEL_NAME}"
# ============================================================
log "Mendownload model ${MODEL_NAME} (ukuran ~3.4GB, harap tunggu)..."

# Tunggu Ollama API benar-benar siap
for i in {1..15}; do
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    log "Ollama API siap."
    break
  fi
  log "Menunggu Ollama siap... ($i/15)"
  sleep 2
done

if ollama pull "${MODEL_NAME}"; then
  log "Model ${MODEL_NAME} berhasil didownload."
else
  warn "Gagal download otomatis. Jalankan manual: ollama pull ${MODEL_NAME}"
fi

# ============================================================
header "5. Buat Systemd Service: ollama-model-preload"
#
# Service ini memastikan model sudah ter-load ke memori RAM
# setiap kali server restart, sehingga tidak ada cold-start
# lambat pada request pertama.
# ============================================================
log "Membuat service ollama-model-preload..."

# Cari path ollama yang benar
OLLAMA_BIN=$(command -v ollama)

sudo tee /etc/systemd/system/ollama-model-preload.service > /dev/null <<EOF
[Unit]
Description=Preload Ollama Model (${MODEL_NAME}) into memory
After=ollama.service network-online.target
Requires=ollama.service

[Service]
Type=oneshot
User=${CURRENT_USER}
# Tunggu Ollama API benar-benar siap sebelum preload
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 20); do curl -sf http://localhost:11434/api/tags && break || sleep 3; done'
# Load model ke RAM dengan mengirim request kosong
ExecStart=${OLLAMA_BIN} run ${MODEL_NAME} ""
# Tetap dianggap aktif setelah oneshot selesai
RemainAfterExit=yes
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama-model-preload.service
sudo systemctl start ollama-model-preload.service \
  || warn "Preload awal gagal, akan dicoba ulang saat boot berikutnya."
log "Service ollama-model-preload aktif dan di-enable saat boot."

# ============================================================
header "6. Install Open WebUI (Antarmuka Web)"
# ============================================================
log "Menjalankan Open WebUI via Docker..."

# Hapus container lama jika ada
sudo docker rm -f open-webui 2>/dev/null || true

# --restart always => otomatis start ulang setiap kali Docker daemon start (boot)
sudo docker run -d \
  --name open-webui \
  --restart always \
  --add-host=host.docker.internal:host-gateway \
  -p 80:8080 \
  -v open-webui:/app/backend/data \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -e WEBUI_AUTH=false \
  ghcr.io/open-webui/open-webui:main

log "Open WebUI berhasil dijalankan di port 80 dengan --restart always."

# ============================================================
header "7. Konfigurasi Firewall (UFW)"
# ============================================================
log "Mengatur firewall UFW..."

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow 22/tcp  comment "SSH"
sudo ufw allow 80/tcp  comment "Open WebUI HTTP"
sudo ufw allow 443/tcp comment "HTTPS (opsional)"
# Uncomment jika ingin akses Ollama API langsung dari luar:
sudo ufw allow 11434/tcp comment "Ollama API"

sudo ufw --force enable
log "Firewall dikonfigurasi."

# ============================================================
header "8. Ringkasan Auto-Start (Urutan Boot)"
# ============================================================
cat <<'BOOT'

  Urutan layanan saat server restart:
  ┌─────────────────────────────────────────────────────────┐
  │  1. systemd starts                                      │
  │  2. docker.service           → Docker daemon aktif      │
  │  3. ollama.service           → Ollama engine aktif      │
  │  4. ollama-model-preload     → qwen3.5:4b load ke RAM   │
  │  5. open-webui (container)   → Web UI aktif di port 80  │
  └─────────────────────────────────────────────────────────┘

BOOT

# ============================================================
header "9. Verifikasi Instalasi"
# ============================================================
sleep 6

echo ""
log "Status services:"

check_service() {
  local name=$1
  if sudo systemctl is-active --quiet "$name"; then
    echo -e "  ${GREEN}✓${NC} $name — aktif"
  else
    echo -e "  ${RED}✗${NC} $name — tidak aktif"
  fi
}

check_service ollama
check_service ollama-model-preload
check_service docker

echo ""
log "Status Open WebUI container:"
if sudo docker ps --filter "name=open-webui" --format "{{.Status}}" | grep -q "^Up"; then
  echo -e "  ${GREEN}✓${NC} open-webui — berjalan"
else
  echo -e "  ${RED}✗${NC} open-webui — tidak berjalan"
fi

echo ""
log "Model yang tersedia di Ollama:"
ollama list

# ── Matikan sudo keep-alive ───────────────────────────────────
kill $SUDO_KEEPALIVE_PID 2>/dev/null || true
trap - INT TERM EXIT

# ============================================================
header "✅ INSTALASI SELESAI"
# ============================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           AKSES OPEN WEBUI (Chat LLM)               ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║   🌐  http://${SERVER_IP}                             ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║   API  http://${SERVER_IP}:11434/api/generate         ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Perintah berguna:${NC}"
echo -e "  Lihat log WebUI       : sudo docker logs -f open-webui"
echo -e "  Lihat log Ollama      : journalctl -u ollama -f"
echo -e "  Lihat log preload     : journalctl -u ollama-model-preload -f"
echo -e "  Status semua service  : sudo systemctl status ollama ollama-model-preload"
echo -e "  List model            : ollama list"
echo -e "  Pull model baru       : ollama pull <nama-model>"
echo -e "  Restart WebUI         : sudo docker restart open-webui"
echo -e "  Restart Ollama        : sudo systemctl restart ollama"
echo ""
echo -e "${YELLOW}Catatan penting:${NC}"
echo -e "${YELLOW}  • Logout lalu login kembali agar bisa pakai 'docker' tanpa sudo.${NC}"
echo -e "${YELLOW}  • Jika pakai cloud provider (AWS/GCP/DigitalOcean/Vultr), buka${NC}"
echo -e "${YELLOW}    port 80 dan 22 di Security Group / panel firewall cloud.${NC}"
echo ""
