// Builds the Zabbix item map for a NEW Zabbix server. READ-ONLY against Zabbix: only apiinfo.version, user.login/user.logout (when a
// password is used), host.get and item.get are called.
//
//   Normally run through:  grafana-platform item-map        (uses ZABBIX_URL, ZABBIX_USER and the zabbix-password secret of the platform)
//   Directly:  ZABBIX_URL=… ZABBIX_USER=… ZABBIX_PASSWORD_FILE=/root/zbx.pw  node tools/zabbix-item-map.mjs --out map.json
//          or  ZABBIX_URL=… ZABBIX_TOKEN_FILE=/root/zbx.token                node tools/zabbix-item-map.mjs --out map.json
//
// Options
//   --out F                 where to write {"<lab id>": "<id on this Zabbix>"} (default ./zabbix-item-map.json)
//   --descriptors F         default config/zabbix-item-descriptors.json
//   --merge                 keep entries already in --out for ids not resolved in this run (hand-set ids survive a re-run)
//   --host LAB=PROD         the LAB host name LAB is called PROD on this Zabbix (repeatable; comma-separated also accepted)
//   --set LABID=ITEMID      an item id you verified yourself in Zabbix (repeatable); always wins
//   --search WORD           list hosts matching WORD and their items (to find ids by hand); writes nothing
//   --check                 only test the login (count visible hosts) and exit
//
// The NOC dashboards address Zabbix items by numeric id (queryType 3). config/zabbix-item-descriptors.json says which host + item key each
// LAB id stood for; this tool finds the same host + key here. It never guesses an id: a host or key that is missing or ambiguous is
// listed and the exit code is 3 (the file is still written with everything that WAS resolved). Descriptors with "item_key_candidates"
// (the SNMP uptime items behind the "UP" freshness signal) resolve to the FIRST candidate key that exists exactly once on that host;
// the chosen key is printed under REVIEW so you can confirm it.
import { readFileSync, writeFileSync, existsSync, renameSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const die = (m, c = 2) => { console.error('ERROR: ' + m); process.exit(c); };

export function parseCli(argv) {
  const a = { hosts: {}, sets: {}, merge: false, check: false };
  const kv = (v, into, what) => String(v || '').split(',').filter(Boolean).forEach((p) => {
    const i = p.indexOf('='); if (i < 1) die(`${what} expects NAME=VALUE, got "${p}"`);
    into[p.slice(0, i).trim()] = p.slice(i + 1).trim();
  });
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--merge') a.merge = true;
    else if (t === '--check') a.check = true;
    else if (t === '--host') kv(argv[++i], a.hosts, '--host');
    else if (t === '--set') kv(argv[++i], a.sets, '--set');
    else if (['--out', '--descriptors', '--search'].includes(t)) a[t.slice(2)] = argv[++i];
    else die(`unknown option ${t}`);
  }
  for (const [k, v] of Object.entries(a.sets)) if (!/^\d+$/.test(k) || !/^\d+$/.test(v)) die(`--set ${k}=${v}: both ids must be numeric`);
  return a;
}

/** JSON-RPC client. Session handling follows the server version: 6.4+ takes the session id / token as a Bearer header, older ones as "auth". */
export function client(url, fetchImpl = fetch) {
  let seq = 0, auth = null, version = null, headerAuth = true, session = false;
  const call = async (method, params, { noAuth = false } = {}) => {
    const body = { jsonrpc: '2.0', method, params, id: ++seq };
    const headers = { 'Content-Type': 'application/json-rpc' };
    if (auth && !noAuth) { if (headerAuth) headers.Authorization = `Bearer ${auth}`; else body.auth = auth; }
    const r = await fetchImpl(url, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(30000) });
    const text = await r.text();
    let j; try { j = JSON.parse(text); } catch { throw new Error(`${method}: HTTP ${r.status}, not a JSON-RPC answer (is ZABBIX_URL the api_jsonrpc.php endpoint?)`); }
    if (j.error) throw new Error(`${method}: ${j.error.message} ${j.error.data || ''}`.trim());
    return j.result;
  };
  return {
    call,
    async version() { version = await call('apiinfo.version', {}, { noAuth: true }); const [maj, min] = version.split('.').map(Number); headerAuth = maj > 6 || (maj === 6 && min >= 4); return version; },
    useToken(t) { auth = t; },
    async login(user, password) {
      const [maj, min] = (version || '7.0').split('.').map(Number);
      const params = maj > 5 || (maj === 5 && min >= 4) ? { username: user, password } : { user, password };
      auth = await call('user.login', params, { noAuth: true });
      session = true;
      return true;
    },
    async logout() { if (session) { session = false; try { await call('user.logout', []); } catch { /* session may already be gone */ } } },
  };
}

async function findHost(call, name) {
  let h = await call('host.get', { output: ['hostid', 'host', 'name'], filter: { host: [name] } });
  if (!h.length) h = await call('host.get', { output: ['hostid', 'host', 'name'], filter: { name: [name] } });
  return h.length === 1 ? h[0].hostid : (h.length ? 'AMBIGUOUS' : null);
}

