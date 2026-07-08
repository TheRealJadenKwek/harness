# Harness Chat — desktop

The web app as a native Mac + Windows app, ChatGPT-desktop style: a thin Electron shell adds a real dock icon, window chrome, ⌘N, and OS-browser sign-in (Google blocks OAuth inside app shells, so the gate hands off to your default browser and the session returns via a custom URL scheme).

Because it's a shell over [chat-web](../chat-web/), every web deploy updates the desktop app instantly.

## Download

Grab the installer from the [latest release](https://github.com/TheRealJadenKwek/harness/releases/latest) — macOS (Apple Silicon) and Windows (x64).

## Build

```bash
npm install
npm start                    # dev
npx electron-builder --mac   # or --win --x64
```
