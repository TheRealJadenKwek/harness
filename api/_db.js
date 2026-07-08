// Supabase REST helper. The key lives only in the Vercel env — every route
// validates the user's access code before touching the DB.
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

function authed(req, res) {
  const code = req.headers['x-access-code'] || '';
  if (!process.env.ACCESS_CODE || code !== process.env.ACCESS_CODE) {
    res.status(401).json({ error: 'bad access code' });
    return null;
  }
  return code;
}

module.exports = { db, authed };
