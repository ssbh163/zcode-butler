// status 单测:聚合降级(模块级 errors[] 不拖垮整体)+ 摘要行(零 IO,纯注入)
import test from 'node:test';
import assert from 'node:assert/strict';
import { collect, summaryLine } from './status.mjs';
import { emptyProtocol, validateProtocol, ringOf, mcpRingOf, keyCardOf, newsStateOf, newsCardOf } from './lib/protocol.mjs';

const fakeUsage = (account) => async () => ({ account, raw: {} });
const fakeWatch = (keys) => async () => ({ month: '2026-09', fetchedAt: Date.now(), keys });
const fakeNews = (unread = 0) => async () => ({
  unread, items: [newsCardOf({ id: 'n1', title: 't' })], channels: [],
});

test('collect:三模块全成 → 协议合法且校验通过', async () => {
  const { payload, raw } = await collect({
    deps: {
      fetchAccountData: fakeUsage({ fiveHour: ringOf({ pct: 3 }), weekly: null, mcpMonthly: null, peakNow: false }),
      runQuery: fakeWatch([keyCardOf({ id: 'k1', name: 'a', tier: 'PRO', tail: '····A1B2', pct: 42, usedWeighted: 7, quota: 10, peak: 1, offpeak: 2, resetDate: '2026-09-30', status: 'ok' })]),
      getNewsState: fakeNews(1),
    },
  });
  assert.equal(payload.account.fiveHour.pct, 3);
  assert.equal(payload.keys.length, 1);
  assert.equal(payload.news.unread, 1);
  assert.deepEqual(payload.errors, []);
  assert.deepEqual(validateProtocol(payload), []);
  assert.ok(raw.account && raw.watch && raw.news);
});

test('collect:usage 失败 → errors 记账,keys/news 不受影响(降级红线)', async () => {
  const { payload } = await collect({
    deps: {
      fetchAccountData: async () => { throw new Error('网络错误,无法连接 x'); },
      runQuery: fakeWatch([]),
      getNewsState: fakeNews(0),
    },
  });
  assert.deepEqual(payload.account, { fiveHour: null, weekly: null, mcpMonthly: null, peakNow: false });
  assert.equal(payload.errors.length, 1);
  assert.equal(payload.errors[0].module, 'usage');
  assert.match(payload.errors[0].message, /网络错误/);
  assert.equal(payload.keys.length, 0); // watch 模块返回空 keys,不是崩
  assert.deepEqual(validateProtocol(payload), []);
});

test('collect:watch 失败 → account 正常,errors 记 watch;三模块全挂仍输出合法骨架', async () => {
  const boom = async () => { throw new Error('HTTP 401'); };
  const half = await collect({
    deps: {
      fetchAccountData: fakeUsage({ fiveHour: null, weekly: null, mcpMonthly: mcpRingOf({ pct: 11 }), peakNow: false }),
      runQuery: boom,
      getNewsState: fakeNews(0),
    },
  });
  assert.equal(half.payload.account.mcpMonthly.pct, 11);
  assert.equal(half.payload.errors[0].module, 'watch');

  const all = await collect({ deps: { fetchAccountData: boom, runQuery: boom, getNewsState: boom } });
  assert.equal(all.payload.errors.length, 3);
  assert.deepEqual(all.payload.errors.map((e) => e.module).sort(), ['news', 'usage', 'watch']);
  assert.deepEqual(validateProtocol(all.payload), []);
});

test('summaryLine:三环 + 满额 + 未读拼接;全空 → 兜底文案', () => {
  const p = emptyProtocol();
  p.account.fiveHour = ringOf({ pct: 8, resetAt: Date.now() + 3.75 * 3600_000 });
  p.account.mcpMonthly = mcpRingOf({ pct: 11, resetAt: Date.now() + 10 * 24 * 3600_000 });
  p.account.weekly = ringOf({ pct: 4, resetAt: Date.now() + 5 * 24 * 3600_000 });
  p.keys = [keyCardOf({ id: 'k1', name: '主力', tier: 'PRO', tail: '····A1B2', pct: 100, usedWeighted: 0, quota: 1, peak: 0, offpeak: 0, resetDate: '2026-09-30', status: 'ok' })];
  p.news = newsStateOf([newsCardOf({ id: 'n1', title: 't' })], []);
  const line = summaryLine(p);
  assert.match(line, /^【码管家】/);
  assert.match(line, /MCP 11%/);
  assert.match(line, /5小时池 8%/);
  assert.match(line, /每月|每周/);
  assert.match(line, /1 把 Key 本月已用满/);
  assert.match(line, /1 条资讯未读/);
  assert.match(line, /node status\.mjs/);

  const quiet = summaryLine(emptyProtocol());
  assert.equal(quiet, '【码管家】暂无数据');
});
