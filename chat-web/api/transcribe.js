// Voice input: audio → text via a multimodal model on the user's own key.
const { authed, userKey } = require('./_db.js');

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const user = await authed(req, res);
  if (!user) return;
  const key = await userKey(user.id);
  if (!key) { res.status(402).json({ error: 'no_key' }); return; }
  const { audio, format } = req.body || {};   // base64, e.g. webm/mp4
  if (!audio || String(audio).length > 8000000) { res.status(400).json({ error: 'bad audio' }); return; }
  try {
    const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'google/gemini-3.1-flash-lite',
        messages: [{ role: 'user', content: [
          { type: 'text', text: 'Transcribe this audio exactly. Reply with ONLY the transcription, no commentary. If there is no speech, reply with an empty string.' },
          { type: 'input_audio', input_audio: { data: audio, format: format === 'mp4' ? 'mp4' : 'webm' } },
        ] }],
      }),
    });
    const j = await r.json();
    const text = ((((j.choices || [])[0] || {}).message || {}).content || '').trim();
    res.json({ text });
  } catch (e) { res.status(500).json({ error: String(e.message || e) }); }
};
