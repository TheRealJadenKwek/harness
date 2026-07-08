#!/usr/bin/env python3
"""
Claude/Codex Harness Server — a local, multi-thread, multi-model harness that
fronts the `claude` and `codex` CLIs on the Mac and streams to a native iOS app
over Tailscale. Stdlib only (http.server + threading), no pip deps.

Each THREAD is an independent CLI conversation (its own resumable session) with
its own engine + model/provider. New providers (GLM 5.2, Kimi, DeepSeek, …) are
added in providers.json — for Anthropic-compatible APIs the harness sets
ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / model per thread, so any such model
runs through the real `claude` CLI with full tool use.

HTTP API (all except GET /health require  Authorization: Bearer <HARNESS_TOKEN>):
  GET  /health                      -> {ok, version, engines}
  GET  /providers                   -> [{id,label,engine,model,enabled,...}]
  GET  /threads                     -> [thread summaries] (newest first)
  POST /threads  {provider?,engine?,cwd?,title?}   -> thread
  GET  /threads/{id}                -> full thread incl. messages
  POST /threads/{id}/rename {title} -> thread
  DELETE /threads/{id}              -> {ok}
  POST /threads/{id}/messages {text}-> text/event-stream of:
         {type:session,id} {type:thinking,delta} {type:text,delta}
         {type:tool,name} {type:done,text,session_id} {type:error,message}
  POST /threads/{id}/stop           -> {ok}  (kills that thread's running job)
"""
import os, re, sys, json, time, uuid, glob, shutil, tempfile, threading, subprocess, ipaddress, hmac, base64, signal, plistlib, queue, socket, urllib.parse, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Only accept connections from loopback or the Tailscale CGNAT range (100.64.0.0/10).
# Belt-and-suspenders with the bearer token: even on hostile Wi-Fi, non-tailnet
# clients are refused before auth, since this exec server runs full-control CLIs.
TAILNET = ipaddress.ip_network('100.64.0.0/10')

VERSION = '0.5.0'
BASE = os.path.expanduser('~/.claude-harness')
CONFIG = os.path.join(BASE, 'config.env')
PROVIDERS_FILE = os.path.join(BASE, 'providers.json')
KEYS_FILE = os.path.join(BASE, 'keys.json')   # app-set provider API keys (chmod 600)
THREADS_DIR = os.path.join(BASE, 'threads')
TRASH_DIR = os.path.join(BASE, 'trash')        # soft-deleted threads (restorable; auto-purged)
IMG_DIR = os.path.join(BASE, 'uploads')
PUSH_FILE = os.path.join(BASE, 'push.json')   # registered APNs device tokens
USAGE_FILE = os.path.join(BASE, 'usage.json') # latest plan rate-limit snapshot (from Claude stream)
LOG = os.path.join(BASE, 'harness.log')
HOME = os.path.expanduser('~')
TRASH_TTL_DAYS = 30
os.makedirs(THREADS_DIR, exist_ok=True)
os.makedirs(TRASH_DIR, exist_ok=True)
os.makedirs(IMG_DIR, exist_ok=True)

# --------------------------------------------------------------------------- config
def load_config():
    cfg = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return cfg

CFG = load_config()
# App-set provider keys persist here and overlay config.env (so keys entered in the
# iOS app survive restarts without editing config.env).
APP_KEYS = {}
try:
    with open(KEYS_FILE) as _kf:
        APP_KEYS = json.load(_kf)
        CFG.update(APP_KEYS)
except Exception:
    APP_KEYS = {}

def save_keys():
    tmp = KEYS_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(APP_KEYS, f)
    try:
        os.chmod(tmp, 0o600)
    except Exception:
        pass
    os.replace(tmp, KEYS_FILE)

TOKEN = CFG.get('HARNESS_TOKEN', '').strip()
# Per-boot secret shared ONLY with the approval_tool.py we spawn (via its mcp-config env),
# so the unauthenticated loopback /internal/approval can't be driven by other local processes.
APPROVAL_SECRET = base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip('=')
MAX_PENDING_APPROVALS = 64
PORT = int(CFG.get('HARNESS_PORT', '8787'))
CLAUDE_BIN = CFG.get('CLAUDE_BIN', '').strip() or shutil.which('claude') or 'claude'
CODEX_BIN = CFG.get('CODEX_BIN', '').strip() or shutil.which('codex') or 'codex'
GEMINI_BIN = CFG.get('GEMINI_BIN', '').strip() or shutil.which('gemini') or 'gemini'
JOB_TIMEOUT = int(CFG.get('JOB_TIMEOUT', '1800'))
MAX_MSG = int(CFG.get('MAX_MSG_CHARS', '100000'))
# APNs (push). Inactive until APNS_KEY_FILE/KEY_ID/TEAM_ID are set in config.env.
APNS_KEY_ID   = CFG.get('APNS_KEY_ID', '').strip()
APNS_TEAM_ID  = CFG.get('APNS_TEAM_ID', '').strip()
APNS_KEY_FILE = os.path.expanduser(CFG.get('APNS_KEY_FILE', '').strip())
APNS_BUNDLE   = CFG.get('APNS_BUNDLE_ID', 'com.jadenkwek.harness').strip()
APNS_ENV      = CFG.get('APNS_ENV', 'sandbox').strip()   # dev-signed app => sandbox
MAX_BODY = 32 * 1024 * 1024         # hard cap on raw request body (anti-DoS; fits compressed images)
ALLOWED_MODES = {'bypass', 'plan', 'acceptEdits', 'default'}   # Claude permission modes
ALLOWED_EFFORTS = {'default', 'low', 'medium', 'high', 'xhigh', 'max'}  # claude has max; codex tops at xhigh

HINT = (CFG.get('HARNESS_HINT', '').strip() or
        "You are reachable from a native iOS app on the user's Mac; keep replies readable on a phone.")

# Portable PATH: keep whatever launchd/shell gave us, then add the dirs of the detected CLIs
# plus the usual install locations — so node-based `claude`/`codex` resolve on any Mac.
BASE_ENV = dict(os.environ)
BASE_ENV['HOME'] = HOME
_extra_path = []
for _b in (CLAUDE_BIN, CODEX_BIN, GEMINI_BIN):
    _d = os.path.dirname(_b) if os.path.isabs(_b) else ''
    if _d and _d not in _extra_path:
        _extra_path.append(_d)
for _d in (os.path.join(HOME, '.local/bin'), '/opt/homebrew/bin', '/usr/local/bin',
           '/usr/bin', '/bin', '/usr/sbin', '/sbin'):
    if _d not in _extra_path:
        _extra_path.append(_d)
BASE_ENV['PATH'] = ':'.join(_extra_path) + ':' + BASE_ENV.get('PATH', '')

def log(msg):
    line = '[%s] %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg)
    print(line, flush=True)
    try:
        open(LOG, 'a').write(line + '\n')
    except Exception:
        pass


def rotate_logs():
    """Keep log files bounded: past 5MB, keep only the last ~1MB.
    harness.log is append-per-write (safe). stdout/stderr are held open by
    launchd/Task Scheduler — tail-keep leaves the writer's offset alone, which
    creates a sparse gap; disk usage stays small, which is all we need."""
    for name in ('harness.log', 'stdout.log', 'stderr.log'):
        p = os.path.join(BASE, name)
        try:
            if os.path.getsize(p) <= 5 * 1024 * 1024:
                continue
            with open(p, 'r+b') as f:
                f.seek(-1024 * 1024, 2)
                tail = f.read()
                nl = tail.find(b'\n')
                tail = tail[nl + 1:] if nl >= 0 else tail
                f.seek(0)
                f.write(b'[rotated]\n' + tail)
                f.truncate()
        except Exception:
            pass


def _rotate_loop():
    while True:
        time.sleep(6 * 3600)
        rotate_logs()


def tailnet_ip():
    """This machine's Tailscale IPv4. Route-probe first (no subprocess, and the
    macOS CLI can't run headless under launchd — it tries to start the GUI):
    a connected UDP socket toward MagicDNS reveals which local IP routes there."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('100.100.100.100', 53))          # no packets are sent
        ip = s.getsockname()[0]
        s.close()
        if ipaddress.ip_address(ip) in TAILNET:
            return ip
    except Exception:
        pass
    for c in ('tailscale', r'C:\Program Files\Tailscale\tailscale.exe'):
        try:
            r = subprocess.run([c, 'ip', '-4'], capture_output=True, text=True, timeout=5)
            ip = (r.stdout or '').strip().splitlines()[0].strip() if r.returncode == 0 else ''
            if ip and ipaddress.ip_address(ip) in TAILNET:
                return ip
        except Exception:
            continue
    return None


# Pairing page (loopback-only; contains the token). The QR encodes a harness://
# deep link the iOS app scans. QR rendering uses a small MIT-licensed generator
# from jsDelivr — if the CDN is unreachable the page still shows URL + token.
PAIR_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pair Harness</title>
<style>body{font:17px/1.6 -apple-system,system-ui,sans-serif;max-width:560px;margin:48px auto;padding:0 20px;color:#1d1d1f;text-align:center}
#qr{margin:24px auto}code{background:#f5f5f7;padding:2px 8px;border-radius:6px;font-size:15px;word-break:break-all}</style></head>
<body>
<h1>Pair your phone</h1>
<p>In the Harness app: <b>Settings &rarr; Add server &rarr; Scan QR</b></p>
<div id="qr"><p style="color:#86868b">(QR needs internet to render &mdash; or enter manually below)</p></div>
<p>URL <code>__URL__</code><br>Token <code>__TOKEN__</code></p>
<script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.min.js"
        onload="var q=qrcode(0,'M');q.addData('__PAIR__');q.make();document.getElementById('qr').innerHTML=q.createSvgTag({cellSize:6,margin:4});"></script>
</body></html>"""

# --------------------------------------------------------------------------- providers
DEFAULT_PROVIDERS = [
    {"id": "claude", "label": "Claude", "engine": "claude", "model": None,
     "base_url": None, "api_key_env": None, "enabled": True,
     "models": [{"label": "Opus 4.8", "value": "claude-opus-4-8"},
                {"label": "Sonnet 4.6", "value": "claude-sonnet-4-6"},
                {"label": "Haiku 4.5", "value": "claude-haiku-4-5"},
                {"label": "Opus 4.7", "value": "claude-opus-4-7"},
                {"label": "Opus 4.6", "value": "claude-opus-4-6"}]},
    {"id": "codex",  "label": "Codex",  "engine": "codex",  "model": None,
     "base_url": None, "api_key_env": None, "enabled": True,
     "models": [{"label": "GPT-5.5", "value": "gpt-5.5"},
                {"label": "GPT-5.4", "value": "gpt-5.4"},
                {"label": "GPT-5.4-Mini", "value": "gpt-5.4-mini"},
                {"label": "GPT-5.3-Codex-Spark", "value": "gpt-5.3-codex-spark"}]},
    # --- BYO-key slots: add the key to config.env, set "enabled": true, restart the harness ---
    # GLM coding plan via Z.ai's Anthropic-compatible endpoint (runs through the claude CLI).
    # Set model to glm-4.6 (stable) or glm-5.2 if your plan serves it.
    {"id": "glm", "label": "GLM (Z.ai coding)", "engine": "claude", "model": "glm-4.6",
     "base_url": "https://api.z.ai/api/anthropic", "api_key_env": "GLM_API_KEY", "enabled": False,
     "models": [{"label": "GLM-4.6", "value": "glm-4.6"}, {"label": "GLM-5.2", "value": "glm-5.2"}]},
    # OpenRouter via Codex's custom-provider mechanism (OpenAI-compatible). Set `model` to any
    # OpenRouter model id (e.g. "z-ai/glm-4.6", "anthropic/claude-3.7-sonnet", "deepseek/deepseek-chat").
    # If it errors on startup, change "wire_api" to "chat".
    {"id": "harness-code", "label": "Harness Code", "engine": "harness-code",
     "model": "deepseek/deepseek-v4-pro",
     "models": [{"label": "DeepSeek V4 Pro", "value": "deepseek/deepseek-v4-pro"},
                {"label": "Claude Fable 5", "value": "anthropic/claude-fable-5"},
                {"label": "GLM-5", "value": "z-ai/glm-5"},
                {"label": "GPT-4o-mini", "value": "openai/gpt-4o-mini"}]},
    {"id": "openrouter", "label": "OpenRouter", "engine": "codex", "model": "z-ai/glm-4.6",
     "base_url": "https://openrouter.ai/api/v1", "api_key_env": "OPENROUTER_API_KEY",
     "wire_api": "responses", "enabled": False},
]

def load_providers():
    try:
        with open(PROVIDERS_FILE) as f:
            return json.load(f)
    except Exception:
        with open(PROVIDERS_FILE, 'w') as f:
            json.dump(DEFAULT_PROVIDERS, f, indent=2)
        return list(DEFAULT_PROVIDERS)

def provider_by_id(pid):
    for p in load_providers():
        if p.get('id') == pid:
            return p
    return None

ALIAS_LABELS = {
    'opus': 'Opus 4.8', 'sonnet': 'Sonnet 4.6', 'haiku': 'Haiku 4.5',
    'claude-opus-4-8': 'Opus 4.8', 'claude-sonnet-4-6': 'Sonnet 4.6',
    'claude-haiku-4-5': 'Haiku 4.5', 'claude-opus-4-7': 'Opus 4.7', 'claude-opus-4-6': 'Opus 4.6',
    'gpt-5.5': 'GPT-5.5', 'gpt-5.4': 'GPT-5.4', 'gpt-5.4-mini': 'GPT-5.4-Mini',
    'gpt-5.3-codex-spark': 'GPT-5.3-Codex-Spark',
}

def _claude_default_model():
    try:
        return json.load(open(os.path.expanduser('~/.claude/settings.json'))).get('model')
    except Exception:
        return None

def _codex_default_model():
    try:
        for line in open(os.path.expanduser('~/.codex/config.toml')):
            line = line.strip()
            if (line.startswith('model') and '=' in line and 'reasoning' not in line
                    and 'provider' not in line):
                return line.split('=', 1)[1].strip().strip('"\'')
    except Exception:
        pass
    return None

def default_model_label(p):
    """Friendly name of what 'Default' resolves to for a provider."""
    raw = p.get('model')
    if not raw:
        eng = p.get('engine')
        raw = _claude_default_model() if eng == 'claude' else (_codex_default_model() if eng == 'codex' else None)
    return ALIAS_LABELS.get(str(raw).lower(), str(raw)) if raw else None

EFFORT_LABELS = {'low': 'Low', 'medium': 'Medium', 'high': 'High',
                 'xhigh': 'Extra High', 'max': 'Max', 'minimal': 'Minimal'}

def _codex_default_effort():
    try:
        for line in open(os.path.expanduser('~/.codex/config.toml')):
            line = line.strip()
            if line.startswith('model_reasoning_effort') and '=' in line:
                return line.split('=', 1)[1].strip().strip('"\'')
    except Exception:
        pass
    return None

def default_effort_label(p):
    eng = p.get('engine')
    raw = _codex_default_effort() if eng == 'codex' else None   # claude has no settable default
    return EFFORT_LABELS.get(str(raw).lower(), str(raw)) if raw else None

_MODELS_CACHE = {}                 # provider id -> (fetched_at, [{label,value}])
_models_lock = threading.Lock()

def fetch_provider_models(p):
    """Live model catalog for an OpenAI-compatible provider (base_url + /models), so the
    app can search ANY model the key unlocks (e.g. all of OpenRouter). Cached 1h; falls
    back to the static providers.json list on failure or for the built-in claude/codex."""
    pid, static = p.get('id'), (p.get('models') or [])
    base = p.get('base_url')
    if not base:
        return static
    with _models_lock:
        c = _MODELS_CACHE.get(pid)
        if c and time.time() - c[0] < 3600:
            return c[1]
    req = urllib.request.Request(base.rstrip('/') + '/models',
                                 headers={'Accept': 'application/json', 'User-Agent': 'harness'})
    key = CFG.get(p.get('api_key_env') or '') or ''
    if key:
        req.add_header('Authorization', 'Bearer ' + key)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r)
        items = data.get('data') if isinstance(data, dict) else data
        models, seen = [], set()
        for it in (items or []):
            mid = (it.get('id') if isinstance(it, dict) else str(it) or '').strip()
            if not mid or mid in seen:
                continue
            seen.add(mid)
            name = (it.get('name') if isinstance(it, dict) else '') or mid
            models.append({'label': str(name)[:70], 'value': mid})
        models.sort(key=lambda m: m['value'])
        if models:
            with _models_lock:
                _MODELS_CACHE[pid] = (time.time(), models)
            log('fetched %d models for %s' % (len(models), pid))
            return models
    except Exception as e:
        log('model fetch failed for %s: %s' % (pid, e))
    return static

