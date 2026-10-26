// What this repository deploys to ONE environment: rendered datasources + dashboards with the environment's Zabbix item ids.
//   --env-file <file>  (or PLATFORM_ENV_FILE)   KEY=VALUE environment; default env/lab.env.example (the LAB reference)
//   --item-map <file>  (or ZABBIX_ITEM_MAP_FILE in the env file)   {"<LAB zabbix item id>": "<item id on this Zabbix>"}
import { join } from 'node:path';
import { ROOT, repoDashboards } from './grafana.mjs';
import { loadEnvFile, renderDatasources, loadItemMap, applyItemMap, itemIds, flag, deferredDatasources, datasourceRefs, deferReason } from './envcfg.mjs';
import { readJson } from './grafana.mjs';

export function loadContext(args) {
  const file = args['env-file'] || process.env.PLATFORM_ENV_FILE || join(ROOT, 'env', 'lab.env.example');
  const env = loadEnvFile(file);
  const itemMap = loadItemMap(args['item-map'] || env.ZABBIX_ITEM_MAP_FILE);
  return { envFile: file, env, envName: env.PLATFORM_ENV || 'lab', itemMap, datasources: renderDatasources(env) };
}

/** [{ file, folderDir, dashboard, state: 'ok' | 'pending' | 'refused', reason? }]. `dashboard` already carries this environment's item ids.
 *  Every managed dashboard is deployed, so its folder is never empty:
 *  'pending' = deployed with a notice panel at the top saying what is still missing and the one command that completes it:
 *     - the dashboard needs a datasource the environment does not connect yet (CLICKHOUSE_ENABLED=no -> the 5 NetFlow dashboards,
 *       ZABBIX_ENABLED=no -> the NOC dashboards). Datasource references are kept, so the dashboard works as soon as it is connected.
 *     - the dashboard addresses Zabbix items by id and the item map is missing or incomplete (ALLOW_NOC_WITHOUT_ITEM_MAP=yes, default):
 *       mapped ids are used, unmapped ones are left EMPTY (never a LAB id: on another Zabbix it could be an unrelated item).
 *  'refused' = ALLOW_NOC_WITHOUT_ITEM_MAP=no and the map is incomplete (install stops; the reason says what to do). */
export function effectiveDashboards(ctx) {
  const off = new Set(deferredDatasources(ctx.env));
  const allowNoc = flag(ctx.env, 'ALLOW_NOC_WITHOUT_ITEM_MAP', true);
  return repoDashboards().map(({ file, folderDir, dashboard }) => {
    const needs = datasourceRefs(dashboard).filter((u) => off.has(u));
    if (needs.length) {
      const what = needs.map((u) => DS_LABEL[u] || u).join(' and ');
      const cmd = needs.map((u) => DS_COMMAND[u]).filter(Boolean).join(' / ');
      return { file, folderDir, state: 'pending', reason: `${what} not connected yet (${needs.map(deferReason).join(', ')}); connect it: ${cmd}`,
        dashboard: withNotice(applyItemMap(dashboard, ctx.envName === 'lab' ? null : (ctx.itemMap || {}), { blankMissing: true }).dashboard,
          `**${what} is not connected yet** — the panels below stay empty until it is. Connect it with \`${cmd}\`; this dashboard then works without being imported again.`) };
    }
    const usesItems = itemIds(dashboard).length > 0;
    if (!usesItems || ctx.envName === 'lab') return { file, folderDir, dashboard: applyItemMap(dashboard, null).dashboard, state: 'ok' };   // LAB: the captured ids ARE the ids
    const r = applyItemMap(dashboard, ctx.itemMap || {}, { blankMissing: true });
    if (!r.missing.length) return { file, folderDir, dashboard: r.dashboard, state: 'ok' };
    const total = new Set(itemIds(dashboard)).size;
    const what = ctx.itemMap ? `${r.missing.length} of ${total} Zabbix item(s) are not mapped to this Zabbix (${r.missing.slice(0, 6).join(', ')}${r.missing.length > 6 ? ', ...' : ''})` : `no Zabbix item map yet (${total} item(s))`;
    if (!allowNoc) return { file, folderDir, dashboard, state: 'refused', reason: `${what}; run 'grafana-platform setup --zabbix' or set ALLOW_NOC_WITHOUT_ITEM_MAP=yes` };
    const panels = r.affectedPanels.slice(0, 8).join('; ') + (r.affectedPanels.length > 8 ? '; ...' : '');
    return { file, folderDir, state: 'pending', reason: `${what}; affected panels show no data until mapped: sudo grafana-platform setup --dashboards`,
      dashboard: withNotice(r.dashboard, `**${r.missing.length} of ${total} Zabbix items are not mapped to this Zabbix yet**, so ${r.affectedPanels.length} panel(s) show no data: ${panels}. Map them (asks the Zabbix host names of the routers): \`sudo grafana-platform setup --dashboards\`.`) };
  });
}

const DS_LABEL = { 'netflow-clickhouse': 'ClickHouse (Akvorado NetFlow)', 'zabbix-lab': 'Zabbix' };
const DS_COMMAND = { 'netflow-clickhouse': 'sudo grafana-platform setup --clickhouse', 'zabbix-lab': 'sudo grafana-platform setup --zabbix' };
export const NOTICE_PANEL_TITLE = 'Setup still incomplete';

/** Copy of `dash` with a full-width text panel at the top (other panels moved down). */
export function withNotice(dash, markdown) {
  const copy = JSON.parse(JSON.stringify(dash));
  const H = 3;
  const ids = [];
  (function walk(ps) { for (const p of ps || []) { if (typeof p.id === 'number') ids.push(p.id); walk(p.panels); } })(copy.panels);
  for (const p of copy.panels || []) if (p.gridPos) p.gridPos.y += H;
  copy.panels = [{ id: Math.max(0, ...ids) + 1, type: 'text', title: NOTICE_PANEL_TITLE, gridPos: { h: H, w: 24, x: 0, y: 0 },
    options: { mode: 'markdown', content: markdown } }, ...(copy.panels || [])];
  return copy;
}

/** Playlists restricted to the dashboards this environment deploys. [{ playlist, state: 'ok' | 'skipped', reason? }] */
export function effectivePlaylists(ctx) {
  const deployed = new Set(effectiveDashboards(ctx).filter((d) => d.state === 'ok').map((d) => d.dashboard.uid));
  return readJson('config/playlists.json').map((p) => {
    const items = p.items.filter((it) => it.type !== 'dashboard_by_uid' || deployed.has(it.value));
    if (!items.length) return { playlist: p, state: 'skipped', reason: 'every dashboard of this playlist is deferred' };
    return { playlist: { ...p, items }, state: 'ok', ...(items.length < p.items.length ? { reason: `${p.items.length - items.length} deferred dashboard(s) left out` } : {}) };
  });
}
