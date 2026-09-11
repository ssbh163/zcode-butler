#!/usr/bin/env node
/**
 * news.mjs —— 活动资讯(PROJECT.md §6.4:数据源可插拔,首期本地 assets/news.json,不做抓取)
 *
 * 数据源接口约定(二期可加远程源而不改架构):
 *   resolve() → [{ id, title, date, source, level: 'info'|'warn', url?, expiresAt? }]
 *   - expiresAt('YYYY-MM-DD')到期条目自动过滤
 *   - items 已按新→旧人工维护;已读状态在 ~/.zcode/butler-news-read.json
 *
 * CLI:node news.mjs [--json] [--read-all] [--read <id>]
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readJsonDefensive, makeColorKit } from './lib/api.mjs';
import { newsCardOf, newsStateOf } from './lib/protocol.mjs';

const NEWS_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'news.json');
const READ_FILE = path.join(os.homedir(), '.zcode', 'butler-news-read.json');

const argv = process.argv.slice(2);
const flagValue = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

/** 'YYYY-MM-DD' → epoch(当日 23:59:59 到期,给人工维护留全天余量);畸形返回 Infinity(不过滤) */
export function expiresMsOf(dateStr) {
  const m = String(dateStr || '').match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return Infinity;
  const ms = Date.parse(`${m[1]}-${m[2]}-${m[3]}T23:59:59+08:00`);
  return Number.isFinite(ms) ? ms : Infinity;
}

/**
 * news.json 原始对象 → 协议条目数组(纯函数):字段清洗 + 过期过滤 + 兜底排序(新→旧)。
 * 文件不存在/结构异常返回 [](资讯缺位不拖垮聚合)。
 */
export function resolveNewsItems(rawObj, nowMs = Date.now()) {
  const arr = Array.isArray(rawObj?.items) ? rawObj.items : [];
  return arr
    .filter((n) => n && typeof n.id === 'string' && typeof n.title === 'string')
    .filter((n) => nowMs < expiresMsOf(n.expiresAt))
    .map((n) => newsCardOf(n))
    .sort((a, b) => String(b.date).localeCompare(String(a.date)));
}

/** 官方渠道直达链接清单(README/资讯面板底部共用) */
export function resolveChannels(rawObj) {
  const arr = Array.isArray(rawObj?.channels) ? rawObj.channels : [];
  return arr
    .filter((ch) => ch && typeof ch.name === 'string' && typeof ch.url === 'string')
    .map((ch) => ({ name: String(ch.name), url: String(ch.url) }));
}

function readIds() {
  const obj = readJsonDefensive(READ_FILE);
  return Array.isArray(obj?.ids) ? obj.ids.filter((x) => typeof x === 'string') : [];
}

function writeIds(ids) {
  try {
    fs.mkdirSync(path.dirname(READ_FILE), { recursive: true });
    fs.writeFileSync(READ_FILE, JSON.stringify({ ids }, null, 2) + '\n', 'utf8');
  } catch { /* 已读写失败不影响输出 */ }
}

/** 资讯状态(协议 news 段):unread + 全量 items(最新在前) */
export function getNewsState(nowMs = Date.now()) {
  const raw = readJsonDefensive(NEWS_FILE) || {};
  const items = resolveNewsItems(raw, nowMs);
  return { ...newsStateOf(items, readIds()), channels: resolveChannels(raw) };
}

/** 标记全部已读;返回新状态 */
export function markAllRead() {
  const state = getNewsState();
  writeIds([...new Set([...readIds(), ...state.items.map((n) => n.id)])]);
  return getNewsState();
}

/** 标记单条已读 */
export function markRead(id) {
  if (!id) return getNewsState();
  writeIds([...new Set([...readIds(), id])]);
  return getNewsState();
}

/** 协议 news 段 → hook 一行摘要(空 = 无未读,不注入) */
export function newsSummaryLine(news) {
  const unread = Number(news?.unread) || 0;
  return unread > 0 ? `🔔 ${unread} 条资讯未读` : '';
}

// ---------- 卡片 ----------
export function renderNewsCard(state) {
  const { bold, dim } = makeColorKit();
  const lines = [' ⚡ 码管家 · 资讯', ''];
  if (!state.items.length) {
    lines.push(dim('   (暂无资讯;数据源人工维护于 assets/news.json)'));
  }
  for (const n of state.items) {
    lines.push(` ${n.read ? ' ' : '●'} ${bold(n.title)}  ${dim(`${n.date} · ${n.source}`)}${n.level === 'warn' ? ' ⚠' : ''}`);
  }
  if (state.channels.length) {
    lines.push('');
    lines.push(dim('   官方渠道:'));
    for (const ch of state.channels) lines.push(dim(`   · ${ch.name} ${ch.url}`));
  }
  if (state.unread > 0) {
    lines.push('');
    lines.push(dim(`   ${state.unread} 条未读 · node news.mjs --read-all 全部标已读`));
  }
  return lines.join('\n');
}

// ---------- CLI ----------
async function main() {
  if (argv.includes('--read-all')) {
    const s = markAllRead();
    console.log(`已标记 ${s.items.length} 条资讯为已读。`);
    return;
  }
  const oneId = flagValue('--read');
  if (oneId) {
    markRead(oneId);
    console.log(`已标记 ${oneId} 为已读。`);
    return;
  }
  const state = getNewsState();
  if (argv.includes('--json')) {
    console.log(JSON.stringify(state, null, 2));
    return;
  }
  console.log(renderNewsCard(state));
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (isMain) main().catch((e) => { console.error('资讯读取失败:', e.message); process.exit(1); });
