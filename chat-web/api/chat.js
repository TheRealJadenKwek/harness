// Agentic streaming proxy: tool-capable models get web_search + create_file.
// The server runs searches; file specs are forwarded to the client, which
// builds the actual PDF/XLSX/PPTX/text artifact as a download.
const { db, authed, userKey } = require('./_db.js');

const MODEL_OK = /^[\w.-]+\/[\w.:-]+$/;
const MAX_ROUNDS = 6;

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
      name: 'create_file',
      description: 'Create a downloadable file for the user. kind "text" (any plain text: .txt/.md/.csv/code) needs {filename, content}. kind "pdf" needs {filename, title, body} (body = plain text, blank lines separate paragraphs). kind "xlsx" needs {filename, sheets:[{name, rows:[[cell,…],…]}]} — first row is the header. kind "pptx" needs {filename, slides:[{title, bullets:[…], notes?}]}. Prefer this over pasting long documents/tables/decks into chat.',
      parameters: { type: 'object', properties: {
        kind: { type: 'string', enum: ['text', 'pdf', 'xlsx', 'pptx'] },
        filename: { type: 'string' },
        content: { type: 'string' },
        title: { type: 'string' },
        body: { type: 'string' },
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
      + (toolsOK ? '\n\nYou have tools. Use web_search whenever current or verifiable information would help — news, prices, facts, links. Use create_file whenever the user wants a document, spreadsheet, presentation, or any file: deliver a real download (pdf/xlsx/pptx/text) instead of pasting long content into the chat, then briefly say what you made.' : '')
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
        } else if (tc.function.name === 'create_file') {
          const spec = {
            kind: ['text', 'pdf', 'xlsx', 'pptx'].includes(args.kind) ? args.kind : 'text',
            filename: String(args.filename || 'file.txt').slice(0, 80),
            content: typeof args.content === 'string' ? args.content.slice(0, 400000) : undefined,
            title: typeof args.title === 'string' ? args.title.slice(0, 200) : undefined,
            body: typeof args.body === 'string' ? args.body.slice(0, 400000) : undefined,
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
