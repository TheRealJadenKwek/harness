'use strict';
// Semantic codebase index: chunk source files, embed via OpenRouter, cosine search.
// Index is cached per-cwd in ~/.harness-code/index/<sha1>.json and refreshed
// incrementally by mtime, so only changed files are re-embedded.
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');
const crypto = require('crypto');

const EMBED_MODEL = 'openai/text-embedding-3-small';
const CODE_EXT = new Set(['.js', '.jsx', '.ts', '.tsx', '.py', '.rb', '.go', '.rs', '.java', '.kt', '.swift', '.c', '.h', '.cpp', '.hpp', '.cs', '.php', '.sh', '.zsh', '.sql', '.html', '.css', '.scss', '.vue', '.svelte', '.md', '.yml', '.yaml', '.toml', '.json']);
const SKIP_DIRS = new Set(['node_modules', '.git', 'dist', 'build', 'out', '.next', 'venv', '.venv', '__pycache__', 'Pods', 'DerivedData', 'vendor', 'coverage', '.cache']);
const MAX_FILES = 600;
const MAX_CHUNKS = 8000;
const CHUNK_LINES = 40;
const OVERLAP = 8;

function idxPath(cwd) {
  const dir = path.join(os.homedir(), '.harness-code', 'index');
  fs.mkdirSync(dir, { recursive: true });
  return path.join(dir, crypto.createHash('sha1').update(cwd).digest('hex').slice(0, 16) + '.json');
}

function walk(cwd) {
  const out = [];
  const stack = [cwd];
  while (stack.length && out.length < MAX_FILES) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (e.name.startsWith('.') && e.name !== '.env.example') continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) stack.push(full); continue; }
      if (!CODE_EXT.has(path.extname(e.name).toLowerCase())) continue;
      let st;
      try { st = fs.statSync(full); } catch { continue; }
      if (st.size > 300 * 1024) continue;
      out.push({ path: path.relative(cwd, full), mtime: st.mtimeMs });
      if (out.length >= MAX_FILES) break;
    }
  }
  return out;
}

function chunkFile(cwd, rel) {
  let text;
  try { text = fs.readFileSync(path.join(cwd, rel), 'utf8'); } catch { return []; }
  const lines = text.split('\n');
  const chunks = [];
  for (let i = 0; i < lines.length; i += CHUNK_LINES - OVERLAP) {
    const body = lines.slice(i, i + CHUNK_LINES).join('\n').trim();
    if (body.length > 30) chunks.push({ line: i + 1, text: body.slice(0, 3000) });
    if (i + CHUNK_LINES >= lines.length) break;
  }
  return chunks;
}

function embed(texts, apiKey) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ model: EMBED_MODEL, input: texts });
    const req = https.request({
      method: 'POST', hostname: 'openrouter.ai', path: '/api/v1/embeddings',
      headers: { 'Authorization': 'Bearer ' + apiKey, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 60000,
    }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => {
        try {
          const j = JSON.parse(b);
          if (!j.data) return reject(new Error('embeddings failed: ' + b.slice(0, 200)));
          resolve(j.data.map((d) => d.embedding));
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('embeddings timed out')); });
    req.write(body);
    req.end();
  });
}

// quantize floats to 3 decimals — 4x smaller index files, negligible recall loss
const q3 = (v) => v.map((x) => Math.round(x * 1000) / 1000);

async function ensureIndex(cwd, apiKey, onProgress) {
  const file = idxPath(cwd);
  let idx = { files: {} };
  try { idx = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
  const seen = new Set();
  const stale = [];
  for (const f of walk(cwd)) {
    seen.add(f.path);
    const cur = idx.files[f.path];
    if (!cur || cur.mtime !== f.mtime) stale.push(f);
  }
  for (const p of Object.keys(idx.files)) if (!seen.has(p)) delete idx.files[p];

  if (stale.length) {
    let done = 0;
    for (const f of stale) {
      const chunks = chunkFile(cwd, f.path);
      if (!chunks.length) { idx.files[f.path] = { mtime: f.mtime, chunks: [] }; continue; }
      // embed this file's chunks in batches of 64
      const vecs = [];
      for (let i = 0; i < chunks.length; i += 64) {
        const batch = chunks.slice(i, i + 64);
        const vs = await embed(batch.map((c) => f.path + '\n' + c.text), apiKey);
        vecs.push(...vs.map(q3));
      }
      idx.files[f.path] = { mtime: f.mtime, chunks: chunks.map((c, i) => ({ line: c.line, text: c.text.slice(0, 600), vec: vecs[i] })) };
      done++;
      if (onProgress && (done % 20 === 0)) onProgress(done, stale.length);
      const total = Object.values(idx.files).reduce((a, x) => a + x.chunks.length, 0);
      if (total > MAX_CHUNKS) break;
    }
    fs.writeFileSync(file, JSON.stringify(idx));
  }
  return idx;
}

function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}

async function search(cwd, query, apiKey, onProgress) {
  const idx = await ensureIndex(cwd, apiKey, onProgress);
  const [qv] = await embed([query], apiKey);
  const hits = [];
  for (const [p, f] of Object.entries(idx.files)) {
    for (const c of f.chunks) hits.push({ file: p, line: c.line, text: c.text, score: cosine(qv, c.vec) });
  }
  hits.sort((a, b) => b.score - a.score);
  return hits.slice(0, 8);
}

module.exports = { search, ensureIndex };
