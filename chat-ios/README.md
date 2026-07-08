# Harness Chat — iOS

**Every AI model in your pocket — cloud, or fully on-device.**

The iPhone member of the Harness Chat family. Same account, chats, memory, and OpenRouter key as the [web](../chat-web/) and [desktop](../chat-desktop/) apps — or no account at all.

- **Full OpenRouter catalog** with curated defaults, search, ★ favourites, live pricing
- **On-device MLX models** (MiniCPM5 1B, Qwen3) — download once, chat in airplane mode, free, with a Think/No-think toggle
- **Tools** — web search status lines and tappable file cards (PDF renders natively; Excel/PowerPoint/zip build in a hidden WebView with the same libraries as the web app, then hand off to the share sheet)
- **Optional sign-in** (Apple or Google) adds sync + memory; guest mode keeps everything on the phone with a locally-stored key, and upgrading later is lossless
- Parallel chats, per-chat effort levels, spend + context stats, long-press copy/rewind/fork

## Build

```bash
brew install xcodegen
xcodegen && open HarnessChat.xcodeproj   # set your team, run on device
```

MIT.
