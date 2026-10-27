// Updates ONE dashboard - "NOC — Command Center" (uid noc-command-center) - in a running Grafana, through its HTTP API, and nothing else.
//   node scripts/update-command-center.mjs --env-file F --backup-dir D [--dry-run]
//   node scripts/update-command-center.mjs --env-file F --backup-dir D --restore <backup file>
//
// What it does, in this order:
//   1. reads (GET only): Grafana health, the NOC folder, the Zabbix data source the dashboard will use (must exist; never written)
//   2. fingerprints every OTHER dashboard (uid, version, folder, content hash), every data source (full definition incl. version) and the
//      installed plugins (id, version)
//   3. renders this release's Command Center (placeholders, adopted Zabbix data source uid, saved Device Type host groups)
//   4. unchanged -> stops (no write, no backup, no new version).  Different -> saves the CURRENT JSON to <backup-dir>/ (and reads the
//      file back), then writes ONLY this uid with the live version number (optimistic lock: a concurrent edit makes the write fail, nothing is lost)
//   5. fingerprints again and compares: all other dashboards, all data sources and all plugins must be identical; exit 4 if anything differs
// The uid, the folder and therefore the URL (/d/noc-command-center/...) are kept. Never touches: other dashboards, folders, data sources,
// plugins, grafana.ini, provisioning, playlists, alerting, users. Grafana is not restarted (this tool has no way to).
// Refuses (exit 3, nothing written) when the Command Center would be deployed with a "setup incomplete" notice instead of the real content
// (Zabbix not connected / data source missing), or when the folder or the Zabbix data source it needs does not exist.
import { mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, chmodSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { api, get, URL_, parseArgs, normalizeDashboard, canonical, sha256, stamp, fail } from './lib/grafana.mjs';
import { loadContext, effectiveDashboards } from './lib/content.mjs';
import { adoptedZabbixUid } from './lib/envcfg.mjs';

const UID = 'noc-command-center';
const args = parseArgs(process.argv.slice(2));
const DRY = !!args['dry-run'];
const BACKUPS = resolve(args['backup-dir'] || 'backups/command-center');
const say = (k, m) => console.log(`${k.padEnd(10)} ${m}`);
const stop = (m, code = 3) => { say('refused', m); console.log('\nNothing was written to Grafana.'); process.exit(code); };

const health = await get('/api/health').catch((e) => fail(`Grafana is not reachable at ${URL_}: ${e.message}`));
if (health.database !== 'ok') fail(`Grafana health is ${JSON.stringify(health)}`);
console.log(`Grafana ${health.version} at ${URL_}${DRY ? '   [DRY RUN: nothing is written]' : ''}`);

/** What must stay exactly as it is. */
async function fingerprint() {
  const dashboards = {};
  for (const h of await get('/api/search?type=dash-db&limit=5000')) {
    if (h.uid === UID) continue;
    const full = await get(`/api/dashboards/uid/${h.uid}`);
    dashboards[h.uid] = `v${full.dashboard.version} folder=${full.meta.folderUid || ''} ${sha256(canonical(normalizeDashboard(full.dashboard))).slice(0, 16)}`;
  }
  const datasources = {};
  for (const d of await get('/api/datasources')) datasources[d.uid] = `v${d.version} ${sha256(canonical(d)).slice(0, 16)}`;
  const plugins = {};
  for (const p of await get('/api/plugins?core=0')) plugins[p.id] = p.info?.version;
  return { dashboards, datasources, plugins };
}
function diff(a, b) {
  const out = [];
  for (const kind of Object.keys(a)) {
    for (const k of new Set([...Object.keys(a[kind]), ...Object.keys(b[kind])])) if (a[kind][k] !== b[kind][k]) out.push(`${kind} ${k}: ${a[kind][k] ?? '(absent)'} -> ${b[kind][k] ?? '(absent)'}`);
  }
  return out;
}

function backup(cur) {
  mkdirSync(BACKUPS, { recursive: true, mode: 0o700 }); chmodSync(BACKUPS, 0o700);
  const file = join(BACKUPS, `${UID}-v${cur.dashboard.version}-${stamp()}.json`);
  const text = JSON.stringify(cur, null, 2) + '\n';
  writeFileSync(file, text, { mode: 0o600 });
  if (sha256(readFileSync(file, 'utf8')) !== sha256(text)) fail(`backup ${file} could not be read back; nothing was changed`, 5);
  const old = readdirSync(BACKUPS).filter((f) => f.startsWith(UID + '-') && f.endsWith('.json')).sort();
  for (const f of old.slice(0, Math.max(0, old.length - 20))) rmSync(join(BACKUPS, f));   // keep the newest 20
  return file;
}

const before = await fingerprint();
say('read', `${Object.keys(before.dashboards).length} other dashboards, ${Object.keys(before.datasources).length} data sources, ${Object.keys(before.plugins).length} plugins fingerprinted`);
const cur = await get(`/api/dashboards/uid/${UID}`, { allow404: true });
let want, folderUid, action;

if (args.restore) {
  // roll back: put a saved backup (full API response) back under the same uid
  const saved = JSON.parse(readFileSync(resolve(args.restore), 'utf8'));
  if (saved?.dashboard?.uid !== UID) stop(`${args.restore} is not a backup of ${UID}`);
  want = saved.dashboard; folderUid = saved.meta?.folderUid || 'noc';
} else {
  const CTX = loadContext(args);
  const cand = effectiveDashboards(CTX).find((d) => d.dashboard.uid === UID);
  if (!cand) stop(`this release has no dashboard ${UID}`);
  if (cand.state !== 'ok') stop(`the Command Center would be deployed as "${cand.state}" (${cand.reason}); keep the working one - fix the cause first`);
  const adopted = adoptedZabbixUid(CTX.env);
  const dsUid = adopted || 'zabbix-lab';
  const ds = await get(`/api/datasources/uid/${dsUid}`, { allow404: true });
  if (!ds) stop(`the Zabbix data source ${dsUid} does not exist in Grafana`);
  if (ds.type !== 'alexanderzobnin-zabbix-datasource') stop(`data source ${dsUid} is of type ${ds.type}, not Zabbix`);
  want = cand.dashboard; folderUid = cand.folderDir;
  say('read', `Zabbix data source ${dsUid} "${ds.name}" exists (read only, never modified)`);
}
if (!(await get(`/api/folders/${folderUid}`, { allow404: true }))) stop(`folder ${folderUid} does not exist in Grafana (this tool never creates folders; run 'sudo ./install.sh --dashboards' once)`);

if (!cur) {
  action = 'created';
  say('create', `${UID} -> folder ${folderUid} (it did not exist)`);
  if (!DRY) await api('POST', '/api/dashboards/db', { dashboard: { ...want, id: null }, folderUid, overwrite: false, message: `update-command-center ${args.restore ? 'restore' : 'create'}` });
} else if (canonical(normalizeDashboard(cur.dashboard)) === canonical(normalizeDashboard(want)) && (cur.meta.folderUid || '') === folderUid) {
  action = 'unchanged';
  say('unchanged', `${UID} already equals this release (no backup, no write, version stays v${cur.dashboard.version})`);
} else {
  action = 'updated';
  if (DRY) say('would', `back up ${UID} v${cur.dashboard.version} and update it`);
  else {
    const file = backup(cur);
    say('backup', `${file}`);
    await api('POST', '/api/dashboards/db', { dashboard: { ...want, id: cur.dashboard.id, version: cur.dashboard.version }, folderUid, overwrite: false, message: `update-command-center ${args.restore ? 'restore' : 'update'}` });
    say('updated', `${UID} v${cur.dashboard.version} -> v${cur.dashboard.version + 1}`);
  }
}

let problems = [];
if (!DRY) {
  const now = await get(`/api/dashboards/uid/${UID}`);
  if (canonical(normalizeDashboard(now.dashboard)) !== canonical(normalizeDashboard(want))) problems.push('the Command Center in Grafana differs from what was written');
  if (cur && now.meta.url !== cur.meta.url) problems.push(`URL changed: ${cur.meta.url} -> ${now.meta.url}`);
  say('verified', `uid ${UID}, URL ${now.meta.url}, ${now.dashboard.panels.length} panels, folder ${now.meta.folderUid}`);
}
const after = await fingerprint();
const changed = diff(before, after);
if (changed.length) problems.push(...changed.map((c) => `CHANGED ${c}`)); else say('verified', 'every other dashboard (uid, version, folder, content), every data source and every plugin is identical to before');
console.log(`\n${action}: ${UID}${problems.length ? '' : '; nothing else changed'}`);
if (problems.length) { console.log('PROBLEMS:\n  ' + problems.join('\n  ')); process.exit(4); }
