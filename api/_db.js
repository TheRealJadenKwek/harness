// Supabase REST helper + auth. Users sign in with Supabase Auth (Google);
// every route verifies the JWT and works with that user's id. The anon key
// lives only in the Vercel env.
async function db(path, { method = 'GET', body, headers = {} } = {}) {
  const r = await fetch(process.env.SUPABASE_URL + '/rest/v1/' + path, {
    method,
    headers: {
      'apikey': process.env.SUPABASE_KEY,
      'Authorization': 'Bearer ' + process.env.SUPABASE_KEY,
      'Content-Type': 'application/json',
      'Prefer': 'return=representation,resolution=merge-duplicates',
      ...headers,
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  if (!r.ok) throw new Error('db ' + r.status + ': ' + (await r.text()).slice(0, 200));
  const text = await r.text();
  return text ? JSON.parse(text) : null;
}

// Verify the user's Supabase JWT → { id, email }, or respond 401.
async function authed(req, res) {
  const jwt = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!jwt) { res.status(401).json({ error: 'sign in first' }); return null; }
  const r = await fetch(process.env.SUPABASE_URL + '/auth/v1/user', {
    headers: { 'apikey': process.env.SUPABASE_KEY, 'Authorization': 'Bearer ' + jwt },
  });
  if (!r.ok) { res.status(401).json({ error: 'session expired — sign in again' }); return null; }
  const u = await r.json();
  if (!u || !u.id) { res.status(401).json({ error: 'sign in first' }); return null; }
  return { id: u.id, email: u.email || '' };
}

// The user's own OpenRouter key (BYOK). null → they need to add one.
async function userKey(userId) {
  const rows = await db('profiles?user_id=eq.' + encodeURIComponent(userId) + '&select=openrouter_key');
  const k = rows[0] && rows[0].openrouter_key;
  return k && k.startsWith('sk-or-') ? k : null;
}

module.exports = { db, authed, userKey };
