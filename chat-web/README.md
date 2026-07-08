# Harness Chat — web

**[harness-chat-web.vercel.app](https://harness-chat-web.vercel.app)** — a ChatGPT-style, bring-your-own-key AI chat app.

- **Any model** — a curated default list (MiniMax M3, DeepSeek V4 Pro/Flash, Nemotron free) plus search across the full OpenRouter catalog, with real pricing shown
- **Tools** — web search with live status, and downloadable artifacts: PDF, Excel, PowerPoint, HTML with live preview, zipped multi-file projects
- **Automatic memory** — a cheap model extracts durable facts after each exchange; every reply gets them injected; view/delete anytime, export everything as JSON
- **Optional accounts** — Sign in with Apple or Google purely for sync between web, desktop, and iPhone; guest mode keeps chats in the browser and calls OpenRouter directly
- **Honest numbers** — exact per-chat spend (provider-billed cost, not estimates), % of context used, automatic compaction at 70%
- Claude-style niceties: effort levels, hover copy on every message, rewind, forking, quote-a-selection, pin/rename/archive/groups via right-click

## Stack

One static `index.html` (zero-dependency vanilla JS) + Vercel serverless functions (`api/`) + Supabase (auth, chats, memories). The user's OpenRouter key is stored server-side per account and never ships to the browser; guest keys never leave the browser.

## Deploy your own

```bash
npx vercel deploy --prod   # set env: SUPABASE_URL, SUPABASE_KEY (anon), and create the tables in db (see api/_db.js)
```
