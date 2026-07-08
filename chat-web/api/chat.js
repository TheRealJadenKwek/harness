// Agentic streaming proxy: tool-capable models get web_search + create_file.
// The server runs searches; file specs are forwarded to the client, which
// builds the actual PDF/XLSX/PPTX/text artifact as a download.
const { db, authed, userKey } = require('./_db.js');

const MODEL_OK = /^[\w.-]+\/[\w.:-]+$/;
const MAX_ROUNDS = 6;

async function fetchPage(url) {
  if (!/^https?:\/\//i.test(url)) url = 'https://' + url;
  try {
    const r = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh) HarnessChat', 'Accept': 'text/html,*/*' }, signal: AbortSignal.timeout(15000) });
    if (!r.ok) return { error: 'HTTP ' + r.status };
    const ct = r.headers.get('content-type') || '';
    if (!/text\/html|text\/plain|application\/xhtml/.test(ct)) return { error: 'not a readable page (' + ct.split(';')[0] + ')' };
    let html = (await r.text()).slice(0, 900000);
    const title = (/<title[^>]*>([\s\S]*?)<\/title>/i.exec(html) || [])[1] || '';
    html = html.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ')
               .replace(/<nav[\s\S]*?<\/nav>/gi, ' ').replace(/<footer[\s\S]*?<\/footer>/gi, ' ')
               .replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#\d+;/g, ' ')
               .replace(/\s+/g, ' ').trim();
    return { url, title: title.trim(), text: html.slice(0, 12000) + (html.length > 12000 ? ' …[truncated]' : '') };
  } catch (e) { return { error: String(e.message || e).slice(0, 120) }; }
}

const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'web_search',
      description: 'Search the web (DuckDuckGo). Returns top results as {title, url, snippet}. Use for anything current: news, prices, facts you are unsure of, links.',
      parameters: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'fetch_page',
      description: 'Fetch a web page and return its readable text (title + ~12k chars). Use after web_search to actually READ a promising result, or when the user gives you a URL.',
      parameters: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'generate_image',
      description: 'Generate an image from a text prompt (billed to the user\'s key). Returns the image directly to the user as a card. Use when the user asks you to draw, create, or generate a picture/illustration/logo.',
      parameters: { type: 'object', properties: { prompt: { type: 'string' } }, required: ['prompt'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'run_code',
      description: 'Execute code on the user\'s device and get the output. language "python" (scientific stack available) or "javascript". The result arrives in the user\'s NEXT message (the run happens client-side) — so after calling this, briefly say what you are computing and STOP; continue when the result comes back.',
      parameters: { type: 'object', properties: { language: { type: 'string', enum: ['python', 'javascript'] }, code: { type: 'string' } }, required: ['language', 'code'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'create_file',
      description: 'Create a downloadable file for the user. kind "text" (any single plain-text file: .txt/.md/.csv/.py/code) needs {filename, content}. kind "html" (a web page, game, or interactive app — the user gets a LIVE PREVIEW button plus download; make it fully self-contained, inline CSS/JS) needs {filename, content}. kind "zip" (multi-file projects: a Python app, a game with several modules, a website) needs {filename, files:[{path, content}]}. kind "pdf" needs {filename, title, body} (plain text, blank lines separate paragraphs). kind "xlsx" needs {filename, sheets:[{name, rows:[[cell,…],…]}]} — first row is the header. kind "pptx" needs {filename, slides:[{title, bullets:[…], notes?}]}. Prefer this over pasting long content into chat.',
      parameters: { type: 'object', properties: {
        kind: { type: 'string', enum: ['text', 'html', 'zip', 'pdf', 'xlsx', 'pptx'] },
        filename: { type: 'string' },
        content: { type: 'string' },
        title: { type: 'string' },
        body: { type: 'string' },
        files: { type: 'array', items: { type: 'object', properties: {
          path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'] } },
        sheets: { type: 'array', items: { type: 'object', properties: {
          name: { type: 'string' }, rows: { type: 'array', items: { type: 'array' } } } } },
        slides: { type: 'array', items: { type: 'object', properties: {
          title: { type: 'string' }, bullets: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } } } },
      }, required: ['kind', 'filename'] },
    },
  },
];

async function webSearch(q) {
  const body = await fetch('https://html.duckduckgo.com/html/', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': 'Mozilla/5.0 (Macintosh) HarnessChat' },
    body: 'q=' + encodeURIComponent(q),
  }).then((r) => r.text()).catch(() => null);
  if (!body) return { error: 'search failed' };
  const results = [];
  const re = /<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?class="result__snippet"[^>]*>([\s\S]*?)<\/a>/g;
  const strip = (h) => (h || '').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/\s+/g, ' ').trim();
  let m;
  while ((m = re.exec(body)) && results.length < 8) {
    let url = m[1];
    const uddg = /[?&]uddg=([^&]+)/.exec(url);
    if (uddg) { try { url = decodeURIComponent(uddg[1]); } catch {} }
    results.push({ title: strip(m[2]), url, snippet: strip(m[3]).slice(0, 300) });
  }
  return results.length ? { query: q, results } : { error: 'no results' };
}

// which models can do native tool calls (catalog cached while the function is warm)
let toolModels = null, toolModelsAt = 0;
async function supportsTools(model, key) {
  if (!toolModels || Date.now() - toolModelsAt > 3600e3) {
    try {
      const r = await fetch('https://openrouter.ai/api/v1/models', { headers: { 'Authorization': 'Bearer ' + key } });
      const data = (await r.json()).data || [];
      toolModels = new Set(data.filter((m) => (m.supported_parameters || []).includes('tools')).map((m) => m.id));
      toolModelsAt = Date.now();
    } catch { return true; }   // unknown → try; worst case the provider ignores it
  }
  return toolModels.has(model);
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const user = await authed(req, res);
  if (!user) return;
  const key = await userKey(user.id);
  if (!key) { res.status(402).json({ error: 'no_key' }); return; }

  const { model, messages, effort } = req.body || {};
  const eff = ['low', 'medium', 'high'].includes(effort) ? effort : null;
  if (typeof model !== 'string' || !MODEL_OK.test(model)) { res.status(400).json({ error: 'bad model id' }); return; }
  if (!Array.isArray(messages) || !messages.length || messages.length > 400) {
    res.status(400).json({ error: 'bad messages' }); return;
  }
  const convo = messages.map((m) => {
    const role = m.role === 'assistant' ? 'assistant' : 'user';
    if (Array.isArray(m.images) && m.images.length) {
      return { role, content: [
        { type: 'text', text: String(m.content || '').slice(0, 60000) },
        ...m.images.slice(0, 4).filter((u) => typeof u === 'string' && u.startsWith('data:image/')).map((u) => ({ type: 'image_url', image_url: { url: u.slice(0, 3000000) } })),
      ] };
    }
    return { role, content: String(m.content || '').slice(0, 60000) };
  });

  const toolsOK = await supportsTools(model, key);
  let memoryBlock = '';
  try {
    const mems = await db('memories?code=eq.' + encodeURIComponent(user.id) + '&order=created.desc&limit=60&select=fact');
    if (mems.length) memoryBlock = '\n\nThings you remember about the user from earlier conversations (use them naturally, never recite the list):\n' + mems.map((m) => '- ' + m.fact).join('\n');
  } catch {}
  convo.unshift({
    role: 'system',
    content: 'You are Harness, the user\'s personal assistant — warm, sharp, and quick. You are especially good at writing and improving emails: match their natural voice, keep them concise and human, never stiff or corporate unless asked. For other tasks, be direct and genuinely useful.'
      + (toolsOK ? '\n\nYou have tools. Use web_search for current information, then fetch_page to actually read a promising result (search snippets alone are shallow — read before you summarize or cite). Use generate_image when asked to draw or create a picture. Use run_code for calculations, data analysis, or anything better computed than guessed. Use create_file whenever the user wants a document, spreadsheet, presentation, web page, app, game, or any file: deliver a real artifact (pdf/xlsx/pptx/html with live preview/zip for multi-file projects/plain text) instead of pasting long content into the chat, then briefly say what you made.' : '')
      + memoryBlock,
  });

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  const send = (obj) => res.write('data: ' + JSON.stringify(obj) + '\n\n');

  try {
    for (let round = 0; round < MAX_ROUNDS; round++) {
      const upstream = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + key,
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://harness-chat-web.vercel.app',
          'X-Title': 'Harness Chat Web',
        },
        body: JSON.stringify({
          model, messages: convo, stream: true, max_tokens: 8000, usage: { include: true },
          ...(toolsOK ? { tools: TOOLS } : {}),
          ...(eff ? { reasoning: { effort: eff } } : {}),
        }),
      });
      if (!upstream.ok) {
        const err = await upstream.text();
        send({ harness: { error: err.slice(0, 300) } });
        break;
      }
      // parse this round's SSE: forward text deltas + usage, assemble tool calls
      const reader = upstream.body.getReader();
      const dec = new TextDecoder();
      let buf = '', content = '';
      const calls = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
          if (!line.startsWith('data:')) continue;
          const payload = line.slice(5).trim();
          if (payload === '[DONE]') continue;
          let d; try { d = JSON.parse(payload); } catch { continue; }
          if (d.usage) send({ usage: d.usage });
          const ch = d.choices && d.choices[0];
          if (!ch) continue;
          const delta = ch.delta || {};
          if (delta.content) { content += delta.content; send({ choices: [{ delta: { content: delta.content } }] }); }
          if (delta.tool_calls) {
            for (const tc of delta.tool_calls) {
              const i = tc.index || 0;
              if (!calls[i]) calls[i] = { id: '', type: 'function', function: { name: '', arguments: '' } };
              if (tc.id) calls[i].id = tc.id;
              if (tc.function) {
                if (tc.function.name) calls[i].function.name = tc.function.name;
                if (tc.function.arguments) calls[i].function.arguments += tc.function.arguments;
              }
            }
          }
        }
      }
      const toolCalls = calls.filter(Boolean);
      if (!toolCalls.length) break;   // no tools → that was the final answer

      convo.push({ role: 'assistant', content: content || '', tool_calls: toolCalls });
      for (const tc of toolCalls) {
        let args = {};
        try { args = JSON.parse(tc.function.arguments || '{}'); } catch {}
        let result;
        if (tc.function.name === 'web_search') {
          send({ harness: { tool: 'web_search', status: 'run', detail: String(args.query || '').slice(0, 80) } });
          result = await webSearch(String(args.query || ''));
          send({ harness: { tool: 'web_search', status: 'done', detail: result.results ? result.results.length + ' results' : (result.error || '') } });
        } else if (tc.function.name === 'fetch_page') {
          send({ harness: { tool: 'fetch_page', status: 'run', detail: String(args.url || '').slice(0, 80) } });
          result = await fetchPage(String(args.url || ''));
          send({ harness: { tool: 'fetch_page', status: 'done', detail: result.title ? result.title.slice(0, 60) : (result.error || '') } });
        } else if (tc.function.name === 'generate_image') {
          send({ harness: { tool: 'generate_image', status: 'run', detail: String(args.prompt || '').slice(0, 80) } });
          try {
            const ir = await fetch('https://openrouter.ai/api/v1/chat/completions', {
              method: 'POST',
              headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' },
              body: JSON.stringify({ model: 'google/gemini-3.1-flash-image', modalities: ['image', 'text'],
                                     messages: [{ role: 'user', content: String(args.prompt || '').slice(0, 2000) }] }),
            });
            const ij = await ir.json();
            const imgs = (((ij.choices || [])[0] || {}).message || {}).images || [];
            const dataUrl = imgs[0] && imgs[0].image_url && imgs[0].image_url.url;
            if (dataUrl) {
              send({ harness: { file: { kind: 'image', filename: 'image.png', dataUrl: String(dataUrl).slice(0, 8000000) } } });
              send({ harness: { tool: 'generate_image', status: 'done', detail: 'image delivered' } });
              result = { ok: true, note: 'image generated and shown to the user — do not describe it exhaustively, just confirm briefly' };
            } else {
              send({ harness: { tool: 'generate_image', status: 'done', detail: 'no image returned' } });
              result = { error: (ij.error && ij.error.message) || 'model returned no image' };
            }
          } catch (e) { result = { error: String(e.message || e).slice(0, 200) }; }
        } else if (tc.function.name === 'run_code') {
          const spec = { language: args.language === 'javascript' ? 'javascript' : 'python', code: String(args.code || '').slice(0, 100000) };
          send({ harness: { exec: spec } });
          result = { status: 'running on the user\'s device — the output will arrive in the next user message. Stop here and wait for it.' };
        } else if (tc.function.name === 'create_file') {
          const spec = {
            kind: ['text', 'html', 'zip', 'pdf', 'xlsx', 'pptx'].includes(args.kind) ? args.kind : 'text',
            filename: String(args.filename || 'file.txt').slice(0, 80),
            content: typeof args.content === 'string' ? args.content.slice(0, 400000) : undefined,
            title: typeof args.title === 'string' ? args.title.slice(0, 200) : undefined,
            body: typeof args.body === 'string' ? args.body.slice(0, 400000) : undefined,
            files: Array.isArray(args.files) ? args.files.slice(0, 40).map((f) => ({ path: String(f.path || 'file.txt').slice(0, 120), content: String(f.content || '').slice(0, 400000) })) : undefined,
            sheets: Array.isArray(args.sheets) ? args.sheets.slice(0, 10) : undefined,
            slides: Array.isArray(args.slides) ? args.slides.slice(0, 40) : undefined,
          };
          send({ harness: { file: spec } });
          result = { ok: true, note: 'file "' + spec.filename + '" delivered to the user as a download card — do not repeat its contents in chat' };
        } else {
          result = { error: 'unknown tool' };
        }
        convo.push({ role: 'tool', tool_call_id: tc.id, name: tc.function.name, content: JSON.stringify(result).slice(0, 60000) });
      }
      // loop → next round streams the model's follow-up
    }
  } catch (e) {
    try { send({ harness: { error: String(e.message || e).slice(0, 200) } }); } catch {}
  }
  res.write('data: [DONE]\n\n');
  res.end();
};
