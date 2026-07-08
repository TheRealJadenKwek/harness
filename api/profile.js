// The user's own OpenRouter key: validated against OpenRouter, stored per account.
const { db, authed } = require('./_db.js');

module.exports = async (req, res) => {
  const user = await authed(req, res);
  if (!user) return;
  try {
    if (req.method === 'GET') {
      const rows = await db('profiles?user_id=eq.' + encodeURIComponent(user.id) + '&select=openrouter_key');
      const k = rows[0] && rows[0].openrouter_key;
      res.json({ email: user.email, hasKey: !!k, keyTail: k ? '…' + k.slice(-4) : null });
    } else if (req.method === 'POST') {
      const key = String((req.body || {}).key || '').trim();
      if (!key.startsWith('sk-or-')) { res.status(400).json({ error: 'that doesn\'t look like an OpenRouter key (they start with sk-or-)' }); return; }
      const check = await fetch('https://openrouter.ai/api/v1/key', { headers: { 'Authorization': 'Bearer ' + key } });
      if (!check.ok) { res.status(400).json({ error: 'OpenRouter rejected that key — copy it again from openrouter.ai/settings/keys' }); return; }
      await db('profiles?on_conflict=user_id', { method: 'POST', body: [{ user_id: user.id, email: user.email, openrouter_key: key }] });
      res.json({ ok: true, keyTail: '…' + key.slice(-4) });
    } else res.status(405).json({ error: 'nope' });
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
};
