// Automatic memory: after each exchange, a cheap model extracts durable facts
// about the user; they persist across chats and get injected into every reply.
const { db, authed, userKey } = require('./_db.js');

module.exports = async (req, res) => {
  const user = await authed(req, res);
  if (!user) return;
  const code = user.id;
  try {
    if (req.method === 'GET') {
      const rows = await db('memories?code=eq.' + encodeURIComponent(code) + '&order=created.desc&limit=100&select=id,fact,created');
      res.json({ memories: rows });
    } else if (req.method === 'DELETE') {
      const id = (req.body || {}).id;
      if (!id) { res.status(400).json({ error: 'no id' }); return; }
      await db('memories?id=eq.' + encodeURIComponent(id) + '&code=eq.' + encodeURIComponent(code), { method: 'DELETE' });
      res.json({ ok: true });
    } else if (req.method === 'POST') {
      const { user, assistant } = req.body || {};
      if (!user) { res.status(400).json({ error: 'no exchange' }); return; }
      const key = await userKey(code);
      if (!key) { res.json({ added: [] }); return; }
      const existing = await db('memories?code=eq.' + encodeURIComponent(code) + '&order=created.desc&limit=60&select=fact');
      const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: 'deepseek/deepseek-v4-flash',
          max_tokens: 300,
          messages: [{
            role: 'user',
            content: 'You maintain a memory file about a chat-assistant user. Existing memories:\n'
              + (existing.map((m) => '- ' + m.fact).join('\n') || '(none)')
              + '\n\nNew exchange:\nUser: ' + String(user).slice(0, 4000)
              + (assistant ? '\nAssistant: ' + String(assistant).slice(0, 2000) : '')
              + '\n\nExtract at most 2 NEW durable facts about the user worth remembering long-term (their name, job, people in their life, preferences, recurring tasks, tone they like). Do NOT repeat existing memories, do NOT store one-off trivia. Reply with ONLY a JSON array of strings, [] if nothing.',
          }],
        }),
      });
      const j = await r.json();
      let facts = [];
      try { facts = JSON.parse((j.choices[0].message.content.match(/\[[\s\S]*\]/) || ['[]'])[0]); } catch {}
      facts = facts.filter((f) => typeof f === 'string' && f.trim()).slice(0, 2);
      if (facts.length) {
        await db('memories', { method: 'POST', body: facts.map((fact) => ({ code, fact: fact.slice(0, 400) })) });
      }
      res.json({ added: facts });
    } else res.status(405).json({ error: 'nope' });
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
};
