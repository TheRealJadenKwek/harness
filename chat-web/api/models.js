// Model catalog proxied with the user's own key (the mobile picker uses this).
const { authed, userKey } = require('./_db.js');

module.exports = async (req, res) => {
  const user = await authed(req, res);
  if (!user) return;
  const key = await userKey(user.id);
  if (!key) { res.status(402).json({ error: 'no_key' }); return; }
  try {
    // media models are EXCLUDED from the default list — merge the three catalogs
    const H = { 'Authorization': 'Bearer ' + key };
    const [base, img, vid] = await Promise.all([
      fetch('https://openrouter.ai/api/v1/models', { headers: H }).then((r) => r.json()),
      fetch('https://openrouter.ai/api/v1/models?output_modalities=image', { headers: H }).then((r) => r.json()),
      fetch('https://openrouter.ai/api/v1/models?output_modalities=video', { headers: H }).then((r) => r.json()),
    ]);
    const byId = new Map();
    for (const m of [...(base.data || []), ...(img.data || []), ...(vid.data || [])]) byId.set(m.id, m);
    const data = [...byId.values()];
    res.setHeader('Cache-Control', 's-maxage=3600');
    res.json({ models: data.map((m) => ({
      id: m.id, name: m.name || m.id, context: m.context_length || 0,
      promptPrice: Number((m.pricing || {}).prompt) || 0,
      completionPrice: Number((m.pricing || {}).completion) || 0,
      vision: !!(m.architecture && (m.architecture.input_modalities || []).includes('image')),
      imageOut: !!(m.architecture && (m.architecture.output_modalities || []).includes('image')),
      videoOut: !!(m.architecture && (m.architecture.output_modalities || []).includes('video')),
      reasoning: (m.supported_parameters || []).includes('reasoning'),
    })) });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
};
