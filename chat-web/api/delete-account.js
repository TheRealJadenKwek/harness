// App Store 5.1.1(v): full in-app account deletion. Calls the delete_user()
// SECURITY DEFINER function with the USER'S OWN JWT — it wipes chats, memories,
// the profile (including the stored OpenRouter key), and the auth user itself.
const { authed } = require('./_db.js');

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const user = await authed(req, res);
  if (!user) return;
  const jwt = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  try {
    const r = await fetch(process.env.SUPABASE_URL + '/rest/v1/rpc/delete_user', {
      method: 'POST',
      headers: {
        'apikey': process.env.SUPABASE_KEY,
        'Authorization': 'Bearer ' + jwt,      // runs as the user — auth.uid() scopes the wipe
        'Content-Type': 'application/json',
      },
      body: '{}',
    });
    if (!r.ok) throw new Error('delete failed: ' + (await r.text()).slice(0, 200));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
};
