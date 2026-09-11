// watch 单测:移植自 zcode-watch.test.mjs(纯函数与源项目逐字节等价,漂移控制锚点)
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_MONTHLY_QUOTA, MIN_WINDOW_HOURS,
  monthKeyOf, nextMonthStartOf, dayKeyOf,
  parseBillTime, parseTimeWindowStart, isPeakMinute,
  keyIdSegmentOf, aggregateRows, computePullStart, mergeBuckets,
  weightedOf, parseConfig, resetCacheIfStale,
  daysUntilReset, keysSummaryLine,
} from './watch.mjs';

// 日历事实:2026-09-04 是周五,09-05 周六,09-06 周日,09-07 周一
const D = (s) => new Date(s);

// ---------- 时间解析(账单 timeWindow 为服务端北京时间字符串;纯字符串切片,+08:00 折算 epoch,时区无关) ----------
test('parseBillTime:补零与不补零都吃,输出 date/hourKey/minuteOfDay/ms', () => {
  const a = parseBillTime('2026-09-08 11:25:00');
  assert.equal(a.date, '2026-09-08');
  assert.equal(a.hourKey, '2026-09-08 11');
  assert.equal(a.minuteOfDay, 11 * 60 + 25);
  assert.equal(a.ms, Date.parse('2026-09-08T11:25:00+08:00'));
  const b = parseBillTime('2026-9-4 1:05:00');
  assert.equal(b.date, '2026-09-04');
  assert.equal(b.hourKey, '2026-09-04 01');
  assert.equal(b.minuteOfDay, 65);
  assert.equal(parseBillTime('not a time'), null);
  assert.equal(parseBillTime(''), null);
});

test('parseTimeWindowStart:取波浪线左侧起始时刻,容忍空格,畸形返回 null', () => {
  const t = parseTimeWindowStart('2026-09-08 11:25:00~2026-09-08 11:26:00');
  assert.equal(t.minuteOfDay, 11 * 60 + 25);
  assert.equal(parseTimeWindowStart('2026-9-4 00:00:00 ~ 2026-9-4 23:59:59').date, '2026-09-04');
  assert.equal(parseTimeWindowStart(''), null);
  assert.equal(parseTimeWindowStart('随便'), null);
});

test('isPeakMinute:工作日 14:00–17:59 为高峰(分钟级,18:00 起非高峰,周末不算)', () => {
  assert.equal(isPeakMinute('2026-09-07', 13 * 60 + 59), false); // 周一 13:59
  assert.equal(isPeakMinute('2026-09-07', 14 * 60), true);        // 周一 14:00
  assert.equal(isPeakMinute('2026-09-07', 17 * 60 + 59), true);   // 周一 17:59
  assert.equal(isPeakMinute('2026-09-07', 18 * 60), false);       // 周一 18:00
  assert.equal(isPeakMinute('2026-09-05', 15 * 60), false);       // 周六
  assert.equal(isPeakMinute('坏日期', 900), false);                // 容错
});

// ---------- Key 段匹配 ----------
test('keyIdSegmentOf:取第一个点号前的 ID 段,无点号整串兜底', () => {
  assert.equal(keyIdSegmentOf('d65d3bb2f5194802943ae8e8e432a222.kJqTsecret'), 'd65d3bb2f5194802943ae8e8e432a222');
  assert.equal(keyIdSegmentOf('d65d3bb2f5194802943ae8e8e432a222.a.b'), 'd65d3bb2f5194802943ae8e8e432a222');
  assert.equal(keyIdSegmentOf('nodotkey'), 'nodotkey');
  assert.equal(keyIdSegmentOf('  trim.me  '), 'trim');
});

