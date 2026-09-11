// cache + news 单测:新鲜度窗口 / 资讯解析与已读
import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { loadButlerCache, saveButlerCache, freshLastResult, CACHE_FILE } from './lib/cache.mjs';
import { resolveNewsItems, resolveChannels, expiresMsOf, newsSummaryLine } from './news.mjs';

// ---------- cache:走真实 ~/.zcode 文件(自有文件,测试前后快照还原) ----------
const BACKUP = CACHE_FILE + '.bak';
const snapshot = () => { try { fs.copyFileSync(CACHE_FILE, BACKUP); return true; } catch { return false; } };
const restore = (had) => {
  if (had) { fs.copyFileSync(BACKUP, CACHE_FILE); fs.rmSync(BACKUP, { force: true }); }
  else fs.rmSync(CACHE_FILE, { force: true });
};

test('cache:坏文件当骨架;save→load 往返;freshLastResult 新鲜度窗口', () => {
  const had = snapshot();
  try {
    fs.mkdirSync(path.dirname(CACHE_FILE), { recursive: true });
    fs.writeFileSync(CACHE_FILE, '{oops', 'utf8'); // 坏 JSON
    assert.deepEqual(loadButlerCache(), { version: 3, month: '', accounts: {}, keyAccount: {}, lastResult: null });

    const now = 1_800_000_000_000;
    saveButlerCache({ version: 3, month: '2026-09', accounts: { c1: { watermark: now } }, keyAccount: { 'k1': 'c1' }, lastResult: { ts: now, month: '2026-09', payload: { keys: [] } } });
    const loaded = loadButlerCache();
    assert.equal(loaded.month, '2026-09');
    assert.equal(loaded.accounts.c1.watermark, now);

    assert.equal(freshLastResult(loaded, now, '2026-09')?.ts, now);            // 同刻同月 → 新鲜
    assert.equal(freshLastResult(loaded, now + 59 * 60_000, '2026-09')?.ts, now); // 59 分钟 → 新鲜
    assert.equal(freshLastResult(loaded, now + 61 * 60_000, '2026-09'), null);   // 超过 60 分钟 → 过期
    assert.equal(freshLastResult(loaded, now, '2026-10'), null);                 // 跨月 → 过期
    assert.equal(freshLastResult({ lastResult: null }, now), null);              // 无记录
  } finally {
    restore(had);
  }
});

// ---------- news:纯函数(assets 解析 / 过期 / 已读) ----------
const RAW = {
  items: [
    { id: 'n2', title: '第二条', date: '09-10', source: '智谱', level: 'warn', url: 'https://x' },
    { id: 'n1', title: '第一条', date: '09-11', source: 'ZCode' },
    { id: 'n3', title: '已过期', date: '09-01', source: 'x', expiresAt: '2026-09-05' },
    { id: 'n4', title: '未过期', date: '09-02', source: 'x', expiresAt: '2030-01-01' },
    { bad: 1 }, // 缺 id/title → 丢弃
  ],
  channels: [{ name: '智谱开放平台', url: 'https://open.bigmodel.cn' }, { name: '坏' }],
};

test('expiresMsOf:北京时间当日 23:59:59 到期;畸形 Infinity(不过滤)', () => {
  assert.equal(expiresMsOf('2026-09-05'), Date.parse('2026-09-05T23:59:59+08:00'));
  assert.equal(expiresMsOf(''), Infinity);
  assert.equal(expiresMsOf('2026/09/05'), Infinity);
});

test('resolveNewsItems:字段过滤 + 过期过滤 + 按日期新→旧', () => {
  const now = Date.parse('2026-09-11T12:00:00+08:00');
  const items = resolveNewsItems(RAW, now);
  assert.deepEqual(items.map((n) => n.id), ['n1', 'n2', 'n4']); // n3 过期、坏行丢弃,n1 最新在前
  assert.equal(items[0].read, undefined); // read 标记由 newsStateOf 加,resolve 不加
  assert.deepEqual(resolveNewsItems(null), []);
});

test('resolveChannels:缺 url 丢弃', () => {
  assert.deepEqual(resolveChannels(RAW), [{ name: '智谱开放平台', url: 'https://open.bigmodel.cn' }]);
});

test('newsSummaryLine:有未读才输出', () => {
  assert.equal(newsSummaryLine({ unread: 3 }), '🔔 3 条资讯未读');
  assert.equal(newsSummaryLine({ unread: 0 }), '');
  assert.equal(newsSummaryLine(undefined), '');
});
