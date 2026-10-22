// SIMULATION ONLY. A stand-in for the Grafana HTTP API, started by the fake `systemctl start grafana-server` of tests/sim.
// It implements exactly the endpoints the grafana-platform content tools use, enforces basic auth with the admin password file that
// grafana.ini points at, reports the plugins that the installer really extracted into <data>/plugins, and runs REAL datasource health
// checks: Zabbix = JSON-RPC user.login with the stored user/password against the configured URL; ClickHouse = GET /ping.
// It proves the installer and content logic; it is NOT Grafana (rendering, query semantics, the plugins' own code are not exercised).
//   node mock-grafana.mjs <grafana.ini> <state.json>
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [iniPath, statePath] = process.argv.slice(2);
const ini = {};
let section = '';
for (const l of readFileSync(iniPath, 'utf8').split('\n')) {
  const m = l.match(/^\[(.+)\]$/); if (m) { section = m[1]; continue; }
  const kv = l.match(/^\s*([a-z_]+)\s*=\s*(.*)$/); if (kv) ini[`${section}.${kv[1]}`] = kv[2].trim();
}
const fileRef = (v) => { const m = /^\$__file\{(.+)\}$/.exec(v || ''); return m ? readFileSync(m[1], 'utf8').trim() : v; };
if (ini['server.protocol'] !== 'http') { console.error('mock-grafana serves http only (TLS is not simulated)'); process.exit(2); }
const PORT = Number(ini['server.http_port']), ADMIN = ini['security.admin_user'], PASS = fileRef(ini['security.admin_password']);
const PLUGINS = ini['paths.plugins'];
const VERSION = process.env.MOCK_GRAFANA_VERSION || '13.2.3';

const S = existsSync(statePath) ? JSON.parse(readFileSync(statePath, 'utf8')) : { folders: {}, ds: {}, dash: {}, playlists: {}, seq: 1 };
const save = () => writeFileSync(statePath, JSON.stringify(S, null, 1));

const plugins = () => (existsSync(PLUGINS) ? readdirSync(PLUGINS) : []).filter((d) => existsSync(join(PLUGINS, d, 'plugin.json')))
  .flatMap((d) => { const p = JSON.parse(readFileSync(join(PLUGINS, d, 'plugin.json'), 'utf8')); return [{ id: p.id, info: { version: p.info.version } }, ...(p.includes_ids || []).map((id) => ({ id, info: { version: p.info.version } }))]; });

async function dsHealth(d) {
  try {
    if (d.type === 'alexanderzobnin-zabbix-datasource') {
      const r = await fetch(d.url, { method: 'POST', headers: { 'Content-Type': 'application/json-rpc' }, body: JSON.stringify({ jsonrpc: '2.0', method: 'user.login', params: { username: d.jsonData.username, password: d.secure?.password || '' }, id: 1 }), signal: AbortSignal.timeout(5000) });
      const j = await r.json();
      return j.result ? { status: 'OK', message: `Zabbix API login OK as ${d.jsonData.username}` } : { status: 'ERROR', message: `Zabbix: ${j.error?.data || j.error?.message}` };
    }
    if (d.type === 'grafana-clickhouse-datasource') {
      const url = `${d.jsonData.secure ? 'https' : 'http'}://${d.jsonData.host}:${d.jsonData.port}/ping`;
      const r = await fetch(url, { headers: { 'X-ClickHouse-User': d.jsonData.username, 'X-ClickHouse-Key': d.secure?.password || '' }, signal: AbortSignal.timeout(5000) });
      return r.status === 200 ? { status: 'OK', message: 'ClickHouse /ping OK' } : { status: 'ERROR', message: `ClickHouse HTTP ${r.status} ${await r.text()}` };
    }
    return { status: 'ERROR', message: 'unknown type' };
  } catch (e) { return { status: 'ERROR', message: e.message }; }
}
const pub = (d) => { const { secure, ...rest } = d; return { ...rest, secureJsonFields: Object.fromEntries(Object.keys(secure || {}).map((k) => [k, true])) }; };

