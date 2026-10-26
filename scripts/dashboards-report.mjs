// READ-ONLY: what Grafana actually holds, asked through its HTTP API (GET only), compared with what this release deploys.
//   node scripts/dashboards-report.mjs --env-file <env> [--item-map <file>] [--brief]   (--brief: one line per folder)
// One line per managed folder and dashboard: present/missing, live folder, datasource uids its panels use, and whether its setup is
// complete. Also lists dashboards in the managed folders that this release does not manage. Exit 1 if a managed dashboard is missing.
import { get, parseArgs, readJson } from './lib/grafana.mjs';
import { loadContext, effectiveDashboards, NOTICE_PANEL_TITLE } from './lib/content.mjs';
import { datasourceRefs } from './lib/envcfg.mjs';

const args = parseArgs(process.argv.slice(2));
const CTX = loadContext(args);
const folders = readJson('config/folders.json');
const eff = effectiveDashboards(CTX);
const live = await get('/api/search?type=dash-db&limit=5000');
const dsCache = new Map();
const dsExists = async (uid) => { if (!dsCache.has(uid)) dsCache.set(uid, !!(await get(`/api/datasources/uid/${uid}`, { allow404: true }))); return dsCache.get(uid); };
let missing = 0;
for (const f of folders) {
  const want = eff.filter((d) => d.folderDir === f.uid);
  const inFolder = live.filter((h) => h.folderUid === f.uid);
  if (!args.brief) console.log(`folder ${f.title} (${f.uid}): ${inFolder.length} dashboard(s) in Grafana, ${want.length} managed`);
  let present = 0; const incomplete = [];
  for (const d of want) {
    const cur = await get(`/api/dashboards/uid/${d.dashboard.uid}`, { allow404: true });
    if (!cur) { missing++; console.log(`  MISSING  ${d.dashboard.uid}  "${d.dashboard.title}"`); continue; }
    present++; if (d.state === 'pending') incomplete.push(d.reason);
    if (args.brief) continue;
    const refs = []; for (const u of datasourceRefs(cur.dashboard)) refs.push(`${u}${(await dsExists(u)) ? '' : ' (datasource not in Grafana)'}`);
    const notice = (cur.dashboard.panels || []).some((p) => p.title === NOTICE_PANEL_TITLE);
    const where = cur.meta.folderUid === f.uid ? '' : `  (in folder ${cur.meta.folderUid || 'General'}!)`;
    console.log(`  present  ${d.dashboard.uid}  "${cur.dashboard.title}"  ${cur.dashboard.panels?.length || 0} panels  datasource: ${refs.join(', ') || '-'}${where}`);
    if (notice || d.state === 'pending') console.log(`           setup incomplete: ${d.reason}`);
  }
  if (args.brief) console.log(`${f.title}: ${present} of ${want.length} dashboards in Grafana${incomplete.length ? `; ${incomplete.length} with setup incomplete: ${incomplete[0].replace(/ \([0-9, .]+\)/, '')}` : ', complete'}`);
  if (!args.brief) for (const h of inFolder.filter((h) => !want.some((d) => d.dashboard.uid === h.uid))) console.log(`  other    ${h.uid}  "${h.title}" (not managed by this release, left alone)`);
}
const total = eff.length; const present = total - missing;
console.log(`dashboards: ${present} of ${total} present in Grafana${missing ? `, ${missing} MISSING` : ''}; ${eff.filter((d) => d.state === 'ok').length} complete, ${eff.filter((d) => d.state === 'pending').length} with setup incomplete`);
process.exit(missing ? 1 : 0);
