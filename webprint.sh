#!/bin/bash
# WebPrint Setup Script
# Run as: sudo bash webprint.sh
# Target: Armbian Linux (s905x) with USB printer

set -euo pipefail

# ─── Privilege check ────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Run this script with sudo:"
  echo "  sudo bash webprint.sh"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(eval echo ~"$REAL_USER")"
APP_DIR="$HOME_DIR/apps/webprint"
SERVICE_NAME="webprint"

echo "============================================================"
echo " WebPrint Setup"
echo " User    : $REAL_USER"
echo " App dir : $APP_DIR"
echo "============================================================"

# ─── Node.js 20 LTS via NodeSource ──────────────────────────────────────────
echo ""
echo "=== Installing Node.js 20 LTS ==="

apt-get install -y curl ca-certificates

NODE_MAJOR=$(node -v 2>/dev/null | grep -oP '(?<=v)\d+' || echo "0")
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "Installing Node.js 20 from NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
else
  echo "Node.js $NODE_MAJOR already installed, skipping."
fi

echo "Node: $(node -v)  NPM: $(npm -v)"

# ─── System packages ─────────────────────────────────────────────────────────
echo ""
echo "=== Installing system packages ==="
apt-get install -y \
  cups \
  build-essential \
  python3 \
  printer-driver-all \
  hplip \
  printer-driver-escpr \
  printer-driver-gutenprint \
  sqlite3

# ─── CUPS configuration ──────────────────────────────────────────────────────
echo ""
echo "=== Configuring CUPS ==="

systemctl enable cups
systemctl start cups

# Add user to printer groups
usermod -aG lpadmin "$REAL_USER"
usermod -aG lp     "$REAL_USER"

CUPSD=/etc/cups/cupsd.conf

# Backup only if not already backed up
[ -f "${CUPSD}.bak" ] || cp "$CUPSD" "${CUPSD}.bak"

# Replace "Listen localhost:631" with "Port 631" to allow LAN access
sed -i 's/^Listen localhost:631/Port 631/' "$CUPSD"

# Also replace any WebInterface No with WebInterface Yes (if present)
sed -i 's/^WebInterface No/WebInterface Yes/' "$CUPSD" || true

# Inject network access blocks only if not already present
if ! grep -q "Allow @LOCAL" "$CUPSD"; then
  cat >> "$CUPSD" << 'CUPSEOF'

<Location />
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin>
  Order allow,deny
  Allow @LOCAL
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow @LOCAL
</Location>
CUPSEOF
fi

systemctl restart cups
echo "CUPS configured and restarted."

# ─── Firewall ────────────────────────────────────────────────────────────────
echo ""
echo "=== Configuring firewall ==="

if command -v ufw > /dev/null 2>&1; then
  ufw allow 3000/tcp comment "WebPrint app"
  ufw allow 631/tcp  comment "CUPS web UI"
  # Enable ufw non-interactively only if not already active
  ufw --force enable
  ufw reload
  echo "UFW rules applied."
else
  echo "UFW not found — skipping firewall setup."
  echo "Ensure port 3000 and 631 are reachable on your network."
fi

# ─── App directory ───────────────────────────────────────────────────────────
echo ""
echo "=== Creating app directory ==="

mkdir -p "$APP_DIR/public" "$APP_DIR/uploads"
chown -R "$REAL_USER:$REAL_USER" "$APP_DIR"

# ─── package.json ────────────────────────────────────────────────────────────
echo ""
echo "=== Writing package.json ==="

cat > "$APP_DIR/package.json" << 'EOF'
{
  "name": "webprint",
  "version": "1.0.0",
  "description": "Wireless PDF print server",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  }
}
EOF

# ─── server.js ───────────────────────────────────────────────────────────────
echo ""
echo "=== Writing server.js ==="

cat > "$APP_DIR/server.js" << 'EOF'
"use strict";

const express  = require("express");
const multer   = require("multer");
const { exec } = require("child_process");
const fs       = require("fs");
const path     = require("path");
const sqlite3 = require("sqlite3").verbose();

