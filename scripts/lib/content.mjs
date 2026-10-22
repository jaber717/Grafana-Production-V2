// What this repository deploys to ONE environment: rendered datasources + dashboards with the environment's Zabbix item ids.
//   --env-file <file>  (or PLATFORM_ENV_FILE)   KEY=VALUE environment; default env/lab.env.example (the LAB reference)
//   --item-map <file>  (or ZABBIX_ITEM_MAP_FILE in the env file)   {"<LAB zabbix item id>": "<item id on this Zabbix>"}
import { join } from 'node:path';
import { ROOT, repoDashboards } from './grafana.mjs';
import { loadEnvFile, renderDatasources, loadItemMap, applyItemMap, itemIds, flag, deferredDatasources, datasourceRefs } from './envcfg.mjs';
import { readJson } from './grafana.mjs';

export function loadContext(args) {
  const file = args['env-file'] || process.env.PLATFORM_ENV_FILE || join(ROOT, 'env', 'lab.env.example');
  const env = loadEnvFile(file);
  const itemMap = loadItemMap(args['item-map'] || env.ZABBIX_ITEM_MAP_FILE);
  return { envFile: file, env, envName: env.PLATFORM_ENV || 'lab', itemMap, datasources: renderDatasources(env) };
}

/** [{ file, folderDir, dashboard, state: 'ok' | 'skipped' | 'refused', reason? }]. `dashboard` already carries this environment's item ids.
 *  'skipped' = deliberately deferred by configuration (reported as WARN, never deployed half-working):
 *     - the dashboard needs a datasource the environment defers (CLICKHOUSE_ENABLED=no -> the NetFlow dashboards);
 *     - the dashboard addresses Zabbix items by id and the item map is missing OR incomplete while ALLOW_NOC_WITHOUT_ITEM_MAP=yes.
 *  'refused' = would be broken and was not deferred (install stops; the reason says what to do). */
export function effectiveDashboards(ctx) {
  const off = new Set(deferredDatasources(ctx.env));
  const allowNoc = flag(ctx.env, 'ALLOW_NOC_WITHOUT_ITEM_MAP', false);
  return repoDashboards().map(({ file, folderDir, dashboard }) => {
    const needs = datasourceRefs(dashboard).filter((u) => off.has(u));
    if (needs.length) return { file, folderDir, dashboard, state: 'skipped', reason: `deferred: needs datasource ${needs.join(', ')} (CLICKHOUSE_ENABLED=no)` };
    const usesItems = itemIds(dashboard).length > 0;
    if (!usesItems) return { file, folderDir, dashboard, state: 'ok' };
    if (ctx.itemMap) {
      const r = applyItemMap(dashboard, ctx.itemMap);
      if (!r.missing.length) return { file, folderDir, dashboard: r.dashboard, state: 'ok' };
      const what = `${r.missing.length} Zabbix item id(s) have no entry in the item map (${r.missing.slice(0, 6).join(', ')}${r.missing.length > 6 ? ', ...' : ''})`;
      if (allowNoc) return { file, folderDir, dashboard, state: 'skipped', reason: `deferred: ${what} (ALLOW_NOC_WITHOUT_ITEM_MAP=yes)` };
      return { file, folderDir, dashboard, state: 'refused', reason: `${what}; run 'grafana-platform item-map' or set ALLOW_NOC_WITHOUT_ITEM_MAP=yes` };
    }
    if (ctx.envName === 'lab') return { file, folderDir, dashboard, state: 'ok' };          // LAB: the captured ids ARE the ids
    if (allowNoc) return { file, folderDir, dashboard, state: 'skipped', reason: 'deferred: no Zabbix item map (ALLOW_NOC_WITHOUT_ITEM_MAP=yes)' };
    return { file, folderDir, dashboard, state: 'refused', reason: "this dashboard addresses Zabbix items by LAB item id and the environment has no item map; run 'grafana-platform item-map' (docs/ZABBIX-ITEM-MAP.md)" };
  });
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
