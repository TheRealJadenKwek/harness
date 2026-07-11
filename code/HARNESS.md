# Harness Code — self-development guide

This repo IS the app you are running inside. You can develop it from here — including
from Jaden's phone — but follow this procedure exactly:

1. Edit files under `src/` only. NEVER edit `/Applications/Harness Code.app/...` directly.
2. After edits, syntax-check what you touched: `node --check src/main/main.js` etc.
3. To ship, run the safe deployer DETACHED (it must survive the app restarting):
   `nohup ~/harness-code/scripts/ship-self.sh >/tmp/hc-selfship.log 2>&1 & disown`
   then tell Jaden: "shipping — this restarts the app, so THIS TURN WILL DIE.
   Reopen the thread in ~30s and ask me to check /tmp/hc-selfship.log".
4. The script validates all JS first, backs up the running bundle, deploys, signs,
   restarts, health-checks the API for 45s, and AUTO-ROLLS-BACK if the new build
   doesn't come up. Exit meanings in the log: HEALTHY / ABORTED (syntax) / ROLLED BACK.
5. After a successful ship, verify the change actually works, THEN commit:
   the repo is a symlink into the ~/harness monorepo — prefix commits with `code:`
   and only `git add` files you changed (Jaden runs parallel sessions).
6. Renderer-only changes still need a full ship (the bundle is a copy, not a link).

Architecture crash course: `src/main/main.js` (Electron main: sessions, tools, MCP,
API server on ~/.harness-code/api-port), `src/agent/agent.js` (the agent loop),
`src/agent/mcp.js` + `mcp-oauth.js` (MCP client), `src/renderer/` (UI, no framework).
