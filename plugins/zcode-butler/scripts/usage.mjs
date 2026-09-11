#!/usr/bin/env node
/**
 * usage.mjs —— 账号三环(5 小时池 / 每周额度 / MCP 月度)+ 当日模型用量(提炼自 zcode-usage v0.0.6)
 *
 * 数据来源:
 *   GET {origin}/api/monitor/usage/quota/limit   —— 三环额度(TIME_LIMIT=MCP月度;TOKENS_LIMIT unit3/5=5h池 unit6=每周)
 *   GET {origin}/api/monitor/usage/model-usage   —— 当日模型 token 用量(小时序列,用于高峰拆分)
 *   GET {origin}/api/monitor/usage/tool-usage    —— 当日 MCP 工具调用
 *
 * 与 zcode-usage 的差异:输出对齐 butler 协议(PROJECT.md §5)的 account 段;
 * 高峰拆分沿用小时序列求和(工作日 14:00-17:59 左闭右开),不单独发峰窗区间请求。
 *
 * CLI:node usage.mjs [--json] [--key K --base U]
 */
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  resolveCredential, makeGet, makeColorKit, padEndW, fmtNum, fmtTokens,
} from './lib/api.mjs';
import { ringOf, mcpRingOf } from './lib/protocol.mjs';

const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const asHook = argv.includes('--hook');
const flagValue = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

// ---------- 北京时间纯函数(export 供单测;智谱按 UTC+8 记账,全部显式折算不吃本机时区) ----------
const BJ_OFFSET_MS = 8 * 3600_000;
const z2 = (n) => String(n).padStart(2, '0');

/** epoch(ms) → 北京时间字符串 'YYYY-MM-DD HH:mm:ss'(纯 UTC 运算) */
export function bjFmt(ms) {
  const d = new Date(ms + BJ_OFFSET_MS);
  return `${d.getUTCFullYear()}-${z2(d.getUTCMonth() + 1)}-${z2(d.getUTCDate())}`
    + ` ${z2(d.getUTCHours())}:${z2(d.getUTCMinutes())}:${z2(d.getUTCSeconds())}`;
}

/** epoch(ms) → 所在北京日的 00:00:00(epoch);当日查询窗口起点 */
export function bjDayStartMs(ms) {
  const d = new Date(ms + BJ_OFFSET_MS);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - BJ_OFFSET_MS;
}

/** epoch(ms) → 北京小时桶标签 'YYYY-MM-DD HH:00'(与 model-usage 的 x_time 同格式) */
export function bjHourLabel(ms) {
  return bjFmt(ms).slice(0, 13) + ':00';
}

