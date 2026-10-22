import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

function mockZabbix(hosts, items) {
  return new Promise((resolve) => {
    const calls = [];
    const srv = createServer((req, res) => {
      let b = ''; req.on('data', (c) => (b += c)).on('end', () => {
        const q = JSON.parse(b); calls.push(q.method);
        if (req.headers.authorization !== 'Bearer test-token' && q.method !== 'apiinfo.version') { res.end(JSON.stringify({ jsonrpc: '2.0', error: { message: 'Not authorised' }, id: q.id })); return; }
        let result;
        if (q.method === 'apiinfo.version') result = '7.0.30';
        else if (q.method === 'host.get') result = hosts.filter((h) => (q.params.filter.host || []).includes(h.host) || (q.params.filter.name || []).includes(h.name || h.host));
        else if (q.method === 'item.get') result = items.filter((i) => q.params.hostids.includes(i.hostid) && q.params.filter.key_.includes(i.key_));
        else { res.end(JSON.stringify({ jsonrpc: '2.0', error: { message: 'method not allowed in test' }, id: q.id })); return; }
        res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ jsonrpc: '2.0', result, id: q.id }));
      });
    }).listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port, calls }));
  });
}

test('item map tool resolves host+key to the target ids, reports gaps, uses only read-only methods', async () => {
  const hosts = [{ hostid: '1', host: 'STC' }, { hostid: '2', host: 'SITE-A' }];
  const items = [{ itemid: '9001', hostid: '1', key_: 'icmpping' }, { itemid: '9002', hostid: '2', key_: 'icmpping' }];
  const { srv, port, calls } = await mockZabbix(hosts, items);
  const dir = mkdtempSync(join(tmpdir(), 'itemmap-'));
  writeFileSync(join(dir, 'desc.json'), JSON.stringify({ items: {
    100: { host: 'STC', item_key: 'icmpping' }, 101: { host: 'SITE-A', item_key: 'icmpping' }, 102: { host: 'NOPE', item_key: 'icmpping' },
    103: { host: 'STC', item_key: 'no.such.key' }, 104: { unresolved: true, used_in: ['dash | panel | UP'] } } }));
  const out = join(dir, 'map.json');
  const p = await new Promise((resolve) => {
    execFile(process.execPath, [join(ROOT, 'tools', 'zabbix-item-map.mjs'), '--descriptors', join(dir, 'desc.json'), '--out', out],
      { env: { ...process.env, ZABBIX_URL: `http://127.0.0.1:${port}/api_jsonrpc.php`, ZABBIX_TOKEN: 'test-token' }, encoding: 'utf8' },
      (err, stdout, stderr) => resolve({ status: err ? err.code : 0, stdout, stderr }));
  });
  srv.close();
  assert.equal(p.status, 3, p.stdout + p.stderr);
  assert.deepEqual(JSON.parse(readFileSync(out, 'utf8')), { 100: '9001', 101: '9002' });
  assert.match(p.stdout, /3 item\(s\) NOT mapped/);
  assert.match(p.stdout, /host "NOPE" not found/);
  assert.match(p.stdout, /0 item\(s\) with key no\.such\.key|0 item/);
  assert.match(p.stdout, /unresolved/);
  assert.ok(calls.every((m) => ['apiinfo.version', 'host.get', 'item.get'].includes(m)), 'only read-only methods: ' + calls.join(','));
});