// ---------- 明细行聚合 ----------
test('aggregateRows:按 apiKey段×小时桶聚合,峰时按行时间判定,只计 输入/输出/缓存命中', () => {
  const rows = [
    // 周一 14:25 高峰分钟窗
    { apiKey: 'aaa111.xxx', timeWindow: '2026-09-07 14:25:00~2026-09-07 14:26:00', tokenType: '输入', usageCount: 100 },
    { apiKey: 'aaa111.xxx', timeWindow: '2026-09-07 14:25:00~2026-09-07 14:26:00', tokenType: '缓存命中', usageCount: 50 },
    // 同 Key 周一 15:00(仍高峰,另一小时桶)
    { apiKey: 'aaa111.xxx', timeWindow: '2026-09-07 15:00:00~2026-09-07 15:01:00', tokenType: '输出', usageCount: 30 },
    // 同 Key 周一 18:30(非高峰)
    { apiKey: 'aaa111.xxx', timeWindow: '2026-09-07 18:30:00~2026-09-07 18:31:00', tokenType: '输入', usageCount: 40 },
    // 周六 15:00(周末非高峰)
    { apiKey: 'aaa111.xxx', timeWindow: '2026-09-05 15:00:00~2026-09-05 15:01:00', tokenType: '输入', usageCount: 60 },
    // 工具行(按次计)与畸形行:不计入
    { apiKey: 'aaa111.xxx', timeWindow: '2026-09-07 14:25:00~2026-09-07 14:26:00', tokenType: '不区分输入输出', usageCount: 999 },
    { apiKey: 'aaa111.xxx', timeWindow: '', tokenType: '输入', usageCount: 5 },
    // 另一把 Key
    { apiKey: 'bbb222.yyy', timeWindow: '2026-09-07 14:25:00~2026-09-07 14:26:00', tokenType: '输入', usageCount: 7 },
    // 未配置的 Key 段:同样聚合缓存(后续添加该 Key 即有历史),展示层不读
    { apiKey: 'ccc333.zzz', timeWindow: '2026-09-07 14:25:00~2026-09-07 14:26:00', tokenType: '输入', usageCount: 8 },
  ];
  const agg = aggregateRows(rows);
  assert.deepEqual(agg['aaa111']['2026-09-07 14'], { tokens: 150, peak: 150 });
  assert.deepEqual(agg['aaa111']['2026-09-07 15'], { tokens: 30, peak: 30 });
  assert.deepEqual(agg['aaa111']['2026-09-07 18'], { tokens: 40, peak: 0 });
  assert.deepEqual(agg['aaa111']['2026-09-05 15'], { tokens: 60, peak: 0 });
  assert.deepEqual(agg['bbb222']['2026-09-07 14'], { tokens: 7, peak: 7 });
  assert.deepEqual(agg['ccc333']['2026-09-07 14'], { tokens: 8, peak: 8 });
});

// ---------- 缺口窗口计算 ----------
const H = 3600_000;
const BASE = 1_800_000_000_000; // 恰为整点(epoch 对齐北京时间整小时)

test('computePullStart:无缓存(首刷)→ 从月初全量', () => {
  const monthStart = BASE - 240 * H;
  const r = computePullStart(null, BASE, null, monthStart);
  assert.equal(r.startMs, monthStart);
  assert.equal(r.gapMs, Infinity);
});

test('computePullStart:gap 1h50m < 2h 保底 → 窗口 2h,起点向下取整到整点', () => {
  const r = computePullStart(BASE - 110 * 60_000, BASE, null, BASE - 240 * H);
  assert.equal(r.windowHours, MIN_WINDOW_HOURS);
  assert.equal(r.startMs, BASE - 2 * H);
});

test('computePullStart:gap 27h10m → 窗口 28h(向上取整到小时)', () => {
  const r = computePullStart(BASE - (27 * H + 10 * 60_000), BASE, null, BASE - 240 * H);
  assert.equal(r.windowHours, 28);
  assert.equal(r.startMs, BASE - 28 * H);
});

test('computePullStart:gap 恰 85h 整 → 窗口 85h(无缝衔接上次 watermark)', () => {
  const r = computePullStart(BASE - 85 * H, BASE, null, BASE - 240 * H);
  assert.equal(r.windowHours, 85);
  assert.equal(r.startMs, BASE - 85 * H);
});

test('computePullStart:时钟回拨(gap ≤ 0)→ 按保底 2h 处理', () => {
  const r = computePullStart(BASE + 5 * 60_000, BASE, null, BASE - 240 * H);
  assert.equal(r.windowHours, MIN_WINDOW_HOURS);
  assert.equal(r.startMs, BASE - 2 * H);
});

test('computePullStart:backlogUntil 比常规起点更早 → 起点延伸到 backlog(断点续拉)', () => {
  const r = computePullStart(BASE - 1 * H, BASE, BASE - 50 * H, BASE - 240 * H);
  assert.equal(r.startMs, BASE - 50 * H);
});

test('computePullStart:任何情况不早于当月 1 日 00:00', () => {
  const r = computePullStart(BASE - 30 * H, BASE, BASE - 90 * H, BASE - 3 * H);
  assert.equal(r.startMs, BASE - 3 * H);
});

