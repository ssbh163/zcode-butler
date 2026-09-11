#!/usr/bin/env node
/**
 * watch.mjs —— 多把 GLM Coding Plan API Key 的自然月加权用量监控(提炼自 zcode-watch v0.4.0)
 *
 * 数据来源:
 *   GET https://bigmodel.cn/api/finance/expenseBill/expenseBillList  —— 分钟级账单(账号级,同账号多 Key 一次拉)
 *   GET {origin}/api/monitor/usage/quota/limit                      —— 套餐档位(缓存 1 小时)
 *
 * 统计口径:每把 Key 独立;高峰 = 工作日 14:00–17:59 分钟窗;加权总量 = 非高峰×1 + 高峰×3;
 * 月度 = 自然月,每月 1 号重置。增量同步:水位线 + 缺口窗口(保底 2h)+ 小时桶幂等合并 + 40 页断点续拉。
 *
 * 与 zcode-watch 的差异:配置改读 ~/.zcode/butler.json(无 keys 时回退兼容 ~/.zcode/zcode-watch.json,
 * 只读不写);缓存并入 ~/.zcode/butler-cache.json(lib/cache.mjs);输出对齐 butler 协议 keys 段。
 *
 * CLI:node watch.mjs [--json]
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PROVIDER_ORIGIN, FINANCE_ORIGIN, makeGet, makeColorKit, padEndW, fmtTokens, maskKey } from './lib/api.mjs';
import { loadButlerCache, saveButlerCache } from './lib/cache.mjs';
import { keyCardOf } from './lib/protocol.mjs';

const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const asHook = argv.includes('--hook');

// ---------- 常量 ----------
export const DEFAULT_MONTHLY_QUOTA = 1750000000; // 17.5 亿加权 token
export const MIN_WINDOW_HOURS = 2;               // 保底拉取窗口(小时)
export const PAGE_SIZE = 500;                    // 明细分页大小
export const MAX_PAGES = 40;                     // 翻页上限(防失控),触顶走 backlog 续拉
export const LEVEL_TTL_MS = 3600_000;            // 档位缓存时长
const HOUR_MS = 3600_000;
const TOKEN_TYPES = new Set(['输入', '输出', '缓存命中']); // 工具行(按次计)不计 token

const BUTLER_CONFIG_FILE = path.join(os.homedir(), '.zcode', 'butler.json');
const LEGACY_WATCH_CONFIG_FILE = path.join(os.homedir(), '.zcode', 'zcode-watch.json');
const FETCH_TIMEOUT = 20000;         // 明细分页可能较大
const HOOK_FETCH_TIMEOUT = 5000;

// ---------- 纯函数(export 供单测) ----------
const z2 = (n) => String(n).padStart(2, '0');
export const monthKeyOf = (d) => `${d.getFullYear()}-${z2(d.getMonth() + 1)}`;
export const dayKeyOf = (d) => `${monthKeyOf(d)}-${z2(d.getDate())}`;
export function nextMonthStartOf(d) { return new Date(d.getFullYear(), d.getMonth() + 1, 1); }

/** 北京时间整月起点(账单月与统计月对应) */
export const monthStartMsOf = (monthKey) => Date.parse(`${monthKey}-01 00:00:00+08:00`);

/** epoch(ms)→ 北京时间小时桶标签 'YYYY-MM-DD HH'(UTC+8 为整小时偏移,epoch 整点即北京整点) */
export function hourKeyOfMs(ms) {
  const d = new Date(ms + 8 * HOUR_MS);
  return `${d.getUTCFullYear()}-${z2(d.getUTCMonth() + 1)}-${z2(d.getUTCDate())} ${z2(d.getUTCHours())}`;
}
const floorToHour = (ms) => Math.floor(ms / HOUR_MS) * HOUR_MS;

/**
 * 解析账单时间字符串(服务端北京时间,月/日/时可能不补零)。
 * 输出 date 'YYYY-MM-DD'、hourKey 'YYYY-MM-DD HH'、minuteOfDay、ms(按 +08:00 折算);畸形返回 null。
 */
export function parseBillTime(s) {
  const m = String(s || '').trim().match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return null;
  const [, y, mo, da, h, mi, se] = m;
  const date = `${y}-${z2(mo)}-${z2(da)}`;
  const hh = z2(h), mm = z2(mi), ss = z2(se || '0');
  const ms = Date.parse(`${date}T${hh}:${mm}:${ss}+08:00`);
  if (!Number.isFinite(ms)) return null;
  return { date, hourKey: `${date} ${hh}`, minuteOfDay: Number(h) * 60 + Number(mi), ms };
}

