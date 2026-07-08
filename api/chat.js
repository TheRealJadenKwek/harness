// Streaming proxy to OpenRouter. The API key lives ONLY here (server env);
// the browser sends an access code instead.
const { db } = require('./_db.js');

const ALLOWED = new Set([
  'deepseek/deepseek-v4-pro',
  'deepseek/deepseek-v4-flash',
  'anthropic/claude-sonnet-5',
]);

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const code = req.headers['x-access-code'] || '';
  if (!process.env.ACCESS_CODE || code !== process.env.ACCESS_CODE) {
    res.status(401).json({ error: 'bad access code' }); return;
  }
  const { model, messages } = req.body || {};
  if (!ALLOWED.has(model)) { res.status(400).json({ error: 'unknown model' }); return; }
  if (!Array.isArray(messages) || !messages.length || messages.length > 400) {
    res.status(400).json({ error: 'bad messages' }); return;
  }
  const clean = messages.map((m) => ({
    role: m.role === 'assistant' ? 'assistant' : 'user',
    content: String(m.content || '').slice(0, 60000),
  }));
  let memoryBlock = '';
  try {
    const mems = await db('memories?code=eq.' + encodeURIComponent(code) + '&order=created.desc&limit=60&select=fact');
    if (mems.length) memoryBlock = '\n\nThings you remember about her from earlier conversations (use them naturally, never recite the list):\n' + mems.map((m) => '- ' + m.fact).join('\n');
  } catch {}
  clean.unshift({
    role: 'system',
    content: 'You are Harness, her personal assistant — warm, sharp, and quick. You are especially good at writing and improving emails: match her natural voice, keep them concise and human, never stiff or corporate unless she asks. For other tasks, be direct and genuinely useful.' + memoryBlock,
  });

  const upstream = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + process.env.OPENROUTER_API_KEY,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://harness.local',
      'X-Title': 'Harness Chat Web',
    },
    body: JSON.stringify({ model, messages: clean, stream: true, max_tokens: 8000 }),
  });

  if (!upstream.ok) {
    const err = await upstream.text();
    res.status(upstream.status).json({ error: err.slice(0, 300) });
    return;
  }
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  const reader = upstream.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      res.write(value);
    }
  } catch {}
  res.end();
};
