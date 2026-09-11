#!/usr/bin/env node
/**
 * status.mjs —— 聚合器:悬浮窗 / 斜杠命令 / 对话 / CLI 四端唯一数据源(零依赖)
 *
 *   node status.mjs --json   统一协议输出(PROJECT.md §5,悬浮窗同源;输出前自检协议)
 *   node status.mjs --hook   SessionStart 摘要:读 ≤60 分钟 lastResult 零请求,过期实查(5s 超时)
 *   node status.mjs          终端大卡片(账号三环 + Key 月度 + 资讯)
 *
 * 降级纪律(AGENTS.md 红线):各模块独立 try/catch,单模块失败写 errors[],
 * 对应协议段落空/为 null,不得拖垮整体。
 */
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { makeColorKit } from './lib/api.mjs';
import { loadButlerCache, saveButlerCache, freshLastResult } from './lib/cache.mjs';
import {
  emptyProtocol, validateProtocol,
} from './lib/protocol.mjs';
import { fetchAccountData, renderAccountCard, accountSummaryLine } from './usage.mjs';
import { runQuery, renderWatchCard, keysSummaryLine } from './watch.mjs';
import { getNewsState, newsSummaryLine } from './news.mjs';

const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const asHook = argv.includes('--hook');

/**
 * 并行跑三模块并组装协议载荷。模块级降级:usage/watch 失败写 errors[];
 * news 读本地文件,失败也走 errors[](理论上不会)。
 * deps 供测试注入假模块(键:fetchAccountData/runQuery/getNewsState)。
 * 返回 { payload, raw }(raw 供卡片渲染,不进协议)。
 */
export async function collect({ timeoutMs = 10000, deps } = {}) {
  const d = { fetchAccountData, runQuery, getNewsState, ...deps };
  const payload = emptyProtocol();
  const raw = { account: null, watch: null, news: null };

  const usageTask = d.fetchAccountData({ timeoutMs })
    .then((r) => { payload.account = r.account; raw.account = r; })
    .catch((e) => { payload.errors.push({ module: 'usage', message: e.message }); });

  const watchTask = d.runQuery(timeoutMs)
    .then((w) => {
      payload.keys = w.keys;
      raw.watch = w;
      if (w.fromLegacy) raw.fromLegacy = w.fromLegacy;
    })
    .catch((e) => { payload.errors.push({ module: 'watch', message: e.message }); });

  const newsTask = (async () => {
    try {
      const n = await d.getNewsState(Date.parse(payload.fetchedAt));
      payload.news = { unread: n.unread, items: n.items };
      raw.news = n;
    } catch (e) { payload.errors.push({ module: 'news', message: e.message }); }
  })();

  await Promise.all([usageTask, watchTask, newsTask]);
  return { payload, raw };
}

/** 聚合 → hook 一行摘要(三环 + 满额 Key 警告 + 未读资讯;无事时输出极简一行) */
export function summaryLine(payload, nowMs = Date.now()) {
  const parts = [];
  const acc = accountSummaryLine(payload?.account, nowMs);
  if (acc) parts.push(acc);
  const kw = keysSummaryLine(payload?.keys);
  if (kw) parts.push(kw);
  const nw = newsSummaryLine(payload?.news);
  if (nw) parts.push(nw);
  if (!parts.length) return '【码管家】暂无数据';
  return `【码管家】${parts.join(' · ')}(如需详情运行 node status.mjs)`;
}

/** lastResult 读写(hook 零请求窗口;payload 只存协议所需,月键沿用 watch 的自然月) */
function persistLastResult(payload) {
  const cache = loadButlerCache();
  cache.lastResult = {
    ts: Date.parse(payload.fetchedAt),
    month: new Date(payload.fetchedAt).toISOString().slice(0, 7), // UTC 月份仅供人看,真正月判定在 watch 同步内
    payload: { account: payload.account, keys: payload.keys, news: payload.news },
  };
  saveButlerCache(cache);
}

// ---------- 终端大卡片 ----------
function renderFullCard({ payload, raw }) {
  const { bold, dim } = makeColorKit();
  const sections = [];
  if (raw.account) {
    sections.push(renderAccountCard(payload.account, raw.account.raw));
  } else {
    const err = payload.errors.find((e) => e.module === 'usage');
    sections.push(`⚡ 账号用量:${err ? '查询失败 — ' + err.message : '未运行'}`);
  }
  sections.push('');
  sections.push(renderWatchCard(raw.watch || { empty: true, keys: [] }));
  if (raw.news?.items?.length || raw.news?.channels?.length) {
    sections.push('');
    sections.push(renderNewsCardQuiet(raw.news));
  }
  if (payload.errors.length) {
    sections.push('');
    sections.push(bold(' ⚠ 降级模块:'));
    for (const e of payload.errors) sections.push(dim(`   ${e.module}: ${e.message}`));
  }
  return sections.join('\n');
}

// news.mjs 的卡片带 CLI 提示行,聚合卡片里复用主体但去掉安装指引式尾行
function renderNewsCardQuiet(state) {
  const { bold, dim } = makeColorKit();
  const lines = [' 📣  资讯'];
  for (const n of state.items.slice(0, 5)) {
    lines.push(` ${n.read ? ' ' : '●'} ${bold(n.title)}  ${dim(`${n.date} · ${n.source}`)}`);
  }
  if (state.unread > 0) lines.push(dim(`   …共 ${state.unread} 条未读(node news.mjs 查看)`));
  return lines.join('\n');
}

// ---------- 入口 ----------
async function main() {
  const nowMs = Date.now();

  if (asHook) {
    // ① 缓存新鲜 → 零请求
    const cache = loadButlerCache();
    const fresh = freshLastResult(cache, nowMs);
    let payload = fresh?.payload;
    if (!payload) {
      // ② 过期 → 实查(5s 超时,失败静默输出空摘要,不阻塞会话启动)
      try {
        const r = await collect({ timeoutMs: 5000 });
        payload = r.payload;
      } catch {
        payload = null;
      }
    }
    const line = payload ? summaryLine(payload, nowMs) : '【码管家】摘要暂不可用';
    console.log(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: line },
    }));
    return;
  }

  const { payload, raw } = await collect();
  const errs = validateProtocol(payload);
  if (errs.length) {
    // 协议生成有 bug:仍输出载荷供排查,但 stderr 高亮(悬浮窗应拒渲染)
    console.error(`协议自检失败(${errs.length}):`, errs.join('; '));
  }
  persistLastResult(payload);

  if (asJson) {
    console.log(JSON.stringify(payload, null, 2));
    return;
  }
  console.log(renderFullCard({ payload, raw }));
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) main().catch((e) => {
  console.error('聚合失败:', e.message);
  process.exit(1);
});