/** 取账单 timeWindow 左侧(起始时刻):'2026-09-08 11:25:00~2026-09-08 11:26:00' → parseBillTime(左) */
export function parseTimeWindowStart(timeWindow) {
  const s = String(timeWindow || '').split('~')[0];
  return parseBillTime(s);
}

/** 由 'YYYY-MM-DD' 算星期(0=周日),走 Date.UTC 不吃本机时区 */
export function weekdayOfDateStr(dateStr) {
  const [y, m, d] = String(dateStr).split('-').map(Number);
  if (!y || !m || !d) return -1;
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/** 高峰分钟判定:工作日 14:00–17:59(左闭右开,18:00 起非高峰;纯时间,不看折扣比) */
export function isPeakMinute(dateStr, minuteOfDay) {
  const dow = weekdayOfDateStr(dateStr);
  if (dow < 1 || dow > 5) return false;
  return minuteOfDay >= 14 * 60 && minuteOfDay < 18 * 60;
}

/** 配置 Key(完整 `id.secret`)→ 账单 apiKey 段(第一个点号前);无点号整串兜底 */
export function keyIdSegmentOf(apiKey) {
  const k = String(apiKey || '').trim();
  const i = k.indexOf('.');
  return i > 0 ? k.slice(0, i) : k;
}

/**
 * 明细行聚合 → { [apiKey段]: { [小时桶]: { tokens, peak } } }
 * 只计 tokenType ∈ 输入/输出/缓存命中;畸形时间窗跳过。
 * 聚合保留账号内全部 Key 段(含未配置的)——后续向同账号添加新 Key 时直接命中历史。
 */
export function aggregateRows(rows) {
  const out = {};
  for (const r of rows || []) {
    const seg = keyIdSegmentOf(r?.apiKey);
    if (!seg) continue;
    if (!TOKEN_TYPES.has(r?.tokenType)) continue;
    const t = parseTimeWindowStart(r?.timeWindow);
    if (!t) continue;
    const usage = Number(r?.usageCount) || 0;
    const agg = (out[seg] = out[seg] || {});
    const b = (agg[t.hourKey] = agg[t.hourKey] || { tokens: 0, peak: 0 });
    b.tokens += usage;
    if (isPeakMinute(t.date, t.minuteOfDay)) b.peak += usage;
  }
  return out;
}

/**
 * 缺口窗口计算:window = max(2h, gap 向上取整到小时);start = now−window 向下取整到整点,
 * 再 min(backlogUntil)、max(当月 1 日 00:00)。gap ≤ 0(时钟回拨)按保底 2h。
 */
export function computePullStart(watermarkMs, nowMs, backlogMs, monthStartMs) {
  const gapMs = watermarkMs == null ? Infinity : nowMs - watermarkMs;
  const windowHours = gapMs === Infinity ? Infinity : Math.max(MIN_WINDOW_HOURS, Math.ceil(gapMs / HOUR_MS));
  let startMs = gapMs === Infinity ? monthStartMs : floorToHour(nowMs - windowHours * HOUR_MS);
  if (backlogMs != null) startMs = Math.min(startMs, floorToHour(backlogMs));
  startMs = Math.max(startMs, monthStartMs);
  return { startMs, gapMs, windowHours };
}

/**
 * 小时桶覆盖合并:hourKey ≥ startHourKey 的桶以 fresh 为准(不在 fresh 即视为 0,删除);
 * < startHourKey 的桶保持不动(固化区)。segs 独立处理。
 */
export function mergeBuckets(settled, fresh, startHourKey) {
  const out = {};
  const segs = new Set([...Object.keys(settled || {}), ...Object.keys(fresh || {})]);
  for (const seg of segs) {
    const s = settled?.[seg] || {};
    const f = fresh?.[seg] || {};
    const merged = {};
    for (const [hour, v] of Object.entries(s)) {
      if (hour < startHourKey) merged[hour] = v;
    }
    for (const [hour, v] of Object.entries(f)) {
      if (hour >= startHourKey) merged[hour] = v;
    }
    if (Object.keys(merged).length) out[seg] = merged;
  }
  return out;
}

/** 缓存月份不匹配(进入新自然月)→ 整体重置:月度重置的实现点 */
export function resetCacheIfStale(cache, monthKey) {
  if (cache.month !== monthKey) {
    return { version: 3, month: monthKey, accounts: {}, keyAccount: {}, lastResult: null };
  }
  return cache;
}

/** 总使用额度(加权)= 非高峰×1 + 高峰×3 */
export const weightedOf = (offPeak, peak) => offPeak + peak * 3;

/** 配置解析:剥 BOM、容忍 CRLF、缺省字段给默认值;结构不对抛带指引的错误 */
export function parseConfig(text, configFile = BUTLER_CONFIG_FILE) {
  let obj;
  try {
    obj = JSON.parse(String(text).replace(/^\uFEFF/, ''));
  } catch {
    throw new Error(`配置文件不是合法 JSON:${configFile}`);
  }
  if (!obj || !Array.isArray(obj.keys)) {
    throw new Error(`配置文件缺少 "keys" 数组:${configFile}(格式见 README)`);
  }
  const keys = obj.keys.map((k, i) => {
    const apiKey = typeof k?.apiKey === 'string' ? k.apiKey.trim() : '';
    if (!apiKey) throw new Error(`第 ${i + 1} 个 Key 缺少 apiKey 字段(${configFile})`);
    return {
      id: typeof k.id === 'string' && k.id.trim() ? k.id.trim() : `key-${i + 1}`,
      name: typeof k.name === 'string' && k.name.trim() ? k.name.trim() : `Key ${i + 1}`,
      provider: k.provider === 'zai' ? 'zai' : 'bigmodel',
      apiKey,
      monthlyQuota: Number(k.monthlyQuota) > 0 ? Number(k.monthlyQuota) : DEFAULT_MONTHLY_QUOTA,
    };
  });
  return { keys };
}

/** 距离下月 1 号还剩几天(向上取整;当天重置返回下月计数) */
export function daysUntilReset(now) {
  return Math.max(0, Math.ceil((nextMonthStartOf(now).getTime() - now.getTime()) / 86400000));
}

// ---------- 配置与缓存 IO ----------
function readTextDefensive(file) {
  try {
    const t = fs.readFileSync(file, 'utf8');
    return t.replace(/^\uFEFF/, '');
  } catch {
    return null;
  }
}

/** butler.json 优先;无 keys 时回退旧 zcode-watch.json(只读,不回写),保持源项目独立存续 */
function loadConfig() {
  for (const [file, primary] of [[BUTLER_CONFIG_FILE, true], [LEGACY_WATCH_CONFIG_FILE, false]]) {
    const text = readTextDefensive(file);
    if (text === null || !text.trim()) continue;
    const cfg = parseConfig(text, file);
    return primary ? cfg : { ...cfg, fromLegacy: file };
  }
  return { keys: [], missing: true };
}

function loadCache(monthKey) {
  const cache = resetCacheIfStale(loadButlerCache(), monthKey);
  return cache;
}

// ---------- 同步 ----------
/** 拉一页账单明细(倒序,最新在前) */
async function fetchBillPage(get, monthKey, pageNum) {
  const d = await get(`/api/finance/expenseBill/expenseBillList?billingMonth=${monthKey}&pageNum=${pageNum}&pageSize=${PAGE_SIZE}`);
  const rows = d?.rows;
  if (!Array.isArray(rows)) throw new Error('账单明细返回结构异常(无 rows)');
  return rows;
}

/**
 * 单账号同步:按缺口窗口翻页拉取 → 本地聚合 → 小时桶覆盖合并 → 推进水位线。
 * 失败向上抛(该账号本轮作废,watermark 不推进,下轮窗口自动覆盖)。
 */
async function syncAccount(configKey, state, monthKey, nowMs, timeoutMs) {
  const origin = FINANCE_ORIGIN[configKey.provider];
  const get = makeGet(origin, configKey.apiKey, timeoutMs);
  const monthStartMs = monthStartMsOf(monthKey);
  const { startMs } = computePullStart(
    typeof state.watermark === 'number' ? state.watermark : null,
    nowMs,
    typeof state.backlogUntil === 'number' ? state.backlogUntil : null,
    monthStartMs,
  );

  const pulled = [];
  let pages = 0;
  let reachedFloor = false;
  for (let p = 1; p <= MAX_PAGES; p++) {
    const rows = await fetchBillPage(get, monthKey, p);
    pages = p;
    if (!rows.length) { reachedFloor = true; break; }
    pulled.push(...rows);
    const oldest = parseTimeWindowStart(rows[rows.length - 1]?.timeWindow);
    if (oldest && oldest.ms < startMs) { reachedFloor = true; break; }
    if (rows.length < PAGE_SIZE) { reachedFloor = true; break; } // 末页
  }
  const incomplete = !reachedFloor;

  const validRows = [];
  let oldestValidMs = Infinity;
  let customerId = null;
  for (const r of pulled) {
    const t = parseTimeWindowStart(r?.timeWindow);
    if (!t || t.ms < startMs) continue;
    if (customerId == null && r?.customerId != null) customerId = String(r.customerId);
    validRows.push(r);
    if (t.ms < oldestValidMs) oldestValidMs = t.ms;
  }

  // 水位线与合并边界:正常完成 → watermark=now、合并边界=pullStart;
  // 触顶 → watermark/边界=已连续覆盖的最早整点,记 backlogUntil 断点续拉
  let newWatermark = nowMs;
  let newBacklog = null;
  let mergeStart = hourKeyOfMs(startMs);
  if (incomplete && oldestValidMs < Infinity) {
    const floor = floorToHour(oldestValidMs);
    newWatermark = floor;
    newBacklog = floor;
    mergeStart = hourKeyOfMs(floor);
  }

  const fresh = aggregateRows(validRows);
  state.settled = mergeBuckets(state.settled || {}, fresh, mergeStart);
  state.watermark = newWatermark;
  state.backlogUntil = newBacklog;

  const seenSegs = new Set(validRows.map((r) => keyIdSegmentOf(r?.apiKey)));
  return { customerId, pages, incomplete, seenSegs };
}

/** 账号档位(缓存 1 小时) */
async function fetchLevel(configKey, state, nowMs, timeoutMs) {
  if (state.level && typeof state.levelAt === 'number' && nowMs - state.levelAt < LEVEL_TTL_MS) {
    return state.level;
  }
  const get = makeGet(PROVIDER_ORIGIN[configKey.provider], configKey.apiKey, timeoutMs);
  const quota = await get('/api/monitor/usage/quota/limit');
  state.level = String(quota?.level || '').toUpperCase() || '未知';
  state.levelAt = nowMs;
  return state.level;
}

function sumBuckets(buckets) {
  let tokens = 0, peak = 0;
  for (const v of Object.values(buckets || {})) {
    tokens += v.tokens || 0;
    peak += v.peak || 0;
  }
  return { tokens, peak };
}

// ---------- 主查询 ----------
/**
 * 全量查询(同步 + 组装协议 keys 卡)。返回:
 *   { month, fetchedAt(epoch ms), keys: [协议 KeyCard], fromLegacy?: zcode-watch.json 路径 }
 * 未配置 Key 时返回 { empty: true, keys: [] }。
 */
export async function runQuery(timeoutMs = FETCH_TIMEOUT) {
  const now = new Date();
  const monthKey = monthKeyOf(now);
  const nowMs = now.getTime();
  const cfg = loadConfig();
  if (cfg.missing || !cfg.keys.length) {
    return { empty: true, month: monthKey, fetchedAt: nowMs, keys: [] };
  }
  const cache = loadCache(monthKey);
  const cfgKeyById = new Map(cfg.keys.map((k) => [k.id, k]));

  // 1) 逐账号同步(authKeyId 代表拉取;失败标记账号错误,watermark 不动)
  const accountErrors = {};   // customerId → error 文案
  const accountMeta = {};     // customerId → { pages, incomplete }
  const synced = [];          // [{ customerId, configKey, state }]
  const doneAccounts = new Set();
  // 同步次序:先做已知账号;同账号第二把 Key 不重复拉
  for (const k of cfg.keys) {
    const cid = cache.keyAccount[k.id];
    if (!cid || doneAccounts.has(cid)) continue;
    const state = cache.accounts[cid];
    if (!state) { delete cache.keyAccount[k.id]; continue; }
    // authKey 优先 state.authKeyId,配置里已删则回退该账号任一已知 Key
    const authId = cfgKeyById.has(state.authKeyId) ? state.authKeyId : k.id;
    const authKey = cfgKeyById.get(authId) || k;
    doneAccounts.add(cid);
    try {
      const r = await syncAccount(authKey, state, monthKey, nowMs, timeoutMs);
      state.authKeyId = authKey.id;
      accountMeta[cid] = { pages: r.pages, incomplete: r.incomplete };
      synced.push({ customerId: String(r.customerId || cid), configKey: authKey, state });
    } catch (e) {
      accountErrors[cid] = e.message;
    }
  }

  // 2) 未归组的配置 Key:独立成组自己拉一次(发现账号 / 借道同账号其他 Key 的行)
  for (const k of cfg.keys) {
    if (cache.keyAccount[k.id]) continue;
    const tmp = { settled: {}, watermark: null, backlogUntil: null };
    try {
      const r = await syncAccount(k, tmp, monthKey, nowMs, timeoutMs);
      const cid = r.customerId ? String(r.customerId) : `solo:${k.id}`;
      if (r.customerId && cache.accounts[cid]) {
        // 归入既有账号:数据同源,丢弃临时态,只补映射
        cache.keyAccount[k.id] = cid;
      } else {
        // 新建组:有 customerId → 命名组;零用量 → solo 组(下轮经 keyAccount 走正常同步)
        tmp.authKeyId = k.id;
        cache.accounts[cid] = tmp;
        cache.keyAccount[k.id] = cid;
        accountMeta[cid] = { pages: r.pages, incomplete: r.incomplete };
        synced.push({ customerId: cid, configKey: k, state: tmp });
      }
    } catch (e) {
      accountErrors[`solo:${k.id}`] = e.message;
    }
  }

  // 3) 学习 keyMap(账单段 → 配置 key id)与 keyAccount(配置 key id → 账号)
  for (const k of cfg.keys) {
    const seg = keyIdSegmentOf(k.apiKey);
    for (const [cid, state] of Object.entries(cache.accounts)) {
      if (!state || !state.settled || state.settled[seg] == null) continue;
      state.keyMap = state.keyMap || {};
      state.keyMap[seg] = k.id;
      cache.keyAccount[k.id] = cid;
    }
  }

  // 4) 档位(账号级,缓存 1h;失败不阻塞用量展示)
  for (const { customerId, configKey, state } of synced) {
    try { await fetchLevel(configKey, state, nowMs, timeoutMs); } catch { /* 档位失败容忍 */ }
  }

  // 5) 组装每把配置 Key 的协议卡(按 pct 降序,悬浮窗渐进环按序取前 N 个)
  const keyCards = cfg.keys.map((k) => {
    const seg = keyIdSegmentOf(k.apiKey);
    const cid = cache.keyAccount[k.id];
    const state = cid ? cache.accounts[cid] : null;
    const err = cid ? accountErrors[cid] : accountErrors[`solo:${k.id}`];
    const { tokens, peak } = sumBuckets(state?.settled?.[seg]);
    const offPeak = Math.max(0, tokens - peak);
    const weighted = weightedOf(offPeak, peak);
    const percent = k.monthlyQuota > 0 ? (weighted / k.monthlyQuota) * 100 : 0;
    return keyCardOf({
      id: k.id,
      name: k.name,
      tier: state?.level || '未知',
      tail: maskKey(k.apiKey),
      pct: percent,
      usedWeighted: weighted,
      quota: k.monthlyQuota,
      peak,
      offpeak: offPeak,
      resetDate: dayKeyOf(nextMonthStartOf(now)),
      status: err ? 'error' : 'ok',
      ...(err ? { error: err } : {}),
      provider: k.provider,
      incomplete: cid ? !!(accountMeta[cid]?.incomplete) : false,
    });
  }).sort((a, b) => b.pct - a.pct);

  const payload = { month: monthKey, fetchedAt: nowMs, keys: keyCards };
  if (cfg.fromLegacy) payload.fromLegacy = cfg.fromLegacy;
  if (process.env.BUTLER_DEBUG) {
    payload.debug = {
      accountErrors,
      keyAccount: { ...cache.keyAccount },
      keyMaps: Object.fromEntries(Object.entries(cache.accounts).map(([cid, s]) => [cid, s.keyMap || {}])),
    };
  }
  // lastResult:hook 零请求窗口(status.mjs 聚合时会整体覆盖)
  cache.lastResult = { ts: nowMs, month: monthKey, payload: { keys: keyCards } };
  // 清理已删除 Key 的映射
  const ids = new Set(cfg.keys.map((k) => k.id));
  for (const id of Object.keys(cache.keyAccount)) {
    if (!ids.has(id)) delete cache.keyAccount[id];
  }
  saveButlerCache(cache);
  return payload;
}

/** 协议 keys → hook 一行摘要(满额警告;空 = 无事发生) */
export function keysSummaryLine(keys) {
  const exhausted = (keys || []).filter((k) => k.status === 'ok' && k.pct >= 100);
  return exhausted.length
    ? `⚠ ${exhausted.length} 把 Key 本月已用满 100%:${exhausted.map((k) => `「${k.name} ${k.tail}」`).join(' ')}`
    : '';
}

// ---------- 卡片(终端) ----------
const { bold, dim, c, rateStyle } = makeColorKit();

function bar(pct, width = 18) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  const filled = Math.round((p / 100) * width);
  return c(rateStyle(p), '▰'.repeat(filled) + '▱'.repeat(width - filled))
    + '  ' + c(rateStyle(p), `已用 ${Number(pct).toFixed(1)}%`);
}

