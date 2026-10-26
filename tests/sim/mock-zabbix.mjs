// SIMULATION ONLY. A Zabbix 7.0 JSON-RPC API stand-in for tests/sim (plain HTTP, like the production Zabbix at :8080).
// Hosts are the LAB WAN-edge hosts under PRODUCTION-style names (prefix "RYD-") so the --host rename path is exercised; every item key of
// config/zabbix-item-descriptors.json exists once per host, plus the SNMP uptime key system.net.uptime[sysUpTime.0].
// Item ids are synthetic (900000+) and mean nothing outside this simulation.
//   node mock-zabbix.mjs <port> <user> <password-file> <descriptors.json> [--plain-names]
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';

const [port, user, pwFile, descFile, ...flags] = process.argv.slice(2);
const PASSWORD = readFileSync(pwFile, 'utf8').trim();
const plain = flags.includes('--plain-names');
const desc = JSON.parse(readFileSync(descFile, 'utf8')).items;
const hosts = [], items = [];
let nextItem = 900000;
for (const d of Object.values(desc)) {
  if (!d.host) continue;
  const name = plain ? d.host : `RYD-${d.host}`;
  let h = hosts.find((x) => x.host === name);
  if (!h) { h = { hostid: String(10000 + hosts.length), host: name, name }; hosts.push(h); }
  for (const key of d.item_key ? [d.item_key] : [d.item_key_candidates[0]]) {
    if (!items.find((i) => i.hostid === h.hostid && i.key_ === key)) items.push({ itemid: String(nextItem++), hostid: h.hostid, key_: key, name: d.item || key, delay: '30s', lastclock: String(Math.floor(Date.now() / 1000)) });
  }
}
const sessions = new Set();
const calls = [];
createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)).on('end', () => {
    if (req.url === '/__calls') { res.end(JSON.stringify(calls)); return; }
    const q = JSON.parse(b); calls.push(q.method);
    const ok = (result) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ jsonrpc: '2.0', result, id: q.id })); };
    const err = (message, data = '') => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32602, message, data }, id: q.id })); };
    if (q.method === 'apiinfo.version') return req.headers.authorization ? err('Invalid params.', 'The "apiinfo.version" method must be called without authorization header.') : ok('7.0.30');
    if (q.method === 'user.login') return q.params.username === user && q.params.password === PASSWORD ? (() => { const s = 'sess' + Math.random().toString(16).slice(2); sessions.add(s); ok(s); })() : err('Invalid params.', 'Incorrect user name or password or account is temporarily blocked.');
    const tok = (req.headers.authorization || '').replace(/^Bearer /, '') || q.auth;
    if (!sessions.has(tok)) return err('Invalid params.', 'Session terminated, re-login, please.');
    if (q.method === 'user.logout') { sessions.delete(tok); return ok(true); }
    if (q.method === 'host.get') {
      if (q.params.countOutput) return ok(String(hosts.length));
      if (q.params.search) { const w = q.params.search.host || q.params.search.name; return ok(hosts.filter((h) => h.host.includes(w) || h.name.includes(w))); }
      const f = q.params.filter || {};
      return ok(hosts.filter((h) => (f.host && f.host.includes(h.host)) || (f.name && f.name.includes(h.name))));
    }
    // read-only: the Grafana Zabbix plugin's health check and the installer's Device Type step (all hosts are WAN routers)
    if (q.method === 'hostgroup.get') return ok([{ groupid: '1', name: 'WAN Routers', ...(q.params.selectHosts === 'count' ? { hosts: String(hosts.length) } : {}) }]);
    if (q.method === 'item.get') {
      const ids = q.params.itemids && [].concat(q.params.itemids).map(String); const hids = q.params.hostids && [].concat(q.params.hostids).map(String);
      return ok(items.filter((i) => (!ids || ids.includes(i.itemid)) && (!hids || hids.includes(i.hostid)) && (!q.params.filter?.key_ || q.params.filter.key_.includes(i.key_)))
        .map((i) => ({ ...i, value_type: '3', units: '', hosts: [{ hostid: i.hostid, name: (hosts.find((h) => h.hostid === i.hostid) || {}).name }] })));
    }
    // read-only data calls made by the real Grafana Zabbix plugin for panel queries: one synthetic value per minute
    if (q.method === 'history.get' || q.method === 'trend.get') {
      const now = Math.floor(Date.now() / 1000); const from = Number(q.params.time_from || now - 3600);
      const rows = []; for (const id of [].concat(q.params.itemids || []).map(String)) for (let t = from; t <= now; t += 60) rows.push({ itemid: id, clock: String(t), value: String(1000 + (t % 97)), ns: '0', value_min: '1', value_avg: '2', value_max: '3', num: '1' });
      return ok(rows);
    }
    err('Method not found.', `${q.method} is not allowed in the simulation (read-only)`);
  });
}).listen(Number(port), '127.0.0.1', () => console.log(`mock-zabbix on 127.0.0.1:${port} (${hosts.length} hosts, ${items.length} items)`));
