#!/usr/bin/env bash
set -euo pipefail

# ─── colors ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

ROOKD_HOST="0.0.0.0"
ROOKD_PORT="8787"
ROOKD_DATA_ROOT="$HOME/.local/share/rookd/data"
ROOKD_TLS_CERT=""
ROOKD_TLS_KEY=""
ROOKD_DO_SERVICE=1

usage() {
  cat >&2 <<'EOF'
Usage: server/setup.sh [options]

  --host <addr>        address to listen on (default 0.0.0.0)
  --port <port>        port to listen on (default 8787)
  --data-root <dir>    where transcripts are stored
  --tls-cert <file>    serve HTTPS with this certificate chain
  --tls-key <file>     private key matching --tls-cert
  --no-service         install and configure only; don't start anything
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)       ROOKD_HOST="${2:-}"; shift 2 ;;
    --port)       ROOKD_PORT="${2:-}"; shift 2 ;;
    --data-root)  ROOKD_DATA_ROOT="${2:-}"; shift 2 ;;
    --tls-cert)   ROOKD_TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key)    ROOKD_TLS_KEY="${2:-}"; shift 2 ;;
    --no-service) ROOKD_DO_SERVICE=0; shift ;;
    -h|--help)    usage ;;
    *)            err "unknown option: $1"; usage ;;
  esac
done

if { [ -n "$ROOKD_TLS_CERT" ] && [ -z "$ROOKD_TLS_KEY" ]; } ||
   { [ -z "$ROOKD_TLS_CERT" ] && [ -n "$ROOKD_TLS_KEY" ]; }; then
  err "--tls-cert and --tls-key must be given together"
  exit 1
fi

# ─── fetch a file from this repo's raw API (avoids CDN cache) ────────
ROOK_REPO_API="https://api.github.com/repos/zobinHuang/Rookery/contents"
ROOKD_SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  ROOKD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi

rookd_install_file() {
  # rookd_install_file <repo-path> <dest>
  local src="$1" dest="$2" http_code
  if [ -n "$ROOKD_SCRIPT_DIR" ] && [ -f "$ROOKD_SCRIPT_DIR/../$src" ]; then
    cp "$ROOKD_SCRIPT_DIR/../$src" "$dest"
    return 0
  fi
  http_code="$(curl -sSL -w '%{http_code}' \
                -H 'Accept: application/vnd.github.v3.raw' \
                "${ROOK_REPO_API}/${src}" -o "$dest" 2>/dev/null)" || return 1
  case "$http_code" in
    2??) return 0 ;;
    *) rm -f "$dest"; err "HTTP $http_code fetching $src"; return 1 ;;
  esac
}

echo ""
echo "══════════════════════════════════════════════════"
echo "  Rookery session server"
echo "══════════════════════════════════════════════════"

# ─── 1. python ───────────────────────────────────────────────────────
echo ""
echo "── python ────────────────────────────────────────"

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 not found. Install Python 3.10 or newer first."
  exit 1
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  err "python3 is $(python3 -V 2>&1), but 3.10 or newer is required."
  exit 1
fi
info "python3 $(python3 -VV | head -1 | cut -d' ' -f2)"

# The skill index resolves refs to commits with `git ls-remote`, which is the
# only way to do it that works for GitHub, GitLab and self-hosted alike without
# cloning anything. Session upload does not need git, so this is a warning.
if command -v git >/dev/null 2>&1; then
  info "git $(git --version | cut -d' ' -f3)"
else
  warn "git not found — session upload still works, but the skill index cannot"
  warn "resolve repository refs until git is installed."
fi

# ─── 2. install the package ──────────────────────────────────────────
echo ""
echo "── install ───────────────────────────────────────"

ROOKD_APP_DIR="$HOME/.local/share/rookd/app"
ROOKD_CONFIG="$HOME/.config/rookd/config.json"
ROOKD_BIN="$HOME/.local/bin/rookd"

mkdir -p "$ROOKD_APP_DIR/rookd" "$HOME/.local/bin"
for MODULE in __init__.py __main__.py catalog.py config.py database.py errors.py events.py http.py link.py messages.py playbooks.py records.py resources.py skills.py store.py; do
  if ! rookd_install_file "server/rookd/$MODULE" "$ROOKD_APP_DIR/rookd/$MODULE"; then
    err "Failed to install rookd/$MODULE"
    exit 1
  fi
done
# Stale bytecode from a previous version shadows the modules we just wrote.
rm -rf "$ROOKD_APP_DIR/rookd/__pycache__"
info "Installed rookd to $ROOKD_APP_DIR"

# The live link needs the websockets package; it goes into a virtual
# environment of rookd's own, so the system's Python is left as it is.
ROOKD_VENV="$HOME/.local/share/rookd/venv"
ROOKD_WEBSOCKETS_SPEC='websockets>=13,<17'
if [ ! -x "$ROOKD_VENV/bin/python" ] && ! python3 -m venv "$ROOKD_VENV"; then
  err "Could not create a virtual environment at $ROOKD_VENV (on Debian: apt install python3-venv)"
  exit 1
