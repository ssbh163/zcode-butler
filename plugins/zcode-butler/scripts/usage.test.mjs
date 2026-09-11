// usage 单测:北京时间纯函数 + quota→协议映射 + 当日拆分(结构取自真实接口响应)
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  bjFmt, bjDayStartMs, bjHourLabel, weekdayOfDateStr, isPeakHourLabel, peakOf,
  mapQuotaToAccount, mapToolUsageToday, splitDayUsage, countdown, accountSummaryLine,
} from './usage.mjs';

// 北京时间纯函数:全部显式 +08:00 折算,与本机时区无关
test('bjFmt / bjDayStartMs / bjHourLabel:UTC 运算不吃本机时区', () => {
  const ms = Date.parse('2026-09-08T03:25:00+08:00');
  assert.equal(bjFmt(ms), '2026-09-08 03:25:00');
  assert.equal(bjDayStartMs(ms), Date.parse('2026-09-08T00:00:00+08:00'));
  assert.equal(bjHourLabel(ms), '2026-09-08 03:00');
  // 跨日:北京 23:59 的"当日 00:00"还是同一天
  const late = Date.parse('2026-09-08T23:59:00+08:00');
  assert.equal(bjDayStartMs(late), Date.parse('2026-09-08T00:00:00+08:00'));
});

test('weekdayOfDateStr:走 Date.UTC;畸形返回 -1', () => {
  assert.equal(weekdayOfDateStr('2026-09-11'), 5); // 周五
  assert.equal(weekdayOfDateStr('2026-09-12'), 6);
  assert.equal(weekdayOfDateStr('bad'), -1);
});

// 日历事实:2026-09-07 周一,09-05 周六
test('isPeakHourLabel:工作日 14–17 点为高峰(左闭右开按小时桶,周末不算,畸形 false)', () => {
  assert.equal(isPeakHourLabel('2026-09-07 13:00'), false);
  assert.equal(isPeakHourLabel('2026-09-07 14:00'), true);
  assert.equal(isPeakHourLabel('2026-09-07 17:00'), true);
  assert.equal(isPeakHourLabel('2026-09-07 18:00'), false);
  assert.equal(isPeakHourLabel('2026-09-05 15:00'), false);
  assert.equal(isPeakHourLabel(''), false);
});

test('peakOf:逐小时桶归类 calls/tokens', () => {
  const mu = {
    x_time: ['2026-09-07 13:00', '2026-09-07 14:00', '2026-09-07 17:00', '2026-09-07 18:00', '2026-09-05 15:00'],
    modelCallCount: [1, 2, 4, 8, 16],
    tokensUsage: [10, 20, 40, 80, 160],
  };
  assert.deepEqual(peakOf(mu), { calls: 6, tokens: 60 });
  assert.deepEqual(peakOf({}), { calls: 0, tokens: 0 });
});

// 真实接口结构(2026-09-11 实测):TIME_LIMIT 自带月度 usageDetails;Prompt 环只有 percentage
const REAL_QUOTA = {
  level: 'pro',
  limits: [
    { type: 'TIME_LIMIT', unit: 5, number: 1, usage: 1000, currentValue: 110, remaining: 890, percentage: 11, nextResetTime: 1790071443998,
      usageDetails: [{ modelCode: 'search-prime', usage: 104 }, { modelCode: 'web-reader', usage: 3 }, { modelCode: 'zread', usage: 3 }] },
    { type: 'TOKENS_LIMIT', unit: 3, number: 5, percentage: 9, nextResetTime: 1789138996705 },
    { type: 'TOKENS_LIMIT', unit: 6, number: 1, percentage: 4, nextResetTime: 1789553043993 },
  ],
};

test('mapQuotaToAccount:三环映射 + tools 月度明细 + level', () => {
  // 取一个周五 15:00(北京)做 nowMs → peakNow = true
  const nowMs = Date.parse('2026-09-11T15:00:00+08:00');
  const a = mapQuotaToAccount(REAL_QUOTA, nowMs);
  assert.equal(a.level, 'PRO');
  assert.equal(a.peakNow, true);
  assert.deepEqual(a.mcpMonthly, {
    pct: 11, used: 110, limit: 1000, resetAt: 1790071443998, status: 'ok',
    tools: { webSearch: 104, webReader: 3, zread: 3 },
  });
  assert.deepEqual(a.fiveHour, { pct: 9, used: 0, limit: 0, resetAt: 1789138996705, status: 'ok' });
  assert.deepEqual(a.weekly, { pct: 4, used: 0, limit: 0, resetAt: 1789553043993, status: 'ok' });
  // 周六同时刻 → peakNow = false
  const sat = mapQuotaToAccount(REAL_QUOTA, Date.parse('2026-09-12T15:00:00+08:00'));
  assert.equal(sat.peakNow, false);
});

test('mapQuotaToAccount:limits 为空/畸形 → 三环 null 不抛', () => {
  const a = mapQuotaToAccount({ limits: [] }, 0);
  assert.equal(a.fiveHour, null);
  assert.equal(a.weekly, null);
  assert.equal(a.mcpMonthly, null);
  assert.equal(a.peakNow, false); // nowMs=0 → 1970 周四 08:00(北京),非高峰
  assert.doesNotThrow(() => mapQuotaToAccount(null, 0));
});

test('mapToolUsageToday:当日三项工具调用', () => {
  assert.deepEqual(
    mapToolUsageToday({ totalUsage: { totalSearchMcpCount: 2, totalWebReadMcpCount: 0, totalZreadMcpCount: 1 } }),
    { webSearch: 2, webReader: 0, zread: 1 },
  );
  assert.deepEqual(mapToolUsageToday(null), { webSearch: 0, webReader: 0, zread: 0 });
});

test('splitDayUsage:总量拆高峰/非高峰;序列缺失返回 null', () => {
  const mu = {
    x_time: ['2026-09-11 10:00', '2026-09-11 14:00'],
    modelCallCount: [30, 12],
    tokensUsage: [3000, 1200],
    totalUsage: { totalModelCallCount: 42, totalTokensUsage: 4200 },
  };
  const s = splitDayUsage(mu);
  assert.deepEqual(s.total, { calls: 42, tokens: 4200 });
  assert.deepEqual(s.peak, { calls: 12, tokens: 1200 }); // 2026-09-11 周五 14 点
  assert.deepEqual(s.offPeak, { calls: 30, tokens: 3000 });
  assert.equal(splitDayUsage({ totalUsage: { totalModelCallCount: 1 } }), null);
  assert.equal(splitDayUsage(null), null);
});

test('countdown:天/小时/分钟组合;非正数返回空', () => {
  assert.equal(countdown(0), '');
  assert.equal(countdown(-5), '');
  assert.equal(countdown(3 * 3600_000 + 45 * 60_000), '3 小时 45 分钟后');
  assert.equal(countdown((10 * 24 + 22) * 3600_000 + 46 * 60_000), '10 天 22 小时 46 分钟后');
});

test('accountSummaryLine:三环一行,环缺省跳过', () => {
  const a = mapQuotaToAccount(REAL_QUOTA, Date.parse('2026-09-11T15:00:00+08:00'));
  const line = accountSummaryLine(a, Date.parse('2026-09-11T15:00:00+08:00'));
  assert.match(line, /MCP 11%/);
  assert.match(line, /5小时池 9%/);
  assert.match(line, /每周 4%/);
  assert.equal(accountSummaryLine({ fiveHour: null, weekly: null, mcpMonthly: null }), '');
});
