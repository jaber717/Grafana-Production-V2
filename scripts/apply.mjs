// Idempotently applies this repository to an EXISTING Grafana through its HTTP API.
//   node scripts/apply.mjs [--env-file F] [--item-map F] [--dry-run] [--datasource-only] [--rotate-secrets] [--skip-datasources] [--skip-dashboards] [--skip-playlists] [--allow-title-conflicts]
//   --env-file  environment (KEY=VALUE; default env/lab.env.example)   --item-map  Zabbix item id map for the NOC dashboards (docs/ZABBIX-ITEM-MAP.md)
//   --rotate-secrets  also pushes the password from the environment into a datasource whose definition is unchanged (secret rotation)
//
// Idempotent by construction: every object is compared with the live one first and written ONLY when it differs
// (a second run reports "unchanged" for everything and writes nothing - no new dashboard versions, no duplicates).
//   folders      created when missing (matched by uid); a changed title is updated
//   datasources  matched by uid; created when missing, updated when the managed fields differ. Secrets come from the
//                environment (ZABBIX_GRAFANA_PASSWORD, CLICKHOUSE_RO_PASSWORD). An update that WOULD need a secret and has none
//                is refused instead of risking an empty password.
//   dashboards   matched by uid; `id`/`version` are ignored in the comparison; placed in the folder named by the directory
//   playlists    matched by name
// Duplicates: a dashboard whose TITLE already exists in the target folder under a DIFFERENT uid is refused (it would show up twice)
// unless --allow-title-conflicts is given.
import { api, get, URL_, parseArgs, readJson, repoPlugins, normalizeDashboard, canonical, dsComparable, ApiError, fail } from './lib/grafana.mjs';
import { loadContext, effectiveDashboards, effectivePlaylists } from './lib/content.mjs';
import { deferredDatasources, deferReason } from './lib/envcfg.mjs';

const args = parseArgs(process.argv.slice(2));
const CTX = loadContext(args);
const DRY = !!args['dry-run'];
const SECRET_ENV = { 'zabbix-lab': 'ZABBIX_GRAFANA_PASSWORD', 'netflow-clickhouse': 'CLICKHOUSE_RO_PASSWORD' };
const SECRET_KEY = { 'zabbix-lab': 'password', 'netflow-clickhouse': 'password' };
// SANDBOX MODE (tests only): APPLY_SANDBOX_ENDPOINTS=1 rewrites every datasource endpoint to a dead loopback address so that a throw-away
// Grafana can never contact the real Zabbix / ClickHouse (a health check with a dummy password would be a failed login there).
// Refused unless GRAFANA_URL is loopback.
const SANDBOX = process.env.APPLY_SANDBOX_ENDPOINTS === '1';
if (SANDBOX && !new RegExp('^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:|/|$)').test(URL_)) fail('APPLY_SANDBOX_ENDPOINTS=1 is only allowed against a loopback GRAFANA_URL', 2);
const sandbox = (d) => (SANDBOX ? { ...d, url: d.url ? 'http://127.0.0.1:9/' : d.url, jsonData: { ...d.jsonData, ...(d.jsonData.host ? { host: '127.0.0.1' } : {}) } } : d);
const tally = { created: 0, updated: 0, unchanged: 0, refused: 0, skipped: 0 };
const say = (kind, what) => { console.log(`${kind.padEnd(9)} ${what}`); if (kind in tally) tally[kind]++; };
const act = async (fn) => { if (!DRY) await fn(); };

const health = await get('/api/health').catch((e) => fail(`Grafana is not reachable at ${URL_}: ${e.message}`));
if (health.database !== 'ok') fail(`Grafana health is ${JSON.stringify(health)}`);
console.log(`Grafana ${health.version} at ${URL_}${DRY ? '   [DRY RUN: nothing is written]' : ''}`);

// ---- required plugins ----------------------------------------------------------------------------------------
const installed = new Map((await get('/api/plugins?core=0')).map((p) => [p.id, p.info?.version]));
for (const p of repoPlugins()) {
  if (!installed.has(p.id)) fail(`required plugin ${p.id} ${p.version} is not installed on this Grafana (see docs/installation.md, plugins/plugins.txt)`);
  if (installed.get(p.id) !== p.version) console.log(`WARNING   plugin ${p.id}: installed ${installed.get(p.id)}, repository records ${p.version}`);
}

// ---- folders ---------------------------------------------------------------------------------------------------
const folders = readJson('config/folders.json');
const liveFolders = new Map((await get('/api/folders')).map((f) => [f.uid, f]));
if (!args['skip-dashboards'] && !args['datasource-only']) {
  for (const f of folders) {
    const cur = liveFolders.get(f.uid);
    if (!cur) { await act(() => api('POST', '/api/folders', f)); say('created', `folder ${f.uid} "${f.title}"`); }
    else if (cur.title !== f.title) { await act(async () => { const full = await get(`/api/folders/${f.uid}`); await api('PUT', `/api/folders/${f.uid}`, { title: f.title, version: full.version, overwrite: true }); }); say('updated', `folder ${f.uid} title "${cur.title}" -> "${f.title}"`); }
    else say('unchanged', `folder ${f.uid}`);
  }
}