/** 'YYYY-MM-DD' → 星期(0=周日),走 Date.UTC 不吃本机时区;畸形返回 -1 */
export function weekdayOfDateStr(dateStr) {
  const [y, m, d] = String(dateStr).split('-').map(Number);
  if (!y || !m || !d) return -1;
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/** 小时桶标签 'YYYY-MM-DD HH:00' 是否高峰:工作日 14–17 点(标签自带日期,跨零点/周末边界自洽) */
export function isPeakHourLabel(label) {
  const s = String(label || '');
  const dow = weekdayOfDateStr(s.slice(0, 10));
  if (dow < 1 || dow > 5) return false;
  const hour = Number(s.slice(11, 13));
  return hour >= 14 && hour <= 17;
}

/** model-usage 当日响应 → 高峰用量 { calls, tokens }(逐小时桶按标签归类) */
export function peakOf(modelUsage) {
  let calls = 0;
  let tokens = 0;
  const xTime = modelUsage?.x_time || [];
  for (let i = 0; i < xTime.length; i++) {
    if (!isPeakHourLabel(xTime[i])) continue;
    calls += Number(modelUsage.modelCallCount?.[i]) || 0;
    tokens += Number(modelUsage.tokensUsage?.[i]) || 0;
  }
  return { calls, tokens };
}

// ---------- quota → 协议 account 段(纯函数,单测钉住) ----------
// TIME_LIMIT 的 usageDetails 分工具:modelCode → 协议 tools 字段
const TOOL_CODE_FIELD = {
  'search-prime': 'webSearch',
  'web-reader': 'webReader',
  zread: 'zread',
};

/**
 * quota/limit 响应 → 协议 account 段。
 * Prompt 两环接口只给 percentage(无绝对值),used/limit 记 0 = 未知,渲染端只看 pct;
 * MCP 月度 used=currentValue(已用次数)/limit=usage(总量),tools 取月度 usageDetails。
 */
export function mapQuotaToAccount(quota, nowMs) {
  const account = {
    fiveHour: null,
    weekly: null,
    mcpMonthly: null,
    peakNow: isPeakHourLabel(bjHourLabel(nowMs)),
  };
  for (const l of quota?.limits || []) {
    const pct = Number(l.percentage) || 0;
    if (l.type === 'TIME_LIMIT') {
      const tools = { webSearch: 0, webReader: 0, zread: 0 };
      for (const d of l.usageDetails || []) {
        const field = TOOL_CODE_FIELD[String(d?.modelCode || '').toLowerCase()];
        if (field) tools[field] += Number(d?.usage) || 0;
      }
      account.mcpMonthly = mcpRingOf({
        pct, used: l.currentValue, limit: l.usage, resetAt: l.nextResetTime, tools,
      });
    } else if (Number(l.unit) === 3) {
      account.fiveHour = ringOf({ pct, used: 0, limit: 0, resetAt: l.nextResetTime });
    } else if (Number(l.unit) === 6) {
      account.weekly = ringOf({ pct, used: 0, limit: 0, resetAt: l.nextResetTime });
    }
  }
  account.level = String(quota?.level || '').toUpperCase() || '未知';
  return account;
}

/** tool-usage 当日响应 → { webSearch, webReader, zread }(口径:当日,区别于月度 usageDetails) */
export function mapToolUsageToday(toolUsage) {
  const t = toolUsage?.totalUsage || {};
  return {
    webSearch: Number(t.totalSearchMcpCount) || 0,
    webReader: Number(t.totalWebReadMcpCount) || 0,
    zread: Number(t.totalZreadMcpCount) || 0,
  };
}

/** model-usage 当日响应 → { total:{calls,tokens}, peak:{...}, offPeak:{...} };序列缺失返回 null(只显示总量不拆分) */
export function splitDayUsage(modelUsage) {
  const total = modelUsage?.totalUsage;
  if (!total || !Array.isArray(modelUsage?.x_time)) return null;
  const { calls: pc, tokens: pt } = peakOf(modelUsage);
  return {
    total: {
      calls: Number(total.totalModelCallCount) || 0,
      tokens: Number(total.totalTokensUsage) || 0,
    },
    peak: { calls: pc, tokens: pt },
    offPeak: {
      calls: Math.max(0, (Number(total.totalModelCallCount) || 0) - pc),
      tokens: Math.max(0, (Number(total.totalTokensUsage) || 0) - pt),
    },
  };
}

// ---------- 取数 ----------
/**
 * 账号查询:三个接口,额度失败整体抛错;当日两个失败不影响额度(降级为 null)。
 * 返回 { account, raw: { quota, modelUsage, toolUsage, dayUsage } }。
 */
export async function fetchAccountData({ timeoutMs = 10000, getFlag } = {}) {
  const cred = resolveCredential(getFlag || flagValue);
  if (!cred) {
    const err = new Error('未找到 Coding Plan API Key(参数/环境变量/手动配置/ZCode 配置均无)');
    err.hint = '在 ZCode 模型设置中配置 Coding Plan Key,或设 ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL,'
      + '或运行 node usage.mjs --key <apiKey> --base <baseURL>';
    throw err;
  }
  const origin = new URL(cred.base).origin;
  const get = makeGet(origin, cred.token, timeoutMs);
  const quota = await get('/api/monitor/usage/quota/limit');

  const nowMs = Date.now();
  const qs = (startMs, endMs) => `?startTime=${encodeURIComponent(bjFmt(startMs))}&endTime=${encodeURIComponent(bjFmt(endMs))}`;
  const dayStart = bjDayStartMs(nowMs);
  const [modelUsage, toolUsage] = await Promise.all([
    get('/api/monitor/usage/model-usage' + qs(dayStart, nowMs)).catch(() => null),
    get('/api/monitor/usage/tool-usage' + qs(dayStart, nowMs)).catch(() => null),
  ]);

  return {
    account: mapQuotaToAccount(quota, nowMs),
    raw: {
      quota, modelUsage, toolUsage,
      dayUsage: splitDayUsage(modelUsage),
      toolsToday: mapToolUsageToday(toolUsage),
      credFrom: cred.from,
      origin,
    },
  };
}

// ---------- 展示辅助(hook 摘要与卡片共用) ----------
export function countdown(ms) {
  if (!ms || ms <= 0) return '';
  const min = Math.round(ms / 60000);
  const d = Math.floor(min / 1440), h = Math.floor((min % 1440) / 60), m = min % 60;
  const parts = [];
  if (d) parts.push(`${d} 天`);
  if (h) parts.push(`${h} 小时`);
  if (m || (!d && !h)) parts.push(`${m} 分钟`);
  return parts.join(' ') + '后';
}

/** 协议 account 段 → hook 一行摘要(格式沿用 zcode-usage,用户已习惯) */
export function accountSummaryLine(account, nowMs = Date.now()) {
  const part = (label, ring) => {
    if (!ring) return null;
    const reset = ring.resetAt > 0 ? `,${countdown(ring.resetAt - nowMs)}重置` : '';
    return `${label} ${Number(ring.pct).toFixed(0)}%${reset}`;
  };
  const parts = [
    part('MCP', account?.mcpMonthly),
    part('5小时池', account?.fiveHour),
    part('每周', account?.weekly),
  ].filter(Boolean);
  return parts.length ? parts.join(' · ') : '';
}

// ---------- 卡片(终端) ----------
const { bold, dim, c, rateStyle } = makeColorKit();
const fmtTs = (ts) => ts > 0
  ? new Date(ts).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
  : '—';

function bar(pct, width = 18) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  const filled = Math.round((p / 100) * width);
  return c(rateStyle(p), '▰'.repeat(filled) + '▱'.repeat(width - filled)) + '  ' + c(rateStyle(p), `已用 ${p.toFixed(1)}%`);
}

