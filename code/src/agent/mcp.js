'use strict';
// Minimal MCP (Model Context Protocol) client over stdio — newline-delimited
// JSON-RPC. Zero dependencies. One McpClient per configured server; its tools
// are advertised to the model as mcp__<server>__<tool>.
const { spawn } = require('child_process');
const https = require('https');
const http = require('http');

class McpClient {
  constructor(name, command, cwd) {
    this.name = name;
    this.command = command;
    this.cwd = cwd || null;
    // "https://host/path [bearer-token]" → remote Streamable-HTTP transport
    const rm = String(command || '').match(/^(https?:\/\/\S+)(?:\s+(\S+))?$/);
    this.remote = rm ? { url: rm[1], token: rm[2] || null, sessionId: null } : null;
    this.proc = null;
    this.seq = 0;
    this.pending = new Map();
    this.tools = [];
    this.status = 'stopped';   // stopped | starting | running | error
    this.error = null;
    this.buf = '';
  }

  _httpRpc(method, params, timeout) {
    return new Promise((resolve, reject) => {
      const id = method.startsWith('notifications/') ? null : ++this.seq;
      const u = new URL(this.remote.url);
      const mod = u.protocol === 'https:' ? https : http;
      const body = JSON.stringify({ jsonrpc: '2.0', ...(id != null ? { id } : {}), method, params: params || {} });
      const req = mod.request({
        method: 'POST', hostname: u.hostname, port: u.port || undefined, path: u.pathname + u.search,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          ...(this.remote.token ? { 'Authorization': 'Bearer ' + this.remote.token } : {}),
          ...(this.remote.sessionId ? { 'mcp-session-id': this.remote.sessionId } : {}),
        },
        timeout: timeout || 30000,
      }, (res) => {
        const sid = res.headers['mcp-session-id'];
        if (sid) this.remote.sessionId = sid;
        let b = '';
        res.on('data', (c) => (b += c));
        res.on('end', () => {
          if (id == null) return resolve(null);   // notification — no response expected
          if (res.statusCode < 200 || res.statusCode >= 300) return reject(new Error('HTTP ' + res.statusCode + ': ' + b.slice(0, 200)));
          try {
            // SSE framing: take the last data: line; plain JSON otherwise
            let payload = b.trim();
            if (payload.includes('data:')) {
              const datas = payload.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim());
              payload = datas.reverse().find((d) => { try { const j = JSON.parse(d); return j.id === id; } catch { return false; } }) || datas[datas.length - 1];
            }
            const msg = JSON.parse(payload);
            if (msg.error) return reject(new Error(msg.error.message || JSON.stringify(msg.error)));
            resolve(msg.result);
          } catch (e) { reject(new Error('bad response: ' + e.message)); }
        });
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error(method + ' timed out')); });
      req.write(body);
      req.end();
    });
  }

  start() {
    if (this.remote) {
      this.status = 'starting';
      this.error = null;
      return this._httpRpc('initialize', {
        protocolVersion: '2024-11-05', capabilities: {},
        clientInfo: { name: 'harness-code', version: '1.3.0' },
      }, 20000)
        .then(() => this._httpRpc('notifications/initialized').catch(() => {}))
        .then(() => this._httpRpc('tools/list', {}, 20000))
        .then((r) => { this.tools = (r && r.tools) || []; this.status = 'running'; })
        .catch((e) => { this.status = 'error'; this.error = String((e && e.message) || e); });
    }
    if (this.proc) return Promise.resolve();
    this.status = 'starting';
    this.error = null;
    try {
      this.proc = spawn('/bin/bash', ['-lc', this.command], {
        stdio: ['pipe', 'pipe', 'pipe'], env: process.env,
        ...(this.cwd ? { cwd: this.cwd } : {}),
      });
    } catch (e) {
      this.status = 'error'; this.error = String(e.message || e);
      return Promise.resolve();
    }
    this.proc.stdout.on('data', (c) => this._onData(c));
    this.proc.stderr.on('data', () => {});
    this.proc.on('exit', () => {
      this.status = this.status === 'error' ? 'error' : 'stopped';
      this.proc = null;
      for (const [, p] of this.pending) p.reject(new Error('MCP server exited'));
      this.pending.clear();
    });
    this.proc.on('error', (e) => { this.status = 'error'; this.error = String(e.message || e); });
    return this._rpc('initialize', {
      protocolVersion: '2024-11-05', capabilities: {},
      clientInfo: { name: 'harness-code', version: '0.5.0' },
    }, 20000)
      .then(() => { this._notify('notifications/initialized'); return this._rpc('tools/list', {}, 20000); })
      .then((r) => { this.tools = (r && r.tools) || []; this.status = 'running'; })
      .catch((e) => {
        this.status = 'error'; this.error = String((e && e.message) || e);
        try { this.proc && this.proc.kill(); } catch {}
      });
  }

  stop() { try { this.proc && this.proc.kill(); } catch {} this.proc = null; this.status = 'stopped'; this.tools = []; if (this.remote) this.remote.sessionId = null; }

  call(tool, args) {
    if (this.status !== 'running') return Promise.resolve({ error: 'MCP server "' + this.name + '" is not running' });
    const rpc = this.remote ? this._httpRpc.bind(this) : this._rpc.bind(this);
    return rpc('tools/call', { name: tool, arguments: args || {} }, 120000)
      .then((r) => {
        const parts = ((r && r.content) || []).map((c) => (c.type === 'text' ? c.text : '[' + c.type + ']'));
        const text = parts.join('\n').slice(0, 60000);
        return r && r.isError ? { error: text || 'tool reported an error' } : { result: text };
      })
      .catch((e) => ({ error: String((e && e.message) || e) }));
  }

  _onData(c) {
    this.buf += c.toString();
    let nl;
    while ((nl = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let m;
      try { m = JSON.parse(line); } catch { continue; }
      if (m.id != null && this.pending.has(m.id)) {
        const p = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) p.reject(new Error(m.error.message || JSON.stringify(m.error)));
        else p.resolve(m.result);
      }
    }
  }
  _send(obj) { try { this.proc && this.proc.stdin.write(JSON.stringify(obj) + '\n'); } catch {} }
  _notify(method, params) { this._send({ jsonrpc: '2.0', method, ...(params ? { params } : {}) }); }
  _rpc(method, params, timeout) {
    return new Promise((resolve, reject) => {
      const id = ++this.seq;
      const to = setTimeout(() => { this.pending.delete(id); reject(new Error(method + ' timed out')); }, timeout || 30000);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(to); resolve(v); },
        reject: (e) => { clearTimeout(to); reject(e); },
      });
      this._send({ jsonrpc: '2.0', id, method, params: params || {} });
    });
  }
}

module.exports = { McpClient };