def _provider_public(p):
    """Projection sent to the app — never the key value, just whether one is set."""
    return {'id': p.get('id'), 'label': p.get('label'), 'engine': p.get('engine'),
            'model': p.get('model'), 'enabled': p.get('enabled'),
            'models': p.get('models'), 'default_model': default_model_label(p),
            'default_effort': default_effort_label(p),
            'requires_key': bool(p.get('api_key_env')),
            'has_key': bool(p.get('api_key_env') and CFG.get(p['api_key_env']))}

# --------------------------------------------------------------------------- detached jobs
# A "job" runs an engine turn in a background thread, decoupled from the HTTP
# request that started it. The client SSE connection is just a *subscriber*: if
# the phone closes mid-turn, the job keeps running to completion, persists the
# answer, and fires a push notification. Reconnecting clients re-attach and get
# the buffered backlog + live tail.
_SENTINEL = object()
JOBS = {}                  # thread_id -> Job (only present while running)
_jobs_lock = threading.Lock()

# --------------------------------------------------------------------------- Live Activity pushes
# The app registers each turn's Live Activity push token; the server then keeps the
# lock screen / Dynamic Island moving after the app is closed by pushing content-state
# on PHASE changes (not per token — APNs live-activity updates are budget-limited).
ACTIVITY_TOKENS = {}       # thread_id -> activity push token (ephemeral; re-registered per turn)
_activity_lock = threading.Lock()

def _activity_state(ev):
    """Map a stream event to (phase, detail) for the Live Activity — None = no change."""
    t = ev.get('type')
    if t == 'thinking':          return 'thinking', ''
    if t == 'text':              return 'streaming', ''
    if t == 'tool':              return 'tool', (ev.get('summary') or ev.get('name') or '')[:120]
    if t == 'approval':          return 'approval', (ev.get('detail') or '')[:120]
    if t == 'approval_resolved': return 'streaming', ''
    if t == 'done':              return 'done', (ev.get('text') or '').strip()[:120]
    if t == 'error':             return 'error', (ev.get('message') or '')[:120]
    return None, None

def push_activity(tid, phase, detail):
    with _activity_lock:
        token = ACTIVITY_TOKENS.get(tid)
    if not token or not apns_configured():
        return
    payload = {'aps': {'timestamp': int(time.time()),
                       'event': 'end' if phase in ('done', 'error') else 'update',
                       'content-state': {'phase': phase, 'detail': detail}}}
    if phase in ('done', 'error'):
        payload['aps']['dismissal-date'] = int(time.time()) + 15
    def _send():
        ok, code, reason = apns_send(token, payload, push_type='liveactivity',
                                     topic=APNS_BUNDLE + '.push-type.liveactivity')
        if not ok:
            log('activity push %s… : %s %s' % (token[:8], code, reason))
        if phase in ('done', 'error'):
            with _activity_lock:
                if ACTIVITY_TOKENS.get(tid) == token:
                    del ACTIVITY_TOKENS[tid]
    threading.Thread(target=_send, daemon=True).start()

class Job:
    def __init__(self, tid):
        self.tid = tid
        self.events = []       # everything published so far (replay for late subscribers)
        self.subs = []         # live subscriber Queues
        self.done = False
        self.lock = threading.Lock()
        self.act_phase = ''    # last phase pushed to the Live Activity
        self.act_detail = ''
        self.act_ts = 0.0

    def publish(self, ev):
        # Live Activity: push on phase transitions; tool-detail changes throttle to 1/3s.
        phase, detail = _activity_state(ev)
        if phase:
            now = time.time()
            changed = phase != self.act_phase
            tool_refresh = (phase == 'tool' and detail != self.act_detail
                            and now - self.act_ts >= 3.0)
            if changed or tool_refresh:
                self.act_phase, self.act_detail, self.act_ts = phase, detail, now
                push_activity(self.tid, phase, detail)
        with self.lock:
            self.events.append(ev)
            # Bound replay memory on long agentic turns: keep all structured events
            # (session/tool/question/done/error) but only the tail of text/thinking deltas.
            if len(self.events) > 6000:
                self.events = ([e for e in self.events[:-2000]
                                if e.get('type') not in ('text', 'thinking')]
                               + self.events[-2000:])
            subs = list(self.subs)
        for q in subs:
            try: q.put_nowait(ev)
            except Exception: pass

    def attach(self):
        """Returns (backlog, queue_or_None). None queue => job already finished."""
        q = queue.Queue()
        with self.lock:
            backlog = list(self.events)
            if self.done:
                return backlog, None
            self.subs.append(q)
            return backlog, q

    def detach(self, q):
        with self.lock:
            if q in self.subs:
                self.subs.remove(q)

    def finish(self):
        with self.lock:
            self.done = True
            subs = list(self.subs); self.subs = []
        for q in subs:
            try: q.put_nowait(_SENTINEL)
            except Exception: pass

def job_for(tid):
    with _jobs_lock:
        return JOBS.get(tid)

# --------------------------------------------------------------------------- usage / rate limits
# Claude's stream-json emits a `rate_limit_event` carrying the plan limit that's currently
# binding (five_hour, and seven_day when near the weekly cap): status + resetsAt. We snapshot
# the latest per type. Codex's CLI exposes no plan/quota info — only per-turn tokens.
_usage_lock = threading.Lock()
def _load_usage():
    try:
        with open(USAGE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}
RATE_LIMITS = _load_usage()

def record_rate_limit(info):
    rlt = (info or {}).get('rateLimitType')
    if not rlt:
        return
    with _usage_lock:
        c = RATE_LIMITS.setdefault('claude', {})
        c[rlt] = {'status': info.get('status'), 'resetsAt': info.get('resetsAt'),
                  'isUsingOverage': info.get('isUsingOverage'), 'at': time.time()}
        c['updated'] = time.time()
        try:
            tmp = USAGE_FILE + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(RATE_LIMITS, f)
            os.replace(tmp, USAGE_FILE)
        except Exception:
            pass

# --------------------------------------------------------------------------- push (APNs)
_push_lock = threading.Lock()

# Push relay: harnesses WITHOUT a local APNs key (everyone but the developer)
# forward alert pushes through the hosted relay, which holds the signing key.
# The relay maps each device token to an opaque relay_id; we cache that mapping.
RELAY_URL = CFG.get('RELAY_URL', '').strip().rstrip('/')
_relay_ids = {}          # device token -> relay_id (in-memory cache; re-registers on restart)
_relay_lock = threading.Lock()

def relay_configured():
    return bool(RELAY_URL) and not apns_configured()

def _relay_id_for(token):
    with _relay_lock:
        rid = _relay_ids.get(token)
    if rid:
        return rid
    try:
        req = urllib.request.Request(RELAY_URL + '/register',
                                     data=json.dumps({'token': token}).encode(),
                                     headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=10) as r:
            rid = json.load(r).get('relay_id')
    except Exception as e:
        log('relay register failed: %s' % e)
        return None
    if rid:
        with _relay_lock:
            _relay_ids[token] = rid
    return rid

def relay_send(token, title, body_text, thread_id=None, approval_id=None, category=None):
    """Alert push via the hosted relay. Returns (ok, reason)."""
    rid = _relay_id_for(token)
    if not rid:
        return False, 'no relay_id'
    payload = {'relay_id': rid, 'title': title, 'body': body_text}
    if thread_id:
        payload['thread_id'] = thread_id
        payload['threadId'] = thread_id
    if approval_id:
        payload['approvalId'] = approval_id
    if category:
        payload['category'] = category
    try:
        req = urllib.request.Request(RELAY_URL + '/push', data=json.dumps(payload).encode(),
                                     headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.load(r)
            return bool(d.get('ok')), d.get('reason', '')
    except Exception as e:
        return False, str(e)[:60]

def load_push_tokens():
    try:
        with open(PUSH_FILE) as f:
            return list(dict.fromkeys(json.load(f).get('tokens', [])))
    except Exception:
        return []

def save_push_tokens(tokens):
    tokens = list(dict.fromkeys(tokens))
    tmp = PUSH_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump({'tokens': tokens}, f)
    try: os.chmod(tmp, 0o600)
    except Exception: pass
    os.replace(tmp, PUSH_FILE)
    return tokens

def add_push_token(tok):
    with _push_lock:
        toks = load_push_tokens()
        if tok not in toks:
            toks.append(tok)
            save_push_tokens(toks)
        return toks

def remove_push_tokens(bad):
    with _push_lock:
        toks = [t for t in load_push_tokens() if t not in set(bad)]
        save_push_tokens(toks)

def apns_configured():
    return bool(APNS_KEY_ID and APNS_TEAM_ID and APNS_KEY_FILE and os.path.exists(APNS_KEY_FILE))

_jwt_cache = {'jwt': None, 'iat': 0}
_jwt_lock = threading.Lock()

def _der_to_jose(der):
    """ECDSA DER signature (SEQUENCE{ INTEGER r, INTEGER s }) -> raw 64-byte r||s."""
    if not der or der[0] != 0x30:
        raise ValueError('bad DER')
    i = 2
    if der[1] & 0x80:                       # long-form outer length (defensive)
        i = 2 + (der[1] & 0x7f)
    if der[i] != 0x02: raise ValueError('bad DER r')
    i += 1; rlen = der[i]; i += 1; r = der[i:i+rlen]; i += rlen
    if der[i] != 0x02: raise ValueError('bad DER s')
    i += 1; slen = der[i]; i += 1; s = der[i:i+slen]; i += slen
    r = r.lstrip(b'\x00').rjust(32, b'\x00')
    s = s.lstrip(b'\x00').rjust(32, b'\x00')
    return r + s

def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=')

def apns_jwt():
    """ES256 JWT for APNs, signed via openssl (no pip deps). Cached ~40 min.
    Lock guards the check-mint-store so concurrent job threads don't double-mint."""
    with _jwt_lock:
        now = time.time()
        if _jwt_cache['jwt'] and now - _jwt_cache['iat'] < 2400:
            return _jwt_cache['jwt']
        if not apns_configured():
            return None
        header = _b64u(json.dumps({'alg': 'ES256', 'kid': APNS_KEY_ID}, separators=(',', ':')).encode())
        payload = _b64u(json.dumps({'iss': APNS_TEAM_ID, 'iat': int(now)}, separators=(',', ':')).encode())
        signing_input = header + b'.' + payload
        try:
            p = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', APNS_KEY_FILE],
                               input=signing_input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            if p.returncode != 0 or not p.stdout:
                log('apns jwt sign failed: %s' % (p.stderr or b'')[-200:]); return None
            sig = _der_to_jose(p.stdout)
        except Exception as e:
            log('apns jwt error: %s' % e); return None
        jwt = (signing_input + b'.' + _b64u(sig)).decode()
        _jwt_cache.update(jwt=jwt, iat=now)
        return jwt

def apns_send(token, payload, push_type='alert', topic=None):
    """Returns (ok, status_code, reason). reason is the APNs JSON 'reason' on failure.
    push_type 'liveactivity' + topic '<bundle>.push-type.liveactivity' updates Live Activities."""
    jwt = apns_jwt()
    if not jwt:
        return False, 'nojwt', 'NoJWT'
    host = 'api.sandbox.push.apple.com' if APNS_ENV == 'sandbox' else 'api.push.apple.com'
    url = 'https://%s/3/device/%s' % (host, token)
    cmd = ['curl', '-s', '--http2', '-X', 'POST',
           '-H', 'authorization: bearer ' + jwt,
           '-H', 'apns-topic: ' + (topic or APNS_BUNDLE),
           '-H', 'apns-push-type: ' + push_type,
           '-H', 'apns-priority: 10',
           '-d', json.dumps(payload), '-w', '\n%{http_code}', url]   # body + status (no -o /dev/null)
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15)
        out = (p.stdout or '').rsplit('\n', 1)
        code = out[-1].strip()[-3:] if out else ''
        reason = ''
        if code != '200' and len(out) == 2 and out[0].strip():
            try: reason = (json.loads(out[0]) or {}).get('reason', '')
            except Exception: reason = out[0].strip()[:60]
        return code == '200', (code or 'err'), reason
    except FileNotFoundError:
        return False, 'nocurl', 'CurlMissing'
    except Exception as e:
        return False, 'err', str(e)[:40]

# --------------------------------------------------------------------------- phone-side tool approval
# Ask-mode ('default') claude threads run with --permission-prompt-tool wired to
# approval_tool.py, which POSTs gated tool uses to /internal/approval. That
# request BLOCKS until the phone answers (or times out -> deny), so the CLI
# turn simply waits mid-flight, exactly like pressing y/n in a terminal.
APPROVALS = {}                 # id -> {thread_id, tool_name, input, decision, event, created}
_approvals_lock = threading.Lock()
APPROVAL_TIMEOUT = int(CFG.get('APPROVAL_TIMEOUT', '600'))

def approval_summary(tool_name, tool_input):
    """One human line describing what Claude wants to do."""
    d = tool_input or {}
    if tool_name == 'Bash':
        s = d.get('command') or ''
    elif tool_name in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
        s = d.get('file_path') or ''
    elif tool_name in ('WebFetch', 'WebSearch'):
        s = d.get('url') or d.get('query') or ''
    else:
        s = json.dumps(d)[:180]
    return ('%s: %s' % (tool_name, s))[:200]

def pending_approvals(tid):
    with _approvals_lock:
        return [{'id': a['id'], 'name': a['tool_name'],
                 'detail': approval_summary(a['tool_name'], a['input']),
                 'created': a['created']}
                for a in APPROVALS.values()
                if a['thread_id'] == tid and a['decision'] is None]

def notify_approval_push(thread, rec):
    tokens = load_push_tokens()
    if not tokens:
        return
    title = 'Approval needed — %s' % ((thread or {}).get('title') or 'Claude')[:45]
    body = approval_summary(rec['tool_name'], rec['input'])[:170]
    if relay_configured():
        for tok in tokens:
            ok, reason = relay_send(tok, title, body, thread_id=rec['thread_id'],
                                    approval_id=rec['id'], category='HARNESS_APPROVAL')
            log('relay approval push -> %s… : %s %s' % (tok[:8], 'ok' if ok else 'FAIL', reason))
        return
    if not apns_configured():
        return
    payload = {'aps': {'alert': {'title': title, 'body': body}, 'sound': 'default',
                       'category': 'HARNESS_APPROVAL', 'thread-id': rec['thread_id'],
                       'interruption-level': 'time-sensitive'},
               'threadId': rec['thread_id'], 'approvalId': rec['id']}
    bad = []
    for tok in tokens:
        ok, code, reason = apns_send(tok, payload)
        log('approval push -> %s… : %s %s' % (tok[:8], code, reason))
        if not ok and (code == '410' or reason in ('BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic')):
            bad.append(tok)
    if bad:
        remove_push_tokens(bad)