// ---- datasources -----------------------------------------------------------------------------------------------
if (!args['skip-datasources']) {
  for (const uid of deferredDatasources(CTX.env)) say('skipped', `datasource ${uid}: deferred by configuration (${deferReason(uid)})`);
  for (const want of CTX.datasources.map(sandbox)) {
    const cur = await get(`/api/datasources/uid/${want.uid}`, { allow404: true });
    const envName = SECRET_ENV[want.uid];
    const secret = envName ? process.env[envName] : undefined;
    const body = { uid: want.uid, name: want.name, type: want.type, access: want.access, url: want.url, isDefault: want.isDefault, basicAuth: want.basicAuth, jsonData: want.jsonData };
    if (!cur) {
      if (!secret && envName) { say('refused', `datasource ${want.uid}: missing on this Grafana and ${envName} is not set (needed to create it)`); continue; }
      await act(() => api('POST', '/api/datasources', { ...body, ...(secret ? { secureJsonData: { [SECRET_KEY[want.uid]]: secret } } : {}) }));
      say('created', `datasource ${want.uid} (${want.name})`);
    } else if (canonical(dsComparable(cur)) === canonical(dsComparable(want))) {
      if (args['rotate-secrets'] && secret) {
        await act(() => api('PUT', `/api/datasources/uid/${want.uid}`, { ...body, id: cur.id, version: cur.version, secureJsonData: { [SECRET_KEY[want.uid]]: secret } }));
        say('updated', `datasource ${want.uid} (secret rotated)`);
      } else say('unchanged', `datasource ${want.uid}`);
    } else {
      if (!secret && envName) { say('refused', `datasource ${want.uid}: differs from the repository and ${envName} is not set; refusing to rewrite it without the secret`); continue; }
      await act(() => api('PUT', `/api/datasources/uid/${want.uid}`, { ...body, id: cur.id, version: cur.version, ...(secret ? { secureJsonData: { [SECRET_KEY[want.uid]]: secret } } : {}) }));
      say('updated', `datasource ${want.uid}`);
    }
    if (!DRY && (cur || secret)) { const h = await get(`/api/datasources/uid/${want.uid}/health`).catch((e) => ({ status: 'ERROR', message: e.message })); console.log(`          health: ${h.status} ${h.message || ''}`); }
  }
}
if (args['datasource-only']) { summary(); process.exit(tally.refused ? 3 : 0); }

// ---- dashboards ------------------------------------------------------------------------------------------------
if (!args['skip-dashboards']) {
  const known = new Set(folders.map((f) => f.uid));
  for (const { file, folderDir, dashboard, state, reason } of effectiveDashboards(CTX)) {
    if (state !== 'ok') { say(state, `${file}: ${reason}`); continue; }
    if (!known.has(folderDir)) { say('refused', `${file}: directory "${folderDir}" is not a folder in config/folders.json`); continue; }
    const want = normalizeDashboard(dashboard);
    const cur = await get(`/api/dashboards/uid/${dashboard.uid}`, { allow404: true });
    if (!cur) {
      const clash = (await get(`/api/search?type=dash-db&folderUIDs=${folderDir}&query=${encodeURIComponent(dashboard.title)}`)).filter((h) => h.title === dashboard.title && h.uid !== dashboard.uid);
      if (clash.length && !args['allow-title-conflicts']) { say('refused', `${file}: a dashboard titled "${dashboard.title}" already exists in folder ${folderDir} with uid ${clash[0].uid}; applying would create a duplicate`); continue; }
      await act(() => api('POST', '/api/dashboards/db', { dashboard: { ...dashboard, id: null }, folderUid: folderDir, overwrite: false, message: 'apply.mjs: create' }));
      say('created', `dashboard ${dashboard.uid} -> ${folderDir}`);
    } else if (canonical(normalizeDashboard(cur.dashboard)) === canonical(want) && (cur.meta.folderUid || '') === folderDir) {
      say('unchanged', `dashboard ${dashboard.uid}`);
    } else {
      await act(() => api('POST', '/api/dashboards/db', { dashboard: { ...dashboard, id: cur.dashboard.id, version: cur.dashboard.version }, folderUid: folderDir, overwrite: true, message: 'apply.mjs: update' }));
      say('updated', `dashboard ${dashboard.uid}${(cur.meta.folderUid || '') !== folderDir ? ` (moved ${cur.meta.folderUid || 'General'} -> ${folderDir})` : ''}`);
    }
  }
}

// ---- playlists -------------------------------------------------------------------------------------------------
if (!args['skip-playlists']) {
  const lists = await get('/api/playlists');
  for (const { playlist: want, state, reason } of effectivePlaylists(CTX)) {
    if (state !== 'ok') { say('skipped', `playlist "${want.name}": ${reason}`); continue; }
    const hit = lists.find((p) => p.name === want.name);
    if (!hit) { await act(() => api('POST', '/api/playlists', want)); say('created', `playlist "${want.name}"`); continue; }
    const cur = await get(`/api/playlists/${hit.uid}`);
    if (cur.interval === want.interval && canonical(cur.items) === canonical(want.items)) say('unchanged', `playlist "${want.name}"`);
    else { await act(() => api('PUT', `/api/playlists/${hit.uid}`, { ...want, uid: hit.uid })); say('updated', `playlist "${want.name}"`); }
  }
}
summary();
process.exit(tally.refused ? 3 : 0);

function summary() {
  console.log(`\n${DRY ? 'would apply' : 'applied'}: ${tally.created} created, ${tally.updated} updated, ${tally.unchanged} unchanged, ${tally.refused} refused${tally.skipped ? `, ${tally.skipped} skipped` : ''}`);
  if (tally.refused) console.log('Some objects were refused (see above); fix the cause and re-run. Exit code 3.');
}
