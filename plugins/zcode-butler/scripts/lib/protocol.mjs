/**
 * lib/protocol.mjs —— status.mjs --json 统一协议(PROJECT.md §5)的构建与校验
 *
 * 悬浮窗 .ps1 / 斜杠命令 / SKILL.md / WIKI §5 四端同源;字段增删必须四端同步(AGENTS.md 红线)。
 * 时间口径:fetchedAt 为 ISO 字符串;resetAt 为 epoch ms 数字(渲染端自行折算倒计时);
 *           resetDate 为 'YYYY-MM-DD'(北京时间自然日)。
 */

export const PROTOCOL_VERSION = 1;

/** 进度环(5h 池 / 每周):pct 0-100;失败时整环 null(由 errors[] 携带原因) */
export function ringOf({ pct, used, limit, resetAt }, status = 'ok') {
  return {
    pct: Math.round(Number(pct) || 0),
    used: Number(used) || 0,
    limit: Number(limit) || 0,
    resetAt: Number(resetAt) || 0,
    status,
  };
}

/** MCP 月度环:tools = 当日三项工具调用数(服务端只有当日口径) */
export function mcpRingOf({ pct, used, limit, resetAt, tools = {} }, status = 'ok') {
  return {
    ...ringOf({ pct, used, limit, resetAt }, status),
    tools: {
      webSearch: Number(tools.webSearch) || 0,
      webReader: Number(tools.webReader) || 0,
      zread: Number(tools.zread) || 0,
    },
  };
}

/** Key 卡:peak/offpeak 为原始 token,usedWeighted = offpeak + peak×3(加权口径);
 *  provider/incomplete 为终端卡片扩展字段(悬浮窗可忽略,不计入校验必填项) */
export function keyCardOf(k) {
  return {
    id: String(k.id),
    name: String(k.name),
    tier: String(k.tier || '未知'),
    tail: String(k.tail || ''),
    pct: Math.round(Number(k.pct) || 0),
    usedWeighted: Number(k.usedWeighted) || 0,
    quota: Number(k.quota) || 0,
    peak: Number(k.peak) || 0,
    offpeak: Number(k.offpeak) || 0,
    resetDate: String(k.resetDate || ''),
    status: k.status === 'error' ? 'error' : 'ok',
    provider: k.provider === 'zai' ? 'zai' : 'bigmodel',
    incomplete: !!k.incomplete,
    ...(k.error ? { error: String(k.error) } : {}),
  };
}

export const newsCardOf = (n) => ({
  id: String(n.id),
  title: String(n.title),
  date: String(n.date || ''),
  source: String(n.source || ''),
  level: n.level === 'warn' ? 'warn' : 'info',
  ...(n.url ? { url: String(n.url) } : {}),
});

/** 协议 news 段:items 全量最新在前(悬浮窗悬停预览取前 2 条,面板展示全量),条目带 read 已读标记 */
export function newsStateOf(items, readIds) {
  const read = new Set(readIds || []);
  const marked = items.map((n) => ({ ...n, read: read.has(n.id) }));
  return { unread: marked.filter((n) => !n.read).length, items: marked };
}

/** 空载荷骨架(全部模块未跑时的起点) */
export function emptyProtocol(nowMs = Date.now()) {
  return {
    protocolVersion: PROTOCOL_VERSION,
    fetchedAt: new Date(nowMs).toISOString(),
    account: { fiveHour: null, weekly: null, mcpMonthly: null, peakNow: false },
    keys: [],
    news: { unread: 0, items: [] },
    errors: [],
  };
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const RING_FIELDS = ['pct', 'used', 'limit', 'resetAt', 'status'];

/**
 * 协议校验:返回错误描述数组(空数组 = 合法)。悬浮窗拿到非空数组应拒渲染并提示。
 * 只校验结构与类型,不校验业务数值合理性(那是各模块的事)。
 */
export function validateProtocol(p) {
  const errs = [];
  if (!isObj(p)) return ['payload 不是对象'];
  if (p.protocolVersion !== PROTOCOL_VERSION) errs.push(`protocolVersion 应为 ${PROTOCOL_VERSION}`);
  if (typeof p.fetchedAt !== 'string') errs.push('fetchedAt 应为 ISO 字符串');

  const checkRing = (name, ring) => {
    if (ring === null) return; // 模块失败时对应环为 null 并入 errors,合法
    if (!isObj(ring)) { errs.push(`account.${name} 应为对象或 null`); return; }
    for (const f of RING_FIELDS) {
      if (f === 'status') {
        if (ring.status !== 'ok' && ring.status !== 'error') errs.push(`account.${name}.status 应为 ok|error`);
      } else if (typeof ring[f] !== 'number') {
        errs.push(`account.${name}.${f} 应为数字`);
      }
    }
    if (name === 'mcpMonthly' && isObj(ring) && !isObj(ring.tools)) {
      errs.push('account.mcpMonthly.tools 应为对象');
    }
  };
  if (!isObj(p.account)) {
    errs.push('account 应为对象');
  } else {
    checkRing('fiveHour', p.account.fiveHour);
    checkRing('weekly', p.account.weekly);
    checkRing('mcpMonthly', p.account.mcpMonthly);
    if (typeof p.account.peakNow !== 'boolean') errs.push('account.peakNow 应为布尔');
  }

  if (!Array.isArray(p.keys)) {
    errs.push('keys 应为数组');
  } else {
    p.keys.forEach((k, i) => {
      if (!isObj(k)) { errs.push(`keys[${i}] 应为对象`); return; }
      for (const f of ['id', 'name', 'tier', 'tail', 'resetDate', 'status']) {
        if (typeof k[f] !== 'string') errs.push(`keys[${i}].${f} 应为字符串`);
      }
      for (const f of ['pct', 'usedWeighted', 'quota', 'peak', 'offpeak']) {
        if (typeof k[f] !== 'number') errs.push(`keys[${i}].${f} 应为数字`);
      }
    });
  }

  if (!isObj(p.news)) {
    errs.push('news 应为对象');
  } else {
    if (typeof p.news.unread !== 'number') errs.push('news.unread 应为数字');
    if (!Array.isArray(p.news.items)) {
      errs.push('news.items 应为数组');
    } else {
      p.news.items.forEach((n, i) => {
        if (!isObj(n) || typeof n.id !== 'string' || typeof n.title !== 'string') {
          errs.push(`news.items[${i}] 缺 id/title 字符串字段`);
        }
      });
    }
  }

  if (!Array.isArray(p.errors)) errs.push('errors 应为数组');
  else p.errors.forEach((e, i) => {
    if (!isObj(e) || typeof e.module !== 'string' || typeof e.message !== 'string') {
      errs.push(`errors[${i}] 应含 module/message 字符串字段`);
    }
  });
  return errs;
}