export function renderAccountCard(account, raw) {
  const lines = [];
  const rule = (ch) => c('2;36', ch.repeat(50));
  const LABEL_W = 22;
  lines.push(rule('━'));
  lines.push(bold(' ⚡ 码管家 · 账号用量'));
  lines.push(dim(`    ${account?.level || '?'} 套餐 · ${raw?.origin || ''} · ${new Date().toLocaleString('zh-CN')}`));
  lines.push(rule('━'));

  const rings = [
    ['🕐', '5 小时 Prompt 池', account?.fiveHour],
    ['📅', '每周额度', account?.weekly],
    ['🔧', 'MCP 工具调用(每月)', account?.mcpMonthly],
  ];
  for (const [icon, label, ring] of rings) {
    lines.push('');
    if (!ring) {
      lines.push(` ${icon}  ${bold(padEndW(label, LABEL_W))}${c('1;31', '!')}`);
      continue;
    }
    lines.push(` ${icon}  ${bold(padEndW(label, LABEL_W))}${bar(ring.pct)}`);
    if (ring === account?.mcpMonthly && ring.limit > 0) {
      lines.push(dim(`      已用 ${fmtNum(ring.used)} / ${fmtNum(ring.limit)} 次 · 剩余 ${fmtNum(Math.max(0, ring.limit - ring.used))}`));
    } else {
      lines.push(dim(`      剩余 ${(100 - ring.pct).toFixed(1)}%`));
    }
    if (ring.resetAt > 0) {
      lines.push(dim(`      ↻ ${fmtTs(ring.resetAt)} 重置(${countdown(ring.resetAt - Date.now())})`));
    }
    if (ring === account?.mcpMonthly) {
      const t = ring.tools || {};
      const parts = [];
      if (t.webSearch) parts.push(`联网搜索 ${fmtNum(t.webSearch)}`);
      if (t.webReader) parts.push(`网页读取 ${fmtNum(t.webReader)}`);
      if (t.zread) parts.push(`Zread ${fmtNum(t.zread)}`);
      if (parts.length) lines.push(dim(`      ${parts.join(' · ')}(月度)`));
    }
  }

  const day = raw?.dayUsage;
  if (day?.total?.calls) {
    lines.push('');
    lines.push(` 📊  ${bold(padEndW('当日模型用量', LABEL_W))}`
      + `${fmtNum(day.total.calls)} 次 · ${fmtTokens(day.total.tokens)} tokens`);
    const splitLine = (label, v) => dim(`      ${padEndW(label, 26)}${fmtNum(v.calls)} 次 · ${fmtTokens(v.tokens)} tokens`);
    lines.push(splitLine('高峰期(工作日 14–18 时)', day.peak));
    lines.push(splitLine('非高峰期', day.offPeak));
  }
  const tt = raw?.toolsToday;
  if (tt && (tt.webSearch || tt.webReader || tt.zread)) {
    const parts = [];
    if (tt.webSearch) parts.push(`联网搜索 ${fmtNum(tt.webSearch)}`);
    if (tt.webReader) parts.push(`网页读取 ${fmtNum(tt.webReader)}`);
    if (tt.zread) parts.push(`Zread ${fmtNum(tt.zread)}`);
    lines.push('');
    lines.push(` 🔌  ${bold(padEndW('当日 MCP 调用', LABEL_W))}${parts.join(' · ')}`);
  }

  lines.push('');
  lines.push(rule('━'));
  lines.push(dim(`    凭据来源 ${raw?.credFrom || '?'} · 加 --json 看原始数据`));
  return lines.join('\n');
}

// ---------- CLI 入口 ----------
async function main() {
  const nowMs = Date.now();
  let data;
  try {
    data = await fetchAccountData({ timeoutMs: asHook ? 5000 : 10000 });
  } catch (e) {
    if (asJson) {
      console.log(JSON.stringify({
        fetchedAt: new Date(nowMs).toISOString(),
        account: { fiveHour: null, weekly: null, mcpMonthly: null, peakNow: false, level: '?' },
        errors: [{ module: 'usage', message: e.message }],
      }, null, 2));
    } else {
      console.error('查询失败:', e.message);
      if (e.hint) console.error(e.hint);
      if (String(e.message).includes('HTTP 401')) {
        console.error('该 API Key 可能:1) 已失效或被更换;2) 不是 Coding Plan 专用 Key。请检查 ZCode 模型设置或智谱开放平台「个人编程套餐」。');
      }
    }
    process.exitCode = 1;
    return;
  }
  if (asJson) {
    console.log(JSON.stringify({
      fetchedAt: new Date(nowMs).toISOString(),
      account: data.account,
      raw: data.raw,
    }, null, 2));
    return;
  }
  console.log(renderAccountCard(data.account, data.raw));
}

// 仅作为可执行入口时运行(main 之外无副作用),供测试安全 import
const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) main().catch((e) => { console.error('查询失败:', e.message); process.exit(1); });
