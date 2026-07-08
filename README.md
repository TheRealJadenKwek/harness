# Harness Chat

**A ChatGPT-style iPhone app for OpenRouter — every model, one key, zero servers.**

The playful sibling of [Harness Code](https://github.com/TheRealJadenKwek/harness-code): where that is a full desktop coding agent, this is just chat — pick any of 340+ OpenRouter models (frontier, open-source, or the nostalgic dumb ones you miss) and talk. Messages go straight from your phone to OpenRouter; history stays on-device; the key lives in your Keychain.

- Streaming replies with light markdown + code blocks
- Full model catalog: search, ★ favourites sorted to the top, or type any model id
- Per-chat model switching, model-remembering default
- Local chat history, swipe to delete
- SwiftUI, ~600 lines, no dependencies

## Build

```bash
brew install xcodegen
xcodegen && open HarnessChat.xcodeproj   # set your team, run on device
```

Paste your OpenRouter key in Settings on first launch. MIT.
