// Model catalog proxied with the user's own key (the mobile picker uses this).
const { authed, userKey } = require('./_db.js');

module.exports = async (req, res) => {
  const user = await authed(req, res);
  if (!user) return;
  const key = await userKey(user.id);
  if (!key) { res.status(402).json({ error: 'no_key' }); return; }
  try {
    const r = await fetch('https://openrouter.ai/api/v1/models', { headers: { 'Authorization': 'Bearer ' + key } });
    const data = (await r.json()).data || [];
    res.setHeader('Cache-Control', 's-maxage=3600');
    res.json({ models: data.map((m) => ({
      id: m.id, name: m.name || m.id, context: m.context_length || 0,
      promptPrice: Number((m.pricing || {}).prompt) || 0,
      completionPrice: Number((m.pricing || {}).completion) || 0,
      vision: !!(m.architecture && (m.architecture.input_modalities || []).includes('image')),
      reasoning: (m.supported_parameters || []).includes('reasoning'),
    })) });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
};