def notify_push(thread, text, questions=None):
    tokens = load_push_tokens()
    if not tokens:
        return
    who = 'Codex' if thread.get('engine') == 'codex' else 'Claude'
    title = (thread.get('title') or who)[:60]
    if questions:
        body = '❓ ' + str((questions[0] or {}).get('question') or 'Has a question for you')[:150]
    else:
        body = (text or '').replace('\n', ' ').strip()[:170] or 'Done'
    if relay_configured():                     # no local APNs key -> hosted relay
        for tok in tokens:
            ok, reason = relay_send(tok, title, body, thread_id=thread['id'])
            log('relay push -> %s… : %s %s' % (tok[:8], 'ok' if ok else 'FAIL', reason))
        return
    if not apns_configured():
        log('push: %d device(s) registered but APNs not configured (set APNS_* in config.env, or RELAY_URL)' % len(tokens))
        return
    payload = {'aps': {'alert': {'title': title, 'body': body},
                       'sound': 'default', 'badge': 1, 'thread-id': thread['id']},
               'threadId': thread['id'], 'engine': thread.get('engine')}
    bad = []
    for tok in tokens:
        ok, code, reason = apns_send(tok, payload)
        log('push -> %s… : %s %s' % (tok[:8], code, reason))
        # Only prune on a genuine dead-token signal — 410 Unregistered, or 400 BadDeviceToken.
        # A blanket 400/403 prune would delete still-valid tokens on transient/JWT errors.
        if not ok and (code == '410' or reason in ('BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic')):
            bad.append(tok)
    if bad:
        remove_push_tokens(bad)

# --------------------------------------------------------------------------- thread store
_store_lock = threading.Lock()
_persist_lock = threading.Lock()   # serializes thread-file read-modify-write (job persist vs rename)
thread_locks = {}          # id -> Lock (one running job per thread)
running = {}               # id -> Popen (for /stop)
_running_lock = threading.Lock()

def reg_run(tid, proc):
    with _running_lock:
        running[tid] = proc

def unreg_run(tid):
    with _running_lock:
        running.pop(tid, None)

def get_run(tid):
    with _running_lock:
        return running.get(tid)

def valid_tid(tid):
    return len(tid) == 32 and all(c in '0123456789abcdef' for c in tid)

def _lock_for(tid):
    with _store_lock:
        if tid not in thread_locks:
            thread_locks[tid] = threading.Lock()
        return thread_locks[tid]

def thread_path(tid):
    return os.path.join(THREADS_DIR, '%s.json' % tid)

def load_thread(tid):
    try:
        with open(thread_path(tid)) as f:
            return json.load(f)
    except Exception:
        return None

def save_thread(t):
    tmp = thread_path(t['id']) + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(t, f, indent=2)
    os.replace(tmp, thread_path(t['id']))

def thread_summary(t):
    s = {k: t.get(k) for k in
         ('id', 'title', 'engine', 'provider', 'model', 'cwd',
          'permission_mode', 'effort', 'session_id', 'created', 'updated', 'total_cost')}
    msgs = t.get('messages', [])
    s['message_count'] = len(msgs)
    s['running'] = job_for(t.get('id')) is not None
    s['archived'] = bool(t.get('archived'))
    if t.get('deleted_at'):
        s['deleted_at'] = t['deleted_at']
    if msgs:
        last = msgs[-1]
        s['last'] = (last.get('text') or '').replace('\n', ' ').strip()[:120]
        s['last_role'] = last.get('role')
        # a thread is "awaiting you" if its newest message is an assistant question
        s['awaiting'] = bool(last.get('role') == 'assistant' and last.get('questions'))
    return s

def list_threads(view='active'):
    """view: 'active' (non-archived), 'archived', or 'trash' (soft-deleted)."""
    directory = TRASH_DIR if view == 'trash' else THREADS_DIR
    out = []
    for p in glob.glob(os.path.join(directory, '*.json')):
        try:
            with open(p) as f:
                t = json.load(f)
        except Exception:
            continue
        archived = bool(t.get('archived'))
        if view == 'active' and archived:
            continue
        if view == 'archived' and not archived:
            continue
        out.append(thread_summary(t))
    key = 'deleted_at' if view == 'trash' else 'updated'
    out.sort(key=lambda x: x.get(key) or 0, reverse=True)
    return out

def purge_trash():
    cutoff = time.time() - TRASH_TTL_DAYS * 86400
    for p in glob.glob(os.path.join(TRASH_DIR, '*.json')):
        try:
            with open(p) as f:
                t = json.load(f)
            if (t.get('deleted_at') or 0) < cutoff:
                os.remove(p)
        except Exception:
            pass

# --------------------------------------------------------------------------- preview (file serving)
MAX_PREVIEW_BYTES = 64 * 1024 * 1024     # 413 above this
MAX_TEXT_BYTES = 4 * 1024 * 1024         # truncate text/code/markdown/svg past this
SCAN_MAX_DEPTH = 4
SCAN_MAX_ENTRIES = 6000
ARTIFACT_CAP = 300
SCAN_SKIP_DIRS = {'node_modules', '.git', 'dist', '.next', 'build', '.venv', 'venv',
                  '__pycache__', '.cache', 'target', '.svelte-kit', 'vendor', 'Pods'}

# extension -> (kind, content-type). Only these are previewable/served.
PREVIEW_TYPES = {
    '.html': ('html', 'text/html; charset=utf-8'), '.htm': ('html', 'text/html; charset=utf-8'),
    '.pdf': ('pdf', 'application/pdf'),
    '.png': ('image', 'image/png'), '.jpg': ('image', 'image/jpeg'), '.jpeg': ('image', 'image/jpeg'),
    '.gif': ('image', 'image/gif'), '.webp': ('image', 'image/webp'), '.bmp': ('image', 'image/bmp'),
    '.heic': ('image', 'image/heic'),
    '.svg': ('svg', 'image/svg+xml; charset=utf-8'),
    '.md': ('markdown', 'text/markdown; charset=utf-8'), '.markdown': ('markdown', 'text/markdown; charset=utf-8'),
    '.txt': ('text', 'text/plain; charset=utf-8'), '.log': ('text', 'text/plain; charset=utf-8'),
    '.csv': ('text', 'text/plain; charset=utf-8'),
    '.py': ('code', 'text/plain; charset=utf-8'),
    # css/js/json keep their REAL web MIME so they load as a page's sub-resources (nosniff-safe);
    # direct preview still works because QuickLook keys off the file extension, not content-type.
    '.js': ('code', 'text/javascript; charset=utf-8'), '.mjs': ('code', 'text/javascript; charset=utf-8'),
    '.ts': ('code', 'text/plain; charset=utf-8'), '.tsx': ('code', 'text/plain; charset=utf-8'),
    '.jsx': ('code', 'text/plain; charset=utf-8'), '.json': ('code', 'application/json; charset=utf-8'),
    '.css': ('code', 'text/css; charset=utf-8'), '.sh': ('code', 'text/plain; charset=utf-8'),
    '.go': ('code', 'text/plain; charset=utf-8'), '.rs': ('code', 'text/plain; charset=utf-8'),
    '.rb': ('code', 'text/plain; charset=utf-8'), '.yml': ('code', 'text/plain; charset=utf-8'),
    '.yaml': ('code', 'text/plain; charset=utf-8'), '.toml': ('code', 'text/plain; charset=utf-8'),
    '.sql': ('code', 'text/plain; charset=utf-8'), '.swift': ('code', 'text/plain; charset=utf-8'),
    '.c': ('code', 'text/plain; charset=utf-8'), '.h': ('code', 'text/plain; charset=utf-8'),
    '.cpp': ('code', 'text/plain; charset=utf-8'), '.java': ('code', 'text/plain; charset=utf-8'),
}
_TEXTY = {'svg', 'markdown', 'text', 'code'}

# NOTE: macOS APFS is case-INSENSITIVE but realpath preserves the caller's typed case, AND
# os.path.normcase is a NO-OP on POSIX/macOS — so every path comparison MUST be .casefold()'d
# explicitly or `.SSH/config` / `.CLAUDE/keys.json` slip past the deny for `.ssh` / `.claude`.
_HOME_CF = os.path.realpath(HOME).casefold()
DENY_DIRS = [os.path.realpath(os.path.join(HOME, p)).casefold() for p in
             ('.ssh', '.aws', '.gnupg', '.config', '.docker', '.kube', '.gcloud',
              '.codex', '.claude', '.claude-harness',
              'Library/Keychains', 'Library/Cookies', 'Library/Application Support/Google')]
DENY_BASENAMES = {x.casefold() for x in
                  ('config.env', 'keys.json', 'push.json', 'usage.json', 'auth.json',
                   '.credentials.json', 'credentials.json', 'known_hosts', '.netrc',
                   '.git-credentials', '.npmrc', '.pypirc', 'serviceaccount.json')}
DENY_EXT = {'.p8', '.pem', '.key', '.kdbx', '.keychain', '.keychain-db', '.env', '.crt', '.cer', '.pfx'}
DENY_PREFIX = tuple(p.casefold() for p in ('id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa'))

def valid_cwd(cwd):
    """A thread cwd must resolve to a dir UNDER (or equal to) HOME and not inside a denied
    dir — so /file can never be pointed at /private/etc, /Library, another user's home, etc."""
    try:
        rp = os.path.realpath(os.path.expanduser(cwd or HOME))
    except Exception:
        return None
    rpcf = rp.casefold()
    if not (rpcf == _HOME_CF or rpcf.startswith(_HOME_CF + os.sep)):
        return None
    if any(rpcf == d or rpcf.startswith(d + os.sep) for d in DENY_DIRS):
        return None
    if not os.path.isdir(rp):
        return None
    return rp

def _allowed_roots(thread):
    # Only the thread's own working dir — narrow on purpose.
    return [os.path.realpath(thread.get('cwd') or HOME).casefold()]

def safe_resolve(thread, rel_or_abs):
    """The single chokepoint. realpath the FINAL target, then (all case-folded): require it
    inside the thread root, not under any denied dir, basename/ext not denied, and ext on the
    POSITIVE preview allowlist (so extensionless secrets — id_rsa, .env, cookies — never serve)."""
    if not rel_or_abs:
        return None
    base = thread.get('cwd') or HOME
    cand = rel_or_abs if os.path.isabs(rel_or_abs) else os.path.join(base, rel_or_abs)
    try:
        tgt = os.path.realpath(cand)
    except Exception:
        return None
    tcf = tgt.casefold()
    if not any(tcf == r or tcf.startswith(r + os.sep) for r in _allowed_roots(thread)):
        return None
    if any(tcf == d or tcf.startswith(d + os.sep) for d in DENY_DIRS):
        return None
    bncf = os.path.basename(tgt).casefold()
    if bncf in DENY_BASENAMES:
        return None
    if any(bncf.startswith(p) for p in DENY_PREFIX):
        return None
    if bncf == '.env' or bncf.startswith('.env.') or bncf.endswith('.env'):
        return None
    ext = os.path.splitext(bncf)[1]
    if ext in DENY_EXT:
        return None
    if ext not in PREVIEW_TYPES:        # positive allowlist — only known previewable types
        return None
    if not os.path.isfile(tgt):
        return None
    return tgt

def scan_artifacts(thread):
    """Previewable files under the thread cwd modified after the thread was created.
    The ONLY artifact source that works for both Claude and Codex (codex emits no file events)."""
    base = os.path.realpath(thread.get('cwd') or HOME)
    since = (thread.get('created') or 0) - 5      # small grace for clock granularity
    out, seen, count = [], set(), 0
    def walk(d, depth):
        nonlocal count
        if depth > SCAN_MAX_DEPTH or count > SCAN_MAX_ENTRIES:
            return
        try:
            entries = list(os.scandir(d))
        except Exception:
            return
        for e in entries:
            count += 1
            if count > SCAN_MAX_ENTRIES:
                return
            try:
                if e.is_dir(follow_symlinks=False):
                    if e.name in SCAN_SKIP_DIRS or e.name.startswith('.'):
                        continue
                    walk(e.path, depth + 1)
                    continue
                ext = os.path.splitext(e.name)[1].lower()
                if ext not in PREVIEW_TYPES:
                    continue
                st = e.stat()
                if st.st_mtime < since:
                    continue
                rp = os.path.realpath(e.path)
                if rp in seen or safe_resolve(thread, rp) is None:
                    continue
                seen.add(rp)
                kind, _ = PREVIEW_TYPES[ext]
                out.append({'rel': os.path.relpath(rp, base), 'name': e.name, 'ext': ext,
                            'kind': kind, 'size': st.st_size, 'mtime': st.st_mtime})
            except Exception:
                continue
    walk(base, 0)
    out.sort(key=lambda x: x['mtime'], reverse=True)
    return out[:ARTIFACT_CAP]

# --------------------------------------------------------------------------- engine runners
def _provider_env(provider):
    env = dict(BASE_ENV)
    key = None
    if provider.get('api_key_env'):
        key = CFG.get(provider['api_key_env']) or os.environ.get(provider['api_key_env'])
        if key:
            env[provider['api_key_env']] = key      # expose under its own name (Codex env_key)
    # Claude-engine custom endpoint (Anthropic-compatible, e.g. GLM via Z.ai)
    if provider.get('base_url') and provider.get('engine') != 'codex':
        env['ANTHROPIC_BASE_URL'] = provider['base_url']
        if key:
            env['ANTHROPIC_AUTH_TOKEN'] = key
            env['ANTHROPIC_API_KEY'] = key
    return env

def tool_summary(name, inp):
    """One-line human summary of a tool call (the command / file / pattern)."""
    if isinstance(inp, dict):
        if name == 'Task':                       # subagent spawn -> "type — description"
            st = inp.get('subagent_type') or 'agent'
            desc = inp.get('description') or inp.get('prompt') or ''
            return ('%s — %s' % (st, desc)).strip(' —').replace('\n', ' ')[:140]
        for key in ('command', 'file_path', 'path', 'pattern', 'query', 'url', 'prompt', 'description', 'notebook_path'):
            if inp.get(key):
                return str(inp[key]).replace('\n', ' ')[:140]
    return name

def tool_detail(name, inp):
    """Expandable detail for a tool call: a diff for edits, command for Bash, etc.
    Lines starting '- '/'+ ' are rendered as a red/green diff by the app."""
    if not isinstance(inp, dict):
        return None
    if name == 'Edit':
        old = str(inp.get('old_string', ''))[:2000]; new = str(inp.get('new_string', ''))[:2000]
        lines = ['- ' + l for l in old.split('\n')] + ['+ ' + l for l in new.split('\n')]
        return '\n'.join(lines)[:1200] or None
    if name == 'MultiEdit':
        parts = []
        for e in (inp.get('edits') or [])[:6]:
            parts.append('- ' + str(e.get('old_string', ''))[:160])
            parts.append('+ ' + str(e.get('new_string', ''))[:160])
        return '\n'.join(parts)[:1200] or None
    if name == 'Write':
        body = str(inp.get('content', ''))
        return '\n'.join('+ ' + l for l in body.split('\n')[:24])[:1200] or None
    if name == 'TodoWrite':
        todos = inp.get('todos') or []
        return '\n'.join('• ' + str(t.get('content', '')) for t in todos)[:1200] or None
    if name == 'Bash':
        return str(inp.get('command', ''))[:1200] or None
    if name == 'Task':                           # the subagent's instructions
        return str(inp.get('prompt', ''))[:1500] or None
    return None

def normalize_questions(qs):
    """Coerce AskUserQuestion input into a stable shape the app can always decode:
    [{question, header, multiSelect, options:[{label, description}]}]. Drops junk."""
    out = []
    for q in (qs or []):
        if not isinstance(q, dict):
            continue
        text = q.get('question') or q.get('header') or ''
        if not text:
            continue
        opts = []
        for o in (q.get('options') or []):
            if isinstance(o, dict) and o.get('label'):
                desc = o.get('description')
                opts.append({'label': str(o['label'])[:200],
                             'description': (str(desc)[:400] if desc else None)})
            elif isinstance(o, str) and o:
                opts.append({'label': o[:200], 'description': None})
        out.append({'question': str(text)[:600],
                    'header': (str(q.get('header'))[:60] if q.get('header') else None),
                    'multiSelect': bool(q.get('multiSelect')),
                    'options': opts})
    return out

def write_images(images):
    """Decode base64 (or data-URL) images to temp files; returns list of paths."""
    paths = []
    for img in (images or [])[:8]:
        try:
            b = img
            if isinstance(b, str) and b.startswith('data:') and ',' in b:
                b = b.split(',', 1)[1]
            data = base64.b64decode(b)
        except Exception:
            continue
        if not data:
            continue
        ext = '.jpg' if data[:3] == b'\xff\xd8\xff' else '.png'
        f = tempfile.NamedTemporaryFile(delete=False, suffix=ext, dir=IMG_DIR)
        f.write(data); f.close()
        paths.append(f.name)
    return paths

