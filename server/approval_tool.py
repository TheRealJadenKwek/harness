#!/usr/bin/env python3
"""MCP permission-prompt tool for Harness (stdio, stdlib-only).

Claude Code invokes this (via --permission-prompt-tool) whenever a gated tool
use needs permission in Ask mode. We forward the request to the local harness
server, which shows it on the user's phone and blocks until they decide —
or until the timeout, which denies. The CLI treats our JSON reply as the
verdict: {"behavior":"allow","updatedInput":…} or {"behavior":"deny","message":…}.
"""
import json, os, sys, urllib.request

PORT = os.environ.get('HARNESS_PORT', '8787')
THREAD = os.environ.get('HARNESS_THREAD_ID', '')


def send(obj):
    sys.stdout.write(json.dumps(obj) + '\n')
    sys.stdout.flush()


def decide(args):
    body = json.dumps({'thread_id': THREAD,
                       'tool_name': args.get('tool_name') or '?',
                       'input': args.get('input') or {}}).encode()
    req = urllib.request.Request('http://127.0.0.1:%s/internal/approval' % PORT,
                                 data=body, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=660) as r:
            d = json.load(r)
    except Exception as e:
        return {'behavior': 'deny', 'message': 'harness approval relay failed: %s' % e}
    if d.get('decision') == 'allow':
        return {'behavior': 'allow', 'updatedInput': args.get('input') or {}}
    return {'behavior': 'deny', 'message': d.get('message') or 'Denied from the Harness app'}


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        m = json.loads(line)
    except Exception:
        continue
    mid, meth = m.get('id'), m.get('method')
    if meth == 'initialize':
        send({'jsonrpc': '2.0', 'id': mid, 'result': {
            'protocolVersion': (m.get('params') or {}).get('protocolVersion', '2024-11-05'),
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'harness_approval', 'version': '1.0'}}})
    elif meth == 'tools/list':
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'tools': [{
            'name': 'approve',
            'description': 'Relay a gated tool use to the Harness phone app for approval.',
            'inputSchema': {'type': 'object',
                            'properties': {'tool_name': {'type': 'string'},
                                           'input': {'type': 'object'},
                                           'tool_use_id': {'type': 'string'}},
                            'additionalProperties': True}}]}})
    elif meth == 'tools/call':
        res = decide((m.get('params') or {}).get('arguments') or {})
        send({'jsonrpc': '2.0', 'id': mid,
              'result': {'content': [{'type': 'text', 'text': json.dumps(res)}]}})
    elif mid is not None:
        send({'jsonrpc': '2.0', 'id': mid, 'result': {}})