// ── Database ────────────────────────────────────────────────────────────────
const db = new sqlite3.Database("webprint.db", (err) => {
  if (err) { console.error("Failed to open database:", err); process.exit(1); }
});

db.exec(`
  CREATE TABLE IF NOT EXISTS jobs (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    original_name TEXT    NOT NULL,
    file_path     TEXT,
    status        TEXT    NOT NULL DEFAULT 'pending',
    printer       TEXT,
    pages         TEXT,
    copies        INTEGER NOT NULL DEFAULT 1,
    created_at    INTEGER NOT NULL
  )
`);

// ── Promisified DB helpers ──────────────────────────────────────────────────
const dbRun = (sql, ...params) => new Promise((res, rej) =>
  db.run(sql, params, function(err) { err ? rej(err) : res(this); })
);
const dbGet = (sql, ...params) => new Promise((res, rej) =>
  db.get(sql, params, (err, row) => { err ? rej(err) : res(row); })
);
const dbAll = (sql, ...params) => new Promise((res, rej) =>
  db.all(sql, params, (err, rows) => { err ? rej(err) : res(rows); })
);

// ── Express ─────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static("public"));

// ── Multer (10 MB limit, PDF only) ──────────────────────────────────────────
const upload = multer({
  dest: "uploads/",
  limits: { fileSize: 10 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    if (!file.originalname.toLowerCase().endsWith(".pdf")) {
      return cb(Object.assign(new Error("Only PDF files are allowed"), { status: 400 }));
    }
    cb(null, true);
  }
});

