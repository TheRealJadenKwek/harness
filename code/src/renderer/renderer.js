'use strict';
const H = window.harness;
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- state
const S = {
  recs: new Map(),      // id -> { meta, logEl, loaded, cur, queued: [], approvals: [], files: null, streaming: false }
  order: [],            // session ids, most recent first (sidebar order)
  active: null,         // active session id
  models: [],
  skills: [],
  showingApproval: null,
  panel: null,           // null | 'changes' | 'files' | 'tasks' | 'preview'
  selGitFile: null,
  tasks: new Map(),      // taskId -> meta
  selTask: null,
  selFile: null,
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
// compact single-pass syntax highlighter: comment | string | keyword | number
const HL_KW = {
  js: 'const|let|var|function|return|if|else|for|while|do|class|extends|import|from|export|default|new|async|await|try|catch|finally|throw|typeof|instanceof|this|null|undefined|true|false|switch|case|break|continue|of|in|yield|static|get|set',
  py: 'def|return|if|elif|else|for|while|class|import|from|as|try|except|finally|raise|with|pass|yield|lambda|global|nonlocal|assert|del|not|and|or|in|is|None|True|False|self|async|await|print',
  swift: 'func|let|var|return|if|else|guard|for|while|class|struct|enum|extension|protocol|import|init|self|nil|true|false|try|catch|throw|throws|async|await|switch|case|default|break|continue|private|public|static|override|some|any|in',
  sh: 'if|then|else|elif|fi|for|do|done|while|case|esac|function|echo|export|local|return|exit|source|set|cd|sudo|true|false',
};
function hl(code, lang) {
  const e = esc(code);
  const L = (lang || '').toLowerCase();
  const fam = /^(py|python)$/.test(L) ? 'py' : /^(swift)$/.test(L) ? 'swift' : /^(sh|bash|zsh|shell)$/.test(L) ? 'sh'
            : /^(js|jsx|ts|tsx|javascript|typescript|json|java|c|cpp|cs|go|rust|kt)$/.test(L) ? 'js' : null;
  const kw = fam ? HL_KW[fam] : HL_KW.js + '|' + HL_KW.py;
  const cm = fam === 'py' || fam === 'sh' ? '#[^\\n]*' : fam === 'js' || fam === 'swift' ? '\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/' : '\\/\\/[^\\n]*|#[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/';
  const re = new RegExp('(' + cm + ')|("(?:\\\\.|[^"\\\\\\n])*"|\'(?:\\\\.|[^\'\\\\\\n])*\'|`(?:\\\\.|[^`\\\\])*`)|\\b(' + kw + ')\\b|\\b(0x[0-9a-fA-F]+|\\d+\\.?\\d*)\\b', 'g');
  return e.replace(re, (m, c, st, k, n) =>
    c ? '<span class="hl-cm">' + c + '</span>'
    : st ? '<span class="hl-str">' + st + '</span>'
    : k ? '<span class="hl-kw">' + k + '</span>'
    : '<span class="hl-num">' + n + '</span>');
}
function md(src) {
  const blocks = [];
  let s = String(src || '');
  s = s.replace(/```([\w+-]*)\n?([\s\S]*?)(?:```|$)/g, (_, lang, code) => {
    blocks.push('<pre class="code">' + (lang ? '<span class="code-lang">' + esc(lang) + '</span>' : '')
      + '<button class="code-copy" title="Copy code">⧉</button><code>' + hl(code.replace(/\n$/, ''), lang) + '</code></pre>');
    return '\uE000' + (blocks.length - 1) + '\uE001';
  });
  s = esc(s);
  s = s.replace(/`([^`\n]+)`/g, '<code class="ic">$1</code>');
  s = s.replace(/^#### (.*)$/gm, '<h4>$1</h4>');
  s = s.replace(/^### (.*)$/gm, '<h4>$1</h4>');
  s = s.replace(/^## (.*)$/gm, '<h3>$1</h3>');
  s = s.replace(/^# (.*)$/gm, '<h2>$1</h2>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" class="ext">$1</a>');
  s = s.replace(/\[([^\]]+)\]\((?:sandbox:|file:\/\/)?(\/[^)\s]+)\)/g, '<a class="reveal" data-p="$2">$1 ↗</a>');
  s = s.replace(/^(\s*)[-*] /gm, '$1• ');
  s = s.replace(/(?:^\|.+\|[ \t]*(?:\n|$)){2,}/gm, (block) => {
    const rows = block.trim().split('\n').map((r) => r.replace(/^\s*\||\|\s*$/g, '').split('|').map((c) => c.trim()));
    if (rows.length < 2 || !/^[:\s|-]+$/.test(rows[1].join('|'))) return block;
    const head = rows[0], body = rows.slice(2);
    return '<div class="tbl-wrap"><table><thead><tr>' + head.map((c) => '<th>' + c + '</th>').join('')
      + '</tr></thead><tbody>' + body.map((r) => '<tr>' + r.map((c) => '<td>' + c + '</td>').join('') + '</tr>').join('')
      + '</tbody></table></div>';
  });
  s = s.replace(/\uE000(\d+)\uE001/g, (_, i) => blocks[+i]);
  s = s.replace(/<\/(h2|h3|h4|pre)>\n/g, '</$1>');
  return s;
}
const svgIcon = (path, size = 13) => '<svg width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-2px">' + path + '</svg>';
const UI_ICON = {
  brain: svgIcon('<path d="M9.5 2A2.5 2.5 0 0 1 12 4.5v15a2.5 2.5 0 0 1-4.96.44A2.5 2.5 0 0 1 4.5 18a2.5 2.5 0 0 1-.5-4.95 2.5 2.5 0 0 1 .5-4.9A2.5 2.5 0 0 1 7 4.5 2.5 2.5 0 0 1 9.5 2Z"/><path d="M14.5 2A2.5 2.5 0 0 0 12 4.5v15a2.5 2.5 0 0 0 4.96.44A2.5 2.5 0 0 0 19.5 18a2.5 2.5 0 0 0 .5-4.95 2.5 2.5 0 0 0-.5-4.9A2.5 2.5 0 0 0 17 4.5 2.5 2.5 0 0 0 14.5 2Z"/>'),
  image: svgIcon('<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="9" cy="9" r="1.8"/><path d="m21 15-4.5-4.5L6 21"/>'),
  chip: svgIcon('<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>'),
  folder: svgIcon('<path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.7-.9L9.2 3.9A2 2 0 0 0 7.5 3H4a2 2 0 0 0-2 2v13c0 1.1.9 2 2 2Z"/>'),
  mic: svgIcon('<path d="M12 2a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V5a3 3 0 0 1 3-3Z"/><path d="M19 10v1a7 7 0 0 1-14 0v-1"/><path d="M12 18v4"/>', 14),
  files: svgIcon('<path d="M14 2H7a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7Z"/><path d="M14 2v5h5"/>'),
  paperclip: svgIcon('<path d="m21.4 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48"/>'),
};
document.addEventListener('click', (e) => {
  const a = e.target.closest && e.target.closest('a.ext');
  if (a) { e.preventDefault(); H.openExternal(a.href); }
  const r = e.target.closest && e.target.closest('a.reveal');
  if (r) { e.preventDefault(); H.revealFile(r.dataset.p); }
});

// ---------------------------------------------------------------- chat rendering
function logOf(rec) { return rec.logEl; }
function atBottom(el) { return el.scrollHeight - el.scrollTop - el.clientHeight < 90; }
function scrollLog(rec) { const el = logOf(rec); requestAnimationFrame(() => { el.scrollTop = el.scrollHeight; }); }

function timeago(ts) {
  if (!ts) return '';
  const d = Date.now() - ts;
  if (d < 60e3) return 'just now';
  if (d < 3600e3) return Math.floor(d / 60e3) + ' minute' + (Math.floor(d / 60e3) > 1 ? 's' : '') + ' ago';
  if (d < 86400e3) return Math.floor(d / 3600e3) + ' hour' + (Math.floor(d / 3600e3) > 1 ? 's' : '') + ' ago';
  if (d < 7 * 86400e3) return Math.floor(d / 86400e3) + ' day' + (Math.floor(d / 86400e3) > 1 ? 's' : '') + ' ago';
  return new Date(ts).toLocaleDateString();
}
function addUser(rec, text, imageCount, meta) {
  clearEmpty(rec);
  const wrap = document.createElement('div'); wrap.className = 'msg-wrap';
  const thumbs = (meta && meta.thumbs) || [];
  if (thumbs.length) {
    const tr = document.createElement('div'); tr.className = 'user-thumbs';
    for (const u of thumbs) { const im = document.createElement('img'); im.src = u; tr.appendChild(im); }
    wrap.appendChild(tr);
  }
  const el = document.createElement('div'); el.className = 'msg user';
  el.textContent = (imageCount && !thumbs.length ? '🖼 ' + imageCount + ' image' + (imageCount > 1 ? 's' : '') + '\n' : '') + text;
  wrap.appendChild(el);
  const n = meta && meta.n !== undefined ? meta.n : rec.userN++;
  const raw = (meta && meta.raw !== undefined) ? meta.raw : text;
  const ctl = document.createElement('div'); ctl.className = 'mctl';
  const mkBtn = (glyph, tip, fn) => {
    const b = document.createElement('button'); b.className = 'mctl-btn'; b.textContent = glyph; b.title = tip;
    b.onclick = fn; ctl.appendChild(b);
  };
  mkBtn('⧉', 'Copy message', () => H.clipboardWrite(raw));
  mkBtn('↩', 'Rewind — remove this message and everything after it, put it back in the composer', () => doRewind(rec, n, raw));
  mkBtn('⑂', 'Fork a new chat from this point', () => doForkAt(rec, n, raw));
  const t = document.createElement('span'); t.className = 'mctl-time';
  const ts = meta && meta.ts;
  t.textContent = timeago(ts);
  if (ts) { t.title = new Date(ts).toLocaleString(); wrap.onmouseenter = () => { t.textContent = timeago(ts); }; }
  ctl.appendChild(t);
  wrap.appendChild(ctl);
  logOf(rec).appendChild(wrap); scrollLog(rec);
}
async function rerenderLog(rec) {
  rec.logEl.innerHTML = ''; rec.cur = null; rec.userN = 0; rec.planEl = null; rec.lastTool = null;
  const d = await H.sessionGet(rec.meta.id);
  if (d) { rec.meta = d.meta; for (const item of d.transcript) renderItem(rec, item); rec.cur = null; }
  rec.logEl.scrollTop = rec.logEl.scrollHeight;
}
async function doRewind(rec, n, text) {
  if (rec.streaming) { addLine(rec, 'err', '⚠︎ wait for the current turn to finish before rewinding'); return; }
  if (!confirm('Rewind the conversation to before this message? Everything after it is removed (the message text goes back into the composer).')) return;
  const r = await H.sessionRewind(rec.meta.id, n);
  if (r && r.ok) {
    await rerenderLog(rec);
    const inp = $('input');
    inp.value = r.text || text; inp.dispatchEvent(new Event('input')); inp.focus();
  } else addLine(rec, 'err', '⚠︎ ' + ((r && r.error) || 'rewind failed'));
}
async function doForkAt(rec, n, text) {
  const r = await H.sessionForkAt(rec.meta.id, n);
  if (!r || !r.meta) { addLine(rec, 'err', '⚠︎ fork failed'); return; }
  await refreshSessions();
  activate(r.meta.id);
  const inp = $('input');
  inp.value = r.text || text; inp.dispatchEvent(new Event('input')); inp.focus();
}
function addMedia(rec, p, kind) {
  const el = document.createElement('div');
  el.className = 'msg assistant';
  el.innerHTML = kind === 'video'
    ? '<video controls src="file://' + p + '" style="max-width:min(460px,100%);border-radius:12px"></video>'
    : '<img src="file://' + p + '" style="max-width:min(420px,100%);border-radius:12px;cursor:pointer">';
  if (kind !== 'video') el.querySelector('img').onclick = () => H.revealFile(p);
  logOf(rec).appendChild(el); scrollLog(rec);
}
function addSideChat(rec, q, a) {   // legacy inline replay of old {t:'sidechat'} items
  clearEmpty(rec);
  const el = document.createElement('div'); el.className = 'sidechat';
  el.innerHTML = '<div class="sc-head">◦ side chat</div><div class="sc-q"></div><div class="sc-a"></div>';
  el.querySelector('.sc-q').textContent = q;
  el.querySelector('.sc-a').textContent = a || '';
  logOf(rec).appendChild(el); scrollLog(rec); return el;
}

// ---- side chat popup (/btw): its own thread, never touches the agent context ----
function scEl() { return document.getElementById('scpop'); }
function scScroll() { const b = document.getElementById('scBody'); if (b) b.scrollTop = b.scrollHeight; }
// popup placement state: free position or docked as a top-right tab
function scState() { try { return JSON.parse(localStorage.scPos || '{}'); } catch { return {}; } }
function scSaveState(patch) { localStorage.scPos = JSON.stringify({ ...scState(), ...patch }); }
function scApplyPos(pop) {
  const st = scState();
  if (st.docked) {
    pop.style.left = 'auto'; pop.style.top = '82px'; pop.style.right = '14px'; pop.style.bottom = 'auto';
  } else if (typeof st.x === 'number') {
    const r = pop.getBoundingClientRect();
    const x = Math.min(Math.max(st.x, 8), innerWidth - (r.width || 400) - 8);
    const y = Math.min(Math.max(st.y, 8), innerHeight - 80);
    pop.style.left = x + 'px'; pop.style.top = y + 'px'; pop.style.right = 'auto'; pop.style.bottom = 'auto';
  }
}
function scTabEl() { return document.getElementById('sctab'); }
function scShowTab() {
  let tab = scTabEl();
  if (!tab) {
    tab = document.createElement('button');
    tab.id = 'sctab';
    tab.innerHTML = '◦ Side chat<span class="sct-dot"></span>';
    tab.title = 'Side chat (docked) — click to open';
    tab.onmousedown = (e) => {
      e.preventDefault();
      const sx = e.clientX, sy = e.clientY;
      let moved = false;
      const GRAB_X = 70, GRAB_Y = 16;   // where the header lands under the cursor
      const move = (ev) => {
        if (!moved && Math.hypot(ev.clientX - sx, ev.clientY - sy) > 6) {
          moved = true;
          const r = active(); if (!r) return;
          scUndock();
          openSidePopup(r);
        }
        if (!moved) return;
        const pop = scEl(); if (!pop) return;
        const rct = pop.getBoundingClientRect();
        const x = Math.min(Math.max(ev.clientX - GRAB_X, 8), innerWidth - rct.width - 8);
        const y = Math.min(Math.max(ev.clientY - GRAB_Y, 8), innerHeight - rct.height - 8);
        pop.style.left = x + 'px'; pop.style.top = y + 'px';
        pop.style.right = 'auto'; pop.style.bottom = 'auto';
        pop.classList.toggle('sc-snap', (innerWidth - (x + rct.width) < 80) && (y < 90));
      };
      const up = () => {
        document.removeEventListener('mousemove', move);
        document.removeEventListener('mouseup', up);
        if (!moved) {   // plain click: toggle open/closed
          const pop = scEl();
          const r = active(); if (!r) return;
          if (pop && pop.style.display !== 'none') pop.style.display = 'none';
          else openSidePopup(r);
          tab.classList.remove('unread');
          return;
        }
        const pop = scEl(); if (!pop) return;
        pop.classList.remove('sc-snap');
        const rct = pop.getBoundingClientRect();
        if ((innerWidth - rct.right < 80) && (rct.top < 90)) scDock();
        else scSaveState({ x: rct.left, y: rct.top, docked: false });
      };
      document.addEventListener('mousemove', move);
      document.addEventListener('mouseup', up);
    };
    document.body.appendChild(tab);
  }
  tab.style.display = '';
}
function scDock() {
  scSaveState({ docked: true });
  const pop = scEl();
  if (pop) { pop.style.display = 'none'; }
  scShowTab();
}
function scUndock() {
  scSaveState({ docked: false });
  const tab = scTabEl();
  if (tab) tab.style.display = 'none';
}
function openSidePopup(rec) {
  let pop = scEl();
  if (!pop) {
    pop = document.createElement('div');
    pop.id = 'scpop';
    pop.innerHTML = '<div class="sc-bar"><span>Side chat</span><span class="sc-note">separate from the session</span><span style="flex:1"></span>'
      + '<button class="sc-btn" id="scClear" title="Clear side chat">🗑</button><button class="sc-btn" id="scClose" title="Close">✕</button></div>'
      + '<div id="scBody"></div>'
      + '<div class="sc-inrow"><textarea id="scInput" rows="1" placeholder="Ask on the side…"></textarea><button class="sc-btn" id="scSend" title="Send">↵</button></div>';
    document.body.appendChild(pop);
    // drag anywhere by the header; drop near the top-right corner to dock into a tab
    const bar = pop.querySelector('.sc-bar');
    bar.addEventListener('mousedown', (e) => {
      if (e.target.closest('.sc-btn')) return;
      e.preventDefault();
      const r = pop.getBoundingClientRect();
      const dx = e.clientX - r.left, dy = e.clientY - r.top;
      let snapping = false;
      const move = (ev) => {
        const x = Math.min(Math.max(ev.clientX - dx, 8), innerWidth - r.width - 8);
        const y = Math.min(Math.max(ev.clientY - dy, 8), innerHeight - r.height - 8);
        pop.style.left = x + 'px'; pop.style.top = y + 'px';
        pop.style.right = 'auto'; pop.style.bottom = 'auto';
        snapping = (innerWidth - (x + r.width) < 80) && (y < 90);
        pop.classList.toggle('sc-snap', snapping);
      };
      const up = () => {
        document.removeEventListener('mousemove', move);
        document.removeEventListener('mouseup', up);
        pop.classList.remove('sc-snap');
        if (snapping) { scDock(); return; }
        const rr = pop.getBoundingClientRect();
        scUndock();
        scSaveState({ x: rr.left, y: rr.top });
      };
      document.addEventListener('mousemove', move);
      document.addEventListener('mouseup', up);
    });
    document.getElementById('scClose').onclick = () => { pop.style.display = 'none'; if (scState().docked) scShowTab(); };
    document.getElementById('scClear').onclick = () => {
      const r = active(); if (!r) return;
      r.side = []; document.getElementById('scBody').innerHTML = '';
      H.sideClear(r.meta.id);
    };
    const inp = document.getElementById('scInput');
    document.getElementById('scSend').onclick = () => { const r = active(); if (r && inp.value.trim()) { sideSend(r, inp.value.trim()); inp.value = ''; } };
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); document.getElementById('scSend').click(); }
      if (e.key === 'Escape') pop.style.display = 'none';
    });
  }
  pop.style.display = 'flex';
  scApplyPos(pop);
  if (scState().docked) scShowTab();
  const body = document.getElementById('scBody');
  body.innerHTML = '';
  rec.side = rec.side || [];
  for (const m of rec.side) scBubble(m.role, m.content);
  scScroll();
  document.getElementById('scInput').focus();
}
function scBubble(role, text) {
  const body = document.getElementById('scBody');
  const el = document.createElement('div');
  el.className = 'sc-msg ' + (role === 'user' ? 'me' : 'bot');
  if (role === 'assistant') { el.innerHTML = md(text); el.classList.add('md'); }
  else el.textContent = text;
  body.appendChild(el);
  return el;
}
function sideSend(rec, q) {
  if (!scEl() || scEl().style.display === 'none') openSidePopup(rec);
  rec.side = rec.side || [];
  rec.side.push({ role: 'user', content: q });
  scBubble('user', q);
  const el = scBubble('assistant', '');
  el.classList.add('live');
  rec.sideStream = { el, acc: '' };
  scScroll();
  H.sideChat(rec.meta.id, q).then((r) => {
    if (r && !r.ok) { el.textContent = '⚠︎ ' + (r.error || 'side chat failed'); el.classList.remove('live'); rec.sideStream = null; }
  });
}
function clearEmpty(rec) {
  const eh = logOf(rec).querySelector('.empty-home');
  if (eh) eh.remove();
}
function addLine(rec, cls, text) {
  clearEmpty(rec);
  const el = document.createElement('div'); el.className = cls; el.textContent = text;
  logOf(rec).appendChild(el); scrollLog(rec); return el;
}

function ensureAssistant(rec) {
  if (rec.cur) return rec.cur;
  clearEmpty(rec);
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
  c.mdTimer = setTimeout(() => { c.mdTimer = null; if (rec.cur === c) { c.textEl.innerHTML = md(c.raw); c.textEl.dataset.raw = c.raw; } }, 120);
}
function finalizeAssistant(rec, ts) {
  const c = rec.cur; if (!c) return;
  if (c.mdTimer) { clearTimeout(c.mdTimer); c.mdTimer = null; }
  c.textEl.innerHTML = md(c.raw);
  c.textEl.dataset.raw = c.raw;
  c.think.classList.add('closed');
  c.thinkHead.textContent = '✳ thought for a bit';
  if ((c.raw || '').trim() && !c.ctl) {
    const ctl = document.createElement('div'); ctl.className = 'mctl left';
    const b = document.createElement('button'); b.className = 'mctl-btn'; b.textContent = '⧉'; b.title = 'Copy response';
    const raw = c.raw;
    b.onclick = () => H.clipboardWrite(raw);
    ctl.appendChild(b);
    const t = document.createElement('span'); t.className = 'mctl-time';
    t.textContent = timeago(ts);
    if (ts) { t.title = new Date(ts).toLocaleString(); c.el.onmouseenter = () => { t.textContent = timeago(ts); }; }
    ctl.appendChild(t);
    c.el.appendChild(ctl);
    c.ctl = ctl;
  }
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
  el.innerHTML = '<div class="dfile">± ' + esc(file) + '<span class="dstats"><span class="ds-add">+' + adds + '</span><span class="ds-del">−' + dels + '</span></span></div>';
  el.appendChild(pre);
  if (lines > 24) {
    pre.classList.add('clamped');
    const more = document.createElement('button'); more.className = 'd-more'; more.textContent = '⌄ show all ' + lines + ' lines';
    more.onclick = () => { pre.classList.remove('clamped'); more.remove(); };
    el.appendChild(more);
  }
  logOf(rec).appendChild(el); scrollLog(rec);
}

// Live plan card: one per session, updated in place as the model checks items off.
function renderPlan(rec, items) {
  if (!rec.planEl || !rec.planEl.isConnected) {
    rec.planEl = document.createElement('div');
    rec.planEl.className = 'plan';
    logOf(rec).appendChild(rec.planEl);
  }
  rec.planEl.innerHTML = '<div class="plan-title">☰ Plan</div>' +
    items.map((i) => '<div class="plan-item' + (i.done ? ' done' : '') + '">' + (i.done ? '☑' : '☐') + ' ' + esc(i.text) + '</div>').join('');
  scrollLog(rec);
}

// Checkpoint line: click to restore every file this turn touched.
function addCkptLine(rec, ckptId, files) {
  const el = document.createElement('div');
  el.className = 'done ckpt';
  el.textContent = '⤺ revert this turn’s file changes (' + files + ' file' + (files > 1 ? 's' : '') + ')';
  el.title = 'Restores files changed by write/edit this turn. Bash side effects are not reverted.';
  el.onclick = async () => {
    if (!confirm('Revert ' + files + ' file change(s) from this turn?')) return;
    const r = await H.sessionRevert(rec.meta.id, ckptId);
    if (r && r.error) addLine(rec, 'err', '⚠︎ ' + r.error);
    if (S.panel === 'changes') refreshGit();
  };
  logOf(rec).appendChild(el);
  scrollLog(rec);
}

function renderItem(rec, item) {
  if (item.t === 'user') addUser(rec, (item.auto ? '🎯 ' : '') + (item.remote ? '📱 ' : '') + (item.steered ? '↳ ' : '') + item.text, item.images, { n: rec.userN++, ts: item.ts, raw: item.text, thumbs: item.thumbs });
  else if (item.t === 'sidechat') addSideChat(rec, item.q, item.a);
  else if (item.t === 'plan') { renderPlan(rec, item.items); rec.planEl = null; }
  else if (item.t === 'ckpt') addCkptLine(rec, item.id, item.files);
  else if (item.t === 'assistant') {
    const c = ensureAssistant(rec);
    if (item.think) { c.think.style.display = 'block'; c.thinkBody.textContent = item.think; }
    c.raw = item.text || '';
    finalizeAssistant(rec, item.ts);
  }
  else if (item.t === 'tool') addTool(rec, item.name, item.args, item.result === undefined ? { error: '(interrupted)' } : item.result);
  else if (item.t === 'diff') addDiff(rec, item.file, item.before, item.after);
  else if (item.t === 'media') addMedia(rec, item.path, item.kind);
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
  const rec = { meta, logEl, loaded: false, cur: null, queued: [], approvals: [], files: null, streaming: !!meta.streaming, lastTool: null, userN: 0 };
  S.recs.set(meta.id, rec);
  return rec;
}

async function deleteSession(id, title) {
  if (!confirm('Delete "' + (title || 'this chat') + '"?')) return;
  await H.sessionDelete(id);
  if (S.active === id) S.active = null;
  await refreshSessions();
  if (!S.active) {
    const next = S.order.find((sid) => S.recs.get(sid) && !S.recs.get(sid).meta.archived);
    if (next) activate(next);
    else { const nm = await H.sessionCreate({}); await refreshSessions(); activate(nm.id); }
  }
}

function sessEl(rec, badge) {
  const m = rec.meta;
  const el = document.createElement('div'); el.className = 'sess' + (m.id === S.active ? ' active' : '');
  const live = rec.approvals.length ? '<span class="s-live appr">⚠</span>' : (rec.streaming ? '<span class="s-live spin">●</span>' : '');
  el.innerHTML = '<div class="s-title">' + (m.unread ? '<span class="s-unread">●</span> ' : '') + (badge ? badge + ' ' : '') + esc(m.title) + '</div>' +
    '<div class="s-sub">' + esc(shortModel(m.model)) + ' · ' + timeAgo(m.updatedAt) + '</div>' +
    live + '<button class="s-x" title="Delete">✕</button>';
  el.onclick = () => activate(m.id);
  el.oncontextmenu = (e) => { e.preventDefault(); showCtxMenu(e.clientX, e.clientY, m.id); };
  el.querySelector('.s-x').onclick = (e) => { e.stopPropagation(); deleteSession(m.id, m.title); };
  return el;
}

function renderSidebar() {
  const box = $('sessionList'); box.innerHTML = '';
  const header = (t) => { const h = document.createElement('div'); h.className = 'side-sec'; h.textContent = t; box.appendChild(h); return h; };
  let metas = S.order.map((id) => S.recs.get(id)).filter(Boolean);
  if (S.searchIds) metas = metas.filter((r) => S.searchIds.includes(r.meta.id));   // cross-session search filter
  const act = metas.filter((r) => !r.meta.archived);
  const pinned = act.filter((r) => r.meta.pinned);
  const groups = {};
  const rest = [];
  for (const r of act.filter((r) => !r.meta.pinned)) {
    if (r.meta.group) (groups[r.meta.group] || (groups[r.meta.group] = [])).push(r);
    else rest.push(r);
  }
  if (pinned.length) { header('Pinned'); pinned.forEach((r) => box.appendChild(sessEl(r, '📌'))); }
  for (const g of Object.keys(groups).sort()) { header(g); groups[g].forEach((r) => box.appendChild(sessEl(r))); }
  if (rest.length && (pinned.length || Object.keys(groups).length)) header('Chats');
  rest.forEach((r) => box.appendChild(sessEl(r)));
  const arch = metas.filter((r) => r.meta.archived);
  if (arch.length) {
    const h = header('▸ Archived (' + arch.length + ')');
    h.classList.add('clickable');
    if (S.showArchived) h.textContent = '▾ Archived (' + arch.length + ')';
    h.onclick = () => { S.showArchived = !S.showArchived; renderSidebar(); };
    if (S.showArchived) arch.forEach((r) => box.appendChild(sessEl(r)));
  }
  // read-only CLI sessions (claude / codex desktop CLIs), live-tailed
  const ch = header((S.showCli ? '▾' : '▸') + ' CLI sessions');
  ch.classList.add('clickable');
  ch.onclick = async () => { S.showCli = !S.showCli; if (S.showCli) S.cliList = await H.cliSessions(); renderSidebar(); };
  if (S.showCli) {
    for (const cs of (S.cliList || [])) {
      const el = document.createElement('div');
      el.className = 'sess' + (S.cliView && S.cliView.path === cs.path ? ' active' : '');
      el.innerHTML = '<div class="s-title">' + (cs.engine === 'claude' ? '✳ ' : '⌬ ') + esc(cs.title) + '</div>' +
        '<div class="s-sub">' + esc(cs.engine) + ' cli · ' + timeAgo(cs.updated) + ' · read-only</div>';
      el.onclick = () => openCliView(cs.path);
      box.appendChild(el);
    }
    if (!(S.cliList || []).length) { const d = document.createElement('div'); d.className = 'git-empty'; d.textContent = 'No CLI sessions found.'; box.appendChild(d); }
  }
}

// ---- read-only CLI session viewer -----------------------------------------------
function closeCliView() {
  if (!S.cliView) return;
  clearInterval(S.cliView.timer);
  if (S.cliView.el) S.cliView.el.remove();
  S.cliView = null;
  for (const [rid, r] of S.recs) r.logEl.classList.toggle('active', rid === S.active);
  $('input').disabled = false;
  showSuggestion(active());
  renderSidebar();
}
async function openCliView(fp) {
  closeCliView();
  const el = document.createElement('div');
  el.className = 'log active';
  $('logs').appendChild(el);
  for (const [, r] of S.recs) r.logEl.classList.remove('active');
  S.cliView = { path: fp, el, mtime: 0, timer: null };
  $('input').disabled = true;
  $('input').placeholder = 'read-only CLI session — press Esc to return to your chats';
  const render = async () => {
    const d = await H.cliSessionGet(fp);
    if (!d || !S.cliView || S.cliView.path !== fp) return;
    if (d.updated === S.cliView.mtime) return;
    S.cliView.mtime = d.updated;
    const stick = atBottom(el);
    el.innerHTML = '';
    const ban = document.createElement('div'); ban.className = 'done';
    ban.textContent = '👁 read-only ' + d.engine + ' CLI session · ' + shortDir(d.cwd) + ' · updates live · Esc to close';
    el.appendChild(ban);
    for (const m of (d.messages || [])) {
      if (m.role === 'user') { const u = document.createElement('div'); u.className = 'msg user'; u.textContent = m.text; el.appendChild(u); }
      else { const a = document.createElement('div'); a.className = 'msg assistant'; const t = document.createElement('div'); t.className = 'md'; t.innerHTML = md(m.text); a.appendChild(t); el.appendChild(a); }
    }
    if (stick || !el.dataset.scrolled) { el.scrollTop = el.scrollHeight; el.dataset.scrolled = '1'; }
  };
  await render();
  S.cliView.timer = setInterval(render, 2000);
  renderSidebar();
}

// ---- right-click context menu on chats -------------------------------------------
let ctxEl = null;
function hideCtxMenu() { if (ctxEl) { ctxEl.remove(); ctxEl = null; } }
function showCtxMenu(x, y, id, view) {
  hideCtxMenu();
  const rec = S.recs.get(id); if (!rec) return;
  const m = rec.meta;
  ctxEl = document.createElement('div');
  ctxEl.className = 'menu ctx-menu';
  ctxEl.dataset.sessId = id;
  const item = (html, fn, cls) => {
    const d = document.createElement('div'); d.className = 'menu-item' + (cls ? ' ' + cls : ''); d.innerHTML = html;
    d.onmousedown = (e) => e.stopPropagation();
    d.onclick = fn; ctxEl.appendChild(d); return d;
  };
  const sep = () => { const d = document.createElement('div'); d.className = 'menu-sep'; ctxEl.appendChild(d); };
  const patch = async (p) => { hideCtxMenu(); const nm = await H.sessionMeta(id, p); if (nm) rec.meta = nm; renderSidebar(); };

  if (view === 'openin') {
    item('‹ Open in', (e) => { e.stopPropagation(); reopen('root'); });
    sep();
    for (const [t, label] of [['finder', 'Finder'], ['terminal', 'Terminal'], ['vscode', 'VS Code']]) {
      item(label, async () => { hideCtxMenu(); const r = await H.openIn(id, t); if (r && r.error) alert(r.error); });
    }
  } else if (view === 'group') {
    item('‹ Move to group', (e) => { e.stopPropagation(); reopen('root'); });
    sep();
    const names = [...new Set([...S.recs.values()].map((r) => r.meta.group).filter(Boolean))].sort();
    for (const g of names) item((m.group === g ? '✓ ' : '') + esc(g), () => patch({ group: g }));
    item('＋ New group…', () => {
      const g = prompt('Group name:'); if (g && g.trim()) patch({ group: g.trim().slice(0, 30) }); else hideCtxMenu();
    });
    if (m.group) { sep(); item('Remove from group', () => patch({ group: null })); }
  } else {
    item('Open in <span class="mi-hint">›</span>', (e) => { e.stopPropagation(); reopen('openin'); });
    sep();
    item((m.pinned ? 'Unpin' : 'Pin') + ' <span class="mi-hint">P</span>', () => patch({ pinned: !m.pinned }));
    item('Mark as ' + (m.unread ? 'read' : 'unread') + ' <span class="mi-hint">U</span>', () => patch({ unread: !m.unread }));
    item('Rename <span class="mi-hint">R</span>', () => {
      const t = prompt('Rename chat:', m.title); if (t && t.trim()) patch({ title: t.trim() }); else hideCtxMenu();
    });
    item('Fork <span class="mi-hint">F</span>', async () => {
      hideCtxMenu();
      const nm = await H.sessionFork(id);
      if (nm) { await refreshSessions(); activate(nm.id); }
    });
    item('Fork to worktree <span class="mi-hint">W</span>', async () => {
      hideCtxMenu();
      const nm = await H.sessionWorktree(id);
      if (nm && nm.error) { alert(nm.error); return; }
      if (nm) { await refreshSessions(); activate(nm.id); }
    });
    sep();
    item('Move to group <span class="mi-hint">›</span>', (e) => { e.stopPropagation(); reopen('group'); });
    sep();
    item((m.archived ? 'Unarchive' : 'Archive') + ' <span class="mi-hint">A</span>', async () => {
      await patch({ archived: !m.archived });
      if (!m.archived && S.active === id) {   // just archived the active chat
        const next = S.order.find((sid) => S.recs.get(sid) && !S.recs.get(sid).meta.archived);
        if (next) activate(next);
        else { const nm = await H.sessionCreate({}); await refreshSessions(); activate(nm.id); }
      }
    });
    item('Delete <span class="mi-hint">D</span>', () => { hideCtxMenu(); deleteSession(id, m.title); }, 'ctx-danger');
  }
  document.body.appendChild(ctxEl);
  const rect = ctxEl.getBoundingClientRect();
  ctxEl.style.left = Math.min(x, window.innerWidth - rect.width - 8) + 'px';
  ctxEl.style.top = Math.min(y, window.innerHeight - rect.height - 8) + 'px';
  ctxEl.style.right = 'auto';
  function reopen(v) {
    const lx = parseInt(ctxEl.style.left), ly = parseInt(ctxEl.style.top);
    showCtxMenu(lx, ly, id, v);
  }
}
document.addEventListener('mousedown', (e) => { if (ctxEl && !e.target.closest('.ctx-menu')) hideCtxMenu(); });
document.addEventListener('keydown', (e) => {
  if (!ctxEl) return;
  const id = ctxEl.dataset.sessId;
  const rec = S.recs.get(id);
  if (!rec) { hideCtxMenu(); return; }
  const m = rec.meta;
  const patch = async (p) => { hideCtxMenu(); const nm = await H.sessionMeta(id, p); if (nm) rec.meta = nm; renderSidebar(); };
  const k = e.key.toLowerCase();
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); hideCtxMenu(); }
  else if (k === 'p') { e.preventDefault(); patch({ pinned: !m.pinned }); }
  else if (k === 'u') { e.preventDefault(); patch({ unread: !m.unread }); }
  else if (k === 'r') { e.preventDefault(); hideCtxMenu(); const t = prompt('Rename chat:', m.title); if (t && t.trim()) H.sessionMeta(id, { title: t.trim() }).then((nm) => { if (nm) rec.meta = nm; renderSidebar(); updateTitlebar(); }); }
  else if (k === 'f') { e.preventDefault(); hideCtxMenu(); H.sessionFork(id).then(async (nm) => { if (nm) { await refreshSessions(); activate(nm.id); } }); }
  else if (k === 'w') { e.preventDefault(); hideCtxMenu(); H.sessionWorktree(id).then(async (nm) => { if (nm && nm.error) return alert(nm.error); if (nm) { await refreshSessions(); activate(nm.id); } }); }
  else if (k === 'a') { e.preventDefault(); patch({ archived: !m.archived }); }
  else if (k === 'd') { e.preventDefault(); hideCtxMenu(); deleteSession(id, m.title); }
}, true);

// ---------------------------------------------------------------- ⌘K command palette
const CK = { open: false, sel: 0, items: [] };
function ckActions() {
  const rec = active();
  const acts = [
    { label: 'New chat', tag: 'action', run: () => newChat() },
    { label: 'Side chat', hint: 'quick asides, separate from the session', tag: 'action', run: () => rec && openSidePopup(rec) },
    { label: 'Switch model…', hint: '⌘K', tag: 'action', run: () => openModelSheet() },
    { label: 'Change working directory…', tag: 'action', run: () => pickDir() },
    { label: 'Toggle changes panel', tag: 'action', run: () => toggleDiff() },
    { label: 'Compact context', hint: 'summarize & compress', tag: 'action', run: () => runSlash(rec, '/compact') },
    { label: 'Fork chat', tag: 'action', run: () => runSlash(rec, '/fork') },
    { label: 'Rename chat…', tag: 'action', run: () => { const t = prompt('Rename chat:', rec ? rec.meta.title : ''); if (t && t.trim() && rec) H.sessionMeta(rec.meta.id, { title: t.trim() }).then(() => { refreshSessions(); updateTitlebar(); }); } },
    { label: 'Clear conversation', tag: 'action', run: () => runSlash(rec, '/clear') },
    { label: 'Settings', tag: 'action', run: () => openSettings() },
    { label: 'Mode: plan', hint: 'read-only planning', tag: 'mode', run: () => setSessionConfig({ mode: 'plan' }) },
    { label: 'Mode: ask', hint: 'approve every change', tag: 'mode', run: () => setSessionConfig({ mode: 'ask' }) },
    { label: 'Mode: edits', hint: 'auto-approve file edits', tag: 'mode', run: () => setSessionConfig({ mode: 'edits' }) },
    { label: 'Mode: auto', hint: 'auto-approve routine work', tag: 'mode', run: () => setSessionConfig({ mode: 'auto' }) },
  ];
  for (const [id, r] of S.recs) {
    if (r.meta.archived) continue;
    acts.push({ label: r.meta.title || 'Untitled', hint: shortModel(r.meta.model), tag: 'chat', run: () => activate(id) });
  }
  for (const sk of (S.skills || [])) {
    acts.push({ label: '/' + sk.name, hint: sk.description || 'skill', tag: 'skill',
                run: () => { $('input').value = '/' + sk.name + ' '; $('input').focus(); } });
  }
  return acts;
}
function ckRender() {
  const list = document.getElementById('ckList');
  list.innerHTML = '';
  if (!CK.items.length) { list.innerHTML = '<div class="ck-empty">No matches</div>'; return; }
  CK.items.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'ck-row' + (i === CK.sel ? ' sel' : '');
    row.innerHTML = '<span class="ck-label">' + esc(it.label) + '</span>'
      + (it.hint ? '<span class="ck-hint">' + esc(it.hint) + '</span>' : '')
      + '<span class="ck-tag">' + it.tag + '</span>';
    row.onmousedown = (e) => { e.preventDefault(); CK.sel = i; ckRun(); };
    row.onmouseenter = () => { CK.sel = i; ckRender(); };
    list.appendChild(row);
  });
  const sel = list.querySelector('.ck-row.sel');
  if (sel) sel.scrollIntoView({ block: 'nearest' });
}
function ckFilter(q) {
  const all = ckActions();
  if (!q) { CK.items = all.slice(0, 40); return; }
  const lq = q.toLowerCase();
  const scored = all.map((it) => {
    const l = it.label.toLowerCase(), h = (it.hint || '').toLowerCase();
    let sc = -1;
    if (l.startsWith(lq)) sc = 0;
    else if (l.includes(lq)) sc = 1;
    else if (h.includes(lq)) sc = 2;
    return { it, sc };
  }).filter((x) => x.sc >= 0).sort((a, b) => a.sc - b.sc);
  CK.items = scored.map((x) => x.it).slice(0, 40);
}
function ckOpen() {
  let el = document.getElementById('cmdk');
  if (!el) {
    el = document.createElement('div');
    el.id = 'cmdk';
    el.innerHTML = '<div class="ck-box"><input id="ckInput" placeholder="Type a command, chat, or skill…" autocomplete="off" spellcheck="false"><div id="ckList"></div></div>';
    document.body.appendChild(el);
    el.onmousedown = (e) => { if (e.target === el) ckClose(); };
    const inp = document.getElementById('ckInput');
    inp.addEventListener('input', () => { CK.sel = 0; ckFilter(inp.value.trim()); ckRender(); });
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); ckClose(); }
      else if (e.key === 'ArrowDown') { e.preventDefault(); CK.sel = Math.min(CK.sel + 1, CK.items.length - 1); ckRender(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); CK.sel = Math.max(CK.sel - 1, 0); ckRender(); }
      else if (e.key === 'Enter') { e.preventDefault(); ckRun(); }
    });
  }
  CK.open = true; CK.sel = 0;
  el.style.display = 'flex';
  const inp = document.getElementById('ckInput');
  inp.value = '';
  ckFilter(''); ckRender();
  inp.focus();
}
function ckClose() { CK.open = false; const el = document.getElementById('cmdk'); if (el) el.style.display = 'none'; $('input').focus(); }
function ckRun() {
  const it = CK.items[CK.sel];
  ckClose();
  if (it) it.run();
}
if (scState().docked) scShowTab();

document.addEventListener('keydown', (e) => {
  // ⇧⌘P — command palette (⌘K stays the model switcher)
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === 'p' && !e.altKey) {
    e.preventDefault();
    CK.open ? ckClose() : ckOpen();
  }
});

async function activate(id) {
  if (!S.recs.has(id)) return;
  closeCliView();
  S.active = id;
  for (const [rid, rec] of S.recs) rec.logEl.classList.toggle('active', rid === id);
  const rec = S.recs.get(id);
  if (!rec.loaded) {
    rec.loaded = true;
    const d = await H.sessionGet(id);
    if (d) { rec.meta = d.meta; rec.side = d.side || []; for (const item of d.transcript) renderItem(rec, item); rec.cur = null; }
    rec.logEl.scrollTop = rec.logEl.scrollHeight;
  }
  renderSidebar();
  updateTitlebar();
  updateComposer();
  hidePopup();
  hideMenus();
  if (rec.meta.unread) { rec.meta.unread = false; H.sessionMeta(id, { unread: false }); }
  renderAttachRow();
  maybeShowApproval();
  if (S.panel === 'changes') refreshGit();
  else if (S.panel === 'files') refreshFiles();
  showSuggestion(rec);
  maybeEmptyState(rec);
  $('input').focus();
}

const EMPTY_IDEAS = [
  { icon: 'plan', title: 'Start with a plan', sub: 'Align on the approach before writing code', fill: '/mode plan ' },
  { icon: 'bug', title: 'Debug an issue', sub: 'Find the root cause and fix it', fill: 'Help me debug: ' },
  { icon: 'spark', title: 'Build something', sub: 'A dashboard, a script, an app — describe it', fill: 'Build me ' },
];
const EMPTY_ICON = {
  plan: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 6h13M8 12h13M8 18h13"/><path d="M3 6h.01M3 12h.01M3 18h.01"/></svg>',
  bug: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m8 2 1.88 1.88M14.12 3.88 16 2M9 7.13v-1a3.003 3.003 0 1 1 6 0v1"/><path d="M12 20c-3.3 0-6-2.7-6-6v-3a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v3c0 3.3-2.7 6-6 6z"/><path d="M12 20v-9M6.53 9C4.6 8.8 3 7.1 3 5M6 13H2M3 21c0-2.1 1.7-3.9 3.8-4M17.47 9c1.93-.2 3.53-1.9 3.53-4M22 13h-4M20.97 21c0-2.1-1.6-3.9-3.8-4"/></svg>',
  spark: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3 1.9 5.8a2 2 0 0 0 1.3 1.3L21 12l-5.8 1.9a2 2 0 0 0-1.3 1.3L12 21l-1.9-5.8a2 2 0 0 0-1.3-1.3L3 12l5.8-1.9a2 2 0 0 0 1.3-1.3z"/></svg>',
};
function maybeEmptyState(rec) {
  const log = logOf(rec);
  if (log.childElementCount > 0 || log.querySelector('.empty-home')) return;
  const el = document.createElement('div');
  el.className = 'empty-home';
  el.innerHTML = '<div class="eh-logo"><svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 20.5 7 20.5 17 12 22 3.5 17 3.5 7"/><path d="m8.5 9.5 2.5 2.5-2.5 2.5M13.5 15h3"/></svg></div>'
    + '<div class="eh-title">What are we building?</div>'
    + '<div class="eh-sub">' + esc(rec.meta.cwd || '') + '</div>'
    + '<div class="eh-rows">' + EMPTY_IDEAS.map((x, i) =>
        '<button class="eh-row" data-i="' + i + '"><span class="eh-ic">' + EMPTY_ICON[x.icon] + '</span><span class="eh-tx"><b>' + x.title + '</b><i>' + x.sub + '</i></span><span class="eh-go">›</span></button>').join('') + '</div>';
  el.querySelectorAll('.eh-row').forEach((b) => {
    b.onclick = () => {
      const idea = EMPTY_IDEAS[+b.dataset.i];
      if (idea.fill.startsWith('/mode plan')) { setSessionConfig({ mode: 'plan' }); $('input').value = ''; }
      else $('input').value = idea.fill;
      $('input').focus();
    };
  });
  log.appendChild(el);
}

const MODES = [
  { key: 'plan', label: '📋 Plan mode', chip: '📋 Plan' },
  { key: 'ask', label: '🔨 Manual permissions', chip: '🔨 Ask' },
  { key: 'edits', label: '✎ Accept edits', chip: '✎ Edits' },
  { key: 'auto', label: '⚡ Auto mode', chip: '⚡ Auto' },
  { key: 'bypass', label: '⚠ Bypass permissions', chip: '⚠ Bypass' },
];
function updateTitlebar() {
  const rec = active(); if (!rec) return;
  const m = rec.meta;
  $('dirLabel').textContent = shortDir(m.cwd);
  $('modelLabel').textContent = shortModel(m.model);
  const mb = $('modeBtn');
  const md = MODES.find((x) => x.key === m.mode) || MODES[1];
  mb.textContent = md.chip;
  mb.className = 'chip mode ' + m.mode;
  // effort only exists for reasoning-capable models — hide the chip otherwise
  const mm = S.models.find((x) => x.value === m.model);
  const canReason = mm ? !!mm.reasoning : false;
  $('effortBtn').style.display = canReason ? '' : 'none';
  $('effortBtn').textContent = m.effort ? '◔ ' + m.effort[0].toUpperCase() + m.effort.slice(1) : 'Effort';
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
  const note = $('queueNote');
  note.style.display = q ? '' : 'none';
  note.innerHTML = '';
  if (q) {
    const head = document.createElement('span'); head.className = 'q-head';
    head.textContent = q + ' queued — sends when this turn finishes · ⌘↩ steers instead';
    note.appendChild(head);
    rec.queued.forEach((m, i) => {
      const chip = document.createElement('span'); chip.className = 'q-chip';
      const t = document.createElement('span'); t.className = 'q-text'; t.textContent = m.text.slice(0, 60) + (m.text.length > 60 ? '…' : ''); chip.appendChild(t);
      const st = document.createElement('button'); st.className = 'q-btn'; st.textContent = '↯'; st.title = 'Steer now — interject into the running turn';
      st.onclick = async () => {
        if (!rec.streaming) return;
        if (m.images && m.images.length) { addLine(rec, 'err', '⚠︎ can\'t steer with images — it stays queued'); return; }
        rec.queued.splice(i, 1);
        if (!(await steerNow(rec, m.text, m.modelText))) { rec.queued.splice(i, 0, m); addLine(rec, 'err', '⚠︎ steer failed — message re-queued'); }
        updateComposer();
      };
      chip.appendChild(st);
      const x = document.createElement('button'); x.className = 'q-btn'; x.textContent = '✕'; x.title = 'Remove from queue';
      x.onclick = () => { rec.queued.splice(i, 1); updateComposer(); };
      chip.appendChild(x);
      note.appendChild(chip);
    });
  }
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
    setWorking(rec, 'Thinking…');
    const c = ensureAssistant(rec);
    c.think.style.display = 'block'; c.thinkRaw += e.delta; c.thinkBody.textContent = c.thinkRaw;
    if (stick) c.thinkBody.scrollTop = c.thinkBody.scrollHeight;
  }
  else if (e.type === 'text') {
    setWorking(rec, 'Writing…');
    const c = ensureAssistant(rec);
    if (c.thinkRaw && !c.raw) { c.think.classList.add('closed'); c.thinkHead.textContent = '✳ thought for a bit'; }
    c.raw += e.delta; renderCurMd(rec);
  }
  else if (e.type === 'tool_call') { finalizeAssistant(rec, Date.now()); addTool(rec, e.name, e.args); setWorking(rec, 'Running ' + e.name + '…'); }
  else if (e.type === 'tool_result') {
    if (rec.lastTool) setToolResult(rec.lastTool, e.name, e.result);
    if (S.panel === 'changes' && e.sessionId === S.active && MUTATING.includes(e.name)) {
      clearTimeout(gitDebounce); gitDebounce = setTimeout(refreshGit, 500);
    }
  }
  else if (e.type === 'auto_approved') addLine(rec, 'done', '⚡ auto-approved ' + e.kind + ': ' + String(e.detail || '').slice(0, 80));
  else if (e.type === 'control_note') addLine(rec, 'done', e.message);
  else if (e.type === 'remote_user') { addUser(rec, '📱 ' + e.text, (e.thumbs || []).length, { ts: Date.now(), raw: e.text, thumbs: e.thumbs }); rec.streaming = true; startWorking(rec); updateComposer(); renderSidebar(); }
  else if (e.type === 'sidechat_delta') {
    if (rec.sideStream) { rec.sideStream.acc += e.text; rec.sideStream.el.textContent = rec.sideStream.acc; scScroll(); }
  }
  else if (e.type === 'sidechat_done') {
    const scp = scEl();
    if ((!scp || scp.style.display === 'none') && scTabEl() && scTabEl().style.display !== 'none') scTabEl().classList.add('unread');
    if (rec.sideStream) {
      const { el, acc } = rec.sideStream;
      if (e.error) { el.textContent = '⚠︎ ' + e.error; rec.side.push({ role: 'assistant', content: '⚠︎ ' + e.error }); }
      else { el.innerHTML = md(acc); el.classList.add('md'); rec.side.push({ role: 'assistant', content: acc }); }
      el.classList.remove('live');
      rec.sideStream = null; scScroll();
    }
  }
  else if (e.type === 'auto_user') { addUser(rec, '🎯 ' + e.text, 0, { ts: Date.now(), raw: e.text }); rec.streaming = true; startWorking(rec); updateComposer(); renderSidebar(); }
  else if (e.type === 'plan') renderPlan(rec, e.items);
  else if (e.type === 'checkpoint') addCkptLine(rec, e.ckptId, e.files);
  else if (e.type === 'snapshot') { /* main-side checkpoint bookkeeping only */ }
  else if (e.type === 'screenshot') {
    const card = document.createElement('div'); card.className = 'shot';
    const img = document.createElement('img'); img.src = e.dataUrl;
    img.onclick = () => card.classList.toggle('big');
    card.appendChild(img); logOf(rec).appendChild(card); scrollLog(rec);
  }
  else if (e.type === 'media') addMedia(rec, e.path, e.kind);
  else if (e.type === 'diff') addDiff(rec, e.file, e.before, e.after);
  else if (e.type === 'done') {
    finalizeAssistant(rec, Date.now());
    const secs = stopWorking(rec);
    if (e.usage) addLine(rec, 'done', 'done · ~' + ((e.usage.prompt_tokens || 0) + (e.usage.completion_tokens || 0)).toLocaleString() + ' tokens' + (secs ? ' · ' + fmtSecs(secs) : ''));
    endTurn(rec);
  }
  else if (e.type === 'compacted') { finalizeAssistant(rec, Date.now()); addLine(rec, 'done', '✦ context compacted'); endTurn(rec); }
  else if (e.type === 'error') { finalizeAssistant(rec, Date.now()); addLine(rec, 'err', '⚠︎ ' + e.message); endTurn(rec); }
  else if (e.type === 'aborted') { finalizeAssistant(rec, Date.now()); addLine(rec, 'done', 'stopped.'); endTurn(rec); }
  if (stick) scrollLog(rec);
});

// ---- live working indicator: terracotta ✳ + status + elapsed time (Claude-style)
function startWorking(rec) {
  if (rec.workEl) return;
  const el = document.createElement('div');
  el.className = 'working';
  el.innerHTML = '<span class="w-star">✳</span><span class="w-text">Thinking…</span><span class="w-time">0s</span>';
  rec.workStart = Date.now();
  rec.workEl = el;
  logOf(rec).appendChild(el);
  rec.workTimer = setInterval(() => {
    if (!rec.workEl) return;
    const s = Math.floor((Date.now() - rec.workStart) / 1000);
    rec.workEl.querySelector('.w-time').textContent = s < 60 ? s + 's' : Math.floor(s / 60) + 'm ' + (s % 60) + 's';
  }, 1000);
  scrollLog(rec);
}
function setWorking(rec, text) {
  if (!rec.workEl) return;
  rec.workEl.querySelector('.w-text').textContent = text;
  logOf(rec).appendChild(rec.workEl);   // keep it below the latest content
}
function stopWorking(rec) {
  clearInterval(rec.workTimer);
  const secs = rec.workStart ? Math.floor((Date.now() - rec.workStart) / 1000) : 0;
  if (rec.workEl) rec.workEl.remove();
  rec.workEl = null; rec.workStart = null;
  return secs;
}
function fmtSecs(s) { return s < 60 ? s + 's' : Math.floor(s / 60) + 'm ' + (s % 60) + 's'; }

function endTurn(rec) {
  stopWorking(rec);
  rec.streaming = false;
  if (rec.meta.id === S.active) updateComposer();
  else { rec.meta.unread = true; H.sessionMeta(rec.meta.id, { unread: true }); }   // finished in the background
  renderSidebar();
  if (rec.queued.length) {
    const next = rec.queued.shift();
    setTimeout(() => sendText(rec, next.text, next.images, next.modelText), 80);
  }
}

H.onSessionsUpdated(() => refreshSessions());

// ---------------------------------------------------------------- send / stop
async function steerNow(rec, text, modelText) {
  const st = await H.sessionSteer(rec.meta.id, modelText || text);
  if (st && st.ok) { addUser(rec, '↳ ' + text, 0, { ts: Date.now(), raw: text }); updateComposer(); return true; }
  return false;
}
async function sendText(rec, text, images, modelText, opts) {
  if (rec.streaming) {
    // Codex-style: follow-ups queue by default; steering is an explicit action
    if (opts && opts.steer && await steerNow(rec, text, modelText)) return;
    rec.queued.push({ text, images, modelText }); updateComposer(); return;
  }
  rec.streaming = true; rec.cur = null;
  const r = await H.sessionSend(rec.meta.id, text, images && images.length ? images : undefined, modelText);
  if (r.ok) { addUser(rec, text, images ? images.length : 0, { ts: Date.now(), raw: text, thumbs: images }); startWorking(rec); }
  else if (r.error === 'busy') rec.queued.push({ text, images, modelText });
  else rec.streaming = false;
  updateComposer(); renderSidebar();
}
async function onSend(opts) {
  const rec = active(); if (!rec) return;
  const text = $('input').value.trim();
  let images = (rec.attachments || []).map((a) => a.dataUrl).filter(Boolean);
  if (images.length && !visionOk(rec)) addLine(rec, 'done', '🖼 ' + shortModel(rec.meta.model) + ' can\'t see images — they\'ll be auto-described by a vision model');
  if (!text && !images.length) return;
  $('input').value = ''; $('input').style.height = 'auto'; hidePopup();
  rec.suggestion = null; showSuggestion(rec);
  if (text.startsWith('/') && runSlash(rec, text)) return;
  rec.attachments = []; renderAttachRow();
  sendText(rec, text || 'See the attached image(s).', images, undefined, opts);
}
$('sendBtn').onclick = () => onSend();
$('stopBtn').onclick = () => { const rec = active(); if (rec) H.sessionAbort(rec.meta.id); };

function hideSettings() { $('settingsSheet').style.display = 'none'; }
async function fillMediaSelects() {
  const sel = (id) => $(id);
  if (!sel('imgModelSel')) return;
  const m = await H.mediaModels();
  const cfg = await H.getConfig();
  const fill = (el, list, cur, noneLabel) => {
    el.innerHTML = '';
    if (noneLabel) { const o = document.createElement('option'); o.value = ''; o.textContent = noneLabel; el.appendChild(o); }
    for (const x of list) { const o = document.createElement('option'); o.value = x.id; o.textContent = x.name + ' ($' + (x.price * 1e6).toFixed(2) + '/M)'; el.appendChild(o); }
    el.value = cur || (noneLabel ? '' : (list[0] && list[0].id) || '');
  };
  fill(sel('imgModelSel'), m.image, cfg.imageModel || 'google/gemini-3.1-flash-image');
  fill(sel('vidModelSel'), m.video, cfg.videoModel, '— no video model (video gen off) —');
  sel('imgModelSel').onchange = () => H.setConfig({ imageModel: sel('imgModelSel').value });
  sel('vidModelSel').onchange = () => H.setConfig({ videoModel: sel('vidModelSel').value || null });
  $('mediaAutoPick').checked = !!cfg.mediaAutoPick;
  $('mediaAutoPick').onchange = () => H.setConfig({ mediaAutoPick: $('mediaAutoPick').checked });
}
// ---------------------------------------------------------------- automations
async function refreshAutomations() {
  if ($('autoModelList') && !$('autoModelList').children.length && S.models && S.models.length) {
    for (const m of S.models) { const o = document.createElement('option'); o.value = m.value; $('autoModelList').appendChild(o); }
  }
  const box = $('autoList'); if (!box) return;
  const list = await H.automationList();
  box.innerHTML = list.length ? '' : '<div class="muted">No automations yet.</div>';
  for (const a of list) {
    const row = document.createElement('div');
    row.className = 'settings-row';
    const next = a.enabled && a.nextRun ? new Date(a.nextRun).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : 'paused';
    const modelTag = a.model ? ' · ' + shortModel(a.model) : '';
    row.innerHTML = '<div style="flex:1;min-width:0"><div>' + esc(a.name) + ' <span class="mi-hint">' + esc(a.scheduleText) + ' · next: ' + next + esc(modelTag) + '</span></div>'
      + '<div class="mi-hint" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(a.prompt.slice(0, 90)) + '</div></div>';
    const mk = (label, fn, danger) => {
      const b = document.createElement('button');
      b.className = 'sheet-close'; b.textContent = label; if (danger) b.style.color = 'var(--red)';
      b.onclick = fn; row.appendChild(b); return b;
    };
    mk('Run now', async () => { const r = await H.automationRunNow(a.id); if (r.ok) { hideSettings(); await refreshSessions(); activate(r.sessionId); } });
    mk(a.enabled ? 'Pause' : 'Resume', async () => { await H.automationSave({ ...a, enabled: !a.enabled }); refreshAutomations(); });
    mk('✕', async () => { if (confirm('Delete "' + a.name + '"?')) { await H.automationDelete(a.id); refreshAutomations(); } }, true);
    box.appendChild(row);
  }
}
if ($('autoType')) {
  $('autoType').onchange = () => {
    const t = $('autoType').value;
    $('autoDow').style.display = t === 'weekly' ? '' : 'none';
    $('autoTime').style.display = (t === 'daily' || t === 'weekly') ? '' : 'none';
    $('autoMinutes').style.display = (t === 'interval' || t === 'hourly') ? '' : 'none';
    if (t === 'hourly') $('autoMinutes').placeholder = 'minute';
  };
  $('autoAddBtn').onclick = async () => {
    const name = $('autoName').value.trim();
    const prompt = $('autoPrompt').value.trim();
    if (!name || !prompt) return alert('name and prompt are required');
    const t = $('autoType').value;
    const [hh, mm] = ($('autoTime').value || '09:00').split(':').map(Number);
    const schedule = t === 'interval' ? { type: 'interval', minutes: Number($('autoMinutes').value) || 60 }
      : t === 'hourly' ? { type: 'hourly', mm: Number($('autoMinutes').value) % 60 || 0 }
      : t === 'weekly' ? { type: 'weekly', dow: Number($('autoDow').value), hh, mm }
      : { type: 'daily', hh, mm };
    const rec = active();
    await H.automationSave({ name, prompt, schedule, cwd: $('autoCwd').value.trim() || (rec ? rec.meta.cwd : null), model: $('autoModel').value.trim() || (rec ? rec.meta.model : null), mode: 'auto', enabled: true });
    $('autoName').value = ''; $('autoPrompt').value = '';
    refreshAutomations();
  };
}
H.onOpenSession(async ({ id }) => { await refreshSessions(); activate(id); });

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
  { cmd: '/fork', desc: 'Duplicate this chat into a new session' },
  { cmd: '/goal <text>', desc: 'Set a standing goal (empty = clear)' },
  { cmd: '/loop <min> <prompt>', desc: 'Re-send a prompt on an interval · /loop stop' },
  { cmd: '/btw <question>', desc: 'Side chat — quick asides in a popup, never touches the session context' },
  { cmd: '/help', desc: 'Show available commands' },
];
function runSlash(rec, text) {
  const [cmd, ...rest] = text.split(/\s+/);
  const arg = rest.join(' ');
  if (cmd === '/btw' || cmd === '/sidechat') {
    openSidePopup(rec);
    if (arg) sideSend(rec, arg);
    return true;
  }
  if (cmd === '/new') { newChat(); return true; }
  if (cmd === '/clear') { H.sessionClear(rec.meta.id).then(() => { rec.logEl.innerHTML = ''; rec.cur = null; rec.userN = 0; addLine(rec, 'done', 'conversation cleared.'); }); return true; }
  if (cmd === '/compact') {
    rec.streaming = true; updateComposer(); addLine(rec, 'done', '✦ compacting context…'); startWorking(rec);
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
  if (cmd === '/fork') {
    H.sessionFork(rec.meta.id).then(async (m) => { if (m) { await refreshSessions(); activate(m.id); } });
    return true;
  }
  if (cmd === '/goal') {
    H.sessionGoal(rec.meta.id, arg || null);
    rec.meta.goal = arg || null;
    addLine(rec, 'done', arg ? '◎ standing goal set: ' + arg : '◎ standing goal cleared');
    return true;
  }
  if (cmd === '/loop') {
    if (arg === 'stop' || !arg) {
      if (rec.loopTimer) { clearInterval(rec.loopTimer); rec.loopTimer = null; addLine(rec, 'done', '↻ loop stopped'); }
      else addLine(rec, 'err', 'usage: /loop <minutes> <prompt> · /loop stop');
      return true;
    }
    const m = arg.match(/^(\d+)\s+([\s\S]+)$/);
    if (!m) { addLine(rec, 'err', 'usage: /loop <minutes> <prompt>'); return true; }
    const mins = Math.max(1, +m[1]), prompt = m[2];
    if (rec.loopTimer) clearInterval(rec.loopTimer);
    rec.loopTimer = setInterval(() => { if (!rec.streaming) sendText(rec, prompt); }, mins * 60000);
    addLine(rec, 'done', '↻ looping every ' + mins + 'm: "' + prompt.slice(0, 60) + '" — /loop stop to end');
    sendText(rec, prompt);
    return true;
  }
  if (cmd === '/help') {
    addLine(rec, 'done', SLASH.map((s) => s.cmd + ' — ' + s.desc).join('\n') +
      (S.skills.length ? '\n\nskills: ' + S.skills.map((s) => '/' + s.name).join(' ') : ''));
    return true;
  }
  // skills: /name [task] expands the skill content for the model
  const skill = S.skills.find((s) => cmd === '/' + s.name);
  if (skill) {
    sendText(rec, text, null,
      'Follow this skill/playbook:\n\n' + skill.content + '\n\n---\nTask: ' + (arg || 'apply the skill to the current context'));
    return true;
  }
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
    const all = [...SLASH, ...S.skills.map((s) => ({ cmd: '/' + s.name, desc: 'skill — ' + (s.description || '') }))];
    const list = all.filter((s) => s.cmd.startsWith(q) || q === '/');
    pop.mode = 'slash'; pop.sel = 0;
    pop.items = list.map((s) => ({ main: s.cmd, hint: s.desc, insert: s.cmd.replace(/ <.*$/, ' ') }));
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

// ---------------------------------------------------------------- cross-session search
let searchTimer = null;
$('sessSearch').addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    const q = $('sessSearch').value.trim();
    S.searchIds = q ? await H.sessionsSearch(q) : null;
    renderSidebar();
  }, 200);
});
$('sessSearch').addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { $('sessSearch').value = ''; S.searchIds = null; renderSidebar(); $('input').focus(); }
  if (e.key === 'Enter' && S.searchIds && S.searchIds.length) { activate(S.searchIds[0]); }
});

// ---------------------------------------------------------------- voice input (local whisper)
let recState = null;   // { recorder, chunks }
$('micBtn').onclick = async () => {
  if (recState) {   // stop → transcribe
    recState.recorder.stop();
    return;
  }
  const perm = await H.micPermission();
  if (perm && perm.granted === false) { alert('Microphone access denied — grant it in System Settings → Privacy.'); return; }
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); }
  catch (e) { alert('Microphone unavailable: ' + e.message); return; }
  const recorder = new MediaRecorder(stream, { mimeType: 'audio/webm' });
  const chunks = [];
  recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  recorder.onstop = async () => {
    stream.getTracks().forEach((t) => t.stop());
    recState = null;
    $('micBtn').textContent = '…';
    const blob = new Blob(chunks, { type: 'audio/webm' });
    const buf = new Uint8Array(await blob.arrayBuffer());
    let b64 = '';
    for (let i = 0; i < buf.length; i += 0x8000) b64 += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
    const r = await H.transcribe(btoa(b64));
    $('micBtn').innerHTML = UI_ICON.mic;
    $('micBtn').classList.remove('rec');
    if (r.error) { const rec = active(); if (rec) addLine(rec, 'err', '⚠︎ ' + r.error); return; }
    if (r.text) {
      input.value = (input.value ? input.value + ' ' : '') + r.text;
      input.dispatchEvent(new Event('input'));
      input.focus();
    }
  };
  recorder.start();
  recState = { recorder, chunks };
  $('micBtn').textContent = '⏺';
  $('micBtn').classList.add('rec');
};

// ---------------------------------------------------------------- self-update
$('updateBtn').onclick = async () => {
  $('updateStatus').textContent = 'checking…';
  const r = await H.selfUpdate();
  if (r.error) { $('updateStatus').textContent = '⚠︎ ' + r.error; return; }
  if (/Already up to date/i.test(r.out || '')) { $('updateStatus').textContent = '✓ up to date'; return; }
  $('updateStatus').textContent = '✓ updated (' + (r.out || '') + ')';
  if (confirm('Update installed. Relaunch now?')) H.appRelaunch();
};

// ---------------------------------------------------------------- ghost-text suggestions (Tab to accept)
const input = $('input');
const DEFAULT_PLACEHOLDER = input.placeholder;
function showSuggestion(rec) {
  input.placeholder = (rec && rec.suggestion && !input.value)
    ? rec.suggestion + '   ⇥ tab'
    : DEFAULT_PLACEHOLDER;
}
H.onSuggest(({ sessionId, text }) => {
  const rec = S.recs.get(sessionId);
  if (!rec) return;
  rec.suggestion = text;
  if (sessionId === S.active) showSuggestion(rec);
});

// ---------------------------------------------------------------- composer keys
// paste an image straight from the clipboard (⌘V) → attaches like the + menu does
input.addEventListener('paste', (e) => {
  const rec = active(); if (!rec) return;
  for (const item of e.clipboardData.items) {
    if (item.type && item.type.startsWith('image/')) {
      e.preventDefault();
      const f = item.getAsFile();
      const fr = new FileReader();
      fr.onload = () => {
        rec.attachments = rec.attachments || [];
        rec.attachments.push({ name: 'pasted image', dataUrl: fr.result });
        renderAttachRow();
      };
      fr.readAsDataURL(f);
    }
  }
});
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
  // Tab accepts the ghost-text suggestion when the composer is empty
  if (ev.key === 'Tab' && !ev.shiftKey && !pop.mode) {
    const rec = active();
    if (rec && rec.suggestion && !input.value) {
      ev.preventDefault();
      input.value = rec.suggestion;
      rec.suggestion = null;
      showSuggestion(rec);
      input.dispatchEvent(new Event('input'));
      input.setSelectionRange(input.value.length, input.value.length);
      return;
    }
  }
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    const rec = active();
    onSend({ steer: !!((ev.metaKey || ev.ctrlKey) && rec && rec.streaming) });
    return;
  }
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
  if (patch.model && !visionOk(rec) && (rec.attachments || []).some((a) => a.dataUrl)) {
    addLine(rec, 'done', '🖼 ' + shortModel(rec.meta.model) + ' can\'t see images — attachments will be auto-described by a vision model');
  }
  updateTitlebar(); renderSidebar();
}
const MODE_CYCLE = { plan: 'ask', ask: 'edits', edits: 'auto', auto: 'bypass', bypass: 'plan' };
function cycleMode() { const rec = active(); if (rec) setSessionConfig({ mode: MODE_CYCLE[rec.meta.mode] || 'ask' }); }
async function pickDir() {
  const rec = active(); if (!rec) return;
  const d = await H.pickDir(rec.meta.id);
  if (d) {
    rec.meta.cwd = d; rec.files = null; updateTitlebar();
    if (S.panel === 'changes') refreshGit();
    else if (S.panel === 'files') refreshFiles();
  }
}
$('dirBtn').onclick = pickDir;

// ---- mode menu (click the pill; 1–5 select; ⇧Tab still cycles)
$('modeBtn').onclick = () => {
  const open = $('modeMenu').style.display !== 'none';
  hideMenus();
  if (open) return;
  const rec = active(); if (!rec) return;
  for (const it of document.querySelectorAll('#modeMenu .menu-item'))
    it.classList.toggle('on', it.dataset.mode === rec.meta.mode);
  $('modeMenu').style.display = '';
};
$('modeMenu').addEventListener('click', (e) => {
  const it = e.target.closest('.menu-item'); if (!it) return;
  hideMenus();
  setSessionConfig({ mode: it.dataset.mode });
});

// ---- effort menu (OpenRouter unified reasoning effort — faster ↔ smarter)
$('effortBtn').onclick = () => {
  const open = $('effortMenu').style.display !== 'none';
  hideMenus();
  if (open) return;
  const rec = active(); if (!rec) return;
  for (const it of document.querySelectorAll('#effortMenu .menu-item'))
    it.classList.toggle('on', (it.dataset.effort || '') === (rec.meta.effort || ''));
  $('effortMenu').style.display = '';
};
$('effortMenu').addEventListener('click', (e) => {
  const it = e.target.closest('.menu-item'); if (!it) return;
  hideMenus();
  setSessionConfig({ effort: it.dataset.effort || null });
});

// ---- + menu: attach files/photos, add folder, slash commands
function renderAttachRow() {
  const rec = active();
  const row = $('attachRow');
  const atts = rec ? (rec.attachments || []) : [];
  row.style.display = atts.length ? '' : 'none';
  row.innerHTML = '';
  atts.forEach((a, i) => {
    const chip = document.createElement('div'); chip.className = 'att-chip';
    chip.innerHTML = (a.dataUrl ? '<img src="' + a.dataUrl + '">' : '📄') + '<span>' + esc(a.name) + '</span><button title="Remove">✕</button>';
    chip.querySelector('button').onclick = () => { rec.attachments.splice(i, 1); renderAttachRow(); };
    row.appendChild(chip);
  });
}
function visionOk(rec) {
  const m = S.models.find((x) => x.value === rec.meta.model);
  return m ? !!m.vision : true;
}
async function attachFiles() {
  const rec = active(); if (!rec) return;
  const picked = await H.pickFiles(rec.meta.id, visionOk(rec));
  rec.attachments = rec.attachments || [];
  for (const f of picked) {
    if (f.kind === 'image') rec.attachments.push({ name: f.name, dataUrl: f.dataUrl });
    else if (f.kind === 'path') { const i = $('input'); i.value = (i.value ? i.value.replace(/\s?$/, ' ') : '') + '@' + f.path + ' '; }
    else if (f.kind === 'error') addLine(rec, 'err', '⚠︎ ' + f.name + ': ' + f.error);
  }
  renderAttachRow();
  $('input').focus();
}
function openSettings(sec) {
  $('settingsSheet').style.display = 'flex';
  renderMcpList(); renderSkillsList(); renderPluginsList(); refreshAutomations();
  const b = document.querySelector('.snav[data-sec=' + sec + ']');
  if (b) b.onclick();
}
async function renderPlusMenu(view) {
  const box = $('plusMenu'); box.innerHTML = '';
  const item = (html, fn) => {
    const d = document.createElement('div'); d.className = 'menu-item'; d.innerHTML = html;
    d.onmousedown = (e) => e.stopPropagation();
    d.onclick = fn; box.appendChild(d); return d;
  };
  const sep = () => { const d = document.createElement('div'); d.className = 'menu-sep'; box.appendChild(d); };
  if (view === 'root') {
    const va = visionOk(active());
    item(UI_ICON.paperclip + ' Add files' + (va ? ' or photos' : '') + ' <span class="mi-hint">⌘U</span>' + (va ? '' : ' <span class="mi-hint">(no images — model can\'t see them)</span>'), () => { hideMenus(); attachFiles(); });
    item(UI_ICON.folder + ' Add folder', async () => {
      hideMenus();
      const rec = active(); if (!rec) return;
      const p = await H.pickFolderPath(rec.meta.id);
      if (p) { const i = $('input'); i.value = (i.value ? i.value.replace(/\s?$/, ' ') : '') + '@' + p + '/ '; i.focus(); }
    });
    item('▸ Slash commands', () => { hideMenus(); const i = $('input'); i.value = '/'; i.focus(); i.dispatchEvent(new Event('input')); });
    sep();
    item('🔌 Connectors <span class="mi-hint">›</span>', (e) => { e.stopPropagation(); renderPlusMenu('connectors'); });
    item('🧩 Plugins <span class="mi-hint">›</span>', (e) => { e.stopPropagation(); renderPlusMenu('plugins'); });
  } else if (view === 'connectors') {
    item('‹ Connectors', (e) => { e.stopPropagation(); renderPlusMenu('root'); });
    sep();
    const list = await H.mcpList();
    if (!list.length) item('<span class="mi-hint">No MCP servers yet</span>', () => {});
    for (const s of list) {
      const dot = s.status === 'running' ? '🟢' : s.enabled ? '🔴' : '⚪';
      item(dot + ' ' + esc(s.name) + ' <span class="mi-hint">' + (s.status === 'running' ? s.tools.length + ' tools · on' : s.enabled ? s.status : 'off') + '</span>',
        async (e) => {
          e.stopPropagation();
          if (s.source && s.source.startsWith('plugin:')) await H.pluginToggle(s.source.slice(7), !s.enabled);
          else await H.mcpToggle(s.name, !s.enabled);
          renderPlusMenu('connectors');
        });
    }
    sep();
    item('Manage connectors…', () => { hideMenus(); openSettings('mcp'); });
  } else if (view === 'plugins') {
    item('‹ Plugins', (e) => { e.stopPropagation(); renderPlusMenu('root'); });
    sep();
    const list = await H.pluginList();
    if (!list.length) item('<span class="mi-hint">No plugins installed</span>', () => {});
    for (const p of list) {
      item((p.enabled ? '🟢 ' : '⚪ ') + esc(p.name) +
        ' <span class="mi-hint">' + p.skills.length + ' skills · ' + p.mcpServers.length + ' servers</span>',
        async (e) => { e.stopPropagation(); await H.pluginToggle(p.dir, !p.enabled); await loadSkills(); renderPlusMenu('plugins'); });
    }
    sep();
    item('Manage plugins…', () => { hideMenus(); openSettings('plugins'); });
  }
}
$('plusBtn').onclick = () => {
  const open = $('plusMenu').style.display !== 'none';
  hideMenus();
  if (open) return;
  renderPlusMenu('root');
  $('plusMenu').style.display = '';
};

// ---- usage popover: context window + session cost + OpenRouter credits
$('usageLabel').onclick = async () => {
  const open = $('usageMenu').style.display !== 'none';
  hideMenus();
  if (open) return;
  const rec = active(); if (!rec) return;
  $('usageMenu').style.display = '';
  if (!S.models.length) S.models = await H.listModels(false);
  const mm = S.models.find((x) => x.value === rec.meta.model);
  const limit = mm && mm.context ? mm.context : 0;
  const used = (rec.meta.usage && rec.meta.usage.context) || 0;
  const pct = limit ? Math.min(100, Math.round(used / limit * 100)) : 0;
  $('ctxPct').textContent = limit ? fmtTokens(used) + ' / ' + fmtTokens(limit) + ' (' + pct + '%)' : fmtTokens(used) + ' used';
  $('ctxBar').style.width = pct + '%';
  const cost = (rec.meta.usage && rec.meta.usage.cost) || 0;
  $('umCost').textContent = '$' + cost.toFixed(cost < 0.1 ? 4 : 2);
  $('umCredits').textContent = '…';
  const cr = await H.credits();
  if (cr && cr.total != null) {
    $('umCredits').textContent = '$' + (cr.used || 0).toFixed(2) + ' used of $' + cr.total.toFixed(2);
    $('creditsBar').style.width = Math.min(100, Math.round((cr.used || 0) / cr.total * 100)) + '%';
  } else if (cr && cr.used != null) {
    $('umCredits').textContent = '$' + cr.used.toFixed(2) + ' used';
    $('creditsBar').style.width = '0%';
  } else {
    $('umCredits').textContent = 'unavailable';
  }
};
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
$('apAlways').onclick = () => {
  const a = S.showingApproval; if (!a) return;
  $('approvalModal').style.display = 'none';
  H.respondApproval(a.id, true, true);
  const rec = S.recs.get(a.sessionId);
  if (rec) { rec.approvals = rec.approvals.filter((x) => x.id !== a.id); addLine(rec, 'done', '✓ rule saved: always allow "' + String(a.detail || '').split(/\s+/).slice(0, 2).join(' ') + '…" here'); }
  S.showingApproval = null;
  renderSidebar();
  setTimeout(maybeShowApproval, 60);
};
document.addEventListener('keydown', (e) => {
  if ($('approvalModal').style.display !== 'flex') return;
  if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); respondApproval(true); }
  else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); respondApproval(false); }
}, true);

// ---------------------------------------------------------------- right panel (tabs)
const TABS = ['changes', 'files', 'tasks', 'preview'];
function showPanel(tab) {
  S.panel = tab;
  $('rightPanel').style.display = '';
  for (const t of TABS) $('tab-' + t).style.display = t === tab ? '' : 'none';
  for (const b of document.querySelectorAll('.ptab')) b.classList.toggle('on', b.dataset.tab === tab);
  if (tab === 'changes') refreshGit();
  else if (tab === 'files') refreshFiles();
  else if (tab === 'tasks') renderTasks();
}
function closePanel() { S.panel = null; $('rightPanel').style.display = 'none'; }
function togglePanel(tab) { (S.panel === tab) ? closePanel() : showPanel(tab); }
for (const b of document.querySelectorAll('.ptab')) b.onclick = () => showPanel(b.dataset.tab);
$('panelClose').onclick = closePanel;
function toggleDiff() { togglePanel('changes'); }
$('diffToggle').onclick = toggleDiff;
$('gitRefresh').onclick = () => refreshGit();
$('gitCommitBtn').onclick = async () => {
  const rec = active(); if (!rec) return;
  const msg = prompt('Commit message:', 'Changes via Harness Code');
  if (msg === null) return;
  const r = await H.gitCommit(rec.meta.id, msg);
  addLine(rec, r.error ? 'err' : 'done', r.error ? '⚠︎ ' + r.error : '✓ ' + r.out);
  refreshGit();
};
$('gitPrBtn').onclick = async () => {
  const rec = active(); if (!rec) return;
  const r = await H.gitPr(rec.meta.id);
  if (r.error) addLine(rec, 'err', '⚠︎ ' + r.error);
};
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
    el.innerHTML = '<span class="g-st ' + esc(stLetter) + '">' + esc(f.status === '??' ? 'U' : f.status) + '</span><span class="g-path">' + esc(f.path) + '</span><button class="gf-x" title="Discard changes to this file">✕</button>';
    el.onclick = () => { S.selGitFile = f.path; refreshGitSel(); showFileDiff(f.path); };
    el.querySelector('.gf-x').onclick = async (e) => {
      e.stopPropagation();
      if (!confirm('Discard changes to ' + f.path + '?' + (stLetter === 'U' ? ' (deletes the untracked file)' : ''))) return;
      const r = await H.gitDiscard(rec.meta.id, f.path, f.status);
      if (r.error) alert(r.error);
      refreshGit();
    };
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

// ---------------------------------------------------------------- run popover + more menu
const MENU_IDS = ['runPop', 'moreMenu', 'modeMenu', 'plusMenu', 'effortMenu', 'usageMenu'];
const MENU_TRIGGERS = ['#runBtn', '#moreBtn', '#modeBtn', '#plusBtn', '#effortBtn', '#usageLabel'];
function hideMenus() { for (const id of MENU_IDS) $(id).style.display = 'none'; }
document.addEventListener('mousedown', (e) => {
  if (!e.target.closest('.menu') && !MENU_TRIGGERS.some((sel) => e.target.closest(sel))) hideMenus();
});

$('runBtn').onclick = async () => {
  const rec = active(); if (!rec) return;
  const wasOpen = $('runPop').style.display !== 'none';
  hideMenus();
  if (wasOpen) return;
  $('runPop').style.display = '';
  $('runCmd').value = localStorage.getItem('runCmd:' + rec.meta.cwd) || '';
  $('runCmd').focus();
  const scripts = await H.projectScripts(rec.meta.id);
  const box = $('runScripts'); box.innerHTML = '';
  for (const s of scripts.slice(0, 12)) {
    const row = document.createElement('div'); row.className = 'menu-item';
    row.innerHTML = '<span class="p-main">' + esc(s.name) + '</span><span class="mi-hint">' + esc(s.command) + '</span>';
    row.onclick = () => { $('runCmd').value = s.command; startRun(); };
    box.appendChild(row);
  }
};
async function startRun() {
  const rec = active(); if (!rec) return;
  const command = $('runCmd').value.trim();
  if (!command) return;
  localStorage.setItem('runCmd:' + rec.meta.cwd, command);
  hideMenus();
  const t = await H.taskStart(rec.meta.id, command);
  if (t && t.error) { addLine(rec, 'err', '⚠︎ ' + t.error); return; }
  if (t) { S.tasks.set(t.id, t); S.selTask = t.id; showPanel('tasks'); }
}
$('runStart').onclick = startRun;
$('runCmd').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); startRun(); } if (e.key === 'Escape') hideMenus(); });

$('moreBtn').onclick = () => {
  const wasOpen = $('moreMenu').style.display !== 'none';
  hideMenus();
  if (!wasOpen) $('moreMenu').style.display = '';
};
$('moreMenu').addEventListener('click', async (e) => {
  const item = e.target.closest('.menu-item'); if (!item) return;
  const act = item.dataset.act;
  hideMenus();
  const rec = active();
  if (act === 'files' || act === 'tasks' || act === 'preview') showPanel(act);
  else if (act === 'sessions') H.openSessionsFolder();
  else if (rec && (act === 'finder' || act === 'terminal' || act === 'vscode')) {
    const r = await H.openIn(rec.meta.id, act);
    if (r && r.error) addLine(rec, 'err', '⚠︎ ' + r.error);
  }
});

// ---------------------------------------------------------------- background tasks
function taskDot(t) { return t.status === 'running' ? '<span class="t-dot run">●</span>' : '<span class="t-dot dead">●</span>'; }
function renderTasks() {
  const box = $('taskListEl'); box.innerHTML = '';
  const list = [...S.tasks.values()].sort((a, b) => b.startedAt - a.startedAt);
  const running = list.filter((t) => t.status === 'running').length;
  $('taskBadge').style.display = running ? '' : 'none';
  $('taskBadge').textContent = running;
  if (!list.length) { box.innerHTML = '<div class="git-empty">No background tasks. Start one with ▷ in the toolbar.</div>'; $('taskLogEl').textContent = ''; return; }
  for (const t of list) {
    const row = document.createElement('div'); row.className = 'task-row' + (t.id === S.selTask ? ' sel' : '');
    row.innerHTML = taskDot(t) +
      '<span class="t-name">' + esc(t.name) + (t.status === 'exited' ? ' <span class="mi-hint">(exit ' + t.exitCode + ')</span>' : '') + '</span>' +
      (t.url ? '<span class="t-url">' + esc(t.url.replace(/^https?:\/\//, '')) + '</span>' : '') +
      '<button class="t-stop" title="' + (t.status === 'running' ? 'Stop' : 'Remove') + '">' + (t.status === 'running' ? '■' : '✕') + '</button>';
    row.onclick = async () => { S.selTask = t.id; renderTasks(); $('taskLogEl').textContent = await H.taskLog(t.id); $('taskLogEl').scrollTop = 1e9; };
    row.querySelector('.t-stop').onclick = async (e) => {
      e.stopPropagation();
      if (t.status === 'running') await H.taskStop(t.id);
      else { await H.taskRemove(t.id); S.tasks.delete(t.id); if (S.selTask === t.id) { S.selTask = null; $('taskLogEl').textContent = ''; } renderTasks(); }
    };
    box.appendChild(row);
  }
  if (S.selTask && S.tasks.has(S.selTask)) H.taskLog(S.selTask).then((l) => { $('taskLogEl').textContent = l; $('taskLogEl').scrollTop = 1e9; });
}
H.onTaskEvent((e) => {
  if (e.type === 'log') {
    if (S.panel === 'tasks' && e.id === S.selTask) {
      const el = $('taskLogEl');
      const stick = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
      el.textContent = (el.textContent + e.chunk).slice(-60000);
      if (stick) el.scrollTop = el.scrollHeight;
    }
    return;
  }
  H.taskList().then((list) => {
    S.tasks = new Map(list.map((t) => [t.id, t]));
    if (S.panel === 'tasks') renderTasks();
    const running = list.filter((t) => t.status === 'running').length;
    $('taskBadge').style.display = running ? '' : 'none';
    $('taskBadge').textContent = running;
  });
  if (e.type === 'url') setPreview(e.url, true);
});

// ---------------------------------------------------------------- preview (webview)
let webview = null;
function setPreview(url, autoshow) {
  if (!url) return;
  $('previewUrl').value = url;
  if (autoshow) showPanel('preview');
  const host = $('previewHost');
  if (!webview) {
    host.innerHTML = '';
    webview = document.createElement('webview');
    webview.setAttribute('partition', 'preview');
    host.appendChild(webview);
  }
  webview.setAttribute('src', url);
}
$('previewGo').onclick = () => { const u = $('previewUrl').value.trim(); if (u) setPreview(/^https?:/.test(u) ? u : 'http://' + u, false); else if (webview) webview.reload(); };
$('previewUrl').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('previewGo').onclick(); });
$('previewExt').onclick = () => { const u = $('previewUrl').value.trim(); if (u) H.openExternal(/^https?:/.test(u) ? u : 'http://' + u); };

// ---------------------------------------------------------------- files panel
async function refreshFiles() {
  const rec = active(); if (!rec) return;
  $('filesRoot').textContent = shortDir(rec.meta.cwd);
  $('filePreview').style.display = 'none';
  S.selFile = null;
  const tree = $('fileTree'); tree.innerHTML = '';
  await renderTreeLevel(tree, '', 0);
}
$('filesRefresh').onclick = () => refreshFiles();
async function renderTreeLevel(container, sub, depth) {
  const rec = active(); if (!rec || depth > 8) return;
  const entries = await H.fileTree(rec.meta.id, sub || '.');
  for (const e of entries) {
    const rel = sub ? sub + '/' + e.name : e.name;
    const row = document.createElement('div'); row.className = 'ft-row';
    row.style.paddingLeft = (6 + depth * 14) + 'px';
    row.innerHTML = '<span class="ft-i">' + (e.dir ? '▸' : '·') + '</span>' + esc(e.name) + (e.dir ? '/' : '');
    container.appendChild(row);
    if (e.dir) {
      let kids = null;
      row.onclick = async () => {
        if (kids) { kids.remove(); kids = null; row.querySelector('.ft-i').textContent = '▸'; return; }
        kids = document.createElement('div');
        row.after(kids);
        row.querySelector('.ft-i').textContent = '▾';
        await renderTreeLevel(kids, rel, depth + 1);
      };
    } else {
      row.onclick = async () => {
        for (const r of document.querySelectorAll('.ft-row.sel')) r.classList.remove('sel');
        row.classList.add('sel');
        S.selFile = rel;
        const res = await H.fileRead(rec.meta.id, rel);
        const fp = $('filePreview');
        fp.style.display = '';
        fp.textContent = res.error ? '⚠︎ ' + res.error : res.binary ? '(binary file, ' + res.bytes + ' bytes)' : res.content;
      };
    }
  }
}


// ---------------------------------------------------------------- message context menu + code copy
let msgCtxEl = null;
function hideMsgCtx() { if (msgCtxEl) { msgCtxEl.remove(); msgCtxEl = null; } }
document.addEventListener('mousedown', (e) => { if (msgCtxEl && !e.target.closest('.msg-ctx')) hideMsgCtx(); });
document.addEventListener('contextmenu', (e) => {
  const msg = e.target.closest('.msg');
  if (!msg || !e.target.closest('.log')) return;
  e.preventDefault();
  hideMsgCtx(); hideCtxMenu(); hideMenus();
  const sel = String(window.getSelection() || '').trim();
  const mdEl = msg.querySelector('.md');
  const raw = mdEl ? (mdEl.dataset.raw || msg.innerText) : msg.innerText;
  const plain = msg.innerText;
  msgCtxEl = document.createElement('div');
  msgCtxEl.className = 'menu ctx-menu msg-ctx';
  const item = (label, fn) => {
    const d = document.createElement('div');
    d.className = 'menu-item';
    d.textContent = label;
    d.onmousedown = (ev) => ev.stopPropagation();
    d.onclick = () => { hideMsgCtx(); fn(); };
    msgCtxEl.appendChild(d);
  };
  if (sel) item('Copy selection', () => H.clipboardWrite(sel));
  item('Copy message', () => H.clipboardWrite(plain));
  if (mdEl) item('Copy as Markdown', () => H.clipboardWrite(raw));
  item('Attach as context', () => {
    const q = (sel || plain).split('\n').map((l) => '> ' + l).join('\n');
    input.value = (input.value ? input.value + '\n' : '') + q + '\n\n';
    input.dispatchEvent(new Event('input'));
    input.focus();
  });
  document.body.appendChild(msgCtxEl);
  const r = msgCtxEl.getBoundingClientRect();
  msgCtxEl.style.left = Math.min(e.clientX, window.innerWidth - r.width - 8) + 'px';
  msgCtxEl.style.top = Math.min(e.clientY, window.innerHeight - r.height - 8) + 'px';
  msgCtxEl.style.right = 'auto';
});
// one-click copy on any fenced code block
document.addEventListener('click', (e) => {
  const btn = e.target.closest('.code-copy');
  if (!btn) return;
  const code = btn.parentElement.querySelector('code');
  if (code) {
    H.clipboardWrite(code.innerText);
    btn.textContent = '✓';
    setTimeout(() => { btn.textContent = '⧉'; }, 1200);
  }
});

// ---------------------------------------------------------------- model favorites (right-click or ★)
function favModels() { try { return JSON.parse(localStorage.getItem('favModels') || '[]'); } catch { return []; } }
function toggleFavModel(v) {
  const f = favModels();
  const i = f.indexOf(v);
  if (i >= 0) f.splice(i, 1); else f.push(v);
  localStorage.setItem('favModels', JSON.stringify(f));
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
  let list = s ? S.models.filter((m) => m.value.toLowerCase().includes(s) || m.label.toLowerCase().includes(s)) : S.models;
  const fav = favModels();
  if (fav.length) list = [...list].sort((a, b) => (fav.includes(b.value) ? 1 : 0) - (fav.includes(a.value) ? 1 : 0));
  $('modelCount').textContent = list.length + ' of ' + S.models.length + ' models' +
    (s && !S.models.some((m) => m.value === q.trim()) ? ' · Enter to use “' + q.trim() + '”' : '');
  const box = $('modelList'); box.innerHTML = '';
  for (const m of list.slice(0, 400)) {
    const row = document.createElement('div');
    row.className = 'model-row' + (rec && m.value === rec.meta.model ? ' sel' : '');
    const isFav = fav.includes(m.value);
    row.innerHTML = '<div class="m-line"><span class="fav-star' + (isFav ? ' on' : '') + '" title="Favourite (or right-click the row)">' + (isFav ? '★' : '☆') + '</span><div>' + esc(m.label) + (m.reasoning ? ' <span class="mi-hint" title="Supports reasoning effort">' + UI_ICON.brain + '</span>' : '') + (m.vision ? ' <span class="mi-hint" title="Understands images">' + UI_ICON.image + '</span>' : '') + (m.local ? ' <span class="mi-hint" title="Runs locally via Ollama — free">' + UI_ICON.chip + '</span>' : '') + '</div><div class="m-price">' + esc(priceStr(m)) + '</div></div>' +
      '<div class="mv">' + esc(m.value) + (m.context ? ' · ' + Math.round(m.context / 1000) + 'k ctx' : '') + '</div>';
    row.onclick = () => chooseModel(m.value);
    row.oncontextmenu = (e) => { e.preventDefault(); toggleFavModel(m.value); renderModels($('modelSearch').value); };
    row.querySelector('.fav-star').onclick = (e) => { e.stopPropagation(); toggleFavModel(m.value); renderModels($('modelSearch').value); };
    box.appendChild(row);
  }
}
async function chooseModel(v) {
  await setSessionConfig({ model: v });
  $('modelSheet').style.display = 'none';
}

// ---------------------------------------------------------------- settings page
$('settingsBtn').onclick = () => {
  $('settingsSheet').style.display = 'flex';
  $('keyInput').value = '';
  renderMcpList(); renderSkillsList(); renderPluginsList(); renderSpend(); renderRules(); renderTrash(); refreshAutomations(); fillMediaSelects();
  H.getConfig().then((c) => { $('sandboxToggle').checked = !!c.sandboxBash; $('suggestToggle').checked = !!c.suggestions; });
};
$('sandboxToggle').onchange = () => H.setConfig({ sandboxBash: $('sandboxToggle').checked });
$('suggestToggle').onchange = () => H.setConfig({ suggestions: $('suggestToggle').checked });
async function renderTrash() {
  const list = await H.trashList();
  const box = $('trashList'); box.innerHTML = '';
  if (!list.length) { box.innerHTML = '<div class="muted">Trash is empty.</div>'; return; }
  for (const t of list) {
    const row = document.createElement('div'); row.className = 'sl-row';
    row.innerHTML = '<div class="sl-main"><b>' + esc(t.title) + '</b> <span class="mi-hint">' + t.items + ' items · deleted ' + timeAgo(t.deletedAt) + ' ago</span></div>' +
      '<button class="mini-btn" data-a="restore">Restore</button><button class="mini-btn" data-a="purge">✕</button>';
    row.querySelector('[data-a=restore]').onclick = async () => { await H.trashRestore(t.id); await refreshSessions(); renderTrash(); };
    row.querySelector('[data-a=purge]').onclick = async () => { if (confirm('Permanently delete "' + t.title + '"?')) { await H.trashPurge(t.id); renderTrash(); } };
    box.appendChild(row);
  }
}
async function renderRules() {
  const rules = await H.rulesList();
  const box = $('rulesList'); box.innerHTML = '';
  if (!rules.length) { box.innerHTML = '<div class="muted">No rules yet — use "Always allow" on an approval prompt.</div>'; return; }
  rules.forEach((r, i) => {
    const row = document.createElement('div'); row.className = 'sl-row';
    row.innerHTML = '<div class="sl-main"><b>' + esc(r.kind) + '</b> <span class="mi-hint mono">' + esc(r.prefix) + '…</span>' +
      '<div class="mi-hint">' + (r.cwd ? esc(shortDir(r.cwd)) : 'all projects') + '</div></div>' +
      '<button class="mini-btn">✕</button>';
    row.querySelector('button').onclick = async () => { await H.ruleRemove(i); renderRules(); };
    box.appendChild(row);
  });
}

// AI spend (General section)
function money(v) { return '$' + (v < 0.1 ? v.toFixed(4) : v.toFixed(2)); }
async function renderSpend() {
  const s = await H.spendSummary();
  if (!s) return;
  $('spendGrid').innerHTML =
    '<span>Today</span><span>' + money(s.today) + '</span>' +
    '<span>This week</span><span>' + money(s.week) + '</span>' +
    '<span>This month</span><span>' + money(s.month) + '</span>' +
    '<span>YTD</span><span>' + money(s.ytd) + '</span>' +
    '<span>All time</span><span>' + money(s.allTime) + ' <span class="mi-hint">Harness only</span></span>' +
    (s.credits && s.credits.used != null
      ? '<span>Account</span><span>' + money(s.credits.used) + (s.credits.total ? ' of $' + s.credits.total.toFixed(2) + ' credits' : '') + ' <span class="mi-hint">whole OpenRouter key</span></span>'
      : '');
  const max = Math.max(...s.bars.map((b) => b.cost), 0.0001);
  $('spendBars').innerHTML = s.bars.map((b) =>
    '<div class="b" style="height:' + Math.max(2, Math.round(b.cost / max * 100)) + '%" title="' + b.day + ' · ' + money(b.cost) + '"></div>'
  ).join('');
}
$('settingsClose').onclick = () => { $('settingsSheet').style.display = 'none'; };
$('sessionsFolderBtn').onclick = () => H.openSessionsFolder();
$('keySave').onclick = async () => {
  const k = $('keyInput').value.trim();
  if (k) { await H.setConfig({ apiKey: k }); S.models = []; $('keyInput').value = ''; }
};
for (const b of document.querySelectorAll('.snav')) {
  b.onclick = () => {
    for (const x of document.querySelectorAll('.snav')) x.classList.toggle('on', x === b);
    for (const sec of document.querySelectorAll('.ssec')) sec.style.display = 'none';
    $('sec-' + b.dataset.sec).style.display = '';
  };
}

// MCP servers section
async function renderMcpList() {
  const list = await H.mcpList();
  const box = $('mcpList'); box.innerHTML = '';
  if (!list.length) { box.innerHTML = '<div class="muted">No servers yet — add one below.</div>'; return; }
  for (const s of list) {
    const row = document.createElement('div'); row.className = 'sl-row';
    const dot = s.status === 'running' ? '<span class="dot ok">●</span>' : s.status === 'starting' ? '<span class="dot run">●</span>' : '<span class="dot bad">●</span>';
    row.innerHTML = dot + '<div class="sl-main"><b>' + esc(s.name) + '</b> <span class="mi-hint">' + esc(s.status) +
      (s.status === 'running' ? ' · ' + s.tools.length + ' tools' : '') + (s.error ? ' · ' + esc(s.error.slice(0, 80)) : '') + '</span>' +
      '<div class="mi-hint mono">' + esc(s.command) + '</div>' +
      (s.tools.length ? '<div class="mi-hint">' + esc(s.tools.slice(0, 8).join(', ')) + (s.tools.length > 8 ? '…' : '') + '</div>' : '') + '</div>' +
      '<button class="mini-btn" data-a="toggle">' + (s.enabled ? 'Disable' : 'Enable') + '</button>' +
      '<button class="mini-btn" data-a="restart">⟳</button>' +
      '<button class="mini-btn" data-a="remove">✕</button>';
    row.querySelector('[data-a=toggle]').onclick = async () => { await H.mcpToggle(s.name, !s.enabled); renderMcpList(); };
    row.querySelector('[data-a=restart]').onclick = async () => { await H.mcpRestart(s.name); renderMcpList(); };
    row.querySelector('[data-a=remove]').onclick = async () => { if (confirm('Remove MCP server "' + s.name + '"?')) { await H.mcpRemove(s.name); renderMcpList(); } };
    box.appendChild(row);
  }
}
$('mcpAddBtn').onclick = async () => {
  const r = await H.mcpAdd($('mcpName').value.trim(), $('mcpCmd').value.trim());
  if (r.error) alert(r.error);
  else { $('mcpName').value = ''; $('mcpCmd').value = ''; }
  renderMcpList();
};
H.onMcpUpdated(() => { if ($('settingsSheet').style.display === 'flex') renderMcpList(); });

// Skills section
async function loadSkills() { S.skills = await H.skillsList(); }
async function renderSkillsList() {
  await loadSkills();
  const box = $('skillsListEl'); box.innerHTML = '';
  if (!S.skills.length) { box.innerHTML = '<div class="muted">No skills yet — add one below, then type /name in the composer.</div>'; return; }
  for (const s of S.skills) {
    const row = document.createElement('div'); row.className = 'sl-row';
    row.innerHTML = '<div class="sl-main"><b>/' + esc(s.name) + '</b> <span class="mi-hint">' + esc(s.description || '') + '</span></div>' +
      '<button class="mini-btn" data-a="edit">Edit</button><button class="mini-btn" data-a="remove">✕</button>';
    row.querySelector('[data-a=edit]').onclick = () => { $('skillName').value = s.name; $('skillContent').value = s.content; };
    row.querySelector('[data-a=remove]').onclick = async () => { if (confirm('Delete skill /' + s.name + '?')) { await H.skillDelete(s.name); renderSkillsList(); } };
    box.appendChild(row);
  }
}
$('skillSaveBtn').onclick = async () => {
  const r = await H.skillSave($('skillName').value.trim(), $('skillContent').value);
  if (r.error) alert(r.error);
  else { $('skillName').value = ''; $('skillContent').value = ''; }
  renderSkillsList();
};

// Plugins section
async function renderPluginsList() {
  const list = await H.pluginList();
  const box = $('pluginList'); box.innerHTML = '';
  if (!list.length) { box.innerHTML = '<div class="muted">No plugins installed — add one below.</div>'; return; }
  for (const p of list) {
    const row = document.createElement('div'); row.className = 'sl-row';
    row.innerHTML = '<span class="dot ' + (p.enabled ? 'ok' : 'bad') + '">●</span>' +
      '<div class="sl-main"><b>' + esc(p.name) + '</b> <span class="mi-hint">' + esc(p.version || '') + ' ' + esc(p.description || '') + '</span>' +
      '<div class="mi-hint">' + p.skills.length + ' skills' + (p.skills.length ? ' (' + p.skills.map((s) => '/' + s).join(' ') + ')' : '') +
      ' · ' + p.mcpServers.length + ' MCP servers</div></div>' +
      '<button class="mini-btn" data-a="toggle">' + (p.enabled ? 'Disable' : 'Enable') + '</button>' +
      '<button class="mini-btn" data-a="remove">✕</button>';
    row.querySelector('[data-a=toggle]').onclick = async () => { await H.pluginToggle(p.dir, !p.enabled); await loadSkills(); renderPluginsList(); renderMcpList(); };
    row.querySelector('[data-a=remove]').onclick = async () => {
      if (confirm('Uninstall plugin "' + p.name + '"? This deletes its folder.')) { await H.pluginRemove(p.dir); await loadSkills(); renderPluginsList(); renderMcpList(); }
    };
    box.appendChild(row);
  }
}
$('pluginInstallBtn').onclick = async () => {
  const r = await H.pluginInstall($('pluginSource').value.trim());
  if (r.error) alert(r.error);
  else $('pluginSource').value = '';
  await loadSkills();
  renderPluginsList(); renderMcpList();
};

// ---------------------------------------------------------------- appshot + agent-driven browser
H.onAppshot((a) => {
  const rec = active(); if (!rec) return;
  if (!visionOk(rec)) { addLine(rec, 'err', '⚠︎ appshot skipped — ' + shortModel(rec.meta.model) + ' can\'t see images (pick a vision model — image icon in the picker)'); return; }
  rec.attachments = rec.attachments || [];
  rec.attachments.push({ name: a.name, dataUrl: a.dataUrl });
  renderAttachRow();
  addLine(rec, 'done', '📸 appshot attached — describe what you want done with it');
  $('input').focus();
});
H.onPreviewOpen(({ url }) => setPreview(url, true));

// ---------------------------------------------------------------- global keys
document.addEventListener('keydown', (e) => {
  const mod = e.metaKey || e.ctrlKey;
  // number keys pick a mode while the mode menu is open
  if ($('modeMenu').style.display !== 'none' && e.key >= '1' && e.key <= '5') {
    e.preventDefault(); hideMenus();
    setSessionConfig({ mode: MODES[+e.key - 1].key });
    return;
  }
  if (mod && e.key.toLowerCase() === 'u') { e.preventDefault(); attachFiles(); return; }
  if (mod && e.key.toLowerCase() === 'n') { e.preventDefault(); newChat(); }
  else if (mod && e.key.toLowerCase() === 'k') { e.preventDefault(); openModelSheet(false); }
  else if (mod && e.key.toLowerCase() === 'b') { e.preventDefault(); $('sideToggle').onclick(); }
  else if (mod && e.key.toLowerCase() === 'd') { e.preventDefault(); toggleDiff(); }
  else if (mod && e.shiftKey && e.key.toLowerCase() === 'f') { e.preventDefault(); togglePanel('files'); }
  else if (mod && e.key >= '1' && e.key <= '9') {
    const idx = +e.key - 1;
    if (S.order[idx]) { e.preventDefault(); activate(S.order[idx]); }
  }
  else if (e.key === 'Escape' && $('approvalModal').style.display !== 'flex') {
    if ($('modelSheet').style.display === 'flex') $('modelSheet').style.display = 'none';
    else if ($('settingsSheet').style.display === 'flex') $('settingsSheet').style.display = 'none';
    else if (S.cliView) closeCliView();
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
  loadSkills();
  // the effort chip needs per-model reasoning flags — load the (cached) catalog now
  S.models = await H.listModels(false);
  updateTitlebar();
  setInterval(renderSidebar, 60000);   // keep "2m ago" labels fresh
})();
