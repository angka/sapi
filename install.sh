#!/bin/bash

# ShareOp Installation Script for Ubuntu 24.04
# This script installs and configures ShareOp to run automatically

set -e  # Exit on any error

echo "=== ShareOp Installation Script ==="
echo "This script will install ShareOp on Ubuntu 24.04"
echo "Make sure you are running this as a user with sudo privileges"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    echo "Please run this script as a regular user with sudo (not as root)"
    exit 1
fi

# Update system packages
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install required system packages
echo "Installing required system packages..."
sudo apt install -y git curl wget build-essential

# Install Node.js (LTS version)
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify Node.js and npm installation
echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"

# Create directory for ShareOp
echo "Setting up ShareOp directory..."
SHAREOP_DIR="/home/angka/shareop"
sudo mkdir -p "$SHAREOP_DIR"
sudo chown angka:angka "$SHAREOP_DIR"

# Clone the repository
echo "Cloning ShareOp repository..."
if [ -d "$SHAREOP_DIR/.git" ]; then
    echo "Repository already exists, pulling latest changes..."
    cd "$SHAREOP_DIR" && git pull origin main
else
    git clone https://github.com/angka/shareop.git "$SHAREOP_DIR"
fi

# Navigate to ShareOp directory
cd "$SHAREOP_DIR"

# Install Node.js dependencies
echo "Installing Node.js dependencies..."
npm install

# Create .env file for Telegram configuration
echo "Creating .env file for Telegram Bot configuration..."
if [ ! -f .env ]; then
    cat > .env << EOL
# Telegram Bot Configuration
TELEGRAM_BOT_TOKEN=your_telegram_bot_token_here
TELEGRAM_CHAT_ID=your_telegram_chat_id_here
# Optional: Port for the server (default: 3000)
PORT=3000
EOL
    echo ".env file created. Please edit it to add your Telegram Bot Token and Chat ID."
    echo "You can get these by:"
    echo "1. Talking to @BotFather on Telegram to create a bot and get the token"
    echo "2. Adding the bot to your group and getting the chat ID"
else
    echo ".env file already exists, skipping creation."
fi

# Create systemd service for auto-start
echo "Creating systemd service for auto-start..."
sudo tee /etc/systemd/system/shareop.service > /dev/null << EOL
[Unit]
Description=ShareOp - Jadwal Operasi & Telegram Bot
After=network.target

[Service]
Type=simple
User=angka
WorkingDirectory=/home/angka/shareop
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=10
Environment=PORT=3000
EnvironmentFile=/home/angka/shareop/.env

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd, enable and start the service
echo "Setting up service to start automatically..."
sudo systemctl daemon-reload
sudo systemctl enable shareop.service
sudo systemctl start shareop.service

# Show service status
echo "Checking service status..."
sudo systemctl status shareop.service --no-pager

# Show installation complete message
echo ""
echo "=== Installation Complete ==="
echo ""
echo "ShareOp has been installed and configured to run automatically."
echo ""
echo "Next steps:"
echo "1. Edit the .env file to add your Telegram Bot Token and Chat ID:"
echo "   nano /home/angka/shareop/.env"
echo ""
echo "2. After editing .env, restart the service:"
echo "   sudo systemctl restart shareop.service"
echo ""
echo "3. Check the logs if needed:"
echo "   journalctl -u shareop.service -f"
echo ""
echo "4. Access the web interface at:"
echo "   http://your_server_ip:3000"
echo ""
echo "The application will now start automatically on system boot."
echo ""