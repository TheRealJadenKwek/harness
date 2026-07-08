// Streaming proxy to OpenRouter using the signed-in user's OWN key.
const { db, authed, userKey } = require('./_db.js');

// BYOK: requests bill the user's own key, so any well-formed OpenRouter model
// id is allowed (the mobile app offers the full catalog for nostalgic play).
const MODEL_OK = /^[\w.-]+\/[\w.:-]+$/;

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
  const clean = messages.map((m) => {
    const role = m.role === 'assistant' ? 'assistant' : 'user';
    if (Array.isArray(m.images) && m.images.length) {   // client gates vision by catalog; provider errors if truly unsupported
      return { role, content: [
        { type: 'text', text: String(m.content || '').slice(0, 60000) },
        ...m.images.slice(0, 4).filter((u) => typeof u === 'string' && u.startsWith('data:image/')).map((u) => ({ type: 'image_url', image_url: { url: u.slice(0, 3000000) } })),
      ] };
    }
    return { role, content: String(m.content || '').slice(0, 60000) };
  });
  let memoryBlock = '';
  try {
    const mems = await db('memories?code=eq.' + encodeURIComponent(user.id) + '&order=created.desc&limit=60&select=fact');
    if (mems.length) memoryBlock = '\n\nThings you remember about the user from earlier conversations (use them naturally, never recite the list):\n' + mems.map((m) => '- ' + m.fact).join('\n');
  } catch {}
  clean.unshift({
    role: 'system',
    content: 'You are Harness, the user\'s personal assistant — warm, sharp, and quick. You are especially good at writing and improving emails: match their natural voice, keep them concise and human, never stiff or corporate unless asked. For other tasks, be direct and genuinely useful.' + memoryBlock,
  });

  const upstream = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': 'Bearer ' + key,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://harness-chat-web.vercel.app',
      'X-Title': 'Harness Chat Web',
    },
    body: JSON.stringify({ model, messages: clean, stream: true, max_tokens: 8000, usage: { include: true }, ...(eff ? { reasoning: { effort: eff } } : {}) }),
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