def run_claude_stream(thread, provider, text, images=None):
    """Generator yielding SSE event dicts; reuses the bridge's proven parse."""
    if images:
        text = text + "\n\n[The user attached image(s) at: " + "; ".join(images) + \
               " — use your Read tool to view them.]"
    cmd = [CLAUDE_BIN, '-p', text, '--output-format', 'stream-json',
           '--include-partial-messages', '--verbose',
           '--append-system-prompt', HINT]
    mode = thread.get('permission_mode') or 'bypass'
    mcp_cfg = None
    if mode == 'bypass':
        cmd += ['--dangerously-skip-permissions']
    else:                                   # plan | acceptEdits | default
        cmd += ['--permission-mode', mode]
    if mode in ('default', 'acceptEdits'):
        # Phone-side approval: gated tool uses relay through approval_tool.py
        # (MCP permission tool) -> /internal/approval -> push -> user decides.
        cfg = {'mcpServers': {'harness_approval': {
            'command': sys.executable or 'python3',
            'args': [os.path.join(BASE, 'approval_tool.py')],
            'env': {'HARNESS_PORT': str(PORT), 'HARNESS_THREAD_ID': thread['id'],
                    'HARNESS_APPROVAL_SECRET': APPROVAL_SECRET}}}}
        f = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False)
        json.dump(cfg, f); f.close()
        mcp_cfg = f.name
        cmd += ['--mcp-config', mcp_cfg,
                '--permission-prompt-tool', 'mcp__harness_approval__approve']
    effort = thread.get('effort')
    if effort and effort != 'default':
        cmd += ['--effort', effort]
    model = thread.get('model') or provider.get('model')
    if model:
        cmd += ['--model', model]
    if thread.get('session_id'):
        cmd += ['--resume', thread['session_id']]
    proc = subprocess.Popen(cmd, cwd=thread.get('cwd') or HOME, env=_provider_env(provider),
                            text=True, bufsize=1, encoding='utf-8', errors='replace',
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    reg_run(thread['id'], proc)
    answer, session_id, final_result, saw_error = [], None, None, False
    tool_blocks, tools, usage, thinking_buf, questions_buf = {}, [], None, [], []
    err_buf, done = [], threading.Event()
    timed = {'v': False}
    def killer():
        if not done.wait(JOB_TIMEOUT):
            timed['v'] = True
            try: proc.kill()
            except Exception: pass
    def drain_err():
        try:
            for l in proc.stderr:
                err_buf.append(l)
        except Exception:
            pass
    threading.Thread(target=killer, daemon=True).start()
    threading.Thread(target=drain_err, daemon=True).start()
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line or line[0] != '{':
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get('session_id') and not session_id:
                session_id = d['session_id']
                yield {'type': 'session', 'id': session_id}
            typ = d.get('type')
            if typ == 'rate_limit_event':
                record_rate_limit(d.get('rate_limit_info'))
            elif typ == 'stream_event':
                ev = d.get('event', {})
                et = ev.get('type')
                idx = ev.get('index')
                if et == 'content_block_start':
                    cb = ev.get('content_block', {})
                    if cb.get('type') == 'tool_use':
                        tool_blocks[idx] = {'name': cb.get('name', 'tool'), 'buf': ''}
                elif et == 'content_block_delta':
                    delta = ev.get('delta', {})
                    dt = delta.get('type')
                    if dt == 'text_delta':
                        answer.append(delta.get('text', ''))
                        yield {'type': 'text', 'delta': delta.get('text', '')}
                    elif dt == 'thinking_delta':
                        thinking_buf.append(delta.get('thinking', ''))
                        yield {'type': 'thinking', 'delta': delta.get('thinking', '')}
                    elif dt == 'input_json_delta' and idx in tool_blocks:
                        tool_blocks[idx]['buf'] += delta.get('partial_json', '')
                elif et == 'content_block_stop' and idx in tool_blocks:
                    tb = tool_blocks.pop(idx)
                    try:
                        inp = json.loads(tb['buf']) if tb['buf'].strip() else {}
                    except Exception:
                        inp = {}
                    if tb['name'] == 'AskUserQuestion':   # structured multiple-choice -> tappable chips
                        qs = normalize_questions(inp.get('questions'))
                        if qs:
                            questions_buf.extend(qs)
                            yield {'type': 'question', 'questions': qs}
                        continue
                    info = {'name': tb['name'], 'summary': tool_summary(tb['name'], inp)}
                    detail = tool_detail(tb['name'], inp)
                    if detail:
                        info['detail'] = detail
                    tools.append(info)
                    yield {'type': 'tool', 'name': info['name'],
                           'summary': info['summary'], 'detail': info.get('detail')}
            elif typ == 'result':
                if d.get('result') is not None:
                    final_result = d['result']
                if d.get('is_error'):
                    saw_error = True
                u = d.get('usage') or {}
                usage = {'cost': d.get('total_cost_usd'),
                         'input_tokens': u.get('input_tokens'),
                         'output_tokens': u.get('output_tokens'),
                         'duration_ms': d.get('duration_ms')}
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
    finally:
        done.set()
        unreg_run(thread['id'])
        if mcp_cfg:
            try: os.unlink(mcp_cfg)
            except Exception: pass
    final = (final_result if final_result else ''.join(answer)).strip()
    if timed['v']:
        yield {'type': 'error', 'message': 'claude timed out after %ss' % JOB_TIMEOUT}; return
    if not final and proc.returncode not in (0, None):
        tail = ''.join(err_buf)[-800:]
        yield {'type': 'error', 'message': 'claude exit %s: %s' % (proc.returncode, tail)}; return
    yield {'type': 'done', 'text': ('⚠️ ' + final) if saw_error else (final or '(no output)'),
           'session_id': session_id or thread.get('session_id'),
           'tools': tools, 'usage': usage, 'thinking': ''.join(thinking_buf) or None,
           'questions': questions_buf or None}

# OpenAI/Codex API pricing, $ per 1M tokens (input, output) — verified Jun 2026.
# Codex reports only tokens, so we estimate $ from these. (Claude prices itself.)
OPENAI_PRICING = {
    'gpt-5.5':              (5.00, 30.00),
    'gpt-5.4-mini':         (0.75, 4.50),
    'gpt-5.4':              (2.50, 15.00),
    'gpt-5.3-codex-spark':  (1.75, 14.00),   # Spark rates not finalized; uses 5.3-codex
    'gpt-5.3-codex':        (1.75, 14.00),
}
DEFAULT_CODEX_MODEL = 'gpt-5.5'   # ~/.codex/config.toml default

def model_price(model):
    m = (model or DEFAULT_CODEX_MODEL).lower()
    if m in OPENAI_PRICING:
        return OPENAI_PRICING[m]
    for key in sorted(OPENAI_PRICING, key=len, reverse=True):   # most-specific first
        if m.startswith(key) or key in m:
            return OPENAI_PRICING[key]
    return OPENAI_PRICING[DEFAULT_CODEX_MODEL]

def codex_cost_estimate(u, model, provider):
    """Estimate API-equivalent $ for a codex run from token counts + current rates.
    Per-provider price_in/price_out (per 1M) override the table (e.g. OpenRouter)."""
    if not u:
        return None
    pin, pout = model_price(model)
    if provider.get('price_in') is not None:
        pin = float(provider['price_in'])
    if provider.get('price_out') is not None:
        pout = float(provider['price_out'])
    inp = u.get('input_tokens') or 0
    cached = u.get('cached_input_tokens') or 0
    out = u.get('output_tokens') or 0
    eff_in = max(0, inp - cached) + cached * 0.1       # cached input ~10% (matches $0.50 on 5.5)
    return eff_in / 1e6 * pin + out / 1e6 * pout

def run_codex_stream(thread, provider, text, images=None):
    """Stream codex exec line-by-line: reasoning summaries surface as `thinking`
    events (so they show before the answer), then the final message as `text`."""
    outfile = tempfile.NamedTemporaryFile(delete=False, suffix='.txt'); outfile.close()
    resuming = bool(thread.get('session_id'))
    opts = ['--json', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox',
            '-o', outfile.name]
    model = thread.get('model') or provider.get('model')
    if model:
        opts += ['-m', model]
    effort = thread.get('effort')
    if effort == 'max':
        effort = 'xhigh'                  # codex tops out at xhigh ("Extra High")
    if effort and effort != 'default':
        opts += ['-c', 'model_reasoning_effort=%s' % effort]
    # Force reasoning summaries on so the thinking is actually visible/clickable.
    opts += ['-c', 'model_reasoning_summary=detailed']
    if provider.get('base_url'):              # custom OpenAI-compatible provider (e.g. OpenRouter)
        pn = 'harness'
        opts += ['-c', 'model_providers.%s.name=%s' % (pn, pn),
                 '-c', 'model_providers.%s.base_url=%s' % (pn, provider['base_url']),
                 '-c', 'model_providers.%s.wire_api=%s' % (pn, provider.get('wire_api', 'responses'))]
        if provider.get('api_key_env'):
            opts += ['-c', 'model_providers.%s.env_key=%s' % (pn, provider['api_key_env'])]
        opts += ['-c', 'model_provider=%s' % pn]
    for p in (images or []):
        opts += ['-i', p]
    # `codex exec resume` rejects -C/--color (it keeps the session's dir; Popen cwd covers it).
    if resuming:
        cmd = [CODEX_BIN, 'exec', 'resume'] + opts + [thread['session_id'], text]
    else:
        cmd = [CODEX_BIN, 'exec'] + opts + ['-C', thread.get('cwd') or HOME, '--color', 'never', text]
    t0 = time.time()
    proc = subprocess.Popen(cmd, cwd=thread.get('cwd') or HOME, env=_provider_env(provider),
                            text=True, bufsize=1, encoding='utf-8', errors='replace',
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    reg_run(thread['id'], proc)
    # Watchdog kills the run past JOB_TIMEOUT; stderr drained off-thread to avoid pipe deadlock.
    timed_out = {'v': False}
    def _kill():
        timed_out['v'] = True
        try: proc.kill()
        except Exception: pass
    wd = threading.Timer(JOB_TIMEOUT, _kill); wd.daemon = True; wd.start()
    err_lines = []
    def _drain():
        try:
            for l in proc.stderr: err_lines.append(l)
        except Exception: pass
    dt = threading.Thread(target=_drain, daemon=True); dt.start()
    new_sess, cusage, thinking_buf, stream_text = None, None, [], ''
    try:
        for line in proc.stdout:
            line = line.strip()
            if not line.startswith('{'):
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get('type')
            if t == 'thread.started' and d.get('thread_id'):
                new_sess = d['thread_id']
                yield {'type': 'session', 'id': new_sess}
            elif t == 'item.completed':
                it = d.get('item', {})
                itype = it.get('item_type') or it.get('type')
                if itype == 'reasoning':
                    rt = (it.get('text') or it.get('content') or '').strip()
                    if rt:
                        thinking_buf.append(rt)
                        yield {'type': 'thinking', 'delta': rt + '\n\n'}
                elif itype == 'agent_message':
                    stream_text = it.get('text') or it.get('content') or stream_text
            elif t == 'turn.completed' and d.get('usage'):
                cusage = d['usage']
        proc.wait()
    finally:
        wd.cancel(); unreg_run(thread['id'])
    err = ''.join(err_lines)
    if timed_out['v']:
        try: os.unlink(outfile.name)
        except Exception: pass
        yield {'type': 'error', 'message': 'codex timed out after %ss' % JOB_TIMEOUT}; return
    try:
        result = open(outfile.name, encoding='utf-8', errors='replace').read().strip()
    except Exception:
        result = ''
    finally:
        try: os.unlink(outfile.name)
        except Exception: pass
    result = result or stream_text
    if proc.returncode != 0 and not result:
        yield {'type': 'error', 'message': 'codex exit %s: %s' % (proc.returncode, (err or '')[-800:])}; return
    if result:
        # Codex hands back the whole answer at once. Emit it in chunks so the phone renders
        # progressively instead of one giant block (the block render was a freeze suspect).
        for i in range(0, len(result), 600):
            yield {'type': 'text', 'delta': result[i:i + 600]}
    cu = None
    if cusage:
        cu = {'cost': codex_cost_estimate(cusage, thread.get('model') or provider.get('model'), provider),
              'input_tokens': cusage.get('input_tokens'),
              'output_tokens': cusage.get('output_tokens'),
              'duration_ms': (time.time() - t0) * 1000}
    yield {'type': 'done', 'text': result or '(no output)',
           'session_id': new_sess or thread.get('session_id'), 'usage': cu,
           'thinking': '\n\n'.join(thinking_buf) or None}

GEMINI_MODES = {'bypass': 'yolo', 'plan': 'plan', 'acceptEdits': 'auto_edit', 'default': 'default'}

def run_gemini_stream(thread, provider, text, images=None):
    """Gemini CLI (buffered text output). Continuity via transcript replay, since
    `gemini --resume` is index-based; auth is the user's one-time Google login."""
    hist = thread.get('messages') or []
    convo = ''
    for m in hist[-12:]:
        who = 'User' if m.get('role') == 'user' else 'Assistant'
        convo += '%s: %s\n\n' % (who, m.get('text', ''))
    prompt = (convo + 'User: ' + text + '\n\nAssistant:') if convo else text
    cmd = [GEMINI_BIN, '-p', prompt, '--skip-trust', '-o', 'text']
    model = thread.get('model') or provider.get('model')
    if model:
        cmd += ['-m', model]
    cmd += ['--approval-mode', GEMINI_MODES.get(thread.get('permission_mode') or 'bypass', 'yolo')]
    proc = subprocess.Popen(cmd, cwd=thread.get('cwd') or HOME, env=_provider_env(provider),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    reg_run(thread['id'], proc)
    try:
        out, err = proc.communicate(timeout=JOB_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill(); out, err = proc.communicate()
        unreg_run(thread['id'])
        yield {'type': 'error', 'message': 'gemini timed out after %ss' % JOB_TIMEOUT}; return
    finally:
        unreg_run(thread['id'])
    result = (out or '').strip()
    if proc.returncode != 0 and not result:
        tail = (err or '')[-800:]
        hint = '  (set a free Gemini API key from aistudio.google.com/apikey in Settings)' if ('auth' in tail.lower() or 'api' in tail.lower() or 'key' in tail.lower()) else ''
        yield {'type': 'error', 'message': 'gemini exit %s: %s%s' % (proc.returncode, tail, hint)}; return
    if result:
        yield {'type': 'text', 'delta': result}
    yield {'type': 'done', 'text': result or '(no output)', 'session_id': thread.get('session_id')}


# ---------------------------------------------------------------- harness-code engine
# Fronts the Harness Code desktop app (github.com/TheRealJadenKwek/harness-code) over
# its localhost API. The session LIVES in Harness Code, so every message sent from the
# phone streams live in the desktop app too — one chat, two screens.
def _hc_url():
    u = CFG.get('HARNESS_CODE_URL', '').strip()
    if u:
        return u
    try:
        port = open(os.path.expanduser('~/.harness-code/api-port')).read().strip()
    except Exception:
        port = '8799'
    return 'http://127.0.0.1:%s' % (port or '8799')
HC_MODES = {'bypass': 'bypass', 'default': 'ask', 'acceptEdits': 'edits', 'plan': 'plan'}

def _hc_token():
    try:
        return open(os.path.expanduser('~/.harness-code/api-token')).read().strip()
    except Exception:
        return ''

def run_harnesscode_stream(thread, provider, text, images=None):
    import urllib.request, urllib.error
    tok = _hc_token()
    hdrs = {'X-HC-Token': tok, 'Content-Type': 'application/json'}
    mode = HC_MODES.get(thread.get('permission_mode') or 'bypass', 'ask')
    model = thread.get('model') or provider.get('model')
    img_urls = []
    for pth in (images or []):
        try:
            raw = open(pth, 'rb').read()
            mime = 'image/jpeg' if raw[:3] == b'\xff\xd8\xff' else 'image/png'
            img_urls.append('data:%s;base64,%s' % (mime, base64.b64encode(raw).decode()))
        except Exception:
            pass
    try:
        sid = thread.get('session_id')
        if not sid:
            req = urllib.request.Request(_hc_url() + '/api/sessions', headers=hdrs,
                data=json.dumps({'cwd': thread.get('cwd') or HOME, 'model': model, 'mode': mode}).encode())
            meta = json.load(urllib.request.urlopen(req, timeout=10))
            sid = meta['id']
            yield {'type': 'session', 'id': sid}
        payload = {'text': text, 'mode': mode}
        if model:
            payload['model'] = model
        if img_urls:
            payload['images'] = img_urls
        req = urllib.request.Request(_hc_url() + '/api/sessions/%s/send' % sid, headers=hdrs,
                                     data=json.dumps(payload).encode())
        resp = urllib.request.urlopen(req, timeout=JOB_TIMEOUT)
        final = []
        for line in resp:
            try:
                e = json.loads(line.decode('utf-8', 'replace'))
            except Exception:
                continue
            t = e.get('type')
            if t == 'text':
                final.append(e.get('delta', ''))
                yield {'type': 'text', 'delta': e.get('delta', '')}
            elif t == 'reasoning':
                yield {'type': 'thinking', 'delta': e.get('delta', '')}
            elif t == 'tool_call':
                yield {'type': 'tool', 'name': e.get('name', ''),
                       'summary': json.dumps(e.get('args') or {})[:140], 'detail': None}
            elif t == 'approval_request':
                yield {'type': 'thinking', 'delta': '\n[approval needed on the Mac: %s %s]\n' %
                       (e.get('kind', ''), str(e.get('detail', ''))[:80])}
            elif t == 'done':
                yield {'type': 'done', 'text': e.get('text') or ''.join(final) or '(no output)',
                       'session_id': sid}
                return
            elif t == 'aborted':
                yield {'type': 'done', 'text': ''.join(final) or '(stopped)', 'session_id': sid}
                return
            elif t == 'error':
                yield {'type': 'error', 'message': e.get('message', 'harness-code error')}
                return
        yield {'type': 'done', 'text': ''.join(final) or '(no output)', 'session_id': sid}
    except urllib.error.HTTPError as ex:
        yield {'type': 'error', 'message': 'harness-code HTTP %s: %s' % (ex.code, ex.read()[:150])}
    except Exception as ex:
        yield {'type': 'error', 'message': 'harness-code: %s — is the Harness Code app open on the Mac?' % ex}

def run_thread(thread, provider, text, images=None):
    eng = provider.get('engine')
    if eng == 'codex':
        yield from run_codex_stream(thread, provider, text, images)
    elif eng == 'gemini':
        yield from run_gemini_stream(thread, provider, text, images)
    elif eng == 'harness-code':
        yield from run_harnesscode_stream(thread, provider, text, images)
    else:
        yield from run_claude_stream(thread, provider, text, images)

def start_job(t, prov, text, image_paths, thread_lock):
    """Run an engine turn in a detached daemon thread. The caller already holds
    `thread_lock`; the job OWNS it now and releases it only after persisting +
    pushing, so the turn survives the client disconnecting. Returns the Job."""
    tid = t['id']
    job = Job(tid)

    def work():
        final_text, session_id = None, t.get('session_id')
        final_tools = final_usage = final_thinking = final_questions = None
        try:
            for ev in run_thread(t, prov, text, image_paths):
                typ = ev.get('type')
                if typ == 'session':
                    session_id = ev['id']
                elif typ == 'done':
                    final_text = ev.get('text')
                    final_tools = ev.get('tools')
                    final_usage = ev.get('usage')
                    final_thinking = ev.get('thinking')
                    final_questions = ev.get('questions')
                job.publish(ev)
        except Exception as e:
            job.publish({'type': 'error', 'message': str(e)})
        # persist under _persist_lock (serializes vs a concurrent rename's write-back);
        # reload to merge a rename; bail if deleted mid-turn. PUSH happens AFTER we release
        # the thread lock so the thread isn't reported 'busy' during slow APNs calls.
        push_arg = None
        try:
            with _persist_lock:
                cur = load_thread(tid)
                if cur is not None:
                    cur['session_id'] = session_id
                    cur['provider'] = prov['id']
                    cur['engine'] = prov['engine']
                    cur['model'] = t.get('model') or prov.get('model')
                    cur['cwd'] = t.get('cwd') or cur.get('cwd')
                    cur['permission_mode'] = t.get('permission_mode') or cur.get('permission_mode')
                    cur['effort'] = t.get('effort') or cur.get('effort')
                    if not cur.get('title'):
                        cur['title'] = text[:48]
                    cur.setdefault('messages', [])
                    umsg = {'role': 'user', 'text': text, 'ts': time.time()}
                    if image_paths:
                        umsg['images'] = len(image_paths)
                    cur['messages'].append(umsg)
                    if final_text is not None:
                        amsg = {'role': 'assistant', 'text': final_text, 'ts': time.time()}
                        if final_thinking:
                            amsg['thinking'] = final_thinking
                        if final_tools:
                            amsg['tools'] = final_tools
                        if final_questions:
                            amsg['questions'] = final_questions
                        if final_usage:
                            amsg['usage'] = final_usage
                            if final_usage.get('cost'):
                                cur['total_cost'] = (cur.get('total_cost') or 0) + final_usage['cost']
                        cur['messages'].append(amsg)
                    cur['updated'] = time.time()
                    try:
                        save_thread(cur)
                    except Exception as e:
                        log('persist failed for thread %s: %s' % (tid, e))
                    if final_text is not None:            # only ping on a real answer/question
                        push_arg = (dict(cur), final_text, final_questions)
            if cur is not None and prov.get('engine') == 'claude':
                sync_desktop_sidebar(cur)             # phone-born chats appear on the desktop
        finally:
            for p in image_paths:
                try: os.unlink(p)
                except Exception: pass
            job.finish()
            with _jobs_lock:
                if JOBS.get(tid) is job:
                    del JOBS[tid]
            try: thread_lock.release()
            except Exception: pass
        if push_arg is not None:                          # outside the thread lock now
            try:
                notify_push(*push_arg)
            except Exception as e:
                log('push failed for thread %s: %s' % (tid, e))

    thread = threading.Thread(target=work, daemon=True)
    with _jobs_lock:
        JOBS[tid] = job
    try:
        thread.start()
    except Exception:
        with _jobs_lock:
            if JOBS.get(tid) is job:
                del JOBS[tid]
        job.finish()        # release any racing /stream subscriber (sentinel), don't leave it hung
        raise               # caller releases thread_lock + returns 500
    return job

# --------------------------------------------------------------------------- automations
_WDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

def describe_schedule(d):
    ci = d.get('StartCalendarInterval')
    if ci:
        parts = []
        for c in (ci if isinstance(ci, list) else [ci]):
            if not isinstance(c, dict):
                continue
            hm = '%02d:%02d' % (c.get('Hour') or 0, c.get('Minute') or 0) if c.get('Hour') is not None else ''
            wd = c.get('Weekday')
            if wd is not None:                     # weekly (launchd: 0 and 7 both = Sunday)
                parts.append(('%s %s' % (_WDAYS[int(wd) % 7], hm)).strip())
            elif c.get('Day') is not None:         # monthly
                parts.append(('day %d %s' % (int(c['Day']), hm)).strip())
            elif hm:
                parts.append('daily ' + hm)
        return ', '.join(parts) if parts else 'scheduled'
    if d.get('StartInterval'):
        s = int(d['StartInterval'])
        return ('every %dm' % (s // 60)) if s >= 60 else ('every %ds' % s)
    if d.get('KeepAlive'):
        return 'always on'
    if d.get('RunAtLoad'):
        return 'at login'
    return 'on demand'

_LLM_MARK = re.compile(r'(claude|codex|gemini|anthropic|openai|gpt-?\d|\bllm\b)', re.I)
# Absolute or ~ paths embedded ANYWHERE in a command — incl. inside a `zsh -lc "a; b"`
# wrapper where the scripts aren't standalone tokens.
_PATH_RE = re.compile(r"""(?:~|/)[^\s;&|"'`<>()]+""")

def _touches_llm(cmd_tokens):
    """True if a job's command — or any script file it runs — mentions an LLM CLI.
    Jobs bury `claude -p` / codex backups inside shell scripts, and frequently behind a
    `zsh -lc "scriptA; scriptB"` wrapper, so we scan every path found ANYWHERE in the
    command (not just whole-token paths) with a bounded read."""
    text = ' '.join(str(x) for x in cmd_tokens)
    if _LLM_MARK.search(text):
        return True
    seen = set()
    for frag in _PATH_RE.findall(text):
        p = os.path.expanduser(frag.rstrip(';,'))
        if p in seen or not os.path.isfile(p):
            continue
        seen.add(p)
        try:
            if os.path.getsize(p) <= 256 * 1024 and \
               _LLM_MARK.search(open(p, encoding='utf-8', errors='replace').read()):
                return True
        except Exception:
            pass
    return False

def list_automations(show_all=False):
    """The user's SCHEDULED agent jobs (read-only view for the app). By default this
    hides the plumbing — always-on daemons (KeepAlive services) and anything that
    never touches an LLM (dock scripts, backups). show_all=True returns everything."""
    out = []
    home = os.path.expanduser('~')
    pids = {}
    try:
        res = subprocess.run(['launchctl', 'list'], capture_output=True, text=True, timeout=10, env=BASE_ENV)
        for line in res.stdout.splitlines()[1:]:
            cols = line.split('\t')
            if len(cols) >= 3:
                pids[cols[2].strip()] = cols[0].strip()
    except Exception:
        pass
    for plist in sorted(glob.glob(os.path.join(home, 'Library/LaunchAgents/*.plist'))):
        try:
            with open(plist, 'rb') as f:
                d = plistlib.load(f)
        except Exception:
            continue
        label = d.get('Label') or os.path.basename(plist)[:-6]
        prog = d.get('ProgramArguments') or ([d['Program']] if d.get('Program') else [])
        if not show_all:
            scheduled = bool(d.get('StartCalendarInterval') or d.get('StartInterval'))
            if not scheduled or not _touches_llm(prog):
                continue
        pid = pids.get(label)
        status = 'running' if (pid and pid not in ('-', '0')) else ('loaded' if label in pids else 'stopped')
        out.append({'name': label, 'kind': 'launchd', 'schedule': describe_schedule(d),
                    'status': status, 'detail': ' '.join(str(x) for x in prog)[:240]})
    try:
        res = subprocess.run(['crontab', '-l'], capture_output=True, text=True, timeout=5, env=BASE_ENV)
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(None, 5)
            if len(parts) >= 6:
                if not show_all and not _touches_llm(parts[5].split()):
                    continue
                out.append({'name': parts[5][:48], 'kind': 'cron', 'schedule': ' '.join(parts[:5]),
                            'status': 'active', 'detail': parts[5][:240]})
    except Exception:
        pass
    out.sort(key=lambda a: (a['kind'], a['name']))
    return out

# --------------------------------------------------------------------------- dev-server preview proxy
# Lets the phone browse a dev server (vite/next/flask…) running on THIS machine:
# GET/POST /threads/{tid}/proxy/{port}/<path> forwards to http://127.0.0.1:{port}.
# v1 is plain HTTP — pages, assets, fetch/XHR via the app's scheme handler work;
# websocket HMR does not (page loads fine, hot-reload needs a manual refresh).
DEV_PORT_CANDIDATES = (3000, 3001, 3002, 4200, 4321, 5000, 5173, 5174, 5175, 5176,
                       5177, 8000, 8080, 8081, 8501, 8888, 9000)

def scan_dev_servers():
    """Listening localhost TCP ports that look like dev servers."""
    found = []
    try:
        if sys.platform == 'win32':
            r = subprocess.run(['netstat', '-ano', '-p', 'tcp'], capture_output=True, text=True, timeout=10)
            listening = set()
            for line in r.stdout.splitlines():
                p = line.split()
                if len(p) >= 4 and p[3].upper() == 'LISTENING':
                    try: listening.add(int(p[1].rsplit(':', 1)[1]))
                    except Exception: pass
            found = [{'port': pt, 'process': ''} for pt in DEV_PORT_CANDIDATES if pt in listening]
        else:
            r = subprocess.run(['lsof', '-nP', '-iTCP', '-sTCP:LISTEN'],
                               capture_output=True, text=True, timeout=10, env=BASE_ENV)
            seen = {}
            for line in r.stdout.splitlines()[1:]:
                p = line.split()
                if len(p) >= 9:
                    try: port = int(p[8].rsplit(':', 1)[1])
                    except Exception: continue
                    if port in DEV_PORT_CANDIDATES and port not in seen \
                            and not p[0].startswith('ControlCe'):   # macOS AirPlay squats :5000
                        seen[port] = p[0]
            found = [{'port': pt, 'process': seen[pt]} for pt in sorted(seen)]
    except Exception:
        pass
    return found

def proxy_request(port, subpath, query, method, body, in_headers):
    """Forward one request to the local dev server; returns (status, headers, body).
    Same-origin redirects are followed HERE, so the phone never has to re-resolve
    a Location header against the custom preview scheme."""
    url = 'http://127.0.0.1:%d/%s' % (port, subpath)
    if query:
        url += '?' + query
    req = urllib.request.Request(url, data=body if body else None, method=method)
    for h in ('Content-Type', 'Accept', 'Range', 'Cookie', 'If-None-Match', 'If-Modified-Since'):
        v = in_headers.get(h)
        if v:
            req.add_header(h, v)
    req.add_header('Accept-Encoding', 'identity')     # skip gzip: we re-frame with Content-Length
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            data = r.read(64 * 1024 * 1024)
            return r.status, dict(r.headers), data
    except urllib.error.HTTPError as e:
        data = e.read() if e.fp else b''
        return e.code, dict(e.headers or {}), data
    except Exception as e:
        return 502, {'Content-Type': 'application/json'}, \
               json.dumps({'error': 'dev server not reachable on :%d (%s)' % (port, e)}).encode()

# --------------------------------------------------------------------------- desktop session import
# Both CLIs keep resumable transcripts on disk (Claude: ~/.claude/projects/**/<id>.jsonl,
# the stem IS the --resume id; Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl,
# resumed via `exec resume <id>`). We surface the recent ones so a thread you started on
# the desktop can be continued from the phone — importing binds a harness thread to that
# session id, and the next message resumes it with the CLI's full context intact.
CLAUDE_SESS_DIR = os.path.expanduser('~/.claude/projects')
CODEX_SESS_DIR = os.path.expanduser('~/.codex/sessions')
# Claude Code desktop keeps each chat's sidebar TITLE (incl. user renames) in per-session
# metadata JSONs keyed by cliSessionId. Codex desktop persists titles only for cloud
# threads, so codex sessions fall back to their first user message.
CLAUDE_TITLE_DIRS = [os.path.expanduser('~/Library/Application Support/Claude/claude-code-sessions'),
                     os.path.join(os.environ.get('APPDATA', ''), 'Claude', 'claude-code-sessions')]

CODEX_INDEX = os.path.expanduser('~/.codex/session_index.jsonl')

def codex_title_map():
    """session id -> Codex desktop thread_name (its AI-generated/renamed title).
    The index is append-style; the LAST entry for an id is current."""
    m = {}
    try:
        with open(CODEX_INDEX, encoding='utf-8', errors='replace') as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                sid, name = d.get('id'), (d.get('thread_name') or '').strip()
                if sid and name:
                    m[sid] = name[:70]        # later lines overwrite -> newest name wins
    except Exception:
        pass
    return m

def claude_title_map():
    """cliSessionId -> desktop sidebar title. Re-read per scan so renames show up live."""
    m = {}
    for base in CLAUDE_TITLE_DIRS:
        if not base or not os.path.isdir(base):
            continue
        for p in glob.glob(os.path.join(base, '*', '*', '*.json')):
            try:
                with open(p, encoding='utf-8', errors='replace') as f:
                    d = json.load(f)
                cid, title = d.get('cliSessionId'), (d.get('title') or '').strip()
                if cid and title:
                    m[cid] = title[:70]
            except Exception:
                pass
    return m
_SKIP_TITLE = ('this session is being continued', '<command-', '<environment_context',
               '<permissions', 'caveat:', '[request interrupted', '<task-notification',
               '<system-reminder', '<local-command', '<codex_delegation', '<user_instructions')

def _clean_title(s):
    s = (s or '').strip()
    low = s.lower()
    if not s or any(low.startswith(p) for p in _SKIP_TITLE):
        return None
    return s.replace('\n', ' ').strip()[:70]

# --- reverse direction: surface HARNESS-born claude threads in the desktop sidebar.
# The desktop app lists chats from its claude-code-sessions store, so a thread created on
# the phone is invisible there even though its CLI session lives on this machine. We write
# one metadata entry per harness thread (deterministic uuid5 filename -> updated in place
# each turn, tracking the current session id). PRIVATE schema — best-effort by design:
# every write is wrapped, and an app update changing the format just means entries stop
# appearing, never breakage of the harness itself.
def _sidebar_store_dir():
    """The desktop app's active workspace store = the dir whose entries are freshest."""
    best, best_m = None, -1.0
    for base in CLAUDE_TITLE_DIRS:
        if not base or not os.path.isdir(base):
            continue
        for d in glob.glob(os.path.join(base, '*', '*')):
            files = glob.glob(os.path.join(d, 'local_*.json'))
            if not files:
                continue
            m = max(os.path.getmtime(f) for f in files)
            if m > best_m:
                best, best_m = d, m
    return best

_SIDEBAR_MODES = {'bypass': 'bypassPermissions', 'default': 'default',
                  'acceptEdits': 'acceptEdits', 'plan': 'plan'}

def sync_desktop_sidebar(t):
    """Mirror a claude harness thread into the desktop app's sidebar store."""
    try:
        if t.get('engine') != 'claude' or not t.get('session_id'):
            return
        d = _sidebar_store_dir()
        if not d:
            return
        sid = t['session_id']
        marker = str(uuid.uuid5(uuid.NAMESPACE_URL, 'harness-thread:' + t['id']))
        ours = os.path.join(d, 'local_%s.json' % marker)
        # If the app (or an import source) already tracks this cli session, don't duplicate.
        for p in glob.glob(os.path.join(d, 'local_*.json')):
            if p == ours:
                continue
            try:
                with open(p, encoding='utf-8', errors='replace') as f:
                    if json.load(f).get('cliSessionId') == sid:
                        return
            except Exception:
                continue
        title = (t.get('title') or '').strip()
        if not title:
            for m in t.get('messages', []):
                if m.get('role') == 'user' and (m.get('text') or '').strip():
                    title = m['text'].strip()[:60]
                    break
        entry = {'sessionId': 'local_' + marker,
                 'cliSessionId': sid,
                 'cwd': t.get('cwd') or HOME,
                 'originCwd': t.get('cwd') or HOME,
                 'createdAt': int((t.get('created') or time.time()) * 1000),
                 'lastActivityAt': int((t.get('updated') or time.time()) * 1000),
                 'lastFocusedAt': int((t.get('updated') or time.time()) * 1000),
                 'model': t.get('model') or '',
                 'sessionSettings': {},
                 'isArchived': bool(t.get('archived')),
                 'title': title or 'Harness thread',
                 'titleSource': 'auto',
                 'permissionMode': _SIDEBAR_MODES.get(t.get('permission_mode') or 'bypass',
                                                      'bypassPermissions'),
                 'enabledMcpTools': {}}
        tmp = ours + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(entry, f, indent=1)
        os.replace(tmp, ours)
    except Exception as e:
        log('sidebar sync skipped: %s' % e)

def _parse_claude_session(path, full=False):
    """-> {id, engine, cwd, title, updated, turns[, messages]}. Bounded read for listing."""
    sid = os.path.basename(path)[:-6]
    cwd, title, turns, messages = None, None, 0, []
    limit = 4000 if full else 400
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                if i > limit:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get('isSidechain'):
                    continue
                if not cwd and d.get('cwd'):
                    cwd = d['cwd']
                typ = d.get('type')
                if typ not in ('user', 'assistant'):
                    continue
                m = d.get('message', {})
                c = m.get('content')
                if isinstance(c, list):
                    c = ' '.join(b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
                if not isinstance(c, str) or not c.strip():
                    continue
                turns += 1
                if typ == 'user' and not title:
                    title = _clean_title(c)
                if full:
                    messages.append({'role': typ, 'text': c[:6000], 'ts': None})
    except Exception:
        return None
    out = {'id': sid, 'engine': 'claude', 'cwd': cwd or HOME,
           'title': title or ('Claude session ' + sid[:8]),
           'updated': os.path.getmtime(path), 'turns': turns}
    if full:
        out['messages'] = messages[-120:]
    return out

def _parse_codex_session(path, full=False):
    sid, cwd, title, turns, messages = None, None, None, 0, []
    limit = 6000 if full else 500
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                if i > limit:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                p = d.get('payload', {}) or {}
                if d.get('type') == 'session_meta' or p.get('type') == 'session_meta':
                    sid = sid or p.get('session_id') or p.get('id')
                    cwd = cwd or p.get('cwd')
                if p.get('type') == 'turn_context' and not cwd:
                    cwd = p.get('cwd')
                if d.get('type') == 'response_item' and p.get('type') == 'message':
                    role = p.get('role')
                    if role not in ('user', 'assistant'):
                        continue
                    txt = ' '.join(b.get('text', '') for b in (p.get('content') or [])
                                   if isinstance(b, dict) and b.get('type') in ('input_text', 'output_text', 'text'))
                    if not txt.strip():
                        continue
                    turns += 1
                    if role == 'user' and not title:
                        title = _clean_title(txt)
                    if full:
                        messages.append({'role': role, 'text': txt[:6000], 'ts': None})
    except Exception:
        return None
    if not sid:
        sid = os.path.basename(path).split('-')[-1][:-6]
    out = {'id': sid, 'engine': 'codex', 'cwd': cwd or HOME,
           'title': title or ('Codex session ' + sid[:8]),
           'updated': os.path.getmtime(path), 'turns': turns}
    if full:
        out['messages'] = messages[-120:]
    return out

def _session_files():
    """(engine, path) for recent desktop sessions, newest first, capped."""
    files = []
    for p in glob.glob(os.path.join(CLAUDE_SESS_DIR, '*', '*.jsonl')):
        files.append(('claude', p))
    for p in glob.glob(os.path.join(CODEX_SESS_DIR, '*', '*', '*', 'rollout-*.jsonl')):
        files.append(('codex', p))
    files.sort(key=lambda ep: os.path.getmtime(ep[1]) if os.path.exists(ep[1]) else 0, reverse=True)
    return files[:60]

def list_desktop_sessions():
    out = []
    ctitles, xtitles = claude_title_map(), codex_title_map()
    for engine, path in _session_files():
        s = _parse_claude_session(path) if engine == 'claude' else _parse_codex_session(path)
        if not s or s['turns'] == 0:
            continue
        # Claude resolves --resume per PROJECT DIR (derived from cwd): if the session's cwd
        # can't be the thread cwd (outside home), resume would launch in the wrong project
        # and fail with "No conversation found" — don't offer those.
        if engine == 'claude' and valid_cwd(s['cwd']) is None:
            continue
        desktop = (ctitles if engine == 'claude' else xtitles).get(s['id'])
        if desktop:                               # desktop sidebar name (incl. renames) wins
            s['title'] = desktop
        out.append(s)
    return out[:40]

def _find_session_path(sid, engine):
    if engine == 'claude':
        hits = glob.glob(os.path.join(CLAUDE_SESS_DIR, '*', sid + '.jsonl'))
        return hits[0] if hits else None
    hits = glob.glob(os.path.join(CODEX_SESS_DIR, '*', '*', '*', 'rollout-*-%s.jsonl' % sid))
    return hits[0] if hits else None

def import_desktop_session(sid, engine):
    """Create a harness thread bound to a desktop session id; the next message resumes it."""
    if engine not in ('claude', 'codex'):
        return None, 'unknown engine'
    path = _find_session_path(sid, engine)
    if not path:
        return None, 'session not found'
    parsed = (_parse_claude_session if engine == 'claude' else _parse_codex_session)(path, full=True)
    if not parsed:
        return None, 'could not parse session'
    dt = (claude_title_map() if engine == 'claude' else codex_title_map()).get(sid)
    if dt:
        parsed['title'] = dt                      # keep the desktop name on the imported thread
    prov = provider_by_id(engine) or provider_by_id('claude')
    cwd = valid_cwd(parsed['cwd'])
    if engine == 'claude' and cwd is None:
        return None, 'session cwd is outside your home folder — continue it on the desktop'
    cwd = cwd or HOME
    now = time.time()
    t = {'id': uuid.uuid4().hex, 'title': ('📥 ' + parsed['title'])[:80],
         'engine': prov['engine'], 'provider': prov['id'], 'model': prov.get('model'),
         'cwd': cwd, 'permission_mode': 'bypass', 'effort': 'default',
         'session_id': sid,                       # <- the resume key; continuation just works
         'created': now, 'updated': now,
         'messages': parsed.get('messages', [])}
    save_thread(t)
    log('imported %s desktop session %s -> thread %s (%d msgs)'
        % (engine, sid[:8], t['id'][:8], len(t['messages'])))
    return t, None

# --------------------------------------------------------------------------- managed automations
# Phone-created scheduled agent jobs. The harness daemon ITSELF is the scheduler
# (it's already always-on), so this works identically on macOS and Windows — no
# launchd plists, no schtasks. Each automation owns a dedicated thread; results
# land there like any other detached turn, completion push included.
AUTOS_FILE = os.path.join(BASE, 'automations.json')
_autos_lock = threading.Lock()

def load_autos():
    try:
        with open(AUTOS_FILE) as f:
            return json.load(f)
    except Exception:
        return []

def save_autos(autos):
    tmp = AUTOS_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(autos, f, indent=1)
    os.replace(tmp, AUTOS_FILE)

def schedule_text(s):
    if (s or {}).get('type') == 'interval':
        m = int(s.get('minutes', 60))
        return 'every %dh' % (m // 60) if m % 60 == 0 else 'every %dm' % m
    return 'daily %02d:%02d' % (int((s or {}).get('hour', 0)), int((s or {}).get('minute', 0)))

def auto_public(a):
    d = {k: a.get(k) for k in ('id', 'name', 'prompt', 'provider', 'model', 'effort',
                               'cwd', 'enabled', 'thread_id', 'last_run', 'last_status',
                               'max_runs_per_day')}
    d['schedule'] = a.get('schedule') or {}
    d['schedule_text'] = schedule_text(d['schedule'])
    return d

def _validate_auto(body, existing=None):
    """Returns (auto_dict, error). Merges onto `existing` for updates."""
    a = dict(existing or {})
    name = (body.get('name') if 'name' in body else a.get('name') or '').strip()
    prompt = (body.get('prompt') if 'prompt' in body else a.get('prompt') or '').strip()
    if not name or len(name) > 60:
        return None, 'name required (max 60 chars)'
    if not prompt or len(prompt) > MAX_MSG:
        return None, 'prompt required'
    pid = body.get('provider') or a.get('provider') or 'claude'
    if not provider_by_id(pid):
        return None, 'unknown provider: %s' % pid
    s = body.get('schedule') or a.get('schedule') or {}
    if s.get('type') == 'interval':
        try:
            s = {'type': 'interval', 'minutes': max(5, min(7 * 24 * 60, int(s.get('minutes', 60))))}
        except Exception:
            return None, 'bad interval'
    else:
        try:
            s = {'type': 'daily', 'hour': min(23, max(0, int(s.get('hour', 9)))),
                 'minute': min(59, max(0, int(s.get('minute', 0))))}
        except Exception:
            return None, 'bad time'
    cwd = body.get('cwd') if 'cwd' in body else a.get('cwd')
    if cwd:
        cwd = valid_cwd(cwd)
        if cwd is None:
            return None, 'cwd must be a directory inside your home folder'
    eff = body.get('effort') or a.get('effort') or 'default'
    if eff not in ALLOWED_EFFORTS:
        eff = 'default'
    try:
        cap = max(0, min(96, int(body.get('max_runs_per_day',
                                          a.get('max_runs_per_day') or 0) or 0)))
    except Exception:
        cap = 0
    a.update({'name': name, 'prompt': prompt, 'provider': pid,
              'model': (body.get('model') if 'model' in body else a.get('model')) or None,
              'effort': eff, 'cwd': cwd, 'schedule': s, 'max_runs_per_day': cap,
              'enabled': bool(body.get('enabled', a.get('enabled', True)))})
    a.setdefault('id', uuid.uuid4().hex[:12])
    return a, None

def usage_blocked():
    """True while Claude's five-hour window is exhausted (auto-lifts at resetsAt).
    Scheduled automations skip instead of burning the user's remaining window."""
    with _usage_lock:
        fh = (RATE_LIMITS.get('claude') or {}).get('five_hour') or {}
    if fh.get('status') != 'rejected':
        return False
    try:
        resets = float(fh.get('resetsAt') or 0)
    except Exception:
        resets = 0
    return not resets or time.time() < resets

def _mark_auto(aid, status):
    """Record a scheduler decision on the automation (only when it changed)."""
    with _autos_lock:
        autos = load_autos()
        for x in autos:
            if x['id'] == aid and x.get('last_status') != status:
                x['last_status'] = status
                save_autos(autos)
                log('automation "%s" %s' % (x['name'], status))
                return

def _auto_thread(a):
    """The automation's dedicated thread — created on first run."""
    t = load_thread(a.get('thread_id') or '')
    if t is not None:
        return t
    prov = provider_by_id(a.get('provider') or 'claude') or provider_by_id('claude')
    now = time.time()
    t = {'id': uuid.uuid4().hex, 'title': ('⚡ ' + a['name'])[:80],
         'engine': prov['engine'], 'provider': prov['id'],
         'model': a.get('model') or prov.get('model'),
         'cwd': (valid_cwd(a.get('cwd')) if a.get('cwd') else None) or HOME,
         'permission_mode': 'bypass', 'effort': a.get('effort') or 'default',
         'session_id': None, 'created': now, 'updated': now, 'messages': []}
    save_thread(t)
    return t

def run_automation(aid):
    """Fire one automation now. Returns (ok, thread_id_or_error)."""
    with _autos_lock:
        a = next((x for x in load_autos() if x['id'] == aid), None)
    if not a:
        return False, 'no such automation'
    prov = provider_by_id(a.get('provider') or 'claude') or provider_by_id('claude')
    if not prov:
        return False, 'no provider available'
    t = _auto_thread(a)
    if a.get('model'):
        t['model'] = a['model']
    if a.get('effort'):
        t['effort'] = a['effort']
    lock = _lock_for(t['id'])
    if not lock.acquire(blocking=False):
        return False, 'previous run still going'
    try:
        start_job(t, prov, a['prompt'], [], lock)
    except Exception as e:
        lock.release()
        return False, str(e)
    today = time.strftime('%Y-%m-%d')
    with _autos_lock:
        autos = load_autos()
        for x in autos:
            if x['id'] == aid:
                x['thread_id'] = t['id']
                x['last_run'] = time.time()
                x['last_status'] = 'started'
                x['runs_today'] = (int(x.get('runs_today') or 0) + 1) if x.get('runs_day') == today else 1
                x['runs_day'] = today
        save_autos(autos)
    log('automation RUN "%s" -> thread %s' % (a['name'], t['id'][:8]))
    return True, t['id']

def _autos_loop():
    while True:
        time.sleep(30)
        try:
            lt, nowts = time.localtime(), time.time()
            with _autos_lock:
                autos = load_autos()
            for a in autos:
                if not a.get('enabled', True):
                    continue
                s, last = a.get('schedule') or {}, a.get('last_run') or 0
                due = (nowts - last >= int(s.get('minutes', 60)) * 60) if s.get('type') == 'interval' \
                    else (lt.tm_hour == int(s.get('hour', -1)) and lt.tm_min == int(s.get('minute', -1))
                          and nowts - last > 120)
                if not due:
                    continue
                # Guardrails: never burn a capped Claude window on a scheduled run,
                # and honor the per-automation daily run limit (manual Run-now bypasses both).
                prov = provider_by_id(a.get('provider') or 'claude')
                if prov and prov.get('engine') == 'claude' and usage_blocked():
                    _mark_auto(a['id'], 'skipped: usage cap')
                    continue
                cap = int(a.get('max_runs_per_day') or 0)
                if cap and a.get('runs_day') == time.strftime('%Y-%m-%d') \
                        and int(a.get('runs_today') or 0) >= cap:
                    _mark_auto(a['id'], 'skipped: daily cap')
                    continue
                run_automation(a['id'])
        except Exception as e:
            log('automations loop error: %s' % e)

# --------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _internal_approval(self):
        """approval_tool.py relay: register the ask, alert the phone, block until
        the user decides (or APPROVAL_TIMEOUT -> deny). Loopback only — this
        endpoint is unauthenticated and must never be reachable from the tailnet."""
        try:
            if not ipaddress.ip_address(self.client_address[0]).is_loopback:
                return self._json(403, {'error': 'forbidden'})
        except Exception:
            return self._json(403, {'error': 'forbidden'})
        body = self._body() or {}
        # Authenticate the caller as an approval_tool WE spawned (blocks other local processes
        # from spoofing approval prompts to the phone or exhausting threads).
        if not hmac.compare_digest(str(body.get('secret') or ''), APPROVAL_SECRET):
            return self._json(403, {'error': 'forbidden'})
        with _approvals_lock:
            if len(APPROVALS) >= MAX_PENDING_APPROVALS:
                return self._json(429, {'decision': 'deny', 'message': 'too many pending approvals'})
        tid = str(body.get('thread_id') or '')
        rec = {'id': uuid.uuid4().hex[:12], 'thread_id': tid,
               'tool_name': str(body.get('tool_name') or '?')[:80],
               'input': body.get('input') if isinstance(body.get('input'), dict) else {},
               'decision': None, 'event': threading.Event(), 'created': time.time()}
        with _approvals_lock:
            APPROVALS[rec['id']] = rec
        summary = approval_summary(rec['tool_name'], rec['input'])
        job = job_for(tid)
        if job:
            job.publish({'type': 'approval', 'id': rec['id'],
                         'name': rec['tool_name'], 'detail': summary})
        notify_approval_push(load_thread(tid), rec)
        log('approval WAIT %s %s' % (rec['id'], summary[:100]))
        rec['event'].wait(APPROVAL_TIMEOUT)
        with _approvals_lock:
            APPROVALS.pop(rec['id'], None)
        dec = rec['decision']
        if job:
            job.publish({'type': 'approval_resolved', 'id': rec['id'], 'text': dec or 'timeout'})
        log('approval %s -> %s' % (rec['id'], dec or 'timeout(deny)'))
        if dec == 'allow':
            return self._json(200, {'decision': 'allow'})
        return self._json(200, {'decision': 'deny',
                                'message': 'Denied from the Harness app' if dec == 'deny'
                                else 'No approval from the phone within %ss' % APPROVAL_TIMEOUT})

    def _proxy(self, tid, parts, raw=b''):
        """Forward /threads/{tid}/proxy/{port}/<sub> to the local dev server on {port}."""
        if load_thread(tid) is None:
            return self._json(404, {'error': 'no such thread'})
        try:
            port = int(parts[4])
            if not (1024 <= port <= 65535):
                raise ValueError
        except Exception:
            return self._json(400, {'error': 'bad port'})
        sub = '/'.join(parts[5:])
        q = urllib.parse.urlparse(self.path).query
        status, hdrs, data = proxy_request(port, sub, q, self.command, raw, self.headers)
        log('proxy %s :%d /%s -> %s (%dB)' % (self.command, port, sub, status, len(data)))
        hdrs = {k.title(): v for k, v in hdrs.items()}   # http.server sends 'Content-type'
        self.send_response(status)
        self.send_header('Content-Type', hdrs.get('Content-Type') or 'application/octet-stream')
        loc = hdrs.get('Location')
        if loc:   # keep redirects on the proxied origin: strip any local absolute prefix
            self.send_header('Location',
                             re.sub(r'^https?://(127\.0\.0\.1|localhost)(:\d+)?', '', loc) or '/')
        if hdrs.get('Set-Cookie'):
            self.send_header('Set-Cookie', hdrs['Set-Cookie'])
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            return self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return None

    def _client_allowed(self):
        try:
            a = ipaddress.ip_address(self.client_address[0])
        except Exception:
            return False
        return a.is_loopback or a in TAILNET

    def _authed(self):
        if not TOKEN:
            return True
        return hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + TOKEN)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get('Content-Length', 0) or 0)
        if n <= 0:
            return {}
        if n > MAX_BODY:
            return None                       # signal "too large" to caller
        try:
            return json.loads(self.rfile.read(n).decode() or '{}')
        except Exception:
            return {}

    def _ws_tunnel(self, tid, parts, qs):
        """Transparent TCP relay for a WebSocket upgrade on a proxy path (HMR live-reload).
        Browsers can't set Authorization on a WebSocket, so the token rides in ?_hbtok=.
        After the dev server's 101, framing is opaque — we just shuttle bytes both ways."""
        self.close_connection = True          # a hijacked socket is never reused
        tok = (qs.get('_hbtok', [''])[0])
        if not (TOKEN and hmac.compare_digest(tok, TOKEN)):
            self.send_response(401); self.end_headers(); return
        if load_thread(tid) is None:
            self.send_response(404); self.end_headers(); return
        try:
            port = int(parts[4])
            if not (1024 <= port <= 65535):
                raise ValueError
        except Exception:
            self.send_response(400); self.end_headers(); return
        sub = '/'.join(parts[5:])
        try:
            dev = socket.create_connection(('127.0.0.1', port), timeout=10)
        except Exception:
            self.send_response(502); self.end_headers(); return
        # Replay the upgrade handshake to the dev server (Host rewritten; token stripped).
        q = '&'.join('%s=%s' % (k, v) for k, vs in qs.items() if k != '_hbtok' for v in vs)
        line = 'GET /%s%s HTTP/1.1\r\n' % (sub, ('?' + q) if q else '')
        heads = [line, 'Host: 127.0.0.1:%d\r\n' % port]
        for k in self.headers:
            if k.lower() in ('host', 'authorization'):
                continue
            heads.append('%s: %s\r\n' % (k, self.headers[k]))
        heads.append('\r\n')
        try:
            dev.sendall(''.join(heads).encode('latin-1', 'ignore'))
        except Exception:
            dev.close(); return
        client = self.connection
        client.settimeout(None); dev.settimeout(None)
        done = threading.Event()
        def pump(src, dst):
            try:
                while not done.is_set():
                    b = src.recv(65536)
                    if not b:
                        break
                    dst.sendall(b)
            except Exception:
                pass
            finally:
                done.set()
                for s in (src, dst):
                    try: s.shutdown(socket.SHUT_RDWR)
                    except Exception: pass
        t2 = threading.Thread(target=pump, args=(dev, client), daemon=True); t2.start()
        pump(client, dev)                 # dev->client runs in t2; client->dev here
        try: dev.close()
        except Exception: pass

    # ---- routing
    def do_GET(self):
        if not self._client_allowed():
            return self._json(403, {'error': 'forbidden'})
        path = self.path.split('?')[0].rstrip('/')
        # WebSocket upgrade on a proxy path -> raw tunnel (auth via ?_hbtok=, pre-_authed).
        if (self.headers.get('Upgrade', '').lower() == 'websocket'):
            pe = path.split('/')
            if len(pe) >= 5 and pe[1] == 'threads' and pe[3] == 'proxy' and valid_tid(pe[2]):
                qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                return self._ws_tunnel(pe[2], pe, qs)
        if path == '/health':
            return self._json(200, {'ok': True, 'version': VERSION,
                                    'engines': ['claude', 'codex'],
                                    'push_configured': apns_configured(),
                                    'push_devices': len(load_push_tokens())})
        if path == '/pair':
            # Loopback ONLY — the page contains the bearer token.
            try:
                if not ipaddress.ip_address(self.client_address[0]).is_loopback:
                    return self._json(403, {'error': 'forbidden'})
            except Exception:
                return self._json(403, {'error': 'forbidden'})
            ip = tailnet_ip()
            url = 'http://%s:%s' % (ip or '<your-tailscale-ip>', PORT)
            name = urllib.parse.quote(socket.gethostname().split('.')[0])
            pair = 'harness://pair?url=%s&token=%s&name=%s' % (
                urllib.parse.quote(url, safe=''), urllib.parse.quote(TOKEN or '', safe=''), name)
            body = (PAIR_HTML.replace('__URL__', url).replace('__TOKEN__', TOKEN or '(none)')
                    .replace('__PAIR__', pair)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if not self._authed():
            return self._json(401, {'error': 'unauthorized'})
        if path == '/providers':
            return self._json(200, [_provider_public(p) for p in load_providers()])
        if path.startswith('/providers/') and path.endswith('/models'):
            pid = path.split('/')[2]
            p = provider_by_id(pid)
            if not p:
                return self._json(404, {'error': 'unknown provider'})
            return self._json(200, fetch_provider_models(p))
        if path == '/threads':
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            view = 'archived' if q.get('view', [''])[0] == 'archived' else 'active'
            return self._json(200, list_threads(view))
        if path == '/trash':
            return self._json(200, list_threads('trash'))
        if path == '/automations':
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            with _autos_lock:
                managed = [auto_public(a) for a in load_autos()]
            return self._json(200, {'managed': managed,
                                    'system': list_automations(show_all=q.get('all', [''])[0] == '1')})
        if path == '/desktop/sessions':
            return self._json(200, list_desktop_sessions())
        if path == '/usage':
            with _usage_lock:
                return self._json(200, json.loads(json.dumps(RATE_LIMITS)))
        if path.startswith('/threads/'):
            parts = path.split('/')
            tid = parts[2] if len(parts) > 2 else ''
            if not valid_tid(tid):
                return self._json(404, {'error': 'no such thread'})
            if len(parts) >= 4 and parts[3] == 'stream':    # reconnect to an in-flight turn
                job = job_for(tid)
                if not job:
                    return self._json(200, {'running': False})
                return self._stream_job(job)
            if len(parts) >= 4 and parts[3] == 'approvals':  # pending phone-side approvals
                return self._json(200, pending_approvals(tid))
            if len(parts) >= 4 and parts[3] == 'devservers':
                return self._json(200, scan_dev_servers())
            if len(parts) >= 5 and parts[3] == 'proxy':      # browse a local dev server
                return self._proxy(tid, parts)
            if len(parts) >= 4 and parts[3] == 'artifacts':
                t = load_thread(tid)
                if not t:
                    return self._json(404, {'error': 'no such thread'})
                return self._json(200, {'cwd': t.get('cwd'), 'artifacts': scan_artifacts(t)})
            if len(parts) >= 4 and parts[3] == 'file':
                t = load_thread(tid)
                if not t:
                    return self._json(404, {'error': 'no such thread'})
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                return self._serve_file(t, q.get('path', [''])[0])
            t = load_thread(tid)
            if not t:
                return self._json(404, {'error': 'no such thread'})
            t['running'] = job_for(tid) is not None
            return self._json(200, t)
        return self._json(404, {'error': 'not found'})

    def _serve_file(self, thread, rel):
        tgt = safe_resolve(thread, rel)
        if not tgt:
            return self._json(404, {'error': 'no such file'})
        try:
            size = os.path.getsize(tgt)
        except Exception:
            return self._json(404, {'error': 'no such file'})
        if size > MAX_PREVIEW_BYTES:
            return self._json(413, {'error': 'file too large to preview'})
        ext = os.path.splitext(tgt)[1].lower()
        kind, ctype = PREVIEW_TYPES.get(ext, ('binary', 'application/octet-stream'))
        # text-ish: truncate to keep the phone responsive
        if kind in _TEXTY and size > MAX_TEXT_BYTES:
            try:
                with open(tgt, 'rb') as f:
                    body = f.read(MAX_TEXT_BYTES) + b'\n\xe2\x80\xa6[truncated]\n'
            except Exception:
                return self._json(500, {'error': 'read failed'})
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)
            return
        # single-range support for pdf/image (PDFKit/large media seek)
        rng = self.headers.get('Range')
        start, end = 0, size - 1
        partial = False
        if rng and kind in ('pdf', 'image') and rng.startswith('bytes='):
            try:
                a, b = rng.split('=', 1)[1].split('-', 1)
                start = int(a) if a else 0
                end = int(b) if b else size - 1
                if 0 <= start <= end < size:
                    partial = True
                else:
                    start, end = 0, size - 1
            except Exception:
                start, end = 0, size - 1
        length = end - start + 1
        try:
            f = open(tgt, 'rb')
        except Exception:
            return self._json(500, {'error': 'read failed'})
        try:
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(length))
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Accept-Ranges', 'bytes')
            if partial:
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
            if kind == 'html':
                # a generated page can't phone home / exfiltrate tailnet-reachable data
                self.send_header('Content-Security-Policy',
                                 "default-src 'self' data: blob: 'unsafe-inline'; connect-src 'none'; "
                                 "img-src 'self' data: blob:; frame-src 'none'")
            self.end_headers()
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(65536, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break
                remaining -= len(chunk)
        finally:
            f.close()

    def do_DELETE(self):
        if not self._client_allowed():
            return self._json(403, {'error': 'forbidden'})
        if not self._authed():
            return self._json(401, {'error': 'unauthorized'})
        path = self.path.split('?')[0].rstrip('/')
        parts = path.split('/')
        if len(parts) == 3 and parts[1] == 'automations':  # delete a managed automation
            with _autos_lock:
                autos = load_autos()
                keep = [x for x in autos if x['id'] != parts[2]]
                if len(keep) == len(autos):
                    return self._json(404, {'error': 'no such automation'})
                save_autos(keep)
            return self._json(200, {'ok': True})
        if len(parts) >= 3 and parts[1] == 'trash':       # permanent delete from trash
            tid = parts[2]
            if not valid_tid(tid):
                return self._json(404, {'error': 'no such thread'})
            try:
                os.remove(os.path.join(TRASH_DIR, '%s.json' % tid))
            except FileNotFoundError:
                return self._json(404, {'error': 'not in trash'})
            return self._json(200, {'ok': True})
        if path.startswith('/threads/'):                  # soft delete -> move to trash (restorable)
            tid = parts[2]
            if not valid_tid(tid):
                return self._json(404, {'error': 'no such thread'})
            lock = _lock_for(tid)
            if not lock.acquire(blocking=False):          # don't delete mid-stream
                return self._json(409, {'error': 'thread busy'})
            try:
                with _persist_lock:
                    t = load_thread(tid)
                    if t is None:
                        return self._json(404, {'error': 'no such thread'})
                    t['deleted_at'] = time.time()
                    tmp = os.path.join(TRASH_DIR, '%s.json.tmp' % tid)
                    with open(tmp, 'w') as f:
                        json.dump(t, f, indent=2)
                    os.replace(tmp, os.path.join(TRASH_DIR, '%s.json' % tid))
                    try: os.remove(thread_path(tid))
                    except FileNotFoundError: pass
            finally:
                lock.release()
                with _store_lock:
                    thread_locks.pop(tid, None)           # reclaim the lock entry
            return self._json(200, {'ok': True})
        return self._json(404, {'error': 'not found'})

    def do_POST(self):
        if not self._client_allowed():
            return self._json(403, {'error': 'forbidden'})
        if self.path.split('?')[0].rstrip('/') == '/internal/approval':
            return self._internal_approval()   # loopback-only, pre-auth (relay from approval_tool.py)
        if not self._authed():
            return self._json(401, {'error': 'unauthorized'})
        path = self.path.split('?')[0].rstrip('/')
        pe = path.split('/')
        if len(pe) >= 5 and pe[1] == 'threads' and pe[3] == 'proxy':
            # Dev-server POST (form/fetch): body is raw bytes, not our JSON — read it here.
            n = int(self.headers.get('Content-Length', 0) or 0)
            raw = self.rfile.read(n) if 0 < n <= MAX_BODY else b''
            return self._proxy(pe[2], pe, raw=raw)
        body = self._body()
        if body is None:
            self.close_connection = True
            return self._json(413, {'error': 'request body too large'})
        if path == '/threads':
            return self._create_thread(body)
        if path == '/push/register':
            tok = (body.get('token') or '').strip()
            if not tok or not all(c in '0123456789abcdefABCDEF' for c in tok) or not (32 <= len(tok) <= 200):
                log('push/register REJECTED bad token (len=%d) from %s' % (len(tok), self.client_address[0]))
                return self._json(400, {'error': 'bad token'})
            add_push_token(tok.lower())
            log('push/register OK token=%s… (len=%d) from %s' % (tok[:8], len(tok), self.client_address[0]))
            return self._json(200, {'ok': True, 'configured': apns_configured()})
        if path == '/push/unregister':
            tok = (body.get('token') or '').strip().lower()
            if tok:
                remove_push_tokens([tok])
                log('push/unregister token=%s…' % tok[:8])
            return self._json(200, {'ok': True})
        if path == '/push/test':
            toks = load_push_tokens()
            if not apns_configured():
                return self._json(200, {'ok': False, 'reason': 'apns not configured', 'tokens': len(toks)})
            results = []
            for t in toks:
                ok, code, reason = apns_send(t, {'aps': {'alert': {
                    'title': 'Harness', 'body': 'Push is working ✅'}, 'sound': 'default'}})
                results.append({'token': t[:8], 'code': code, 'reason': reason, 'ok': ok})
            return self._json(200, {'ok': True, 'sent': results})
        if path.startswith('/providers/'):
            return self._set_provider(path.split('/')[2], body)
        if path == '/desktop/handoff':                   # continue a session ON THE OTHER ENGINE
            sid = (body.get('id') or '').strip()
            engine = (body.get('engine') or '').strip()
            if engine not in ('claude', 'codex') or not sid:
                return self._json(400, {'error': 'id and engine required'})
            target = 'codex' if engine == 'claude' else 'claude'
            spath = _find_session_path(sid, engine)
            if not spath:
                return self._json(404, {'error': 'session not found'})
            parsed = (_parse_claude_session if engine == 'claude' else _parse_codex_session)(spath, full=True)
            if not parsed:
                return self._json(404, {'error': 'could not parse session'})
            title = (claude_title_map() if engine == 'claude' else codex_title_map()).get(sid) or parsed['title']
            hdir = os.path.join(BASE, 'handoffs')
            os.makedirs(hdir, exist_ok=True)
            hpath = os.path.join(hdir, '%s.md' % sid[:12])
            with open(hpath, 'w') as f:
                f.write('# %s\n(handoff from a %s conversation)\n\n' % (title, engine))
                for m in parsed.get('messages', []):
                    f.write('## %s\n\n%s\n\n' % (m['role'].upper(), m['text']))
            prov = provider_by_id(target)
            now = time.time()
            t = {'id': uuid.uuid4().hex, 'title': ('⇄ ' + title)[:80],
                 'engine': prov['engine'], 'provider': prov['id'], 'model': prov.get('model'),
                 'cwd': valid_cwd(parsed['cwd']) or HOME, 'permission_mode': 'bypass',
                 'effort': 'default', 'session_id': None,
                 'created': now, 'updated': now, 'messages': []}
            save_thread(t)
            draft = ('Read %s — it is the full transcript of a conversation I had with %s. '
                     'Absorb it as if it were our own history, briefly confirm where things '
                     'left off, and continue from there.' % (hpath, 'Claude' if engine == 'claude' else 'Codex'))
            log('handoff %s(%s) -> %s thread %s' % (engine, sid[:8], target, t['id'][:8]))
            return self._json(200, {'thread': thread_summary(t), 'draft': draft})
        if path == '/desktop/import':                    # continue a desktop CLI session
            sid = (body.get('id') or '').strip()
            engine = (body.get('engine') or '').strip()
            if not sid:
                return self._json(400, {'error': 'id required'})
            t, err = import_desktop_session(sid, engine)
            if err:
                return self._json(404, {'error': err})
            return self._json(200, thread_summary(t))
        if path == '/automations':                       # create
            a, err = _validate_auto(body)
            if err:
                return self._json(400, {'error': err})
            with _autos_lock:
                autos = load_autos()
                autos.append(a)
                save_autos(autos)
            log('automation NEW "%s" (%s)' % (a['name'], schedule_text(a['schedule'])))
            return self._json(200, auto_public(a))
        if path.startswith('/automations/'):
            parts_a = path.split('/')
            aid = parts_a[2]
            if len(parts_a) == 4 and parts_a[3] == 'run':   # run now
                ok, res = run_automation(aid)
                if not ok:
                    return self._json(409 if 'still going' in res else 404, {'error': res})
                return self._json(200, {'ok': True, 'thread_id': res})
            with _autos_lock:                                # update
                autos = load_autos()
                cur = next((x for x in autos if x['id'] == aid), None)
                if not cur:
                    return self._json(404, {'error': 'no such automation'})
                a, err = _validate_auto(body, existing=cur)
                if err:
                    return self._json(400, {'error': err})
                autos = [a if x['id'] == aid else x for x in autos]
                save_autos(autos)
            return self._json(200, auto_public(a))
        parts = path.split('/')
        if len(parts) == 4 and parts[1] == 'threads' and parts[3] == 'activity':
            tok = (body.get('token') or '').strip().lower()
            if not tok or not all(c in '0123456789abcdef' for c in tok) or not (32 <= len(tok) <= 200):
                return self._json(400, {'error': 'bad token'})
            with _activity_lock:
                ACTIVITY_TOKENS[parts[2]] = tok
            return self._json(200, {'ok': True})
        if len(parts) == 5 and parts[1] == 'threads' and parts[3] == 'approvals':
            dec = 'allow' if body.get('decision') == 'allow' else 'deny'
            with _approvals_lock:
                rec = APPROVALS.get(parts[4])
                if rec and rec['thread_id'] == parts[2] and rec['decision'] is None:
                    rec['decision'] = dec
                    rec['event'].set()
                else:
                    rec = None
            if not rec:
                return self._json(404, {'error': 'no such pending approval'})
            return self._json(200, {'ok': True, 'decision': dec})
        if len(parts) >= 4 and parts[1] == 'threads':
            tid, action = parts[2], parts[3]
            if not valid_tid(tid):
                return self._json(404, {'error': 'no such thread'})
            if action == 'restore':                       # lives in trash, not the active store
                return self._restore_thread(tid)
            t = load_thread(tid)
            if not t:
                return self._json(404, {'error': 'no such thread'})
            if action == 'rename':
                # reload under the persist lock so we only change the title and never clobber
                # messages a running job appended. 404 (don't resurrect) if it was deleted meanwhile.
                with _persist_lock:
                    cur = load_thread(tid)
                    if cur is None:
                        return self._json(404, {'error': 'no such thread'})
                    cur['title'] = (body.get('title') or cur.get('title') or 'Untitled')[:80]
                    cur['updated'] = time.time()
                    save_thread(cur)
                return self._json(200, cur)
            if action == 'archive':
                with _persist_lock:
                    cur = load_thread(tid)
                    if cur is None:
                        return self._json(404, {'error': 'no such thread'})
                    cur['archived'] = bool(body.get('archived', True))
                    cur['updated'] = time.time()
                    save_thread(cur)
                return self._json(200, thread_summary(cur))
            if action == 'stop':
                p = get_run(tid)
                if p and p.poll() is None:
                    p.kill()
                    return self._json(200, {'ok': True, 'stopped': True})
                return self._json(200, {'ok': True, 'stopped': False})
            if action == 'fork':
                # Branch the conversation: the fork resumes from the SAME point, then
                # diverges. Claude's --resume forks cleanly (each -p run mints a new
                # session). Codex `exec resume` APPENDS to the shared rollout, so a
                # codex fork gets a fresh session instead (history kept, context reset).
                now = time.time()
                f = {**{k: t.get(k) for k in ('title', 'engine', 'provider', 'model', 'cwd',
                                              'permission_mode', 'effort')},
                     'id': uuid.uuid4().hex,
                     'title': (body.get('title') or ((t.get('title') or 'Untitled') + ' (fork)'))[:80],
                     'session_id': None if t.get('engine') == 'codex' else t.get('session_id'),
                     'created': now, 'updated': now,
                     'messages': list(t.get('messages') or [])}
                save_thread(f)
                log('fork %s -> %s' % (tid[:8], f['id'][:8]))
                return self._json(200, f)
            if action == 'messages':
                return self._send_message(t, body)
        return self._json(404, {'error': 'not found'})

    def _create_thread(self, body):
        pid = body.get('provider') or 'claude'
        prov = provider_by_id(pid)
        if not prov:
            return self._json(400, {'error': 'unknown provider: %s' % pid})
        cwd = valid_cwd(body.get('cwd') or HOME)
        if cwd is None:
            return self._json(400, {'error': 'cwd must be a directory inside your home folder'})
        mode = body.get('permission_mode') or 'bypass'
        if mode not in ALLOWED_MODES:
            mode = 'bypass'
        effort = body.get('effort') or 'default'
        if effort not in ALLOWED_EFFORTS:
            effort = 'default'
        now = time.time()
        t = {'id': uuid.uuid4().hex, 'title': (body.get('title') or '').strip()[:80],
             'engine': prov['engine'], 'provider': pid,
             'model': (body.get('model') or prov.get('model')),
             'cwd': cwd, 'permission_mode': mode, 'effort': effort, 'session_id': None,
             'created': now, 'updated': now, 'messages': []}
        save_thread(t)
        return self._json(200, t)

    def _restore_thread(self, tid):
        src = os.path.join(TRASH_DIR, '%s.json' % tid)
        if not os.path.exists(src):
            return self._json(404, {'error': 'not in trash'})
        with _persist_lock:
            try:
                with open(src) as f:
                    t = json.load(f)
            except Exception:
                return self._json(500, {'error': 'unreadable'})
            t.pop('deleted_at', None)
            t['archived'] = False
            t['updated'] = time.time()
            save_thread(t)                 # back into the active store
            try: os.remove(src)
            except Exception: pass
        return self._json(200, thread_summary(t))

    def _set_provider(self, pid, body):
        provs = load_providers()
        prov = next((p for p in provs if p.get('id') == pid), None)
        if not prov:
            return self._json(404, {'error': 'no such provider'})
        if 'api_key' in body and prov.get('api_key_env'):
            key = (body.get('api_key') or '').strip()
            env_name = prov['api_key_env']
            if key:
                CFG[env_name] = key
                APP_KEYS[env_name] = key
            else:
                CFG.pop(env_name, None)
                APP_KEYS.pop(env_name, None)
            save_keys()
        if 'enabled' in body:
            for p in provs:
                if p.get('id') == pid:
                    p['enabled'] = bool(body['enabled'])
            tmp = PROVIDERS_FILE + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(provs, f, indent=2)
            os.replace(tmp, PROVIDERS_FILE)
            prov = next((p for p in provs if p.get('id') == pid), prov)
        return self._json(200, _provider_public(prov))

    def _send_message(self, t, body):
        text = (body.get('text') or '').strip()
        if not text:
            return self._json(400, {'error': 'empty text'})
        if len(text) > MAX_MSG:
            return self._json(400, {'error': 'text too long'})
        # resolve provider BEFORE committing to a 200 stream, so failure is a clean JSON error
        prov = provider_by_id(body.get('provider') or t.get('provider')) or provider_by_id('claude')
        if not prov:
            return self._json(503, {'error': 'no provider available'})
        # optional per-message cwd override — lets a thread "cd" into a repo.
        # Changing dir = a new project, so start a fresh session there.
        cwd_override = body.get('cwd')
        if cwd_override:
            np = valid_cwd(cwd_override)            # contained to HOME; ignore if invalid
            if np and np != (t.get('cwd') or HOME):
                t['cwd'] = np
                t['session_id'] = None
        pm = body.get('permission_mode')        # optional per-message mode override
        if pm in ALLOWED_MODES:
            t['permission_mode'] = pm
        eff = body.get('effort')                # optional per-message effort override
        if eff in ALLOWED_EFFORTS:
            t['effort'] = eff
        if 'model' in body:                     # free-form per-thread model override
            t['model'] = body.get('model') or None
        lock = _lock_for(t['id'])
        if not lock.acquire(blocking=False):
            return self._json(409, {'error': 'thread busy'})
        image_paths = write_images(body.get('images'))
        try:
            job = start_job(t, prov, text, image_paths, lock)   # job now owns `lock`
        except Exception as e:
            for p in image_paths:
                try: os.unlink(p)
                except Exception: pass
            lock.release()
            return self._json(500, {'error': str(e)})
        self._stream_job(job)

    def _sse(self, ev):
        try:
            self.wfile.write(('data: ' + json.dumps(ev) + '\n\n').encode())
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    def _stream_job(self, job):
        """Relay a (possibly already-running) job's events to this SSE client.
        Disconnecting only detaches us — the job keeps running and will push."""
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        backlog, q = job.attach()
        for ev in backlog:
            if not self._sse(ev):
                if q: job.detach(q)
                return
        if q is None:                       # job finished before/at attach
            return
        try:
            idle = 0.0
            while True:
                try:
                    ev = q.get(timeout=15)
                    idle = 0.0
                except queue.Empty:
                    idle += 15
                    if idle >= JOB_TIMEOUT + 60:
                        break
                    # SSE comment keepalive: long tool runs / thinking gaps go minutes without
                    # events, and idle client timeouts were killing the stream mid-turn.
                    try:
                        self.wfile.write(b': ping\n\n'); self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        break
                    continue
                if ev is _SENTINEL:
                    break
                if not self._sse(ev):
                    break
        finally:
            job.detach(q)

def main():
    if not TOKEN:
        log('No HARNESS_TOKEN in config.env — refusing to start (set it first).')
        # stay alive so launchd doesn't thrash
        while True:
            time.sleep(60)
    load_providers()   # materialize default file on first run
    purge_trash()      # drop soft-deleted threads older than the TTL
    rotate_logs()      # keep log files bounded (repeats every 6h)
    threading.Thread(target=_rotate_loop, daemon=True).start()
    threading.Thread(target=_autos_loop, daemon=True).start()   # managed automations scheduler
    def _cleanup(signum, frame):
        with _running_lock:
            for proc in list(running.values()):
                try:
                    proc.kill()
                except Exception:
                    pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, _cleanup)   # launchd stop / kill -> don't orphan CLIs
    signal.signal(signal.SIGINT, _cleanup)
    log('claude-harness %s on :%d  claude=%s codex=%s' % (VERSION, PORT, CLAUDE_BIN, CODEX_BIN))
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()

def export_session_cli(query):
    """`server.py --export "<title or id fragment>"` — find a desktop session from EITHER
    engine by title/id and print its transcript as markdown. This is what lets a chat in
    one desktop app say "go read my <other app> chat about X and continue" — the agent
    runs this, gets the whole conversation, and picks up where it left off."""
    q = query.lower().strip()
    sessions = list_desktop_sessions()
    hit = None
    for s in sessions:
        if q in s['title'].lower() or s['id'].lower().startswith(q):
            hit = s
            break
    if not hit:
        print('No desktop session matching %r. Recent sessions:' % query)
        for s in sessions[:15]:
            print('  [%s] %s  (%s)' % (s['engine'], s['title'], s['id'][:8]))
        return 1
    path = _find_session_path(hit['id'], hit['engine'])
    full = (_parse_claude_session if hit['engine'] == 'claude' else _parse_codex_session)(path, full=True)
    print('# %s\n(engine: %s · session %s · cwd %s)\n' % (hit['title'], hit['engine'], hit['id'], full['cwd']))
    for m in full.get('messages', []):
        print('## %s\n\n%s\n' % (m['role'].upper(), m['text']))
    return 0

if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == '--export':
        sys.exit(export_session_cli(' '.join(sys.argv[2:])))
    if len(sys.argv) >= 2 and sys.argv[1] == '--sessions':
        for s in list_desktop_sessions():
            print('[%s] %s  (%s, %d msgs)' % (s['engine'], s['title'], s['id'][:8], s['turns']))
        sys.exit(0)
    main()
