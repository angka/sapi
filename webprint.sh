#!/bin/bash

set -e

REAL_USER=${SUDO_USER:-$USER}
HOME_DIR=$(eval echo ~$REAL_USER)
APP_DIR="$HOME_DIR/apps/webprint"

echo "User: $REAL_USER"
echo "Dir: $APP_DIR"

echo "=== System update ==="
sudo apt update && sudo apt upgrade -y

echo "=== Install CUPS + drivers ==="
sudo apt install -y \
  cups \
  nodejs npm \
  printer-driver-all \
  hplip \
  printer-driver-escpr \
  gutenprint

echo "=== Enable CUPS ==="
sudo systemctl enable cups
sudo systemctl restart cups

echo "=== Add user to groups ==="
sudo usermod -aG lpadmin $REAL_USER
sudo usermod -aG lp $REAL_USER

echo "=== Configure CUPS ==="
sudo cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak || true
sudo sed -i 's/^Listen localhost:631/Port 631/' /etc/cups/cupsd.conf

if ! grep -q "Allow @LOCAL" /etc/cups/cupsd.conf; then
sudo bash -c 'cat >> /etc/cups/cupsd.conf <<EOF

<Location />
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin>
  Order allow,deny
  Allow @LOCAL
</Location>
EOF'
fi

sudo systemctl restart cups

echo "=== Setup project ==="
mkdir -p "$APP_DIR/public" "$APP_DIR/uploads"
sudo chown -R "$REAL_USER:$REAL_USER" "$APP_DIR"
cd "$APP_DIR"

[ -f package.json ] || npm init -y
npm install express multer

echo "=== Create server.js ==="
cat > server.js << 'EOF'
const express = require("express");
const multer = require("multer");
const { exec } = require("child_process");
const fs = require("fs");
const path = require("path");

const app = express();
app.use(express.json());
app.use(express.static("public"));

const upload = multer({ dest: "uploads/" });
const QUEUE_FILE = "queue.json";

if (!fs.existsSync(QUEUE_FILE)) {
  fs.writeFileSync(QUEUE_FILE, JSON.stringify([]));
}

function loadQueue() {
  return JSON.parse(fs.readFileSync(QUEUE_FILE));
}

function saveQueue(queue) {
  fs.writeFileSync(QUEUE_FILE, JSON.stringify(queue, null, 2));
}

// ===== Upload =====
app.post("/upload", upload.single("file"), (req, res) => {
  if (!req.file) return res.send("No file");

  if (!req.file.originalname.toLowerCase().endsWith(".pdf")) {
    fs.unlinkSync(req.file.path);
    return res.send("Only PDF allowed");
  }

  const queue = loadQueue();

  const job = {
    id: Date.now(),
    file: req.file.path,
    name: req.file.originalname,
    status: "pending",
    createdAt: Date.now()
  };

  queue.push(job);
  saveQueue(queue);

  res.json(job);
});

// ===== Queue =====
app.get("/queue", (req, res) => {
  res.json(loadQueue());
});

// ===== Print =====
app.post("/print/:id", (req, res) => {
  const queue = loadQueue();
  const job = queue.find(j => j.id == req.params.id);

  if (!job) return res.send("Job not found");

  job.status = "printing";
  saveQueue(queue);

  exec(`lp -o fit-to-page ${job.file}`, (err) => {
    job.status = err ? "failed" : "done";
    saveQueue(queue);
  });

  res.send("Printing started");
});

// ===== Preview =====
app.get("/file/:id", (req, res) => {
  const queue = loadQueue();
  const job = queue.find(j => j.id == req.params.id);

  if (!job) return res.sendStatus(404);

  if (!job.file || !fs.existsSync(job.file)) {
    return res.send("File no longer available");
  }

  res.sendFile(path.resolve(job.file));
});

// ===== Printer Status =====
app.get("/printers", (req, res) => {
  exec("lpstat -p -d", (err, stdout) => {
    if (err) return res.send("Error reading printers");

    const lines = stdout.split("\n");
    const printers = [];

    lines.forEach(line => {
      if (line.startsWith("printer")) {
        const parts = line.split(" ");
        printers.push({
          name: parts[1],
          status: line.includes("idle") ? "idle" :
                  line.includes("printing") ? "printing" : "unknown"
        });
      }
    });

    res.json(printers);
  });
});

// ===== Auto Cleanup =====
function cleanupOldFiles() {
  const queue = loadQueue();
  const now = Date.now();

  let changed = false;

  queue.forEach(job => {
    if (job.file && (now - job.createdAt > 10 * 60 * 1000)) {
      try {
        fs.unlinkSync(job.file);
        job.file = null;
        changed = true;
      } catch {}
    }
  });

  if (changed) saveQueue(queue);
}

setInterval(cleanupOldFiles, 60000);

app.listen(3000, "0.0.0.0", () => {
  console.log("WebPrint running on port 3000");
});
EOF

echo "=== Create frontend ==="
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Web Print Dashboard</title>
</head>
<body>

<h2>Printers</h2>
<div id="printers"></div>

<h2>Upload PDF</h2>
<input type="file" id="file">
<button onclick="upload()">Upload</button>

<h2>Queue</h2>
<div id="queue"></div>

<script>
async function loadPrinters() {
  const res = await fetch("/printers");
  const data = await res.json();

  const div = document.getElementById("printers");
  div.innerHTML = "";

  data.forEach(p => {
    div.innerHTML += `<b>${p.name}</b> - ${p.status}<br>`;
  });
}

async function upload() {
  const file = document.getElementById("file").files[0];
  const formData = new FormData();
  formData.append("file", file);

  await fetch("/upload", { method: "POST", body: formData });
  loadQueue();
}

async function loadQueue() {
  const res = await fetch("/queue");
  const data = await res.json();

  const div = document.getElementById("queue");
  div.innerHTML = "";

  data.forEach(job => {
    div.innerHTML += `
      <div style="border:1px solid #000; margin:5px; padding:5px;">
        <b>${job.name}</b><br>
        Status: ${job.status}<br>
        <button onclick="preview(${job.id})">Preview</button>
        <button onclick="printJob(${job.id})">Print</button>
      </div>
    `;
  });
}

function preview(id) {
  window.open("/file/" + id);
}

async function printJob(id) {
  await fetch("/print/" + id, { method: "POST" });
  loadQueue();
}

loadPrinters();
loadQueue();
setInterval(loadPrinters, 5000);
setInterval(loadQueue, 5000);
</script>

</body>
</html>
EOF

echo "=== Install PM2 ==="
if ! command -v pm2 >/dev/null 2>&1; then
  sudo npm install -g pm2
fi

pm2 start server.js --name webprint || pm2 restart webprint
pm2 save

pm2 startup systemd -u "$REAL_USER" --hp "$HOME_DIR" | sudo bash

echo ""
echo "✅ DONE!"
echo "Web:  http://<SERVER-IP>:3000"
echo "CUPS: http://<SERVER-IP>:631"
echo "⚠️ Re-login or reboot required"
