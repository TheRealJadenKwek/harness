# Harness Code mobile — Mac server

The bridge between the [iPhone app](../ios/) and your computer's coding agents. A single-file Python server (launchd-managed) that spawns Claude Code / Codex / [Harness Code](../code/) sessions, streams their output as NDJSON over your Tailscale network, relays approvals, and mirrors Harness Code chats live between phone and desktop.

See [`../ios/README.md`](../ios/README.md) for setup.
