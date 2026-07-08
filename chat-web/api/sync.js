// Chat persistence: history follows the access code, not the browser.
const { db, authed } = require('./_db.js');

module.exports = async (req, res) => {
  const user = await authed(req, res);
  if (!user) return;
  const code = user.id;
  try {
    if (req.method === 'GET') {
      const rows = await db('chats?code=eq.' + encodeURIComponent(code) + '&order=updated.desc&limit=100&select=id,title,model,messages,updated,meta');
      res.json({ chats: rows });
    } else if (req.method === 'POST') {
      const c = (req.body || {}).chat;
      if (!c || !c.id) { res.status(400).json({ error: 'no chat' }); return; }
      await db('chats?on_conflict=id', {
        method: 'POST',
        body: [{
          id: String(c.id).slice(0, 40), code,
          title: String(c.title || 'New chat').slice(0, 80),
          model: String(c.model || '').slice(0, 80),
          messages: (Array.isArray(c.messages) ? c.messages : []).slice(-400),
          meta: { pinned: !!c.pinned, group: c.group ? String(c.group).slice(0, 40) : null, archived: !!c.archived },
          updated: new Date().toISOString(),
        }],
      });
      res.json({ ok: true });
    } else if (req.method === 'DELETE') {
      const id = (req.body || {}).id;
      if (!id) { res.status(400).json({ error: 'no id' }); return; }
      await db('chats?id=eq.' + encodeURIComponent(id) + '&code=eq.' + encodeURIComponent(code), { method: 'DELETE' });
      res.json({ ok: true });
    } else res.status(405).json({ error: 'nope' });
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
};
