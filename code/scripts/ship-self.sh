#!/bin/bash
# ship-self.sh — deploy ~/harness-code/src into the installed app, SAFELY.
# Designed to be run BY the Harness Code agent from inside the app:
#   nohup ~/harness-code/scripts/ship-self.sh >/tmp/hc-selfship.log 2>&1 & disown
# It survives the app restarting (which kills the agent's turn), validates the
# source first, health-checks the relaunched app, and AUTO-ROLLS-BACK if the
# new build doesn't come up — so a remote phone session can never brick itself.
set -u
REPO="$HOME/harness-code"
APPDIR="/Applications/Harness Code.app/Contents/Resources/app"
BACKUP="$HOME/.harness-code/bundle-backup"
IDENTITY="Apple Development: JADEN CALEB KWEK (Y3L6295L7T)"
say() { echo "[$(date '+%H:%M:%S')] $*"; }

# 1. validate every JS file compiles — refuse to ship broken source
say "validating source…"
FAIL=0
while IFS= read -r f; do
  if ! node --check "$f" 2>/tmp/hc-ship-checkerr; then
    say "SYNTAX ERROR in $f:"; cat /tmp/hc-ship-checkerr; FAIL=1
  fi
done < <(find "$REPO/src" -name '*.js' -not -path '*node_modules*')
[ "$FAIL" = 1 ] && { say "ABORTED — fix the errors and re-run."; exit 1; }

# 2. back up the currently-running bundle (known good)
say "backing up current bundle…"
rm -rf "$BACKUP" && mkdir -p "$BACKUP"
cp -R "$APPDIR/src" "$BACKUP/src"

# 3. deploy + sign
say "deploying…"
rsync -a --delete "$REPO/src/" "$APPDIR/src/"
rsync -a "$REPO/assets/" "$APPDIR/assets/" 2>/dev/null
codesign --force --deep --sign "$IDENTITY" "/Applications/Harness Code.app" 2>&1 | tail -1

# 4. restart the app (this kills the agent turn that launched us — expected)
say "restarting the app…"
pkill -f "Harness Code.app" 2>/dev/null
sleep 2
open -a "Harness Code"

# 5. health check: the app's local API must answer within 45s
say "health check…"
TOKEN=$(cat "$HOME/.harness-code/api-token" 2>/dev/null)
for i in $(seq 1 45); do
  sleep 1
  PORT=$(cat "$HOME/.harness-code/api-port" 2>/dev/null)
  [ -z "$PORT" ] && continue
  if curl -s --max-time 2 -H "X-HC-Token: $TOKEN" "http://127.0.0.1:$PORT/api/sessions" | grep -q '\['; then
    say "HEALTHY — new build is live (took ${i}s)."
    exit 0
  fi
done

# 6. the new build never came up — roll back to the known-good bundle
say "UNHEALTHY — rolling back…"
pkill -f "Harness Code.app" 2>/dev/null
sleep 1
rsync -a --delete "$BACKUP/src/" "$APPDIR/src/"
codesign --force --deep --sign "$IDENTITY" "/Applications/Harness Code.app" 2>&1 | tail -1
open -a "Harness Code"
sleep 8
say "ROLLED BACK — the previous build is running again. Check your changes."
exit 2
