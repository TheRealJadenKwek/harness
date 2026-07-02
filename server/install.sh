#!/bin/bash
# Harness installer — sets up the Mac companion server that the iOS "Harness" app drives.
# Usage:  ./install.sh            install / repair (idempotent — keeps an existing token)
#         ./install.sh --update   fetch the latest server from harness-site, verify, restart
#                                 (compile-checked; auto-rolls-back if the new server won't start)
#         ./install.sh --dry-run  show what it would do, change nothing
set -euo pipefail

DRY=0; MODE=install
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --update)  MODE=update ;;
esac
say()  { printf '  %s\n' "$*"; }
head() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

DEST="$HOME/.claude-harness"
SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL="sh.harness.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT=8787

head "Harness installer"

# 0) Self-update -----------------------------------------------------------
SITE="${HARNESS_UPDATE_URL:-https://harness-site.vercel.app}"
if [ "$MODE" = update ]; then
  PY="$(command -v python3 || true)"; [ -n "$PY" ] || die "python3 not found"
  [ -f "$DEST/server.py" ] || die "no existing install at $DEST — run ./install.sh first"
  UPORT="$(grep -m1 '^HARNESS_PORT=' "$DEST/config.env" 2>/dev/null | cut -d= -f2 || true)"
  UPORT="${UPORT:-$PORT}"
  head "Updating harness from $SITE"
  for f in server.py approval_tool.py; do
    curl -fsSL "$SITE/$f" -o "$DEST/$f.new" || die "download failed: $f"
  done
  "$PY" -m py_compile "$DEST/server.py.new" || die "new server.py doesn't compile — aborting, nothing changed"
  cp "$DEST/server.py" "$DEST/server.py.prev"
  mv "$DEST/server.py.new" "$DEST/server.py"
  mv "$DEST/approval_tool.py.new" "$DEST/approval_tool.py"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
  ok=0
  for i in $(seq 1 15); do
    curl -fsS "http://127.0.0.1:$UPORT/health" >/dev/null 2>&1 && ok=1 && break || sleep 1
  done
  if [ "$ok" = 0 ]; then
    cp "$DEST/server.py.prev" "$DEST/server.py"
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
    die "new server failed its health check — ROLLED BACK to the previous version"
  fi
  VER="$(curl -fsS "http://127.0.0.1:$UPORT/health" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo '?')"
  head "✅ Updated to $VER (previous kept at server.py.prev)"
  exit 0
fi

# 1) Prerequisites ---------------------------------------------------------
head "1. Checking prerequisites"
PY="$(command -v python3 || true)";   [ -n "$PY" ]   || die "python3 not found. Install it (e.g. 'xcode-select --install')."
CLAUDE="$(command -v claude || true)"
CODEX="$(command -v codex || true)"
TS="$(command -v tailscale || true)"; [ -n "$TS" ] || TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
say "python3 : $PY"
say "claude  : ${CLAUDE:-NOT FOUND — install + log in: https://docs.anthropic.com/claude-code}"
say "codex   : ${CODEX:-NOT FOUND — install + log in: https://github.com/openai/codex}"
[ -x "$TS" ] && say "tailscale: $TS" || say "tailscale: NOT FOUND — install from https://tailscale.com/download and log in"
[ -n "$CLAUDE" ] || [ -n "$CODEX" ] || die "Need at least one of the claude / codex CLIs installed and logged in."

# 2) Files -----------------------------------------------------------------
head "2. Installing files to $DEST"
if [ ! -f "$SRC/server.py" ]; then die "server.py not found next to install.sh ($SRC)."; fi
if [ "$DRY" = 0 ]; then
  mkdir -p "$DEST" "$DEST/threads" "$DEST/trash" "$DEST/uploads"
  [ "$SRC/server.py" -ef "$DEST/server.py" ] || cp "$SRC/server.py" "$DEST/server.py"
  # Phone-side tool approval (Ask mode) relies on this MCP relay next to server.py.
  if [ -f "$SRC/approval_tool.py" ] && ! [ "$SRC/approval_tool.py" -ef "$DEST/approval_tool.py" ]; then
    cp "$SRC/approval_tool.py" "$DEST/approval_tool.py"
  fi
fi
say "server.py -> $DEST/server.py"

# 3) Token + config --------------------------------------------------------
head "3. Configuration"
if [ -f "$DEST/config.env" ] && grep -q '^HARNESS_TOKEN=' "$DEST/config.env"; then
  TOKEN="$(grep -m1 '^HARNESS_TOKEN=' "$DEST/config.env" | cut -d= -f2-)"
  say "Reusing existing token (config.env already present)."
else
  TOKEN="$("$PY" -c 'import secrets;print(secrets.token_urlsafe(24))')"
  say "Generated a new access token."
  if [ "$DRY" = 0 ]; then
    cat > "$DEST/config.env" <<EOF
# Harness config — keep this file private.
HARNESS_TOKEN=$TOKEN
HARNESS_PORT=$PORT
CLAUDE_BIN=$CLAUDE
CODEX_BIN=$CODEX
JOB_TIMEOUT=1800
MAX_MSG_CHARS=100000
# Push notifications work out of the box via the hosted relay (no Apple key needed).
RELAY_URL=https://harness-relay-production.up.railway.app
# Advanced: run your OWN APNs push instead of the relay — fill these and the relay is bypassed.
# APNS_KEY_ID=
# APNS_TEAM_ID=
# APNS_KEY_FILE=
# APNS_BUNDLE_ID=com.jadenkwek.harness
# APNS_ENV=sandbox
EOF
    chmod 600 "$DEST/config.env"
  fi
fi

# 4) LaunchAgent (auto-start at login, restart on crash) -------------------
head "4. Background service"
NODEBIN="$([ -n "$CLAUDE" ] && dirname "$CLAUDE" || ([ -n "$CODEX" ] && dirname "$CODEX" || echo /usr/local/bin))"
RUNPATH="$NODEBIN:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ "$DRY" = 0 ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$DEST/server.py</string></array>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DEST/stdout.log</string>
  <key>StandardErrorPath</key><string>$DEST/stderr.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$RUNPATH</string>
  </dict>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi
say "LaunchAgent: $PLIST  (label $LABEL)"

# 5) Verify + connection details ------------------------------------------
head "5. Verifying"
if [ "$DRY" = 0 ]; then
  for i in $(seq 1 15); do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break || sleep 1
  done
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || die "Server didn't come up — check $DEST/stderr.log"
fi
TSIP='<your-mac-tailscale-ip>'
[ -x "$TS" ] && TSIP="$("$TS" ip -4 2>/dev/null | sed -n '1p')" && [ -n "$TSIP" ] || TSIP='<your-mac-tailscale-ip>'
head "✅ Done. In the iOS app → gear → enter:"
printf '\n   URL    \033[1mhttp://%s:%s\033[0m\n' "$TSIP" "$PORT"
printf   '   Token  \033[1m%s\033[0m\n\n' "$TOKEN"
say "Make sure your iPhone is logged into the SAME Tailscale account."
say "Prefer scanning? Open http://127.0.0.1:$PORT/pair on this Mac for a QR code."
[ "$DRY" = 1 ] && head "(dry run — nothing was written or started)"
