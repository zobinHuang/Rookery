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

CROWD_HOST="0.0.0.0"
CROWD_PORT="8787"
CROWD_DATA_ROOT="$HOME/.local/share/crowd/data"
CROWD_TLS_CERT=""
CROWD_TLS_KEY=""
CROWD_DO_SERVICE=1

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
    --host)       CROWD_HOST="${2:-}"; shift 2 ;;
    --port)       CROWD_PORT="${2:-}"; shift 2 ;;
    --data-root)  CROWD_DATA_ROOT="${2:-}"; shift 2 ;;
    --tls-cert)   CROWD_TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key)    CROWD_TLS_KEY="${2:-}"; shift 2 ;;
    --no-service) CROWD_DO_SERVICE=0; shift ;;
    -h|--help)    usage ;;
    *)            err "unknown option: $1"; usage ;;
  esac
done

if { [ -n "$CROWD_TLS_CERT" ] && [ -z "$CROWD_TLS_KEY" ]; } ||
   { [ -z "$CROWD_TLS_CERT" ] && [ -n "$CROWD_TLS_KEY" ]; }; then
  err "--tls-cert and --tls-key must be given together"
  exit 1
fi

# ─── fetch a file from this repo's raw API (avoids CDN cache) ────────
CROW_REPO_API="https://api.github.com/repos/zobinHuang/Rookery/contents"
CROWD_SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  CROWD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi

crowd_install_file() {
  # crowd_install_file <repo-path> <dest>
  local src="$1" dest="$2" http_code
  if [ -n "$CROWD_SCRIPT_DIR" ] && [ -f "$CROWD_SCRIPT_DIR/../$src" ]; then
    cp "$CROWD_SCRIPT_DIR/../$src" "$dest"
    return 0
  fi
  http_code="$(curl -sSL -w '%{http_code}' \
                -H 'Accept: application/vnd.github.v3.raw' \
                "${CROW_REPO_API}/${src}" -o "$dest" 2>/dev/null)" || return 1
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

CROWD_APP_DIR="$HOME/.local/share/crowd/app"
CROWD_CONFIG="$HOME/.config/crowd/config.json"
CROWD_BIN="$HOME/.local/bin/crowd"

mkdir -p "$CROWD_APP_DIR/crowd" "$HOME/.local/bin"
for MODULE in __init__.py __main__.py config.py errors.py http.py playbooks.py records.py skills.py store.py; do
  if ! crowd_install_file "server/crowd/$MODULE" "$CROWD_APP_DIR/crowd/$MODULE"; then
    err "Failed to install crowd/$MODULE"
    exit 1
  fi
done
# Stale bytecode from a previous version shadows the modules we just wrote.
rm -rf "$CROWD_APP_DIR/crowd/__pycache__"
info "Installed crowd to $CROWD_APP_DIR"

cat > "$CROWD_BIN" <<LAUNCHER
#!/bin/sh
# [crow]
PYTHONPATH="$CROWD_APP_DIR\${PYTHONPATH:+:\$PYTHONPATH}" \\
  exec python3 -m crowd --config "$CROWD_CONFIG" "\$@"
LAUNCHER
chmod +x "$CROWD_BIN"
info "Installed crowd command to $CROWD_BIN"

# ─── 3. configure ────────────────────────────────────────────────────
echo ""
echo "── configure ─────────────────────────────────────"

# `init` keeps the token of an existing config, so re-running this script
# upgrades a server without invalidating the clients already connected to it.
CROWD_INIT_ARGS=(init --host "$CROWD_HOST" --port "$CROWD_PORT" --data-root "$CROWD_DATA_ROOT")
if [ -n "$CROWD_TLS_CERT" ]; then
  CROWD_INIT_ARGS+=(--tls-cert "$CROWD_TLS_CERT" --tls-key "$CROWD_TLS_KEY")
fi
"$CROWD_BIN" "${CROWD_INIT_ARGS[@]}" >/dev/null
CROWD_TOKEN="$("$CROWD_BIN" token)"
info "Config at $CROWD_CONFIG, data under $CROWD_DATA_ROOT"

# ─── 4. service ──────────────────────────────────────────────────────
echo ""
echo "── service ───────────────────────────────────────"

CROWD_STARTED=0
if [ "$CROWD_DO_SERVICE" -eq 0 ]; then
  info "Skipped starting the service (--no-service)"
elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  CROWD_UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$CROWD_UNIT_DIR"
  cat > "$CROWD_UNIT_DIR/crowd.service" <<UNIT
[Unit]
Description=Rookery session server
After=network-online.target

[Service]
ExecStart=$CROWD_BIN serve
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now crowd.service
  # Without lingering, a user unit dies the moment you log out.
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||
    warn "Could not enable lingering; crowd will stop when you log out."
  info "Started systemd user unit crowd.service"
  CROWD_STARTED=1
elif [ "$(uname -s)" = "Darwin" ]; then
  CROWD_PLIST="$HOME/Library/LaunchAgents/io.github.zobinhuang.rookery.crowd.plist"
  mkdir -p "$(dirname "$CROWD_PLIST")" "$HOME/.local/share/crowd"
  cat > "$CROWD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.zobinhuang.rookery.crowd</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CROWD_BIN</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.local/share/crowd/crowd.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/share/crowd/crowd.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/io.github.zobinhuang.rookery.crowd" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$CROWD_PLIST"
  info "Started launchd agent io.github.zobinhuang.rookery.crowd"
  CROWD_STARTED=1
else
  warn "No systemd or launchd found. Start the server by hand:"
  warn "  nohup $CROWD_BIN serve > ~/.local/share/crowd/crowd.log 2>&1 &"
fi

# ─── 5. verify ───────────────────────────────────────────────────────
if [ "$CROWD_STARTED" -eq 1 ]; then
  echo ""
  echo "── verify ────────────────────────────────────────"
  CROWD_SCHEME="http"
  [ -n "$CROWD_TLS_CERT" ] && CROWD_SCHEME="https"
  CROWD_PROBE_OK=0
  for _ in 1 2 3 4 5; do
    if curl -fsSk "$CROWD_SCHEME://127.0.0.1:$CROWD_PORT/v1/healthz" >/dev/null 2>&1; then
      CROWD_PROBE_OK=1
      break
    fi
    sleep 1
  done
  if [ "$CROWD_PROBE_OK" -eq 1 ]; then
    info "Health check passed on $CROWD_SCHEME://127.0.0.1:$CROWD_PORT"
  else
    err "Health check failed. Logs: ~/.local/share/crowd/crowd.log or journalctl --user -u crowd"
  fi
fi

# ─── done ─────────────────────────────────────────────────────────────
CROWD_ADDR="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '<host>')"
echo ""
echo "══════════════════════════════════════════════════"
echo "  Server ready"
echo ""
echo "  Run this on each client:"
echo ""
echo "    crow connect $CROWD_ADDR $CROWD_PORT --token $CROWD_TOKEN"
echo ""
if [ -z "$CROWD_TLS_CERT" ]; then
  echo "  This server speaks plain HTTP. Transcripts carry your source code,"
  echo "  paths and anything an agent printed — only expose it on a trusted"
  echo "  network, or re-run with --tls-cert/--tls-key."
  echo ""
fi
echo "══════════════════════════════════════════════════"
echo ""