// ---------- 小时桶覆盖合并 ----------
test('mergeBuckets:≥ 起点的桶以 fresh 覆盖(不在 fresh 即为 0,删除),< 起点的保持不动', () => {
  const settled = { aaa111: { '09-05 13': { tokens: 10, peak: 1 }, '09-05 14': { tokens: 20, peak: 2 }, '09-05 15': { tokens: 30, peak: 3 } } };
  const fresh = { aaa111: { '09-05 15': { tokens: 35, peak: 4 } } };
  const out = mergeBuckets(settled, fresh, '09-05 14');
  assert.deepEqual(out['aaa111'], {
    '09-05 13': { tokens: 10, peak: 1 },   // < 起点:保持
    '09-05 15': { tokens: 35, peak: 4 },    // ≥ 起点:覆盖
    // '09-05 14' ≥ 起点但 fresh 无 → 视为 0,删除
  });
});

test('mergeBuckets:多个 Key 段互不影响;固化区的段保留,重算区无行的段清零;空入参安全', () => {
  const settled = {
    a: { '1 10': { tokens: 1, peak: 0 } },   // 重算区,fresh 有 → 覆盖
    b: { '1 10': { tokens: 2, peak: 2 } },   // 重算区,fresh 无 → 该窗口用量为 0,删除
    c: { '1 08': { tokens: 4, peak: 1 } },   // 固化区(< 起点)→ 保留
  };
  const fresh = { a: { '1 10': { tokens: 9, peak: 0 } } };
  const out = mergeBuckets(settled, fresh, '1 09');
  assert.deepEqual(out.a['1 10'], { tokens: 9, peak: 0 });
  assert.equal(out.b, undefined);
  assert.deepEqual(out.c['1 08'], { tokens: 4, peak: 1 });
  assert.deepEqual(mergeBuckets({}, {}, 'x'), {});
});

// ---------- 缓存 v3 ----------
test('resetCacheIfStale:跨月整体清空;同月原样保留', () => {
  const stale = { version: 3, month: '2026-08', accounts: { c1: { watermark: 1 } }, keyAccount: { 'key-1': 'c1' }, lastResult: { ts: 1 } };
  const fresh = resetCacheIfStale(stale, '2026-09');
  assert.deepEqual(fresh, { version: 3, month: '2026-09', accounts: {}, keyAccount: {}, lastResult: null });
  const same = { version: 3, month: '2026-09', accounts: { c1: { watermark: 2 } }, keyAccount: {}, lastResult: null };
  assert.deepEqual(resetCacheIfStale(same, '2026-09'), same);
});

// ---------- 加权 / 配置 ----------
test('weightedOf:总使用额度 = 非高峰×1 + 高峰×3', () => {
  assert.equal(weightedOf(0, 0), 0);
  assert.equal(weightedOf(410, 610), 410 + 610 * 3);
});

test('parseConfig:BOM + CRLF 容错,缺省字段给默认值;错误信息指向传入的文件', () => {
  const { keys } = parseConfig('\uFEFF{"keys":\r\n[{"apiKey": " abc123 "}]}\r\n');
  assert.equal(keys[0].apiKey, 'abc123');
  assert.equal(keys[0].provider, 'bigmodel');
  assert.equal(keys[0].monthlyQuota, DEFAULT_MONTHLY_QUOTA);
  assert.equal(keys[0].name, 'Key 1');
  assert.equal(keys[0].id, 'key-1');
  assert.throws(() => parseConfig('{oops', '/x/butler.json'), /\/x\/butler\.json/);
});

test('日期辅助:monthKeyOf / nextMonthStartOf / dayKeyOf / daysUntilReset', () => {
  assert.equal(monthKeyOf(D('2026-09-07T23:59:59')), '2026-09');
  assert.deepEqual(nextMonthStartOf(D('2026-12-15T00:00:00')), D('2027-01-01T00:00:00'));
  assert.equal(dayKeyOf(D('2026-09-07T23:00:00')), '2026-09-07');
  assert.equal(daysUntilReset(D('2026-09-07T12:00:00')), 24);
});

// ---------- butler 协议摘要 ----------
test('keysSummaryLine:满额 Key 警告;无事为空', () => {
  const keys = [
    { name: '主力', tail: '····A1B2', status: 'ok', pct: 100 },
    { name: '备用', tail: '····C3D4', status: 'ok', pct: 42 },
    { name: '坏Key', tail: '····E5F6', status: 'error', pct: 100 },
  ];
  const line = keysSummaryLine(keys);
  assert.match(line, /1 把 Key 本月已用满/);
  assert.match(line, /主力 ····A1B2/);
  assert.equal(keysSummaryLine([{ name: 'a', tail: 't', status: 'ok', pct: 42 }]), '');
  assert.equal(keysSummaryLine([]), '');
});
