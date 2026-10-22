// Release 2.0 additions to tools/zabbix-item-map.mjs: password login (what `grafana-platform item-map` uses), session handling per
// Zabbix version, --host renames, --set, --merge, candidate keys for the SNMP uptime items, --check, --search. Read-only methods only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TOOL = join(ROOT, 'tools', 'zabbix-item-map.mjs');

function zabbix({ version = '7.0.30', hosts, items }) {
  return new Promise((resolve) => {
    const calls = [], sessions = new Set();
    const srv = createServer((req, res) => {
      let b = ''; req.on('data', (c) => (b += c)).on('end', () => {
        const q = JSON.parse(b); calls.push({ m: q.method, header: !!req.headers.authorization, bodyAuth: !!q.auth, params: q.params });
        const ok = (result) => res.end(JSON.stringify({ jsonrpc: '2.0', result, id: q.id }));
        const err = (data) => res.end(JSON.stringify({ jsonrpc: '2.0', error: { message: 'Invalid params.', data }, id: q.id }));
        if (q.method === 'apiinfo.version') return req.headers.authorization || q.auth ? err('must be called without auth') : ok(version);
        if (q.method === 'user.login') {
          const u = q.params.username ?? q.params.user;
          if ((version >= '5.4' ? !('username' in q.params) : !('user' in q.params))) return err('wrong login parameter name for this version');
          return u === 'ro' && q.params.password === 'pw' ? (sessions.add('S1'), ok('S1')) : err('Incorrect user name or password');
        }
        const tok = (req.headers.authorization || '').replace('Bearer ', '') || q.auth;
        if (!sessions.has(tok)) return err('Not authorised.');
        if (q.method === 'user.logout') { sessions.delete(tok); return ok(true); }
        if (q.method === 'host.get') {
          if (q.params.countOutput) return ok(String(hosts.length));
          if (q.params.search) return ok(hosts.filter((h) => h.host.includes(q.params.search.host)));
          const f = q.params.filter; return ok(hosts.filter((h) => (f.host || []).includes(h.host) || (f.name || []).includes(h.name)));
        }
        if (q.method === 'item.get') return ok(items.filter((i) => q.params.hostids.includes(i.hostid) && (!q.params.filter || q.params.filter.key_.includes(i.key_))));
        err('not allowed in test');
      });
    }).listen(0, '127.0.0.1', () => resolve({ srv, url: `http://127.0.0.1:${srv.address().port}/api_jsonrpc.php`, calls, sessions }));
  });
}
const run = (args, env) => new Promise((resolve) => execFile(process.execPath, [TOOL, ...args], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8', timeout: 30000 }, (e, stdout, stderr) => resolve({ rc: e ? e.code : 0, out: stdout + stderr })));

const dir = mkdtempSync(join(tmpdir(), 'v2map-'));
const DESC = join(dir, 'desc.json');
writeFileSync(DESC, JSON.stringify({ items: {
  100: { host: 'SITE-A', item_key: 'icmpping' },
  101: { host: 'SITE-A', item: 'SNMP uptime', item_key_candidates: ['system.net.uptime[sysUpTime.0]', 'system.hw.uptime[hrSystemUptime.0]'], needs_review: true },
  102: { host: 'STC', item_key: 'icmpping' },
} }));
const HOSTS = [{ hostid: '1', host: 'RYD-SITE-A', name: 'Riyadh WAN A' }, { hostid: '2', host: 'STC', name: 'STC' }];
const ITEMS = [{ itemid: '7001', hostid: '1', key_: 'icmpping' }, { itemid: '7002', hostid: '1', key_: 'system.hw.uptime[hrSystemUptime.0]' }, { itemid: '7003', hostid: '2', key_: 'icmpping' }];

test('password login (7.x: header session), host rename, candidate key with REVIEW line, logout, read-only', async () => {
  const z = await zabbix({ hosts: HOSTS, items: ITEMS });
  const out = join(dir, 'm1.json');
  const r = await run(['--descriptors', DESC, '--out', out, '--host', 'SITE-A=RYD-SITE-A'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  z.srv.close();
  assert.equal(r.rc, 0, r.out);
  assert.deepEqual(JSON.parse(readFileSync(out, 'utf8')), { 100: '7001', 101: '7002', 102: '7003' });
  assert.match(r.out, /REVIEW[\s\S]*101: host "RYD-SITE-A" \(LAB name SITE-A\) "SNMP uptime" resolved to item 7002 via key system\.hw\.uptime\[hrSystemUptime\.0\]/);
  assert.ok(z.calls.filter((c) => !['apiinfo.version', 'user.login'].includes(c.m)).every((c) => c.header && !c.bodyAuth), '7.x uses the Authorization header');
  assert.equal(z.calls.at(-1).m, 'user.logout', 'session is closed');
  assert.equal(z.sessions.size, 0);
  assert.ok(z.calls.every((c) => ['apiinfo.version', 'user.login', 'user.logout', 'host.get', 'item.get'].includes(c.m)));
  assert.ok(!r.out.includes('pw'), 'password never printed');
});

test('Zabbix 6.0: "auth" in the body, and visible-name host matching', async () => {
  const z = await zabbix({ version: '6.0.40', hosts: HOSTS, items: ITEMS });
  const out = join(dir, 'm2.json');
  const r = await run(['--descriptors', DESC, '--out', out, '--host', 'SITE-A=Riyadh WAN A'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  z.srv.close();
  assert.equal(r.rc, 0, r.out);
  assert.ok(z.calls.filter((c) => c.m === 'host.get').every((c) => c.bodyAuth && !c.header));
});

test('unresolvable items: exit 3, nothing guessed; --set and --merge complete the map without losing hand-set ids', async () => {
  const z = await zabbix({ hosts: HOSTS, items: ITEMS });
  const out = join(dir, 'm3.json');
  let r = await run(['--descriptors', DESC, '--out', out], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  assert.equal(r.rc, 3, r.out);
  assert.match(r.out, /host "SITE-A" not found \(use --host SITE-A=<name on this Zabbix>\)/);
  assert.deepEqual(JSON.parse(readFileSync(out, 'utf8')), { 102: '7003' });
  r = await run(['--descriptors', DESC, '--out', out, '--set', '100=8100', '--set', '101=8101'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  assert.equal(r.rc, 0, r.out);
  r = await run(['--descriptors', DESC, '--out', out, '--merge'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  z.srv.close();
  assert.equal(r.rc, 0, r.out);
  assert.deepEqual(JSON.parse(readFileSync(out, 'utf8')), { 100: '8100', 101: '8101', 102: '7003' }, '--merge keeps the hand-set ids');
  assert.match(r.out, /2 kept from the previous file/);
});

test('--check: wrong password fails clearly; right password reports visible hosts', async () => {
  const z = await zabbix({ hosts: HOSTS, items: ITEMS });
  let r = await run(['--check'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'bad' });
  assert.equal(r.rc, 5); assert.match(r.out, /login as ro failed: .*Incorrect user name or password/);
  r = await run(['--check'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  assert.equal(r.rc, 0); assert.match(r.out, /login OK as ro; 2 host\(s\) visible/);
  r = await run(['--search', 'RYD'], { ZABBIX_URL: z.url, ZABBIX_USER: 'ro', ZABBIX_PASSWORD: 'pw' });
  z.srv.close();
  assert.match(r.out, /host RYD-SITE-A \(visible name Riyadh WAN A\)[\s\S]*7002 +system\.hw\.uptime/);
});

test('the shipped descriptors have no unresolved entry left: every NOC item can be resolved from Zabbix', () => {
  const d = JSON.parse(readFileSync(join(ROOT, 'config', 'zabbix-item-descriptors.json'), 'utf8')).items;
  assert.equal(Object.keys(d).length, 47);
  for (const [id, x] of Object.entries(d)) assert.ok(x.host && (x.item_key || x.item_key_candidates?.length), id);
  assert.equal(Object.values(d).filter((x) => x.needs_review).length, 7);
});