export function renderWatchCard(payload, now = new Date()) {
  if (payload.empty || !payload.keys.length) {
    return [
      '未配置任何监控 Key。添加方式(二选一):',
      '  1. 在 ZCode 对话里说:「码管家添加一个监控 Key,名字 xx,Key 是 xxx」',
      `  2. 手动编辑 ${BUTLER_CONFIG_FILE},格式:`,
      '     { "keys": [ { "id": "key-1", "name": "主力", "provider": "bigmodel",',
      '                   "apiKey": "你的Key", "monthlyQuota": 1750000000 } ] }',
      `     (兼容直接导入 ${LEGACY_WATCH_CONFIG_FILE});provider:bigmodel(智谱)| zai(国际)`,
    ].join('\n');
  }
  const rule = (ch) => c('2;36', ch.repeat(50));
  const LABEL_W = 14;
  const ok = payload.keys.filter((k) => k.status === 'ok').length;
  const lines = [];
  lines.push(rule('━'));
  lines.push(bold(` ⚡ 码管家 · Key 月度用量 · ${payload.month} · ${payload.keys.length} 把(${ok} 把正常)`));
  const legacy = payload.fromLegacy ? dim(`    (读自旧配置 ${payload.fromLegacy},建议迁到 butler.json)`) : '';
  lines.push(dim(`    ${now.toLocaleString('zh-CN')} · 加权口径 = 非高峰×1 + 高峰×3`));
  if (legacy) lines.push(legacy);
  for (const k of payload.keys) {
    lines.push('');
    const head = ` ● ${k.name} ${k.tail} · [${k.tier}]`;
    lines.push(k.pct >= 100 ? c('1;31', head) : bold(head));
    if (k.status === 'error') {
      lines.push(`   ${c('1;31', '⚠ 查询失败:' + (k.error || ''))}`);
      const badKey = /401|令牌|token|鉴权|验证/i.test(k.error || '');
      lines.push(dim(`     ${badKey ? 'Key 无效或非 Coding Plan 专用 Key,请检查 ' + BUTLER_CONFIG_FILE : '稍后重试;持续失败请检查网络与配置'}`));
      continue;
    }
    if (k.pct >= 100) lines.push(`   ${c('1;31', '⚠ 本月已用满 100%,建议停用该 Key')}`);
    lines.push(`   ${bar(k.pct)}`);
    lines.push(`   ${padEndW('总使用额度', LABEL_W)}${fmtTokens(k.usedWeighted)} / ${fmtTokens(k.quota)}`);
    lines.push(`   ${padEndW('高峰期使用', LABEL_W)}${fmtTokens(k.peak)}(×3 折算)`);
    lines.push(`   ${padEndW('非高峰期使用', LABEL_W)}${fmtTokens(k.offpeak)}`);
    lines.push(dim(`   ↻ ${k.resetDate} 重置 · 还剩 ${daysUntilReset(now)} 天`));
    if (k.incomplete) lines.push(dim('   (账单数据量过大,本轮未拉完,断点续拉中)'));
  }
  lines.push('');
  lines.push(rule('━'));
  return lines.join('\n');
}

// ---------- CLI 入口 ----------
async function main() {
  let payload;
  try {
    payload = await runQuery(asHook ? HOOK_FETCH_TIMEOUT : FETCH_TIMEOUT);
  } catch (e) {
    if (asJson) {
      console.log(JSON.stringify({ month: monthKeyOf(new Date()), fetchedAt: Date.now(), keys: [], errors: [{ module: 'watch', message: e.message }] }, null, 2));
      return;
    }
    console.error('查询失败:', e.message);
    process.exitCode = 1;
    return;
  }
  if (asJson) {
    console.log(JSON.stringify(payload, null, 2));
    return;
  }
  console.log(renderWatchCard(payload));
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) main().catch((e) => { console.error('查询失败:', e.message); process.exit(1); });
