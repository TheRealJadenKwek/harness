'use strict';
// Electron main process: owns MANY agent Sessions (one per chat in the sidebar),
// persists each to disk, and bridges them to the renderer over IPC — including the
// approval round-trip that gates mutating tool calls.
const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const https = require('https');
const { execFile } = require('child_process');
const { Session } = require('../agent/agent');

let win;
const sessions = new Map();           // id -> rec (see sessionCreate for shape)
const pendingApprovals = new Map();   // approvalId -> resolve fn
let approvalSeq = 0;

// ---- paths -----------------------------------------------------------------
const configPath = () => path.join(app.getPath('userData'), 'config.json');
const sessionsDir = () => path.join(app.getPath('userData'), 'sessions');
const modelsCachePath = () => path.join(app.getPath('userData'), 'models.json');
const sessionFile = (id) => path.join(sessionsDir(), id + '.json');

// ---- config (key + defaults for new sessions), persisted in userData; key
// bootstraps from ~/.claude-harness/keys.json so there's nothing to paste on day one.
function loadConfig() {
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(configPath(), 'utf8')); } catch {}
  if (!cfg.apiKey) {
    try {
      const k = JSON.parse(fs.readFileSync(path.join(app.getPath('home'), '.claude-harness/keys.json'), 'utf8'));
      if (k.OPENROUTER_API_KEY) cfg.apiKey = k.OPENROUTER_API_KEY;
    } catch {}
  }
  cfg.model = cfg.model || 'z-ai/glm-4.6';
  cfg.mode = cfg.mode || 'ask';
  cfg.cwd = cfg.cwd || app.getPath('home');
  cfg.modeByModel = cfg.modeByModel || {};   // remembered trust level per model
  return cfg;
}
function saveConfig(cfg) {
  try { fs.writeFileSync(configPath(), JSON.stringify(cfg, null, 2)); } catch {}
}

// ---- session records + persistence ------------------------------------------
function newId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }

function metaOf(rec) {
  return {
    id: rec.id, title: rec.title, cwd: rec.cwd, model: rec.model, mode: rec.mode,
    createdAt: rec.createdAt, updatedAt: rec.updatedAt, usage: rec.usage,
    streaming: !!rec.abort,
  };
}

function saveSession(rec) {
  try {
    fs.mkdirSync(sessionsDir(), { recursive: true });
    fs.writeFileSync(sessionFile(rec.id), JSON.stringify({
      meta: {
        id: rec.id, title: rec.title, cwd: rec.cwd, model: rec.model, mode: rec.mode,
        createdAt: rec.createdAt, updatedAt: rec.updatedAt, usage: rec.usage,
      },
      messages: rec.agent ? rec.agent.messages : (rec.savedMessages || []),
      transcript: rec.transcript,
    }));
  } catch {}
}

function loadSessionsFromDisk() {
  let files = [];
  try { files = fs.readdirSync(sessionsDir()); } catch { return; }
  for (const f of files) {
    if (!f.endsWith('.json')) continue;
    try {
      const d = JSON.parse(fs.readFileSync(path.join(sessionsDir(), f), 'utf8'));
      if (!d.meta || !d.meta.id) continue;
      sessions.set(d.meta.id, {
        ...d.meta,
        usage: d.meta.usage || { prompt_tokens: 0, completion_tokens: 0, cost: 0 },
        agent: null, savedMessages: d.messages || [], transcript: d.transcript || [],
        abort: null, cur: null,
      });
    } catch {}
  }
}

function sessionsChanged() { win && win.webContents.send('sessions-updated'); }
function sendToUI(channel, payload) { win && win.webContents.send(channel, payload); }

// ---- model catalog (cached to disk so the picker is instant) -----------------
let modelsMem = null;
function fetchModels(apiKey) {
  return new Promise((resolve) => {
    const req = https.request({
      method: 'GET', hostname: 'openrouter.ai', path: '/api/v1/models',
      headers: { 'Accept': 'application/json', ...(apiKey ? { 'Authorization': 'Bearer ' + apiKey } : {}) },
    }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => {
        try {
          const items = (JSON.parse(b).data || []).map((m) => ({
            value: m.id, label: m.name || m.id,
            context: m.context_length || 0,
            pricing: m.pricing ? { prompt: Number(m.pricing.prompt) || 0, completion: Number(m.pricing.completion) || 0 } : null,
          }));
          items.sort((a, z) => a.value.localeCompare(z.value));
          resolve(items);
        } catch { resolve([]); }
      });
    });
    req.on('error', () => resolve([]));
    req.end();
  });
}
async function getModels(force) {
  if (!force && modelsMem) return modelsMem;
  if (!force) {
    try {
      const c = JSON.parse(fs.readFileSync(modelsCachePath(), 'utf8'));
      if (c.items && c.items.length && Date.now() - c.fetchedAt < 24 * 3600 * 1000) {
        modelsMem = c.items;
        return modelsMem;
      }
    } catch {}
  }
  const items = await fetchModels(loadConfig().apiKey);
  if (items.length) {
    modelsMem = items;
    try { fs.writeFileSync(modelsCachePath(), JSON.stringify({ fetchedAt: Date.now(), items })); } catch {}
  }
  return modelsMem || [];
}
function priceOf(model) {
  const m = (modelsMem || []).find((x) => x.value === model);
  return m && m.pricing ? m.pricing : null;
}