export async function buildMap(descriptors, call, { hosts = {} } = {}) {
  const items = descriptors.items || descriptors;
  const hostIds = new Map(), map = {}, problems = [], review = [];
  for (const [labId, d] of Object.entries(items)) {
    if (d.unresolved) { problems.push(`${labId}: descriptor is unresolved (no data when captured) - used in ${(d.used_in || []).join('; ')}`); continue; }
    const target = hosts[d.host] || d.host;
    if (!hostIds.has(target)) hostIds.set(target, await findHost(call, target));
    const hid = hostIds.get(target);
    const label = target === d.host ? `host "${d.host}"` : `host "${target}" (LAB name ${d.host})`;
    if (!hid) { problems.push(`${labId}: ${label} not found (use --host ${d.host}=<name on this Zabbix>)`); continue; }
    if (hid === 'AMBIGUOUS') { problems.push(`${labId}: ${label} is ambiguous`); continue; }
    const keys = d.item_key_candidates || [d.item_key];
    let hit = null;
    const counts = [];
    for (const key of keys) {
      const found = await call('item.get', { output: ['itemid', 'key_', 'name'], hostids: [hid], filter: { key_: [key] } });
      counts.push(found.length);
      if (found.length === 1) { hit = { id: found[0].itemid, key }; break; }
    }
    if (!hit) {
      problems.push(keys.length > 1
        ? `${labId}: none of the candidate keys found exactly once on ${label} (${keys.map((k, i) => `${k}: ${counts[i] ?? 0}`).join(', ')}); find it with --search`
        : `${labId}: ${counts[0]} item(s) with key ${keys[0]} on ${label}`);
      continue;
    }
    map[labId] = hit.id;
    if (d.item_key_candidates) review.push(`${labId}: ${label} "${d.item || 'item'}" resolved to item ${hit.id} via key ${hit.key}`);
  }
  return { map, problems, review };
}

async function main() {
  const a = parseCli(process.argv.slice(2));
  const url = process.env.ZABBIX_URL || die('set ZABBIX_URL (…/api_jsonrpc.php)');
  const z = client(url);
  const ver = await z.version().catch((e) => die(`Zabbix API not reachable at ${url}: ${e.message}`, 4));
  console.log(`Zabbix API ${ver} at ${url}`);
  const token = process.env.ZABBIX_TOKEN || (process.env.ZABBIX_TOKEN_FILE ? readFileSync(process.env.ZABBIX_TOKEN_FILE, 'utf8').trim() : '');
  const pw = process.env.ZABBIX_PASSWORD || (process.env.ZABBIX_PASSWORD_FILE ? readFileSync(process.env.ZABBIX_PASSWORD_FILE, 'utf8').replace(/\r?\n$/, '') : '');
  if (token) z.useToken(token);
  else if (process.env.ZABBIX_USER && pw) await z.login(process.env.ZABBIX_USER, pw).catch((e) => die(`login as ${process.env.ZABBIX_USER} failed: ${e.message}`, 5));
  else die('credentials: set ZABBIX_TOKEN_FILE, or ZABBIX_USER with ZABBIX_PASSWORD / ZABBIX_PASSWORD_FILE');
  try {
    if (a.check) {
      const n = await z.call('host.get', { countOutput: true });
      console.log(`login OK${token ? ' (API token)' : ` as ${process.env.ZABBIX_USER}`}; ${n} host(s) visible to this user`);
      if (Number(n) === 0) { console.log('WARNING: this user sees no hosts: give its user group read permission on the monitored host groups'); process.exitCode = 6; }
      return;
    }
    if (a.search) {
      const hs = await z.call('host.get', { output: ['hostid', 'host', 'name'], search: { host: a.search, name: a.search }, searchByAny: true, limit: 20 });
      if (!hs.length) console.log(`no host matches "${a.search}"`);
      for (const h of hs) {
        console.log(`\nhost ${h.host}${h.name !== h.host ? ` (visible name ${h.name})` : ''}`);
        const its = await z.call('item.get', { output: ['itemid', 'key_', 'name', 'delay', 'lastclock'], hostids: [h.hostid], sortfield: 'key_', limit: 300 });
        for (const i of its) console.log(`  ${i.itemid.padStart(8)}  ${i.key_.padEnd(48)} every ${String(i.delay).padEnd(5)} last ${i.lastclock && i.lastclock !== '0' ? new Date(i.lastclock * 1000).toISOString() : 'never'}  ${i.name}`);
      }
      return;
    }
    const desc = JSON.parse(readFileSync(a.descriptors || join(ROOT, 'config', 'zabbix-item-descriptors.json'), 'utf8'));
    const out = a.out || 'zabbix-item-map.json';
    const { map, problems, review } = await buildMap(desc, z.call, { hosts: a.hosts });
    const previous = a.merge && existsSync(out) ? JSON.parse(readFileSync(out, 'utf8')) : {};
    const final = { ...previous, ...map, ...a.sets };
    const all = Object.keys(desc.items || desc);
    const still = problems.filter((p) => !(p.split(':')[0] in final));
    const tmp = join(dirname(out), `.${basename(out)}.tmp`);
    writeFileSync(tmp, JSON.stringify(Object.fromEntries(Object.entries(final).sort()), null, 2) + '\n', { mode: 0o640 });
    renameSync(tmp, out);
    const kept = Object.keys(previous).filter((k) => !(k in map) && !(k in a.sets)).length;
    console.log(`wrote ${out}: ${Object.keys(final).length} of ${all.length} item(s) mapped (${Object.keys(map).length} resolved now${kept ? `, ${kept} kept from the previous file` : ''}${Object.keys(a.sets).length ? `, ${Object.keys(a.sets).length} set by hand` : ''})`);
    if (review.length) { console.log('\nREVIEW (resolved through a candidate key - confirm in Zabbix that this is the SNMP uptime item of that router):'); review.forEach((r) => console.log('  - ' + r)); }
    if (still.length) { console.log(`\n${still.length} item(s) NOT mapped - nothing was guessed:`); still.forEach((p) => console.log('  - ' + p)); process.exitCode = 3; return; }
    console.log('all items mapped');
  } finally {
    await z.logout();
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => die(e.message, 1));
}
