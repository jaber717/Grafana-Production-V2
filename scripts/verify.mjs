// READ-ONLY verification that a Grafana equals this repository. Performs GET requests only.
//   node scripts/verify.mjs [--json] [--skip-datasources]
// Checks: health + version, required plugins (id+version), folders, datasource definitions (+ their /health), every dashboard
// (normalized: id/version ignored), the playlist, and that repository-managed folders contain no unmanaged dashboards.
// Exit 0 = PASS (WARN allowed), 1 = FAIL.
import { get, URL_, parseArgs, readJson, repoPlugins, normalizeDashboard, canonical, dsComparable, fail } from './lib/grafana.mjs';
import { loadContext, effectiveDashboards, effectivePlaylists } from './lib/content.mjs';
import { deferredDatasources, deferReason } from './lib/envcfg.mjs';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from './lib/grafana.mjs';

const args = parseArgs(process.argv.slice(2));
const CTX = loadContext(args);
const out = []; let failN = 0, warnN = 0;
const rec = (level, what, detail = '') => { out.push({ level, what, detail }); if (level === 'FAIL') failN++; if (level === 'WARN') warnN++; if (!args.json) console.log(`[${level}] ${what}${detail ? ' - ' + detail : ''}`); };

const health = await get('/api/health').catch((e) => fail(`Grafana is not reachable at ${URL_}: ${e.message}`));
const wantVersion = process.env.GRAFANA_VERSION_OVERRIDE || readFileSync(join(ROOT, 'VERSIONS.env'), 'utf8').match(/^GRAFANA_VERSION=(.+)$/m)?.[1];
rec(health.database === 'ok' ? 'PASS' : 'FAIL', 'health', `database=${health.database}`);
rec(health.version === wantVersion ? 'PASS' : 'WARN', 'Grafana version', `live ${health.version}, repository ${wantVersion}`);

const installed = new Map((await get('/api/plugins?core=0')).map((p) => [p.id, p.info?.version]));
for (const p of repoPlugins()) rec(installed.get(p.id) === p.version ? 'PASS' : installed.has(p.id) ? 'WARN' : 'FAIL', `plugin ${p.id}`, `live ${installed.get(p.id) || 'missing'}, repository ${p.version}`);

const folders = readJson('config/folders.json');
const liveFolders = new Map((await get('/api/folders')).map((f) => [f.uid, f.title]));
for (const f of folders) rec(liveFolders.get(f.uid) === f.title ? 'PASS' : 'FAIL', `folder ${f.uid}`, liveFolders.has(f.uid) ? `title "${liveFolders.get(f.uid)}"` : 'missing');

if (!args['skip-datasources']) for (const uid of deferredDatasources(CTX.env)) rec('WARN', `datasource ${uid}`, `deferred by configuration (${deferReason(uid)})`);
for (const want of args['skip-datasources'] ? [] : CTX.datasources) {
  const cur = await get(`/api/datasources/uid/${want.uid}`, { allow404: true });
  if (!cur) { rec('FAIL', `datasource ${want.uid}`, 'missing'); continue; }
  rec(canonical(dsComparable(cur)) === canonical(dsComparable(want)) ? 'PASS' : 'FAIL', `datasource ${want.uid} definition`);
  const h = await get(`/api/datasources/uid/${want.uid}/health`).catch((e) => ({ status: 'ERROR', message: e.message }));
  rec(h.status === 'OK' ? 'PASS' : 'FAIL', `datasource ${want.uid} health`, h.message || h.status);
}

const managed = new Set();
for (const { file, folderDir, dashboard, state, reason } of effectiveDashboards(CTX)) {
  managed.add(dashboard.uid);
  if (state === 'pending') rec('WARN', `dashboard ${dashboard.uid}`, `deployed, setup incomplete: ${reason}`);
  if (state === 'refused') { rec('FAIL', `dashboard ${dashboard.uid}`, reason); continue; }
  const cur = await get(`/api/dashboards/uid/${dashboard.uid}`, { allow404: true });
  if (!cur) { rec('FAIL', `dashboard ${dashboard.uid}`, 'missing'); continue; }
  const same = canonical(normalizeDashboard(cur.dashboard)) === canonical(normalizeDashboard(dashboard));
  rec(same ? 'PASS' : 'FAIL', `dashboard ${dashboard.uid}`, same ? `folder ${cur.meta.folderUid}, live version ${cur.dashboard.version}` : `content differs from ${file}`);
  if ((cur.meta.folderUid || '') !== folderDir) rec('FAIL', `dashboard ${dashboard.uid} folder`, `live ${cur.meta.folderUid || 'General'}, repository ${folderDir}`);
}
for (const f of folders) {
  for (const h of await get(`/api/search?type=dash-db&folderUIDs=${f.uid}&limit=5000`)) if (!managed.has(h.uid)) rec('WARN', `unmanaged dashboard ${h.uid} "${h.title}" in folder ${f.uid}`, 'not in this repository (apply never deletes it)');
}

const lists = await get('/api/playlists');
for (const { playlist: want, state, reason } of effectivePlaylists(CTX)) {
  if (state !== 'ok') { rec('WARN', `playlist "${want.name}"`, `not deployed: ${reason}`); continue; }
  const hit = lists.find((p) => p.name === want.name);
  if (!hit) { rec('FAIL', `playlist "${want.name}"`, 'missing'); continue; }
  const cur = await get(`/api/playlists/${hit.uid}`);
  rec(cur.interval === want.interval && canonical(cur.items) === canonical(want.items) ? 'PASS' : 'FAIL', `playlist "${want.name}"`);
}

const rules = await get('/api/v1/provisioning/alert-rules').catch(() => null);
rec('PASS', 'alert rules', rules ? `${rules.length} rule(s) live; this repository manages none (none existed at capture)` : 'alerting API not available to this account');

if (args.json) console.log(JSON.stringify({ url: URL_, version: health.version, failed: failN, warned: warnN, checks: out }, null, 2));
else console.log(`\n${failN ? 'VERIFY: FAIL' : 'VERIFY: PASS'} (${failN} failed, ${warnN} warnings)`);
process.exit(failN ? 1 : 0);
