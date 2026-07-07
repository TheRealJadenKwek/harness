'use strict';
// Minimal MCP (Model Context Protocol) client over stdio — newline-delimited
// JSON-RPC. Zero dependencies. One McpClient per configured server; its tools
// are advertised to the model as mcp__<server>__<tool>.
const { spawn } = require('child_process');

class McpClient {
  constructor(name, command, cwd) {
    this.name = name;
    this.command = command;
    this.cwd = cwd || null;
    this.proc = null;
    this.seq = 0;
    this.pending = new Map();
    this.tools = [];
    this.status = 'stopped';   // stopped | starting | running | error
    this.error = null;
    this.buf = '';
  }

  start() {
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

  stop() { try { this.proc && this.proc.kill(); } catch {} this.proc = null; this.status = 'stopped'; this.tools = []; }

  call(tool, args) {
    if (this.status !== 'running') return Promise.resolve({ error: 'MCP server "' + this.name + '" is not running' });
    return this._rpc('tools/call', { name: tool, arguments: args || {} }, 120000)
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