// ---- agent event folding: mirror the live event stream into a compact transcript
// that persists to disk and replays when a session is reopened.
function flushAssistant(rec) {
  if (rec.cur && (rec.cur.text || rec.cur.think)) {
    rec.transcript.push({ t: 'assistant', text: rec.cur.text, think: rec.cur.think });
  }
  rec.cur = null;
}
function foldEvent(rec, e) {
  if (e.type === 'text') { (rec.cur || (rec.cur = { text: '', think: '' })).text += e.delta; }
  else if (e.type === 'reasoning') { (rec.cur || (rec.cur = { text: '', think: '' })).think += e.delta; }
  else if (e.type === 'tool_call') { flushAssistant(rec); rec.transcript.push({ t: 'tool', name: e.name, args: e.args }); }
  else if (e.type === 'tool_result') {
    for (let i = rec.transcript.length - 1; i >= 0; i--) {
      const it = rec.transcript[i];
      if (it.t === 'tool' && it.result === undefined) { it.result = e.result; break; }
    }
  }
  else if (e.type === 'diff') { rec.transcript.push({ t: 'diff', file: e.file, before: e.before, after: e.after }); }
  else if (e.type === 'auto_approved') { rec.transcript.push({ t: 'note', text: '⚡ auto-approved ' + e.kind + ': ' + String(e.detail || '').slice(0, 80) }); }
  else if (e.type === 'compacted') { flushAssistant(rec); rec.transcript.push({ t: 'note', text: '✦ context compacted' }); rec.updatedAt = Date.now(); saveSession(rec); }
  else if (e.type === 'done') {
    flushAssistant(rec);
    if (e.usage) {
      rec.usage.prompt_tokens += e.usage.prompt_tokens || 0;
      rec.usage.completion_tokens += e.usage.completion_tokens || 0;
      const p = priceOf(rec.model);
      if (p) rec.usage.cost += (e.usage.prompt_tokens || 0) * p.prompt + (e.usage.completion_tokens || 0) * p.completion;
      rec.transcript.push({ t: 'note', text: 'done · ~' + ((e.usage.prompt_tokens || 0) + (e.usage.completion_tokens || 0)).toLocaleString() + ' tokens' });
    }
    rec.updatedAt = Date.now();
    saveSession(rec);
  }
  else if (e.type === 'error') { flushAssistant(rec); rec.transcript.push({ t: 'err', text: e.message }); saveSession(rec); }
  else if (e.type === 'aborted') { flushAssistant(rec); rec.transcript.push({ t: 'note', text: 'stopped.' }); saveSession(rec); }
}
function onAgentEvent(rec, e) {
  foldEvent(rec, e);
  sendToUI('agent-event', Object.assign({ sessionId: rec.id }, e));
}

function ensureAgent(rec) {
  const cfg = loadConfig();
  if (!rec.agent) {
    rec.agent = new Session({
      apiKey: cfg.apiKey, model: rec.model, cwd: rec.cwd, mode: rec.mode,
      emit: (e) => onAgentEvent(rec, e),
      approve: (kind, detail, opts = {}) => new Promise((resolve) => {
        const aid = ++approvalSeq;
        pendingApprovals.set(aid, resolve);
        sendToUI('approval', { sessionId: rec.id, sessionTitle: rec.title, id: aid, kind, detail, danger: !!opts.danger });
      }),
    });
    if (rec.savedMessages && rec.savedMessages.length) rec.agent.loadMessages(rec.savedMessages);
    rec.savedMessages = null;
  }
  rec.agent.apiKey = cfg.apiKey;
  return rec.agent;
}

