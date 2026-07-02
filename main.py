"""Harness push relay — lets self-hosted harness servers send APNs pushes without
holding the app's APNs signing key. The relay holds the key; harnesses register a
device token once (getting an opaque relay_id) and then ask the relay to push.

POST /register {token}                          -> {relay_id}
POST /push {relay_id, title, body, thread_id?, approval_id?, category?} -> {ok}
GET  /health                                    -> {ok, devices}

Security: relay_id is an unguessable 128-bit bearer scoped to exactly one device
token; per-relay_id rate limiting; nothing is stored except token<->relay_id.
"""
import base64, json, os, secrets, sqlite3, threading, time

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request

APNS_TEAM_ID = os.environ["APNS_TEAM_ID"]
APNS_KEY_ID = os.environ["APNS_KEY_ID"]
APNS_KEY_PEM = base64.b64decode(os.environ["APNS_KEY_B64"]).decode()
APNS_BUNDLE = os.environ.get("APNS_BUNDLE_ID", "com.jadenkwek.harness")
DB_PATH = os.environ.get("DB_PATH", "/data/relay.db")
RATE_PER_HOUR = int(os.environ.get("RATE_PER_HOUR", "120"))

app = FastAPI()
_lock = threading.Lock()
_jwt_cache = {"t": 0.0, "v": ""}
_rate = {}   # relay_id -> [window_start, count]

os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.execute("CREATE TABLE IF NOT EXISTS devices (relay_id TEXT PRIMARY KEY, token TEXT UNIQUE, created REAL)")
db.commit()


def apns_jwt():
    with _lock:
        if time.time() - _jwt_cache["t"] < 2400:
            return _jwt_cache["v"]
        tok = jwt.encode({"iss": APNS_TEAM_ID, "iat": int(time.time())}, APNS_KEY_PEM,
                         algorithm="ES256", headers={"kid": APNS_KEY_ID})
        _jwt_cache.update(t=time.time(), v=tok)
        return tok


def rate_ok(rid):
    with _lock:
        now = time.time()
        w = _rate.get(rid)
        if not w or now - w[0] > 3600:
            _rate[rid] = [now, 1]
            return True
        if w[1] >= RATE_PER_HOUR:
            return False
        w[1] += 1
        return True


@app.get("/health")
def health():
    n = db.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
    return {"ok": True, "devices": n}


@app.post("/register")
async def register(req: Request):
    body = await req.json()
    token = (body.get("token") or "").strip().lower()
    if not token or not all(c in "0123456789abcdef" for c in token) or not (32 <= len(token) <= 200):
        raise HTTPException(400, "bad token")
    with _lock:
        row = db.execute("SELECT relay_id FROM devices WHERE token=?", (token,)).fetchone()
        if row:
            return {"relay_id": row[0]}
        rid = secrets.token_urlsafe(16)
        db.execute("INSERT INTO devices (relay_id, token, created) VALUES (?,?,?)",
                   (rid, token, time.time()))
        db.commit()
    return {"relay_id": rid}


async def send_apns(token, payload):
    headers = {"authorization": "bearer " + apns_jwt(),
               "apns-topic": APNS_BUNDLE, "apns-push-type": "alert", "apns-priority": "10"}
    async with httpx.AsyncClient(http2=True, timeout=15) as c:
        for host in ("https://api.push.apple.com", "https://api.sandbox.push.apple.com"):
            r = await c.post(f"{host}/3/device/{token}", json=payload, headers=headers)
            if r.status_code == 200:
                return True, "200"
            try:
                reason = r.json().get("reason", "")
            except Exception:
                reason = str(r.status_code)
            if reason != "BadDeviceToken":     # only token-env mismatch falls through to sandbox
                return False, reason
        return False, "BadDeviceToken"


@app.post("/push")
async def push(req: Request):
    body = await req.json()
    rid = body.get("relay_id") or ""
    row = db.execute("SELECT token FROM devices WHERE relay_id=?", (rid,)).fetchone()
    if not row:
        raise HTTPException(404, "unknown relay_id")
    if not rate_ok(rid):
        raise HTTPException(429, "rate limited")
    aps = {"alert": {"title": str(body.get("title") or "Harness")[:80],
                     "body": str(body.get("body") or "")[:180]},
           "sound": "default"}
    if body.get("category"):
        aps["category"] = str(body["category"])[:40]
    if body.get("thread_id"):
        aps["thread-id"] = str(body["thread_id"])[:64]
    payload = {"aps": aps}
    for k in ("threadId", "approvalId"):
        if body.get(k):
            payload[k] = str(body[k])[:64]
    ok, reason = await send_apns(row[0], payload)
    if not ok and reason in ("BadDeviceToken", "Unregistered", "ExpiredToken"):
        with _lock:
            db.execute("DELETE FROM devices WHERE relay_id=?", (rid,))
            db.commit()
    return {"ok": ok, "reason": reason}
