'use strict';
// OAuth 2.1 for remote MCP servers — zero dependencies.
// Flow: RFC 9728 protected-resource discovery → auth-server metadata → RFC 7591
// dynamic client registration (public client, PKCE) → authorization-code flow in
// the default browser with a 127.0.0.1 loopback redirect → token exchange.
// RFC 8707 `resource` is sent on both legs so audience-bound servers work.
const https = require('https');
const http = require('http');
const crypto = require('crypto');

function b64url(buf) { return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }

function httpJson(url, { method = 'GET', headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? https : http;
    const req = mod.request({
      method, hostname: u.hostname, port: u.port || undefined, path: u.pathname + u.search,
      headers: { 'Accept': 'application/json', ...headers },
      timeout: 20000,
    }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(b); } catch {}
        resolve({ status: res.statusCode, headers: res.headers, json, text: b });
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timed out: ' + url)); });
    if (body) req.write(body);
    req.end();
  });
}

// find the authorization server for an MCP endpoint
async function discover(mcpUrl) {
  const u = new URL(mcpUrl);
  const origin = u.origin;
  let prm = null;
  // path-specific first (RFC 9728 §3.1), then origin-wide
  for (const wk of [
    origin + '/.well-known/oauth-protected-resource' + (u.pathname !== '/' ? u.pathname.replace(/\/$/, '') : ''),
    origin + '/.well-known/oauth-protected-resource',
  ]) {
    const r = await httpJson(wk).catch(() => null);
    if (r && r.status === 200 && r.json && Array.isArray(r.json.authorization_servers)) { prm = r.json; break; }
  }
  const asBase = (prm && prm.authorization_servers[0]) || origin;   // legacy servers ARE their own AS
  const asu = new URL(asBase);
  let meta = null;
  for (const wk of [
    asu.origin + '/.well-known/oauth-authorization-server' + (asu.pathname !== '/' ? asu.pathname.replace(/\/$/, '') : ''),
    asu.origin + '/.well-known/oauth-authorization-server',
    asu.origin + '/.well-known/openid-configuration',
  ]) {
    const r = await httpJson(wk).catch(() => null);
    if (r && r.status === 200 && r.json && r.json.authorization_endpoint && r.json.token_endpoint) { meta = r.json; break; }
  }
  if (!meta) throw new Error('no OAuth metadata found for ' + mcpUrl + ' — the server may want a manually-pasted token instead');
  return { meta, scopes: (prm && prm.scopes_supported) || meta.scopes_supported || null };
}

async function registerClient(meta, redirectUri) {
  if (!meta.registration_endpoint) throw new Error('server does not support dynamic client registration');
  const r = await httpJson(meta.registration_endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_name: 'Harness Code',
      client_uri: 'https://github.com/TheRealJadenKwek/harness',
      redirect_uris: [redirectUri],
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
    }),
  });
  if (!r.json || !r.json.client_id) throw new Error('client registration failed: ' + r.text.slice(0, 200));
  return r.json.client_id;
}

function tokenRequest(tokenEndpoint, params) {
  const body = new URLSearchParams(params).toString();
  return httpJson(tokenEndpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  }).then((r) => {
    if (!r.json || !r.json.access_token) throw new Error('token exchange failed: ' + r.text.slice(0, 300));
    return r.json;
  });
}

// full interactive flow; openBrowser(url) is supplied by the caller (shell.openExternal)
async function connect(mcpUrl, openBrowser, onStatus) {
  const say = (m) => { try { onStatus && onStatus(m); } catch {} };
  say('discovering OAuth endpoints…');
  const { meta, scopes } = await discover(mcpUrl);

  const srv = http.createServer();
  const port = await new Promise((ok, bad) => {
    srv.listen(0, '127.0.0.1', () => ok(srv.address().port));
    srv.on('error', bad);
  });
  const redirectUri = 'http://127.0.0.1:' + port + '/callback';

  try {
    say('registering client…');
    const clientId = await registerClient(meta, redirectUri);
    const verifier = b64url(crypto.randomBytes(32));
    const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
    const state = b64url(crypto.randomBytes(16));

    const q = new URLSearchParams({
      response_type: 'code', client_id: clientId, redirect_uri: redirectUri,
      code_challenge: challenge, code_challenge_method: 'S256', state,
      resource: mcpUrl,
      ...(scopes && scopes.length ? { scope: scopes.join(' ') } : {}),
    });
    say('waiting for you to approve in the browser…');
    openBrowser(meta.authorization_endpoint + (meta.authorization_endpoint.includes('?') ? '&' : '?') + q.toString());

    const code = await new Promise((ok, bad) => {
      const to = setTimeout(() => bad(new Error('sign-in timed out (5 minutes)')), 300000);
      srv.on('request', (req, res) => {
        const u = new URL(req.url, redirectUri);
        if (u.pathname !== '/callback') { res.writeHead(404); res.end(); return; }
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end('<html><body style="font-family:-apple-system;display:flex;height:90vh;align-items:center;justify-content:center"><div style="text-align:center"><h2>Connected ✓</h2><p>You can close this tab and return to Harness Code.</p></div></body></html>');
        clearTimeout(to);
        if (u.searchParams.get('state') !== state) return bad(new Error('OAuth state mismatch'));
        const err = u.searchParams.get('error');
        if (err) return bad(new Error(err + ': ' + (u.searchParams.get('error_description') || '')));
        ok(u.searchParams.get('code'));
      });
    });

    say('exchanging code for tokens…');
    const tok = await tokenRequest(meta.token_endpoint, {
      grant_type: 'authorization_code', code, redirect_uri: redirectUri,
      client_id: clientId, code_verifier: verifier, resource: mcpUrl,
    });
    return {
      access_token: tok.access_token,
      refresh_token: tok.refresh_token || null,
      expires_at: tok.expires_in ? Date.now() + tok.expires_in * 1000 : null,
      token_endpoint: meta.token_endpoint,
      client_id: clientId,
      resource: mcpUrl,
    };
  } finally {
    try { srv.close(); } catch {}
  }
}

async function refresh(auth) {
  if (!auth || !auth.refresh_token) throw new Error('no refresh token');
  const tok = await tokenRequest(auth.token_endpoint, {
    grant_type: 'refresh_token', refresh_token: auth.refresh_token,
    client_id: auth.client_id, ...(auth.resource ? { resource: auth.resource } : {}),
  });
  return {
    ...auth,
    access_token: tok.access_token,
    refresh_token: tok.refresh_token || auth.refresh_token,
    expires_at: tok.expires_in ? Date.now() + tok.expires_in * 1000 : null,
  };
}

module.exports = { connect, refresh, discover };
