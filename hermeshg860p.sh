#!/usr/bin/env bash
# Hermes Agent bootstrap for HG680P / Armbian ARM64, 2 GB RAM.
# Installs Hermes + Tailscale, prepares conservative firewall rules, and creates setup/check helpers.
# No public Hermes ports, no router changes. Run as: sudo bash ./install-hermes-hg680p-v2.sh
set -Eeuo pipefail
umask 077
LOG=/var/log/hermes-hg680p-install.log
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo "[ERROR] line ${LINENO}, exit ${rc}. Log: ${LOG}"; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || { echo "Run with sudo from a normal Armbian user: sudo bash $0"; exit 1; }
U="${SUDO_USER:-}"
[[ -n "$U" && "$U" != root ]] || { echo "For safety, use sudo from your normal user, not a root login."; exit 1; }
UH="$(getent passwd "$U" | cut -d: -f6)"
[[ -d "$UH" ]] || { echo "Cannot find home directory for $U"; exit 1; }
ARCH="$(uname -m)"; DPKG="$(dpkg --print-architecture 2>/dev/null || true)"
. /etc/os-release
printf 'HG680P Hermes bootstrap\nUser: %s\nOS: %s\nArchitecture: %s / %s\n' "$U" "${PRETTY_NAME:-unknown}" "$ARCH" "$DPKG"
free -h; df -h /
[[ "$ARCH:$DPKG" == "aarch64:arm64" ]] || { echo "Expected aarch64 + arm64. Aborting."; exit 2; }
command -v apt-get >/dev/null || { echo "Requires Debian/Ubuntu-based Armbian with apt."; exit 1; }
read -r -p "Continue installing packages, Hermes and Tailscale? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || exit 0

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git xz-utils ufw openssh-client openssh-server python3 python3-venv procps iproute2 sudo dbus-user-session

SSH_PORT=22
if command -v sshd >/dev/null 2>&1; then p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"; [[ -n "$p" ]] && SSH_PORT="$p"; fi
IFACE="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5; exit}' || true)"
LAN_CIDR=""
[[ -n "$IFACE" ]] && LAN_CIDR="$(ip -o -f inet addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}' || true)"

if sudo -u "$U" -H bash -lc 'command -v hermes >/dev/null 2>&1 || test -x "$HOME/.local/bin/hermes"'; then
  echo "Hermes CLI already found; skipping installation."
else
  echo "Installing Hermes as $U; skipping optional browser and computer-use packages to save storage."
  sudo -u "$U" -H bash -lc 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser --skip-computer-use'
fi

if ! command -v tailscale >/dev/null 2>&1; then curl -fsSL https://tailscale.com/install.sh | sh; fi
systemctl enable --now tailscaled

# Add narrowly scoped SSH rules before offering to enable UFW. Never reset existing rules.
echo "Detected SSH port=$SSH_PORT, interface=${IFACE:-unknown}, LAN subnet=${LAN_CIDR:-unknown}"
ufw status verbose || true
if [[ -n "$LAN_CIDR" ]]; then ufw allow from "$LAN_CIDR" to any port "$SSH_PORT" proto tcp comment 'SSH from detected LAN' || true; fi
ufw allow in on tailscale0 to any port "$SSH_PORT" proto tcp comment 'SSH over Tailscale' || true
ufw default allow outgoing
ufw default deny incoming
if ! ufw status | grep -q '^Status: active'; then
  read -r -p "Enable UFW now? Check that the SSH allow rules above fit your setup. [y/N] " fw
  if [[ "$fw" =~ ^[Yy]$ ]]; then ufw --force enable; else echo "UFW left inactive; inspect with sudo ufw status numbered"; fi
else echo "UFW already active; rules added without resetting existing rules."; fi

# Persist user-level systemd services across logout/reboot.
loginctl enable-linger "$U" || true

cat >/usr/local/bin/hermes-hg680p-setup <<'SETUP'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" -ne 0 ]] || { echo "Run as your normal Armbian user, not root."; exit 1; }
export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"
command -v hermes >/dev/null || { echo "Hermes not found. Open a new shell and check ~/.local/bin/hermes."; exit 1; }
echo "Configure Gemini API: run the official provider/model selector."
hermes model
echo "Test one ordinary chat with: hermes"
read -r -p "Did a normal chat succeed? Continue to Telegram? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Fix model/provider first; see: hermes doctor"; exit 1; }
echo "Telegram setup needs a bot token from Telegram's BotFather."
hermes gateway setup
echo "Install and start the official Hermes-managed gateway service."
hermes gateway install
hermes gateway start
hermes gateway status
SETUP
chmod 755 /usr/local/bin/hermes-hg680p-setup

cat >/usr/local/bin/hermes-hg680p-check <<'CHECK'
#!/usr/bin/env bash
set -u
export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"
echo '=== OS / resources ==='; uname -a; free -h; df -h /
echo; echo '=== Hermes ==='; command -v hermes || true
if command -v hermes >/dev/null 2>&1; then hermes doctor || true; hermes gateway status || true; fi
echo; echo '=== Tailscale ==='; tailscale status 2>/dev/null || true; tailscale ip -4 2>/dev/null || true
echo; echo '=== Firewall ==='; sudo ufw status verbose 2>/dev/null || true
echo; echo '=== Listening sockets ==='; sudo ss -lntup 2>/dev/null || true
CHECK
chmod 755 /usr/local/bin/hermes-hg680p-check

echo
echo '=== Base installation finished ==='
echo "Log in as $U (not root), start a fresh shell, then run: hermes-hg680p-setup"
echo 'Authenticate Tailscale once: sudo tailscale up'
echo 'Verify: tailscale status && tailscale ip -4'
echo 'Diagnostics: hermes-hg680p-check'
echo 'No Hermes API/dashboard port is opened; no router port forwarding is configured.'
echo "Install log: $LOG"