fi
if ! "$ROOKD_VENV/bin/python" -m pip install --quiet --disable-pip-version-check "$ROOKD_WEBSOCKETS_SPEC"; then
  err "Could not install $ROOKD_WEBSOCKETS_SPEC into $ROOKD_VENV"
  exit 1
fi
info "websockets $("$ROOKD_VENV/bin/python" -c 'import websockets; print(websockets.__version__)') in $ROOKD_VENV"

cat > "$ROOKD_BIN" <<LAUNCHER
#!/bin/sh
# [rook]
PYTHONPATH="$ROOKD_APP_DIR\${PYTHONPATH:+:\$PYTHONPATH}" \\
  exec "$ROOKD_VENV/bin/python" -m rookd --config "$ROOKD_CONFIG" "\$@"
LAUNCHER
chmod +x "$ROOKD_BIN"
info "Installed rookd command to $ROOKD_BIN"

# ─── 3. configure ────────────────────────────────────────────────────
echo ""
echo "── configure ─────────────────────────────────────"

# `init` keeps the token of an existing config, so re-running this script
# upgrades a server without invalidating the clients already connected to it.
ROOKD_INIT_ARGS=(init --host "$ROOKD_HOST" --port "$ROOKD_PORT" --data-root "$ROOKD_DATA_ROOT")
if [ -n "$ROOKD_TLS_CERT" ]; then
  ROOKD_INIT_ARGS+=(--tls-cert "$ROOKD_TLS_CERT" --tls-key "$ROOKD_TLS_KEY")
fi
"$ROOKD_BIN" "${ROOKD_INIT_ARGS[@]}" >/dev/null
ROOKD_TOKEN="$("$ROOKD_BIN" token)"
info "Config at $ROOKD_CONFIG, data under $ROOKD_DATA_ROOT"

# ─── 4. service ──────────────────────────────────────────────────────
echo ""
echo "── service ───────────────────────────────────────"

ROOKD_STARTED=0
if [ "$ROOKD_DO_SERVICE" -eq 0 ]; then
  info "Skipped starting the service (--no-service)"
elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  ROOKD_UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$ROOKD_UNIT_DIR"
  cat > "$ROOKD_UNIT_DIR/rookd.service" <<UNIT
[Unit]
Description=Rookery session server
After=network-online.target

[Service]
ExecStart=$ROOKD_BIN serve
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now rookd.service
  # Without lingering, a user unit dies the moment you log out.
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||
    warn "Could not enable lingering; rookd will stop when you log out."
  info "Started systemd user unit rookd.service"
  ROOKD_STARTED=1
elif [ "$(uname -s)" = "Darwin" ]; then
  ROOKD_PLIST="$HOME/Library/LaunchAgents/io.github.zobinhuang.rookery.rookd.plist"
  mkdir -p "$(dirname "$ROOKD_PLIST")" "$HOME/.local/share/rookd"
  cat > "$ROOKD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.zobinhuang.rookery.rookd</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOKD_BIN</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.local/share/rookd/rookd.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/share/rookd/rookd.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/io.github.zobinhuang.rookery.rookd" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$ROOKD_PLIST"
  info "Started launchd agent io.github.zobinhuang.rookery.rookd"
  ROOKD_STARTED=1
else
  warn "No systemd or launchd found. Start the server by hand:"
  warn "  nohup $ROOKD_BIN serve > ~/.local/share/rookd/rookd.log 2>&1 &"
fi

# ─── 5. verify ───────────────────────────────────────────────────────
if [ "$ROOKD_STARTED" -eq 1 ]; then
  echo ""
  echo "── verify ────────────────────────────────────────"
  ROOKD_SCHEME="http"
  [ -n "$ROOKD_TLS_CERT" ] && ROOKD_SCHEME="https"
  ROOKD_PROBE_OK=0
  for _ in 1 2 3 4 5; do
    if curl -fsSk "$ROOKD_SCHEME://127.0.0.1:$ROOKD_PORT/v1/healthz" >/dev/null 2>&1; then
      ROOKD_PROBE_OK=1
      break
    fi
    sleep 1
  done
  if [ "$ROOKD_PROBE_OK" -eq 1 ]; then
    info "Health check passed on $ROOKD_SCHEME://127.0.0.1:$ROOKD_PORT"
  else
    err "Health check failed. Logs: ~/.local/share/rookd/rookd.log or journalctl --user -u rookd"
  fi
fi

# ─── done ─────────────────────────────────────────────────────────────
ROOKD_ADDR="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '<host>')"
echo ""
echo "══════════════════════════════════════════════════"
echo "  Server ready"
echo ""
echo "  Run this on each client:"
echo ""
echo "    rook connect $ROOKD_ADDR $ROOKD_PORT --token $ROOKD_TOKEN"
echo ""
echo "  Open port $ROOKD_PORT and the live link's port $((ROOKD_PORT + 1)) to them."
echo ""
if [ -z "$ROOKD_TLS_CERT" ]; then
  echo "  This server speaks plain HTTP. Transcripts carry your source code,"
  echo "  paths and anything an agent printed — only expose it on a trusted"
  echo "  network, or re-run with --tls-cert/--tls-key."
  echo ""
fi
echo "══════════════════════════════════════════════════"
echo ""
