'use strict';
const H = window.harness;
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- state
const S = {
  recs: new Map(),      // id -> { meta, logEl, loaded, cur, queued: [], approvals: [], files: null, streaming: false }
  order: [],            // session ids, most recent first (sidebar order)
  active: null,         // active session id
  models: [],
  showingApproval: null,
  diffOpen: false,
  selGitFile: null,
};
const active = () => S.recs.get(S.active);

// ---------------------------------------------------------------- utils
function esc(s) { return (s || '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }
function shortDir(p) { const h = (p || '').replace(/\/Users\/[^/]+/, '~'); const parts = h.split('/'); return parts.length > 3 ? '…/' + parts.slice(-2).join('/') : h; }
function shortModel(m) { return (m || '').split('/').pop(); }
function timeAgo(t) {
  const d = Date.now() - t;
  if (d < 60e3) return 'now';
  if (d < 3600e3) return Math.floor(d / 60e3) + 'm';
  if (d < 86400e3) return Math.floor(d / 3600e3) + 'h';
  return Math.floor(d / 86400e3) + 'd';
}
function fmtTokens(n) { return n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n); }

// Minimal safe markdown: escape first, then transform. Fenced code is lifted out
// before inline rules run and restored after.
function md(src) {
  let s = esc(src || '');
  const blocks = [];
  s = s.replace(/```([\w+-]*)\n?([\s\S]*?)(?:```|$)/g, (_, lang, code) => {
    blocks.push('<pre class="code"><code>' + code.replace(/\n$/, '') + '</code></pre>');
    return '\uE000' + (blocks.length - 1) + '\uE001';
  });
  s = s.replace(/`([^`\n]+)`/g, '<code class="ic">$1</code>');
  s = s.replace(/^#### (.*)$/gm, '<h4>$1</h4>');
  s = s.replace(/^### (.*)$/gm, '<h4>$1</h4>');
  s = s.replace(/^## (.*)$/gm, '<h3>$1</h3>');
  s = s.replace(/^# (.*)$/gm, '<h2>$1</h2>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" class="ext">$1</a>');
  s = s.replace(/^(\s*)[-*] /gm, '$1• ');
  s = s.replace(/\uE000(\d+)\uE001/g, (_, i) => blocks[+i]);
  s = s.replace(/<\/(h2|h3|h4|pre)>\n/g, '</$1>');
  return s;
}
document.addEventListener('click', (e) => {
  const a = e.target.closest && e.target.closest('a.ext');
  if (a) { e.preventDefault(); H.openExternal(a.href); }
});

// ---------------------------------------------------------------- chat rendering
function logOf(rec) { return rec.logEl; }
function atBottom(el) { return el.scrollHeight - el.scrollTop - el.clientHeight < 90; }
function scrollLog(rec) { const el = logOf(rec); requestAnimationFrame(() => { el.scrollTop = el.scrollHeight; }); }

function addUser(rec, text) {
  const el = document.createElement('div'); el.className = 'msg user'; el.textContent = text;
  logOf(rec).appendChild(el); scrollLog(rec);
}
function addLine(rec, cls, text) {
  const el = document.createElement('div'); el.className = cls; el.textContent = text;
  logOf(rec).appendChild(el); scrollLog(rec); return el;
}

function ensureAssistant(rec) {
  if (rec.cur) return rec.cur;
  const el = document.createElement('div'); el.className = 'msg assistant';
  const think = document.createElement('div'); think.className = 'think'; think.style.display = 'none';
  const thinkHead = document.createElement('div'); thinkHead.className = 'think-head'; thinkHead.textContent = '✳ thinking…';
  const thinkBody = document.createElement('div'); thinkBody.className = 'think-body';
  think.appendChild(thinkHead); think.appendChild(thinkBody);
  thinkHead.onclick = () => think.classList.toggle('closed');
  const textEl = document.createElement('div'); textEl.className = 'md';
  el.appendChild(think); el.appendChild(textEl);
  logOf(rec).appendChild(el);
  rec.cur = { el, think, thinkHead, thinkBody, textEl, raw: '', thinkRaw: '', mdTimer: null };
  return rec.cur;
}
function renderCurMd(rec) {
  const c = rec.cur; if (!c) return;
  if (c.mdTimer) return;
  c.mdTimer = setTimeout(() => { c.mdTimer = null; if (rec.cur === c) c.textEl.innerHTML = md(c.raw); }, 120);
}
function finalizeAssistant(rec) {
  const c = rec.cur; if (!c) return;
  if (c.mdTimer) { clearTimeout(c.mdTimer); c.mdTimer = null; }
  c.textEl.innerHTML = md(c.raw);
  c.think.classList.add('closed');
  c.thinkHead.textContent = '✳ thought for a bit';
  rec.cur = null;
}

const TOOL_ARG_SUMMARY = {
  read_file: (a) => a.path, list_dir: (a) => a.path || '.', glob: (a) => a.query,
  grep: (a) => a.pattern, write_file: (a) => a.path, edit_file: (a) => a.path,
  bash: (a) => a.command,
};
function summarizeResult(name, r) {
  if (!r) return '';
  if (r.error) return r.error;
  if (name === 'read_file') return r.bytes + ' bytes';
  if (name === 'bash') return 'exit ' + r.exit_code + (r.stdout ? '\n' + r.stdout.trim().slice(0, 1200) : '') + (r.stderr ? '\n' + r.stderr.trim().slice(0, 400) : '');
  if (name === 'grep' || name === 'glob') return (r.matches || []).length + ' matches' + ((r.matches || []).length ? '\n' + r.matches.slice(0, 20).join('\n') : '');
  if (name === 'list_dir') return (r.entries || []).length + ' entries';
  if (name === 'write_file') return r.written + ' bytes written';
  if (name === 'edit_file') return 'edited';
  return Object.keys(r).join(', ');
}
function addTool(rec, name, args, result) {
  const el = document.createElement('div'); el.className = 'tool';
  const head = document.createElement('div'); head.className = 'tool-head';
  const summ = (TOOL_ARG_SUMMARY[name] ? TOOL_ARG_SUMMARY[name](args || {}) : JSON.stringify(args)) || '';
  head.innerHTML = '<span class="name">▸ ' + esc(name) + '</span><span class="summ">' + esc(String(summ).slice(0, 200)) + '</span><span class="st run">●</span>';
  const body = document.createElement('div'); body.className = 'tool-body';
  body.innerHTML = '<div class="tb-label">args</div><pre>' + esc(JSON.stringify(args, null, 2)) + '</pre><div class="tb-res-slot"></div>';
  head.onclick = () => el.classList.toggle('open');
  el.appendChild(head); el.appendChild(body);
  logOf(rec).appendChild(el); scrollLog(rec);
  rec.lastTool = el;
  if (result !== undefined) setToolResult(el, name, result);
  return el;
}
function setToolResult(el, name, result) {
  const st = el.querySelector('.st');
  const err = result && result.error;
  st.className = 'st ' + (err ? 'bad' : 'ok');
  st.textContent = err ? '✗' : '✓';
  const slot = el.querySelector('.tb-res-slot');
  slot.innerHTML = '<div class="tb-label">result</div><pre class="tb-res' + (err ? ' err' : '') + '">' + esc(summarizeResult(name, result).slice(0, 4000)) + '</pre>';
}

function addDiff(rec, file, before, after) {
  const el = document.createElement('div'); el.className = 'diff';
  const b = (before || '').split('\n'), a = (after || '').split('\n');
  let p = 0; while (p < b.length && p < a.length && b[p] === a[p]) p++;
  let sb = b.length, sa = a.length;
  while (sb > p && sa > p && b[sb - 1] === a[sa - 1]) { sb--; sa--; }
  let html = '', lines = 0;
  for (let i = Math.max(0, p - 2); i < p; i++) if (b[i] !== undefined) { html += '  ' + esc(b[i]) + '\n'; lines++; }
  for (let i = p; i < sb; i++) { html += '<span class="del">- ' + esc(b[i]) + '</span>\n'; lines++; }
  for (let i = p; i < sa; i++) { html += '<span class="add">+ ' + esc(a[i]) + '</span>\n'; lines++; }
  const adds = sa - p, dels = sb - p;
  const pre = document.createElement('pre');
  pre.innerHTML = html || '  (no line changes)';
  el.innerHTML = '<div class="dfile">± ' + esc(file) + '<span class="dstats">+' + adds + ' −' + dels + '</span></div>';
  el.appendChild(pre);
  if (lines > 24) {
    pre.classList.add('clamped');
    const more = document.createElement('button'); more.className = 'd-more'; more.textContent = '⌄ show all ' + lines + ' lines';
    more.onclick = () => { pre.classList.remove('clamped'); more.remove(); };
    el.appendChild(more);
  }
  logOf(rec).appendChild(el); scrollLog(rec);
}

function renderItem(rec, item) {
  if (item.t === 'user') addUser(rec, item.text);
  else if (item.t === 'assistant') {
    const c = ensureAssistant(rec);
    if (item.think) { c.think.style.display = 'block'; c.thinkBody.textContent = item.think; }
    c.raw = item.text || '';
    finalizeAssistant(rec);
  }
  else if (item.t === 'tool') addTool(rec, item.name, item.args, item.result === undefined ? { error: '(interrupted)' } : item.result);
  else if (item.t === 'diff') addDiff(rec, item.file, item.before, item.after);
  else if (item.t === 'note') addLine(rec, 'done', item.text);
  else if (item.t === 'err') addLine(rec, 'err', '⚠︎ ' + item.text);
}

// ---------------------------------------------------------------- sessions / sidebar
async function refreshSessions() {
  const metas = await H.sessionsList();
  S.order = metas.map((m) => m.id);
  for (const m of metas) {
    let rec = S.recs.get(m.id);
    if (!rec) rec = makeLocalRec(m);
    else rec.meta = m;
  }
  for (const id of [...S.recs.keys()]) {
    if (!S.order.includes(id)) { const r = S.recs.get(id); r.logEl.remove(); S.recs.delete(id); }
  }
  renderSidebar();
  updateTitlebar();
}

function makeLocalRec(meta) {
  const logEl = document.createElement('div'); logEl.className = 'log';
  $('logs').appendChild(logEl);
  const rec = { meta, logEl, loaded: false, cur: null, queued: [], approvals: [], files: null, streaming: !!meta.streaming, lastTool: null };
  S.recs.set(meta.id, rec);
  return rec;
}

function renderSidebar() {
  const box = $('sessionList'); box.innerHTML = '';
  for (const id of S.order) {
    const rec = S.recs.get(id); if (!rec) continue;
    const m = rec.meta;
    const el = document.createElement('div'); el.className = 'sess' + (id === S.active ? ' active' : '');
    const live = rec.approvals.length ? '<span class="s-live appr">⚠</span>' : (rec.streaming ? '<span class="s-live spin">●</span>' : '');
    el.innerHTML = '<div class="s-title">' + esc(m.title) + '</div>' +
      '<div class="s-sub">' + esc(shortModel(m.model)) + ' · ' + timeAgo(m.updatedAt) + '</div>' +
      live + '<button class="s-x" title="Delete">✕</button>';
    el.onclick = () => activate(id);
    el.querySelector('.s-x').onclick = async (e) => {
      e.stopPropagation();
      if (!confirm('Delete "' + m.title + '"?')) return;
      await H.sessionDelete(id);
      if (S.active === id) S.active = null;
      await refreshSessions();
      if (!S.active) {
        if (S.order.length) activate(S.order[0]);
        else { const nm = await H.sessionCreate({}); await refreshSessions(); activate(nm.id); }
      }
    };
    box.appendChild(el);
  }
}

async function activate(id) {
  if (!S.recs.has(id)) return;
  S.active = id;
  for (const [rid, rec] of S.recs) rec.logEl.classList.toggle('active', rid === id);
  const rec = S.recs.get(id);
  if (!rec.loaded) {
    rec.loaded = true;
    const d = await H.sessionGet(id);
    if (d) { rec.meta = d.meta; for (const item of d.transcript) renderItem(rec, item); rec.cur = null; }
    rec.logEl.scrollTop = rec.logEl.scrollHeight;
  }
  renderSidebar();
  updateTitlebar();
  updateComposer();
  hidePopup();
  maybeShowApproval();
  if (S.diffOpen) refreshGit();
  $('input').focus();
}

function updateTitlebar() {
  const rec = active(); if (!rec) return;
  const m = rec.meta;
  $('dirLabel').textContent = shortDir(m.cwd);
  $('modelLabel').textContent = shortModel(m.model);
  const mb = $('modeBtn');
  mb.textContent = m.mode === 'plan' ? '📋 Plan' : m.mode === 'auto' ? '⚡ Auto' : '🔨 Ask';
  mb.className = 'chip mode ' + m.mode;
  const u = m.usage || { prompt_tokens: 0, completion_tokens: 0, cost: 0 };
  const tot = (u.prompt_tokens || 0) + (u.completion_tokens || 0);
  $('usageLabel').textContent = tot ? fmtTokens(tot) + ' tok' + (u.cost ? ' · $' + u.cost.toFixed(u.cost < 0.1 ? 4 : 2) : '') : '';
}

function updateComposer() {
  const rec = active();
  const streaming = rec && rec.streaming;
  $('sendBtn').style.display = streaming ? 'none' : '';
  $('stopBtn').style.display = streaming ? '' : 'none';
  const q = rec ? rec.queued.length : 0;
  $('queueNote').style.display = q ? '' : 'none';
  $('queueNote').textContent = q ? q + ' message' + (q > 1 ? 's' : '') + ' queued — sends when this turn finishes' : '';
}

// ---------------------------------------------------------------- agent events
const MUTATING = ['write_file', 'edit_file', 'bash'];
let gitDebounce = null;
H.onEvent((e) => {
  const rec = S.recs.get(e.sessionId);
  if (!rec || !rec.loaded) return;
  const el = logOf(rec); const stick = atBottom(el);
  if (e.type === 'turn_start') { /* keep the current assistant block across tool rounds */ }
  else if (e.type === 'reasoning') {
    const c = ensureAssistant(rec);
    c.think.style.display = 'block'; c.thinkRaw += e.delta; c.thinkBody.textContent = c.thinkRaw;
    if (stick) c.thinkBody.scrollTop = c.thinkBody.scrollHeight;
  }
  else if (e.type === 'text') {
    const c = ensureAssistant(rec);
    if (c.thinkRaw && !c.raw) { c.think.classList.add('closed'); c.thinkHead.textContent = '✳ thought for a bit'; }
    c.raw += e.delta; renderCurMd(rec);
  }
  else if (e.type === 'tool_call') { finalizeAssistant(rec); addTool(rec, e.name, e.args); }
  else if (e.type === 'tool_result') {
    if (rec.lastTool) setToolResult(rec.lastTool, e.name, e.result);
    if (S.diffOpen && e.sessionId === S.active && MUTATING.includes(e.name)) {
      clearTimeout(gitDebounce); gitDebounce = setTimeout(refreshGit, 500);
    }
  }
  else if (e.type === 'auto_approved') addLine(rec, 'done', '⚡ auto-approved ' + e.kind + ': ' + String(e.detail || '').slice(0, 80));
  else if (e.type === 'diff') addDiff(rec, e.file, e.before, e.after);
  else if (e.type === 'done') {
    finalizeAssistant(rec);
    if (e.usage) addLine(rec, 'done', 'done · ~' + ((e.usage.prompt_tokens || 0) + (e.usage.completion_tokens || 0)).toLocaleString() + ' tokens');
    endTurn(rec);
  }
  else if (e.type === 'compacted') { finalizeAssistant(rec); addLine(rec, 'done', '✦ context compacted'); endTurn(rec); }
  else if (e.type === 'error') { finalizeAssistant(rec); addLine(rec, 'err', '⚠︎ ' + e.message); endTurn(rec); }
  else if (e.type === 'aborted') { finalizeAssistant(rec); addLine(rec, 'done', 'stopped.'); endTurn(rec); }
  if (stick) scrollLog(rec);
});

function endTurn(rec) {
  rec.streaming = false;
  if (rec.meta.id === S.active) updateComposer();
  renderSidebar();
  if (rec.queued.length) {
    const next = rec.queued.shift();
    setTimeout(() => sendText(rec, next), 80);
  }
}

H.onSessionsUpdated(() => refreshSessions());

// ---------------------------------------------------------------- send / stop
async function sendText(rec, text) {
  if (rec.streaming) { rec.queued.push(text); updateComposer(); return; }
  rec.streaming = true; rec.cur = null;
  const r = await H.sessionSend(rec.meta.id, text);
  if (r.ok) addUser(rec, text);
  else if (r.error === 'busy') rec.queued.push(text);
  else rec.streaming = false;
  updateComposer(); renderSidebar();
}
async function onSend() {
  const rec = active(); if (!rec) return;
  const text = $('input').value.trim();
  if (!text) return;
  $('input').value = ''; $('input').style.height = 'auto'; hidePopup();
  if (text.startsWith('/') && runSlash(rec, text)) return;
  sendText(rec, text);
}
$('sendBtn').onclick = onSend;
$('stopBtn').onclick = () => { const rec = active(); if (rec) H.sessionAbort(rec.meta.id); };

// ---------------------------------------------------------------- slash commands
const SLASH = [
  { cmd: '/new', desc: 'New chat' },
  { cmd: '/clear', desc: 'Clear this conversation' },
  { cmd: '/compact', desc: 'Summarize & compress the context' },
  { cmd: '/model', desc: 'Choose a model' },
  { cmd: '/mode ask', desc: 'Approve every change' },
  { cmd: '/mode auto', desc: 'Auto-approve routine work (destructive still asks)' },
  { cmd: '/mode plan', desc: 'Read-only planning' },
  { cmd: '/dir', desc: 'Change the working directory' },
  { cmd: '/diff', desc: 'Toggle the changes panel' },
  { cmd: '/rename <title>', desc: 'Rename this chat' },
  { cmd: '/help', desc: 'Show available commands' },
];
function runSlash(rec, text) {
  const [cmd, ...rest] = text.split(/\s+/);
  const arg = rest.join(' ');
  if (cmd === '/new') { newChat(); return true; }
  if (cmd === '/clear') { H.sessionClear(rec.meta.id).then(() => { rec.logEl.innerHTML = ''; rec.cur = null; addLine(rec, 'done', 'conversation cleared.'); }); return true; }
  if (cmd === '/compact') {
    rec.streaming = true; updateComposer(); addLine(rec, 'done', '✦ compacting context…');
    H.sessionCompact(rec.meta.id).then((r) => { if (!r.ok && r.error) { addLine(rec, 'err', '⚠︎ ' + r.error); endTurn(rec); } });
    return true;
  }
  if (cmd === '/model') { openModelSheet(); return true; }
  if (cmd === '/mode') {
    if (['ask', 'auto', 'plan'].includes(arg)) setSessionConfig({ mode: arg });
    else addLine(rec, 'err', 'usage: /mode ask|auto|plan');
    return true;
  }
  if (cmd === '/dir') { pickDir(); return true; }
  if (cmd === '/diff') { toggleDiff(); return true; }
  if (cmd === '/rename') { if (arg) H.sessionRename(rec.meta.id, arg); return true; }
  if (cmd === '/help') { addLine(rec, 'done', SLASH.map((s) => s.cmd + ' — ' + s.desc).join('\n')); return true; }
  return false;   // not a command → send as a normal message
}

// ---------------------------------------------------------------- popup (@files + /commands)
const pop = { mode: null, items: [], sel: 0, mStart: 0, mLen: 0 };
function hidePopup() { pop.mode = null; $('popup').style.display = 'none'; }
function renderPopup() {
  const box = $('popup');
  if (!pop.items.length) { hidePopup(); return; }
  box.innerHTML = '';
  pop.items.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'pop-row' + (i === pop.sel ? ' sel' : '');
    row.innerHTML = '<span class="p-main">' + esc(it.main) + '</span>' + (it.hint ? '<span class="p-hint">' + esc(it.hint) + '</span>' : '');
    row.onmousedown = (e) => { e.preventDefault(); choosePopup(i); };
    box.appendChild(row);
  });
  box.style.display = '';
  box.querySelector('.pop-row.sel') && box.querySelector('.pop-row.sel').scrollIntoView({ block: 'nearest' });
}
async function updatePopup() {
  const i = $('input');
  const posn = i.selectionStart;
  const before = i.value.slice(0, posn);
  const m = before.match(/(^|\s)@([^\s@]*)$/);
  if (m) {
    const rec = active(); if (!rec) return hidePopup();
    if (!rec.files) rec.files = await H.listFiles(rec.meta.id);
    const q = m[2].toLowerCase();
    const list = (q ? rec.files.filter((f) => f.toLowerCase().includes(q)) : rec.files).slice(0, 12);
    pop.mode = 'mention'; pop.sel = 0;
    pop.mStart = posn - m[2].length - 1; pop.mLen = m[2].length + 1;
    pop.items = list.map((f) => ({ main: f, insert: '@' + f + ' ' }));
    renderPopup();
    return;
  }
  if (i.value.startsWith('/') && !i.value.includes('\n')) {
    const q = i.value.toLowerCase();
    const list = SLASH.filter((s) => s.cmd.startsWith(q) || q === '/');
    pop.mode = 'slash'; pop.sel = 0;
    pop.items = list.map((s) => ({ main: s.cmd, hint: s.desc, insert: s.cmd.replace(' <title>', ' ') }));
    renderPopup();
    return;
  }
  hidePopup();
}
function choosePopup(idx) {
  const it = pop.items[idx]; if (!it) return;
  const i = $('input');
  if (pop.mode === 'mention') {
    i.value = i.value.slice(0, pop.mStart) + it.insert + i.value.slice(pop.mStart + pop.mLen);
    const at = pop.mStart + it.insert.length;
    i.setSelectionRange(at, at);
  } else {
    i.value = it.insert.endsWith(' ') ? it.insert : it.insert;
    i.setSelectionRange(i.value.length, i.value.length);
    if (!it.insert.endsWith(' ')) { hidePopup(); i.focus(); onSend(); return; }
  }
  hidePopup(); i.focus();
}

// ---------------------------------------------------------------- composer keys
const input = $('input');
input.addEventListener('input', () => {
  input.style.height = 'auto'; input.style.height = Math.min(180, input.scrollHeight) + 'px';
  updatePopup();
});
input.addEventListener('keydown', (ev) => {
  if (pop.mode) {
    if (ev.key === 'ArrowDown') { ev.preventDefault(); pop.sel = Math.min(pop.sel + 1, pop.items.length - 1); renderPopup(); return; }
    if (ev.key === 'ArrowUp') { ev.preventDefault(); pop.sel = Math.max(pop.sel - 1, 0); renderPopup(); return; }
    if (ev.key === 'Tab' || ev.key === 'Enter') { ev.preventDefault(); choosePopup(pop.sel); return; }
    if (ev.key === 'Escape') { ev.preventDefault(); hidePopup(); return; }
  }
  if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); onSend(); return; }
  if (ev.key === 'Escape') {
    const rec = active();
    if (rec && rec.streaming) { ev.preventDefault(); H.sessionAbort(rec.meta.id); }
  }
  if (ev.key === 'Tab' && ev.shiftKey) { ev.preventDefault(); cycleMode(); }
});

// ---------------------------------------------------------------- titlebar actions
async function setSessionConfig(patch) {
  const rec = active(); if (!rec) return;
  const m = await H.sessionConfig(rec.meta.id, patch);
  if (m) rec.meta = m;
  updateTitlebar(); renderSidebar();
}
const MODE_CYCLE = { ask: 'auto', auto: 'plan', plan: 'ask' };
function cycleMode() { const rec = active(); if (rec) setSessionConfig({ mode: MODE_CYCLE[rec.meta.mode] || 'ask' }); }
async function pickDir() {
  const rec = active(); if (!rec) return;
  const d = await H.pickDir(rec.meta.id);
  if (d) { rec.meta.cwd = d; rec.files = null; updateTitlebar(); if (S.diffOpen) refreshGit(); }
}
$('modeBtn').onclick = cycleMode;
$('dirBtn').onclick = pickDir;
async function newChat() {
  const m = await H.sessionCreate({});
  await refreshSessions();
  activate(m.id);
}
$('newBtn').onclick = newChat;
$('sideToggle').onclick = () => {
  const sb = $('sidebar');
  sb.classList.toggle('hidden');
  document.querySelector('.titlebar').classList.toggle('no-side', sb.classList.contains('hidden'));
};

// ---------------------------------------------------------------- approvals
H.onApproval((a) => {
  const rec = S.recs.get(a.sessionId);
  if (!rec) { H.respondApproval(a.id, false); return; }
  rec.approvals.push(a);
  renderSidebar();
  maybeShowApproval();
});
function maybeShowApproval() {
  if (S.showingApproval) return;
  const rec = active(); if (!rec || !rec.approvals.length) return;
  const a = rec.approvals[0];
  S.showingApproval = a;
  $('apKind').textContent = a.kind;
  $('apSession').textContent = shortModel(rec.meta.model) + ' · ' + rec.meta.title;
  $('apDetail').textContent = a.detail;
  const inner = $('approvalModal').querySelector('.modal-inner');
  inner.classList.toggle('danger-modal', !!a.danger);
  $('apWarn').style.display = a.danger ? 'block' : 'none';
  $('approvalModal').style.display = 'flex';
}
function respondApproval(ok) {
  const a = S.showingApproval; if (!a) return;
  $('approvalModal').style.display = 'none';
  H.respondApproval(a.id, ok);
  const rec = S.recs.get(a.sessionId);
  if (rec) rec.approvals = rec.approvals.filter((x) => x.id !== a.id);
  S.showingApproval = null;
  renderSidebar();
  setTimeout(maybeShowApproval, 60);
}
$('apAllow').onclick = () => respondApproval(true);
$('apDeny').onclick = () => respondApproval(false);
document.addEventListener('keydown', (e) => {
  if ($('approvalModal').style.display !== 'flex') return;
  if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); respondApproval(true); }
  else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); respondApproval(false); }
}, true);

// ---------------------------------------------------------------- git changes panel
function toggleDiff() {
  S.diffOpen = !S.diffOpen;
  $('diffPanel').style.display = S.diffOpen ? '' : 'none';
  if (S.diffOpen) refreshGit();
}
$('diffToggle').onclick = toggleDiff;
$('diffClose').onclick = toggleDiff;
$('gitRefresh').onclick = () => refreshGit();
async function refreshGit() {
  const rec = active(); if (!rec) return;
  const st = await H.gitStatus(rec.meta.id);
  const box = $('gitFiles');
  if (!st.repo) {
    $('gitBranch').textContent = '';
    box.innerHTML = '<div class="git-empty">Not a git repository.<br>Inline diffs still appear in the chat.</div>';
    $('gitDiffView').textContent = '';
    return;
  }
  $('gitBranch').textContent = '⎇ ' + st.branch;
  if (!st.files.length) {
    box.innerHTML = '<div class="git-empty">Working tree clean.</div>';
    $('gitDiffView').textContent = '';
    S.selGitFile = null;
    return;
  }
  box.innerHTML = '';
  for (const f of st.files) {
    const el = document.createElement('div');
    el.className = 'gf' + (f.path === S.selGitFile ? ' sel' : '');
    const stLetter = f.status === '??' ? 'U' : f.status[0];
    el.innerHTML = '<span class="g-st ' + esc(stLetter) + '">' + esc(f.status === '??' ? 'U' : f.status) + '</span><span class="g-path">' + esc(f.path) + '</span>';
    el.onclick = () => { S.selGitFile = f.path; refreshGitSel(); showFileDiff(f.path); };
    box.appendChild(el);
  }
  if (S.selGitFile && st.files.some((f) => f.path === S.selGitFile)) showFileDiff(S.selGitFile);
  else if (st.files.length) { S.selGitFile = st.files[0].path; refreshGitSel(); showFileDiff(S.selGitFile); }
}
function refreshGitSel() {
  for (const el of document.querySelectorAll('.gf')) {
    el.classList.toggle('sel', el.querySelector('.g-path').textContent === S.selGitFile);
  }
}
async function showFileDiff(file) {
  const rec = active(); if (!rec) return;
  const { diff } = await H.gitDiff(rec.meta.id, file);
  const view = $('gitDiffView');
  if (!diff) { view.textContent = '(no diff)'; return; }
  view.innerHTML = diff.split('\n').map((l) => {
    if (l.startsWith('+++') || l.startsWith('---') || l.startsWith('diff ') || l.startsWith('index ') || l.startsWith('new file') || l.startsWith('deleted')) return '<span class="gl-meta">' + esc(l) + '</span>';
    if (l.startsWith('@@')) return '<span class="gl-hunk">' + esc(l) + '</span>';
    if (l.startsWith('+')) return '<span class="gl-add">' + esc(l) + '</span>';
    if (l.startsWith('-')) return '<span class="gl-del">' + esc(l) + '</span>';
    return esc(l) + '\n';
  }).join('');
}

// ---------------------------------------------------------------- model sheet
async function openModelSheet(forceRefresh) {
  $('modelSheet').style.display = 'flex';
  $('modelSearch').value = ''; $('modelSearch').focus();
  if (!S.models.length || forceRefresh) {
    $('modelCount').textContent = 'Loading…';
    S.models = await H.listModels(!!forceRefresh);
  }
  renderModels('');
}
$('modelBtn').onclick = () => openModelSheet(false);
$('modelRefresh').onclick = () => openModelSheet(true);
$('modelClose').onclick = () => { $('modelSheet').style.display = 'none'; };
$('modelSearch').addEventListener('input', (e) => renderModels(e.target.value));
$('modelSearch').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { const q = e.target.value.trim(); if (q) chooseModel(q); }
  if (e.key === 'Escape') { $('modelSheet').style.display = 'none'; }
});
function priceStr(m) {
  if (!m.pricing) return '';
  const pin = m.pricing.prompt * 1e6, pout = m.pricing.completion * 1e6;
  if (!pin && !pout) return 'free';
  return '$' + pin.toFixed(2) + ' / $' + pout.toFixed(2) + ' per M';
}
function renderModels(q) {
  const rec = active();
  const s = q.trim().toLowerCase();
  const list = s ? S.models.filter((m) => m.value.toLowerCase().includes(s) || m.label.toLowerCase().includes(s)) : S.models;
  $('modelCount').textContent = list.length + ' of ' + S.models.length + ' models' +
    (s && !S.models.some((m) => m.value === q.trim()) ? ' · Enter to use “' + q.trim() + '”' : '');
  const box = $('modelList'); box.innerHTML = '';
  for (const m of list.slice(0, 400)) {
    const row = document.createElement('div');
    row.className = 'model-row' + (rec && m.value === rec.meta.model ? ' sel' : '');
    row.innerHTML = '<div class="m-line"><div>' + esc(m.label) + '</div><div class="m-price">' + esc(priceStr(m)) + '</div></div>' +
      '<div class="mv">' + esc(m.value) + (m.context ? ' · ' + Math.round(m.context / 1000) + 'k ctx' : '') + '</div>';
    row.onclick = () => chooseModel(m.value);
    box.appendChild(row);
  }
}
async function chooseModel(v) {
  await setSessionConfig({ model: v });
  $('modelSheet').style.display = 'none';
}

// ---------------------------------------------------------------- settings
$('settingsBtn').onclick = () => { $('settingsSheet').style.display = 'flex'; $('keyInput').value = ''; };
$('settingsClose').onclick = () => { $('settingsSheet').style.display = 'none'; };
$('sessionsFolderBtn').onclick = () => H.openSessionsFolder();
$('keySave').onclick = async () => {
  const k = $('keyInput').value.trim();
  if (k) { await H.setConfig({ apiKey: k }); S.models = []; }
  $('settingsSheet').style.display = 'none';
};

// ---------------------------------------------------------------- global keys
document.addEventListener('keydown', (e) => {
  const mod = e.metaKey || e.ctrlKey;
  if (mod && e.key.toLowerCase() === 'n') { e.preventDefault(); newChat(); }
  else if (mod && e.key.toLowerCase() === 'k') { e.preventDefault(); openModelSheet(false); }
  else if (mod && e.key.toLowerCase() === 'b') { e.preventDefault(); $('sideToggle').onclick(); }
  else if (mod && e.key.toLowerCase() === 'd') { e.preventDefault(); toggleDiff(); }
  else if (mod && e.key >= '1' && e.key <= '9') {
    const idx = +e.key - 1;
    if (S.order[idx]) { e.preventDefault(); activate(S.order[idx]); }
  }
  else if (e.key === 'Escape' && $('approvalModal').style.display !== 'flex') {
    if ($('modelSheet').style.display === 'flex') $('modelSheet').style.display = 'none';
    else if ($('settingsSheet').style.display === 'flex') $('settingsSheet').style.display = 'none';
  }
});

// ---------------------------------------------------------------- boot
(async function boot() {
  const metas = await H.sessionsList();
  if (!metas.length) await H.sessionCreate({});
  await refreshSessions();
  if (S.order.length) activate(S.order[0]);
  const cfg = await H.getConfig();
  if (!cfg.hasKey) $('settingsSheet').style.display = 'flex';
  setInterval(renderSidebar, 60000);   // keep "2m ago" labels fresh
})();