// ---- window ------------------------------------------------------------------
function createWindow() {
  win = new BrowserWindow({
    width: 1360, height: 860, minWidth: 860, minHeight: 520,
    titleBarStyle: 'hiddenInset', backgroundColor: '#161619',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.loadFile(path.join(__dirname, '../renderer/index.html'));
}

app.whenReady().then(() => {
  if (process.platform === 'darwin' && app.dock) {
    try { app.dock.setIcon(path.join(__dirname, '../../assets/icon.png')); } catch {}
  }
  loadSessionsFromDisk();
  getModels(false);   // warm the catalog cache in the background
  createWindow();
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
app.on('before-quit', () => { for (const rec of sessions.values()) if (rec.agent) saveSession(rec); });

// ---- IPC: config ---------------------------------------------------------------
ipcMain.handle('get-config', () => {
  const c = loadConfig();
  return { hasKey: !!c.apiKey, model: c.model, mode: c.mode, cwd: c.cwd };
});
ipcMain.handle('set-config', (_e, patch) => {
  const c = loadConfig();
  saveConfig({ ...c, ...patch });
  if (patch.apiKey) for (const rec of sessions.values()) if (rec.agent) rec.agent.apiKey = patch.apiKey;
  return { ok: true };
});

// ---- IPC: sessions --------------------------------------------------------------
ipcMain.handle('sessions-list', () =>
  [...sessions.values()].sort((a, b) => b.updatedAt - a.updatedAt).map(metaOf));

ipcMain.handle('session-create', (_e, opts = {}) => {
  const cfg = loadConfig();
  const rec = {
    id: newId(), title: 'New chat',
    cwd: opts.cwd || cfg.cwd, model: opts.model || cfg.model, mode: opts.mode || cfg.mode,
    createdAt: Date.now(), updatedAt: Date.now(),
    usage: { prompt_tokens: 0, completion_tokens: 0, cost: 0 },
    agent: null, savedMessages: [], transcript: [], abort: null, cur: null,
  };
  sessions.set(rec.id, rec);
  saveSession(rec);
  return metaOf(rec);
});

ipcMain.handle('session-delete', (_e, id) => {
  const rec = sessions.get(id);
  if (rec) {
    if (rec.abort) rec.abort.abort();
    sessions.delete(id);
    try { fs.unlinkSync(sessionFile(id)); } catch {}
  }
  return { ok: true };
});

ipcMain.handle('session-get', (_e, id) => {
  const rec = sessions.get(id);
  return rec ? { meta: metaOf(rec), transcript: rec.transcript } : null;
});

ipcMain.handle('session-rename', (_e, { id, title }) => {
  const rec = sessions.get(id);
  if (rec && title) { rec.title = String(title).slice(0, 60); saveSession(rec); sessionsChanged(); }
  return { ok: true };
});

ipcMain.handle('session-config', (_e, { id, patch }) => {
  const rec = sessions.get(id);
  if (!rec) return null;
  const cfg = loadConfig();
  // Trust memory: switching models restores the mode last used with that model;
  // changing mode records it for the current model. "New → Auto, old → Ask" sticks.
  if (patch.mode) { rec.mode = patch.mode; cfg.mode = patch.mode; cfg.modeByModel[rec.model] = patch.mode; }
  if (patch.model) {
    rec.model = patch.model; cfg.model = patch.model;
    if (!patch.mode && cfg.modeByModel[patch.model]) rec.mode = cfg.modeByModel[patch.model];
  }
  if (patch.cwd) { rec.cwd = patch.cwd; cfg.cwd = patch.cwd; }
  saveConfig(cfg);
  if (rec.agent) {
    if (patch.model) rec.agent.setModel(rec.model);
    rec.agent.setMode(rec.mode);
    if (patch.cwd) rec.agent.setCwd(rec.cwd);
  }
  saveSession(rec);
  return metaOf(rec);
});

ipcMain.handle('session-send', (_e, { id, text }) => {
  const rec = sessions.get(id);
  if (!rec) return { ok: false, error: 'no such session' };
  const cfg = loadConfig();
  if (!cfg.apiKey) {
    sendToUI('agent-event', { sessionId: id, type: 'error', message: 'No OpenRouter API key set — open Settings.' });
    return { ok: false, error: 'no key' };
  }
  if (rec.abort) return { ok: false, error: 'busy' };
  if (rec.title === 'New chat') {
    rec.title = text.split('\n')[0].slice(0, 48) || 'New chat';
    sessionsChanged();
  }
  rec.transcript.push({ t: 'user', text });
  rec.updatedAt = Date.now();
  const agent = ensureAgent(rec);
  rec.abort = new AbortController();
  sessionsChanged();
  (async () => {
    try { await agent.send(text, rec.abort.signal); }
    catch (err) { onAgentEvent(rec, { type: 'error', message: String((err && err.message) || err) }); }
    finally { rec.abort = null; saveSession(rec); sessionsChanged(); }
  })();
  return { ok: true };
});

ipcMain.handle('session-abort', (_e, id) => {
  const rec = sessions.get(id);
  if (rec && rec.abort) rec.abort.abort();
  return { ok: true };
});

ipcMain.handle('session-clear', (_e, id) => {
  const rec = sessions.get(id);
  if (!rec) return { ok: false };
  if (rec.abort) rec.abort.abort();
  rec.transcript = [];
  rec.savedMessages = [];
  rec.cur = null;
  if (rec.agent) rec.agent.reset();
  rec.usage = { prompt_tokens: 0, completion_tokens: 0, cost: 0 };
  saveSession(rec);
  sessionsChanged();
  return { ok: true };
});

ipcMain.handle('session-compact', async (_e, id) => {
  const rec = sessions.get(id);
  if (!rec || rec.abort) return { ok: false, error: 'busy or missing' };
  const agent = ensureAgent(rec);
  if (agent.messages.length < 3) return { ok: false, error: 'nothing to compact yet' };
  rec.abort = new AbortController();
  sessionsChanged();
  try {
    await agent.compact(rec.abort.signal);
    return { ok: true };
  } catch (e) {
    onAgentEvent(rec, { type: 'error', message: 'compact failed: ' + String((e && e.message) || e) });
    return { ok: false };
  } finally {
    rec.abort = null; saveSession(rec); sessionsChanged();
  }
});

ipcMain.on('approval-response', (_e, { id, approved }) => {
  const resolve = pendingApprovals.get(id);
  if (resolve) { pendingApprovals.delete(id); resolve(!!approved); }
});

// ---- IPC: pickers, models, files, git --------------------------------------------
ipcMain.handle('pick-dir', async (_e, id) => {
  const r = await dialog.showOpenDialog(win, { properties: ['openDirectory'] });
  if (r.canceled || !r.filePaths[0]) return null;
  const dir = r.filePaths[0];
  const cfg = loadConfig(); cfg.cwd = dir; saveConfig(cfg);
  const rec = id && sessions.get(id);
  if (rec) { rec.cwd = dir; if (rec.agent) rec.agent.setCwd(dir); saveSession(rec); }
  return dir;
});

ipcMain.handle('list-models', (_e, force) => getModels(!!force));

ipcMain.handle('list-files', (_e, id) => {
  const rec = sessions.get(id);
  if (!rec) return [];
  const out = [];
  const walk = (dir, depth) => {
    if (depth > 6 || out.length >= 3000) return;
    let ents;
    try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.name.startsWith('.') || ['node_modules', 'dist', 'build', 'out', '.next', 'venv', '__pycache__', 'target'].includes(e.name)) continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full, depth + 1);
      else out.push(path.relative(rec.cwd, full));
    }
  };
  walk(rec.cwd, 0);
  return out.slice(0, 3000);
});

function git(cwdir, args) {
  return new Promise((resolve) => {
    execFile('git', args, { cwd: cwdir, timeout: 15000, maxBuffer: 8 * 1024 * 1024 },
      (err, so, se) => resolve({ err, so: so || '', se: se || '' }));
  });
}

ipcMain.handle('git-status', async (_e, id) => {
  const rec = sessions.get(id);
  if (!rec) return { repo: false };
  const head = await git(rec.cwd, ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (head.err) return { repo: false };
  const st = await git(rec.cwd, ['status', '--porcelain']);
  const files = st.so.split('\n').filter(Boolean).map((l) => {
    let p = l.slice(3);
    if (p.includes(' -> ')) p = p.split(' -> ')[1];
    if (p.startsWith('"') && p.endsWith('"')) p = p.slice(1, -1);
    return { status: l.slice(0, 2).trim() || '??', path: p };
  });
  return { repo: true, branch: head.so.trim(), files };
});

ipcMain.handle('git-diff', async (_e, { id, file }) => {
  const rec = sessions.get(id);
  if (!rec) return { diff: '' };
  let r = await git(rec.cwd, ['diff', '--', file]);
  if (!r.so.trim()) {
    const staged = await git(rec.cwd, ['diff', '--cached', '--', file]);
    if (staged.so.trim()) r = staged;
  }
  if (!r.so.trim()) {
    // Untracked file: render as an all-additions diff.
    const un = await git(rec.cwd, ['diff', '--no-index', '--', '/dev/null', file]);
    if (un.so.trim()) r = un;
  }
  return { diff: r.so.slice(0, 300000) };
});

ipcMain.handle('open-external', (_e, url) => {
  if (/^https?:\/\//i.test(url || '')) shell.openExternal(url);
  return { ok: true };
});

ipcMain.handle('open-sessions-folder', () => {
  try { fs.mkdirSync(sessionsDir(), { recursive: true }); } catch {}
  shell.openPath(sessionsDir());
  return { ok: true };
});
