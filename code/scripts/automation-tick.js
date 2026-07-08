'use strict';
// launchd-driven automation runner: fires scheduled runs while the app is
// CLOSED (the in-app scheduler owns them while it's running). Results are
// written straight into the app's session store, so they appear as unread
// chats on next launch, plus a macOS notification now.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync, execFile } = require('child_process');
const { Session } = require(path.join(__dirname, '..', 'src', 'agent', 'agent'));

const HOME = os.homedir();
const APPDATA = path.join(HOME, 'Library', 'Application Support', 'harness-code');
const AUTOS = path.join(HOME, '.harness-code', 'automations.json');

// the app owns scheduling while it runs
try {
  const up = execFileSync('/usr/bin/pgrep', ['-f', 'Harness Code.app/Contents/MacOS']).toString().trim();
  if (up) process.exit(0);
} catch {}   // pgrep exits 1 when no match — that's our green light

function j(p, fb) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fb; } }
const autos = j(AUTOS, []);
const cfg = j(path.join(APPDATA, 'config.json'), {});
if (!cfg.apiKey || !autos.length) process.exit(0);

function nextRunOf(sched, from = Date.now()) {
  const d = new Date(from);
  if (sched.type === 'interval') return from + Math.max(1, sched.minutes || 60) * 60000;
  if (sched.type === 'hourly') { d.setMinutes(sched.mm || 0, 0, 0); if (d.getTime() <= from) d.setHours(d.getHours() + 1); return d.getTime(); }
  if (sched.type === 'daily') { d.setHours(sched.hh || 9, sched.mm || 0, 0, 0); if (d.getTime() <= from) d.setDate(d.getDate() + 1); return d.getTime(); }
  if (sched.type === 'weekly') {
    d.setHours(sched.hh || 9, sched.mm || 0, 0, 0);
    const want = sched.dow == null ? 1 : sched.dow;
    while (d.getDay() !== want || d.getTime() <= from) d.setDate(d.getDate() + 1);
    return d.getTime();
  }
  return from + 3600000;
}
const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

async function runOne(auto) {
  const rec = {
    id: newId(),
    title: ('⏱ ' + auto.name + ' — ' + new Date().toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })).slice(0, 60),
    cwd: auto.cwd || HOME, model: auto.model || cfg.model, mode: 'auto',
    createdAt: Date.now(), updatedAt: Date.now(),
    usage: { prompt_tokens: 0, completion_tokens: 0, cost: 0 },
    transcript: [{ t: 'user', text: auto.prompt, ts: Date.now() }],
  };
  let curText = '', curThink = '';
  const flush = () => {
    if (curText || curThink) rec.transcript.push({ t: 'assistant', text: curText, think: curThink, ts: Date.now() });
    curText = ''; curThink = '';
  };
  const s = new Session({
    apiKey: cfg.apiKey, model: rec.model, cwd: rec.cwd, mode: 'auto',
    sandbox: cfg.sandboxBash !== false,
    approve: async (kind, detail, opts = {}) => {
      if (!opts.danger) return true;
      // destructive action with nobody at the desk: push Allow/Deny to the phone
      // through the harness server and block on the human (≤~5 min, deny default)
      try {
        const env = fs.readFileSync(path.join(HOME, '.claude-harness', 'config.env'), 'utf8');
        const token = (/HARNESS_TOKEN=(\S+)/.exec(env) || [])[1];
        if (!token) return false;
        const r = await fetch('http://127.0.0.1:8787/automation/approval', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: auto.name, tool_name: kind, detail: String(detail || '').slice(0, 300) }),
          signal: AbortSignal.timeout(295000),
        });
        return ((await r.json()).decision === 'allow');
      } catch { return false; }
    },
    emit: (e) => {
      if (e.type === 'text') curText += e.delta;
      else if (e.type === 'reasoning') curThink += e.delta;
      else if (e.type === 'tool_call') { flush(); rec.transcript.push({ t: 'tool', name: e.name, args: e.args }); }
      else if (e.type === 'tool_result') { const last = [...rec.transcript].reverse().find((i) => i.t === 'tool' && i.result === undefined); if (last) last.result = e.result; }
      else if (e.type === 'error') rec.transcript.push({ t: 'err', text: e.message });
      else if (e.type === 'done') { flush(); rec.transcript.push({ t: 'note', text: 'done · ~' + ((e.usage.prompt_tokens || 0) + (e.usage.completion_tokens || 0)).toLocaleString() + ' tokens (background run)' }); }
    },
  });
  try { await s.send(auto.prompt); } catch (e) { rec.transcript.push({ t: 'err', text: String(e.message || e) }); }
  flush();
  rec.updatedAt = Date.now();
  const dir = path.join(APPDATA, 'sessions');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, rec.id + '.json'), JSON.stringify({
    meta: { id: rec.id, title: rec.title, cwd: rec.cwd, model: rec.model, mode: 'auto',
            effort: null, goal: null, pinned: false, unread: true, group: null, archived: false, worktree: null,
            createdAt: rec.createdAt, updatedAt: rec.updatedAt, usage: rec.usage },
    messages: s.messages, transcript: rec.transcript, checkpoints: [],
  }));
  const last = [...rec.transcript].reverse().find((i) => i.t === 'assistant');
  const body = ((last && last.text) || 'run finished').replace(/["\\]/g, '').slice(0, 110);
  execFile('/usr/bin/osascript', ['-e', 'display notification "' + body + '" with title "⏱ ' + auto.name.replace(/["\\]/g, '') + '" sound name "Glass"']);
  return rec.id;
}

(async () => {
  let dirty = false;
  for (const a of autos) {
    if (!a.enabled) continue;
    if (!a.nextRun) { a.nextRun = nextRunOf(a.schedule); dirty = true; continue; }
    if (Date.now() >= a.nextRun) {
      a.lastRun = Date.now();
      a.nextRun = nextRunOf(a.schedule);
      dirty = true;
      fs.writeFileSync(AUTOS, JSON.stringify(autos, null, 2));   // claim before the (slow) run
      a.lastSession = await runOne(a);
    }
  }
  if (dirty) fs.writeFileSync(AUTOS, JSON.stringify(autos, null, 2));
})();
