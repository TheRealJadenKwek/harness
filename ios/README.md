# Harness Code mobile

**Your computer's AI coding CLIs, as a native iPhone app.**

Harness turns Claude Code, Codex, and [Harness Code](../code) (an open, any-model desktop agent — 340+ models via OpenRouter) running on your own Mac or Windows PC into a phone-first experience: start threads, watch replies stream with full markdown, read reasoning summaries, review the diffs and files your agents produce, answer their questions with a tap, and get a push notification when a long task finishes — from anywhere, over your own private [Tailscale](https://tailscale.com) network.

Your computer does the work; your phone is the remote. No accounts, no middleman, no data leaves your devices.

| Threads | Chat | Reasoning & cost | Live preview |
|---|---|---|---|
| ![Threads](../docs/screenshots/threads.png) | ![Chat](../docs/screenshots/chat.png) | ![Codex](../docs/screenshots/codex.png) | ![Preview](../docs/screenshots/preview.png) |

## How it works

```
iPhone (SwiftUI app)  ──Tailscale──▶  harness server on your Mac/PC (stdlib Python, :8787)
                                        ├─▶ claude -p … --resume   (Claude Code)
                                        └─▶ codex exec --json …    (Codex)
```

- The server is a single-file, dependency-free Python HTTP+SSE server that fronts the CLIs you already have installed and logged in. Each thread is an independent, resumable CLI session.
- Transport is your own tailnet. The server binds locally and only accepts connections from loopback and the Tailscale CGNAT range, plus a bearer token generated at install.
- Turns run as detached jobs on the Mac — close the app mid-task and (optionally) get an APNs push when the answer is ready.

## Quick start

**1. Server** — Mac *or* Windows (requires Python 3, Tailscale, and at least one of the `claude` / `codex` CLIs):

macOS:

```sh
mkdir -p ~/harness-server && cd ~/harness-server
curl -fsSLO https://harness-site.vercel.app/server.py
curl -fsSLO https://harness-site.vercel.app/install.sh
bash install.sh
```

Windows (PowerShell):

```powershell
mkdir $env:USERPROFILE\harness-server; cd $env:USERPROFILE\harness-server
curl.exe -fsSLO https://harness-site.vercel.app/server.py
curl.exe -fsSLO https://harness-site.vercel.app/install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1
```

Either installer generates your private token, sets the server to start at login and restart on crash (LaunchAgent on macOS, Task Scheduler on Windows), opens the firewall where needed, and prints the URL + token for the app. `uninstall.sh` / removing the `HarnessServer` scheduled task reverses it.

**2. iPhone app**: App Store (pending review) — or build from source:

```sh
brew install xcodegen
cd ios && xcodegen generate
open ClaudeHarness.xcodeproj   # set your team, build to your phone
```

No Mac handy? The app ships with a fully offline **demo mode** ("Explore the demo" on the welcome screen).

## Features

- Multiple concurrent threads, each with its own engine, model, working directory, permission mode, and reasoning effort
- **Phone-side tool approval**: in Ask mode, gated tool uses (shell commands, file edits) freeze the turn and surface on your phone — as an in-app Allow/Deny card and as an actionable push notification — exactly like pressing y/n in the terminal. Deny is safe-by-default on timeout, and approving from the lockscreen requires unlocking
- Streaming replies with markdown, code blocks, collapsible thought-process disclosures, and tool-activity timelines (with red/green diffs for edits)
- Per-message token/cost readouts and usage-limit tracking
- Preview HTML, PDFs, images, and code your agents create — rendered on the phone, scoped and sandboxed on the Mac
- Tappable multiple-choice answers when Claude asks structured questions
- Voice dictation (on-device), image attachments, slash-command palette
- Archive, trash with 30-day recovery, search, drafts, deep-linked push notifications
- Server-driven model catalog: add any new model id to `providers.json` and it appears in the app's picker — no rebuild
- Bring-your-own-key providers (any Anthropic- or OpenAI-compatible endpoint) via `providers.json`

## Bring your own engine

Beyond the Claude and Codex CLIs, Harness fronts **[Harness Code](../code)** — a from-scratch desktop coding agent that runs on any of 340+ OpenRouter models. Chats with that engine are *shared live*: the session exists in the desktop app, so a message sent from your phone streams on your Mac's screen in real time, and either device can continue any conversation. New engines are a single generator function in `server/server.py`.

## Security model

- The server never listens beyond your machine + tailnet, and every request (except `/health`) requires the bearer token.
- File preview is path-scoped to each thread's working directory with a denylist for keys, dotfiles, and credentials; HTML previews get a no-network CSP.
- The app stores your server URL and token locally on-device only.
- No analytics, no telemetry, no third-party services. [Privacy policy](https://harness-site.vercel.app/privacy).

## Roadmap / ideas

Contributions welcome — these are good places to start. Open an issue or PR if you want to take one on.

- **Home-screen widget.** A WidgetKit target already exists (it powers the Live Activity). A widget showing running threads, the last automation result, or your usage-window status is mostly a new view against the same `/threads` and `/usage` endpoints.
- **iPad / Mac Catalyst layout.** The app is iPhone-only today (`TARGETED_DEVICE_FAMILY: "1"`). A split-view layout — thread list beside the open thread — would make it a first-class iPad and desktop client.
- **HMR tunnel reconnect.** The WebSocket dev-server tunnel works; it could auto-reconnect if the dev server restarts, instead of needing a manual reload.
- **Codex phone-side approval.** Ask-mode approvals are Claude-only, because `codex exec` has no `--permission-prompt-tool` equivalent yet. Wire it up if/when the Codex CLI grows a permission hook.
- **Android client.** The server is a plain HTTP+SSE API — nothing iOS-specific about it. A Kotlin/Compose client could talk to the same harness.

## License

MIT — see [LICENSE](LICENSE).

Harness is an independent project, not affiliated with Anthropic or OpenAI. Claude Code and Codex run under your own subscriptions.