createServer((req, res) => {
  let body = ''; req.on('data', (c) => (body += c)).on('end', async () => {
    const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    const u = new URL(req.url, 'http://x'); const p = u.pathname; const m = req.method; const b = body ? JSON.parse(body) : null;
    if (p === '/api/health') return send(200, { database: 'ok', version: VERSION, commit: 'simulated' });
    const auth = req.headers.authorization || '';
    if (auth !== 'Basic ' + Buffer.from(`${ADMIN}:${PASS}`).toString('base64')) return send(401, { message: 'invalid username or password' });
    let r;
    if (p === '/api/plugins' && m === 'GET') return send(200, plugins());
    if (p === '/api/folders' && m === 'GET') return send(200, Object.values(S.folders));
    if (p === '/api/folders' && m === 'POST') { S.folders[b.uid] = { uid: b.uid, title: b.title, version: 1 }; save(); return send(200, S.folders[b.uid]); }
    if ((r = p.match(/^\/api\/folders\/([^/]+)$/))) { const f = S.folders[r[1]]; if (!f) return send(404, {}); if (m === 'PUT') { f.title = b.title; f.version++; save(); } return send(200, f); }
    if (p === '/api/datasources' && m === 'POST') { const id = S.seq++; S.ds[b.uid] = { ...b, id, version: 1, secure: b.secureJsonData || {} }; delete S.ds[b.uid].secureJsonData; save(); return send(200, { datasource: pub(S.ds[b.uid]) }); }
    if ((r = p.match(/^\/api\/datasources\/uid\/([^/]+)\/health$/))) { const d = S.ds[r[1]]; return d ? send(200, await dsHealth(d)) : send(404, {}); }
    if ((r = p.match(/^\/api\/datasources\/uid\/([^/]+)$/))) {
      const d = S.ds[r[1]]; if (!d) return send(404, { message: 'not found' });
      if (m === 'PUT') { const secure = b.secureJsonData ? { ...d.secure, ...b.secureJsonData } : d.secure; S.ds[r[1]] = { ...b, id: d.id, version: d.version + 1, secure }; delete S.ds[r[1]].secureJsonData; save(); }
      return send(200, pub(S.ds[r[1]]));
    }
    if ((r = p.match(/^\/api\/dashboards\/uid\/([^/]+)$/))) { const d = S.dash[r[1]]; return d ? send(200, { dashboard: d.dashboard, meta: { folderUid: d.folderUid } }) : send(404, { message: 'not found' }); }
    if (p === '/api/dashboards/db' && m === 'POST') {
      const uid = b.dashboard.uid, cur = S.dash[uid];
      if (cur && !b.overwrite) return send(412, { message: 'exists' });
      S.dash[uid] = { dashboard: { ...b.dashboard, id: cur?.dashboard.id || S.seq++, version: (cur?.dashboard.version || 0) + 1 }, folderUid: b.folderUid }; save();
      return send(200, { uid, status: 'success', version: S.dash[uid].dashboard.version });
    }
    if (p === '/api/search') { const fu = u.searchParams.get('folderUIDs'); const q = u.searchParams.get('query'); return send(200, Object.values(S.dash).filter((d) => (!fu || d.folderUid === fu) && (!q || d.dashboard.title.includes(q))).map((d) => ({ uid: d.dashboard.uid, title: d.dashboard.title, folderUid: d.folderUid }))); }
    if (p === '/api/playlists' && m === 'GET') return send(200, Object.values(S.playlists).map(({ uid, name, interval }) => ({ uid, name, interval })));
    if (p === '/api/playlists' && m === 'POST') { const uid = 'pl' + S.seq++; S.playlists[uid] = { ...b, uid }; save(); return send(200, S.playlists[uid]); }
    if ((r = p.match(/^\/api\/playlists\/([^/]+)$/))) { if (!S.playlists[r[1]]) return send(404, {}); if (m === 'PUT') { S.playlists[r[1]] = { ...b, uid: r[1] }; save(); } return send(200, S.playlists[r[1]]); }
    if (p === '/api/v1/provisioning/alert-rules') return send(200, []);
    send(404, { message: `mock-grafana: ${m} ${p} not implemented` });
  });
}).listen(PORT, '127.0.0.1', () => console.log(`mock-grafana listening on 127.0.0.1:${PORT}`));