// ── POST /upload ─────────────────────────────────────────────────────────────
app.post("/upload", upload.single("file"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "No file uploaded" });

  try {
    const lastId = await dbRun(
      "INSERT INTO jobs (original_name, file_path, status, created_at) VALUES (?, ?, 'pending', ?)",
      req.file.originalname, req.file.path, Date.now()
    );
    const job = await dbGet("SELECT * FROM jobs WHERE id = ?", lastId.lastID);
    res.status(201).json(job);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── GET /queue ────────────────────────────────────────────────────────────────
app.get("/queue", async (_req, res) => {
  try {
    const jobs = await dbAll("SELECT * FROM jobs ORDER BY created_at DESC");
    res.json(jobs);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── POST /print/:id ───────────────────────────────────────────────────────────
app.post("/print/:id", async (req, res) => {
  try {
    const job = await dbGet("SELECT * FROM jobs WHERE id = ?", req.params.id);
    if (!job)                                   return res.status(404).json({ error: "Job not found" });
    if (!job.file_path || !fs.existsSync(job.file_path))
                                                return res.status(410).json({ error: "File no longer available" });
    if (job.status === "printing")              return res.status(409).json({ error: "Already printing" });

    const printer = (req.body.printer || "").trim();
    const copies  = parseInt(req.body.copies, 10) || 1;
    const pages   = (req.body.pages  || "").trim();

    const flags = [
      "-o fit-to-page",
      printer  ? `-d "${printer}"`   : "",
      copies   ? `-n ${copies}`      : "",
      pages    ? `-P "${pages}"`     : ""
    ].filter(Boolean).join(" ");

    await dbRun(
      "UPDATE jobs SET status='printing', printer=?, copies=?, pages=? WHERE id=?",
      printer || null, copies, pages || null, job.id
    );

    const absPath = path.resolve(job.file_path);
    exec(`lp ${flags} -- "${absPath}"`, (err, _out, stderr) => {
      dbRun("UPDATE jobs SET status=? WHERE id=?", err ? "failed" : "done", job.id);
      if (err) console.error("lp error:", stderr);
    });

    res.json({ message: "Printing started" });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── GET /file/:id ─────────────────────────────────────────────────────────────
app.get("/file/:id", async (req, res) => {
  try {
    const job = await dbGet("SELECT * FROM jobs WHERE id = ?", req.params.id);
    if (!job)                                      return res.sendStatus(404);
    if (!job.file_path || !fs.existsSync(job.file_path))
                                                   return res.status(410).send("File no longer available");
    res.sendFile(path.resolve(job.file_path));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── DELETE /job/:id ───────────────────────────────────────────────────────────
app.delete("/job/:id", async (req, res) => {
  try {
    const job = await dbGet("SELECT * FROM jobs WHERE id = ?", req.params.id);
    if (!job) return res.status(404).json({ error: "Job not found" });
    if (job.file_path) { try { fs.unlinkSync(job.file_path); } catch { /* gone */ } }
    await dbRun("DELETE FROM jobs WHERE id=?", job.id);
    res.json({ message: "Job deleted" });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── GET /printers ─────────────────────────────────────────────────────────────
app.get("/printers", (_req, res) => {
  exec("lpstat -p -d 2>/dev/null", (_err, stdout) => {
    const printers = [];
    let   defaultPrinter = "";

    (stdout || "").split("\n").forEach(line => {
      if (line.startsWith("printer")) {
        const parts = line.split(" ");
        printers.push({
          name:    parts[1],
          status:  line.includes("idle")     ? "idle" :
                   line.includes("printing") ? "printing" : "unknown"
        });
      }
      if (line.startsWith("system default")) {
        defaultPrinter = line.split(": ")[1]?.trim() || "";
      }
    });

    res.json({ printers, default: defaultPrinter });
  });
});

// ── Multer / general error handler ───────────────────────────────────────────
app.use((err, _req, res, _next) => {
  const status = err.status || 500;
  res.status(status).json({ error: err.message || "Internal server error" });
});

// ── Cleanup task: runs every minute ──────────────────────────────────────────
function cleanup() {
  const now = Date.now();

  dbAll("SELECT * FROM jobs WHERE file_path IS NOT NULL AND created_at < ?", now - 30 * 60 * 1000)
    .then(toExpire => {
      for (const job of toExpire) {
        try { fs.unlinkSync(job.file_path); } catch { /* already gone */ }
        dbRun("UPDATE jobs SET file_path=NULL WHERE id=?", job.id);
      }
    });

  dbRun(
    "DELETE FROM jobs WHERE status IN ('done','failed') AND created_at < ?",
    now - 60 * 60 * 1000
  );
}

setInterval(cleanup, 60_000);

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(3000, "0.0.0.0", () =>
  console.log("WebPrint running → http://0.0.0.0:3000")
);
EOF

# ─── public/index.html ───────────────────────────────────────────────────────
echo ""
echo "=== Writing frontend ==="

cat > "$APP_DIR/public/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WebPrint</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: system-ui, sans-serif;
      background: #f0f2f5;
      color: #1a1a1a;
      min-height: 100vh;
    }

    header {
      background: #1565c0;
      color: #fff;
      padding: 14px 24px;
      display: flex;
      align-items: center;
      gap: 10px;
      font-size: 1.25rem;
      font-weight: 600;
      box-shadow: 0 2px 6px rgba(0,0,0,.25);
    }

    main {
      max-width: 860px;
      margin: 28px auto;
      padding: 0 16px;
      display: flex;
      flex-direction: column;
      gap: 20px;
    }

    .card {
      background: #fff;
      border-radius: 10px;
      padding: 20px 24px;
      box-shadow: 0 1px 4px rgba(0,0,0,.12);
    }

    h2 {
      font-size: 1rem;
      font-weight: 600;
      margin-bottom: 14px;
      color: #1565c0;
      text-transform: uppercase;
      letter-spacing: .05em;
    }

    /* Upload area */
    #drop-zone {
      border: 2px dashed #90caf9;
      border-radius: 8px;
      padding: 32px;
      text-align: center;
      cursor: pointer;
      transition: background .2s, border-color .2s;
      color: #555;
    }
    #drop-zone.drag-over { background: #e3f2fd; border-color: #1565c0; }
    #drop-zone.has-file  { border-color: #43a047; color: #2e7d32; }
    #drop-zone p { margin-top: 8px; font-size: .9rem; }
    #file-input { display: none; }

    .row { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-top: 12px; }

    select, input[type="number"], input[type="text"] {
      padding: 7px 10px;
      border: 1px solid #ccc;
      border-radius: 6px;
      font-size: .9rem;
      flex: 1;
      min-width: 100px;
    }

    label { font-size: .85rem; color: #555; }

    button {
      padding: 8px 18px;
      border: none;
      border-radius: 6px;
      font-size: .9rem;
      cursor: pointer;
      font-weight: 500;
      transition: opacity .15s;
    }
    button:disabled { opacity: .45; cursor: not-allowed; }
    button:hover:not(:disabled) { opacity: .85; }

    .btn-primary { background: #1565c0; color: #fff; }
    .btn-danger  { background: #c62828; color: #fff; padding: 5px 12px; font-size: .8rem; }
    .btn-ghost   { background: #e8eaf6; color: #283593; padding: 5px 12px; font-size: .8rem; }

    /* Printers */
    #printer-list { display: flex; gap: 10px; flex-wrap: wrap; }
    .printer-chip {
      display: flex; align-items: center; gap: 6px;
      padding: 6px 14px; border-radius: 20px;
      background: #f5f5f5; font-size: .88rem;
    }
    .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
    .dot.idle     { background: #43a047; }
    .dot.printing { background: #fb8c00; }
    .dot.unknown  { background: #9e9e9e; }

    /* Queue table */
    table { width: 100%; border-collapse: collapse; font-size: .9rem; }
    thead th {
      text-align: left; padding: 8px 10px;
      border-bottom: 2px solid #e0e0e0;
      font-weight: 600; color: #555;
    }
    tbody tr:nth-child(even) { background: #fafafa; }
    tbody td { padding: 9px 10px; border-bottom: 1px solid #efefef; vertical-align: middle; }

    .badge {
      display: inline-block;
      padding: 2px 10px; border-radius: 12px;
      font-size: .78rem; font-weight: 600;
    }
    .badge-pending  { background: #fff9c4; color: #795548; }
    .badge-printing { background: #ffe0b2; color: #e65100; }
    .badge-done     { background: #c8e6c9; color: #1b5e20; }
    .badge-failed   { background: #ffcdd2; color: #b71c1c; }

    .actions { display: flex; gap: 6px; flex-wrap: wrap; }

    #toast {
      position: fixed; bottom: 20px; right: 20px;
      background: #323232; color: #fff;
      padding: 10px 18px; border-radius: 8px;
      font-size: .88rem; opacity: 0;
      transition: opacity .3s;
      pointer-events: none;
    }
    #toast.show { opacity: 1; }
    #empty-msg { color: #999; font-style: italic; padding: 12px 0; }
  </style>
</head>
<body>

<header>
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
       stroke-linecap="round" stroke-linejoin="round">
    <polyline points="6 9 6 2 18 2 18 9"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/>
    <rect x="6" y="14" width="12" height="8"/>
  </svg>
  WebPrint
</header>

<main>

  <!-- Printers -->
  <div class="card">
    <h2>Printers</h2>
    <div id="printer-list"><span style="color:#999;font-style:italic;">Loading…</span></div>
  </div>

  <!-- Upload -->
  <div class="card">
    <h2>Upload PDF</h2>

    <div id="drop-zone" onclick="document.getElementById('file-input').click()">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#90caf9"
           stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
        <polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/>
      </svg>
      <p id="drop-label">Click or drag a PDF here</p>
    </div>
    <input type="file" id="file-input" accept=".pdf">

    <div class="row">
      <div style="flex:1">
        <label>Printer (optional)</label>
        <select id="sel-printer"><option value="">Default</option></select>
      </div>
      <div style="width:90px">
        <label>Copies</label>
        <input type="number" id="copies" value="1" min="1" max="99">
      </div>
      <div style="flex:1">
        <label>Pages (e.g. 1-3,5)</label>
        <input type="text" id="pages" placeholder="all">
      </div>
    </div>

    <div class="row">
      <button class="btn-primary" id="upload-btn" onclick="handleUpload()" disabled>
        Upload &amp; Queue
      </button>
      <span id="upload-status" style="font-size:.85rem;color:#555;"></span>
    </div>
  </div>

  <!-- Queue -->
  <div class="card">
    <h2>Print Queue</h2>
    <div id="queue-container">
      <span id="empty-msg">No jobs in queue.</span>
    </div>
  </div>

</main>

<div id="toast"></div>

<script>
// ── State ────────────────────────────────────────────────────────────────────
let selectedFile = null;
let printerList  = [];

// ── Toast ────────────────────────────────────────────────────────────────────
function toast(msg, duration = 2800) {
  const t = document.getElementById("toast");
  t.textContent = msg;
  t.classList.add("show");
  setTimeout(() => t.classList.remove("show"), duration);
}

// ── Drag & drop ───────────────────────────────────────────────────────────────
const dropZone  = document.getElementById("drop-zone");
const fileInput = document.getElementById("file-input");

["dragenter","dragover"].forEach(e =>
  dropZone.addEventListener(e, ev => { ev.preventDefault(); dropZone.classList.add("drag-over"); }));
["dragleave","drop"].forEach(e =>
  dropZone.addEventListener(e, ev => { ev.preventDefault(); dropZone.classList.remove("drag-over"); }));

dropZone.addEventListener("drop", ev => {
  const f = ev.dataTransfer.files[0];
  if (f) setFile(f);
});

fileInput.addEventListener("change", () => {
  if (fileInput.files[0]) setFile(fileInput.files[0]);
});

function setFile(f) {
  if (!f.name.toLowerCase().endsWith(".pdf")) {
    toast("Only PDF files are supported.");
    return;
  }
  selectedFile = f;
  document.getElementById("drop-label").textContent = f.name + "  (" + (f.size/1024).toFixed(0) + " KB)";
  dropZone.classList.add("has-file");
  document.getElementById("upload-btn").disabled = false;
}

// ── Upload ────────────────────────────────────────────────────────────────────
async function handleUpload() {
  if (!selectedFile) return;
  const btn = document.getElementById("upload-btn");
  const status = document.getElementById("upload-status");
  btn.disabled = true;
  status.textContent = "Uploading…";

  const form = new FormData();
  form.append("file", selectedFile);

  try {
    const res  = await fetch("/upload", { method: "POST", body: form });
    const data = await res.json();

    if (!res.ok) {
      toast("Upload failed: " + (data.error || res.statusText));
      status.textContent = "";
      btn.disabled = false;
      return;
    }

    status.textContent = "Queued: " + data.original_name;
    selectedFile = null;
    document.getElementById("drop-label").textContent = "Click or drag a PDF here";
    dropZone.classList.remove("has-file");
    fileInput.value = "";
    btn.disabled = true;
    loadQueue();
    toast("File queued successfully.");
  } catch (err) {
    toast("Network error: " + err.message);
    status.textContent = "";
    btn.disabled = false;
  }
}

// ── Printers ──────────────────────────────────────────────────────────────────
async function loadPrinters() {
  try {
    const res  = await fetch("/printers");
    const data = await res.json();
    printerList = data.printers || [];

    const list = document.getElementById("printer-list");
    if (!printerList.length) {
      list.innerHTML = "<span style='color:#999;font-style:italic;'>No printers found. Add one via CUPS.</span>";
    } else {
      list.innerHTML = printerList.map(p =>
        `<div class="printer-chip">
           <span class="dot ${p.status}"></span>${p.name}
           <span style="font-size:.78rem;color:#777;">(${p.status})</span>
         </div>`
      ).join("");
    }

    const sel = document.getElementById("sel-printer");
    const cur = sel.value;
    sel.innerHTML = '<option value="">Default</option>' +
      printerList.map(p => `<option value="${p.name}">${p.name}</option>`).join("");
    if (cur) sel.value = cur;

    if (data.default) {
      const def = sel.querySelector(`option[value="${data.default}"]`);
      if (def && !cur) def.text += " ★";
    }
  } catch { /* silently skip on network error */ }
}

// ── Queue ─────────────────────────────────────────────────────────────────────
async function loadQueue() {
  try {
    const res  = await fetch("/queue");
    const jobs = await res.json();

    const container = document.getElementById("queue-container");

    if (!jobs.length) {
      container.innerHTML = '<span id="empty-msg">No jobs in queue.</span>';
      return;
    }

    container.innerHTML = `
      <table>
        <thead>
          <tr>
            <th>#</th>
            <th>File</th>
            <th>Printer</th>
            <th>Status</th>
            <th>Time</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${jobs.map(job => {
            const age = ((Date.now() - job.created_at) / 1000 / 60).toFixed(0);
            return `
            <tr>
              <td>${job.id}</td>
              <td title="${job.original_name}">${truncate(job.original_name, 28)}</td>
              <td>${job.printer || "—"}</td>
              <td><span class="badge badge-${job.status}">${job.status}</span></td>
              <td>${age} min ago</td>
              <td class="actions">
                ${job.file_path ? `<button class="btn-ghost" onclick="preview(${job.id})">View</button>` : ""}
                ${canPrint(job) ? `<button class="btn-primary" onclick="printJob(${job.id})" style="font-size:.8rem;padding:5px 12px;">Print</button>` : ""}
                <button class="btn-danger" onclick="deleteJob(${job.id})">Delete</button>
              </td>
            </tr>`;
          }).join("")}
        </tbody>
      </table>`;
  } catch { /* skip */ }
}

function canPrint(job) {
  return job.file_path && (job.status === "pending" || job.status === "failed");
}

function truncate(str, len) {
  return str.length > len ? str.slice(0, len - 1) + "…" : str;
}

function preview(id) {
  window.open("/file/" + id, "_blank");
}

async function printJob(id) {
  const printer = document.getElementById("sel-printer").value;
  const copies  = parseInt(document.getElementById("copies").value, 10) || 1;
  const pages   = document.getElementById("pages").value.trim();

  const res = await fetch("/print/" + id, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ printer, copies, pages })
  });
  const data = await res.json();
  toast(res.ok ? "Sent to printer!" : "Error: " + data.error);
  loadQueue();
}

async function deleteJob(id) {
  const res  = await fetch("/job/" + id, { method: "DELETE" });
  const data = await res.json();
  toast(res.ok ? "Job deleted." : "Error: " + data.error);
  loadQueue();
}

// ── Init & polling ────────────────────────────────────────────────────────────
loadPrinters();
loadQueue();
setInterval(loadPrinters, 8000);
setInterval(loadQueue,    5000);
</script>

</body>
</html>
EOF

# ─── npm install (run as regular user) ───────────────────────────────────────
echo ""
echo "=== Installing npm packages ==="
chown -R "$REAL_USER:$REAL_USER" "$APP_DIR"
sudo -u "$REAL_USER" bash -c "cd '$APP_DIR' && npm install express multer sqlite"

# ─── systemd service ──────────────────────────────────────────────────────────
echo ""
echo "=== Creating systemd service ==="

NODE_BIN="$(command -v node)"

cat > /etc/systemd/system/${SERVICE_NAME}.service << SVCEOF
[Unit]
Description=WebPrint - Wireless PDF print server
After=network.target cups.service
Wants=cups.service

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${NODE_BIN} server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable  "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "Service '$SERVICE_NAME' is running."
else
  echo "WARNING: Service failed to start. Check: journalctl -u $SERVICE_NAME -n 30"
fi

# ─── Detect server IP ─────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================================"
echo " DONE! WebPrint is running."
echo ""
echo " App  : http://${SERVER_IP}:3000"
echo " CUPS : http://${SERVER_IP}:631"
echo ""
echo " Notes:"
echo "   - Re-login (or reboot) for printer group changes to take effect"
echo "   - Add printer via CUPS: http://${SERVER_IP}:631"
echo "   - Logs: journalctl -u ${SERVICE_NAME} -f"
echo "   - Stop:  sudo systemctl stop ${SERVICE_NAME}"
echo "   - Start: sudo systemctl start ${SERVICE_NAME}"
echo "============================================================"
