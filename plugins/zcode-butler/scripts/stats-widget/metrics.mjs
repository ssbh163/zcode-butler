#!/usr/bin/env node
/**
 * metrics.mjs — v0.13q 性能浮标真数据采集器(码管家 stats-widget)
 * 需以 node --experimental-sqlite 启动(宿主 spawn 已带;node:sqlite 在 22.12 为实验特性)。
 *
 * 双通道架构(2026-09-29 定案,方案②):
 *   实时通道 = anchor-probe-ui.ps1 每 ~240ms 读转录区 Document 文本长度(UIA 投影层,
 *             实测 216ms 节拍 10-70 字符/批,思考+文字边流边渲染),正增量追加
 *             ~/.zcode/stats-widget-live.jsonl {"t":ms,"chars":delta};本进程 tail 之。
 *   真值通道 = db.sqlite model_usage 表(只读):本轮平均 = Σoutput/Σ(duration−ttft),
 *             最近请求解码率 = 单行 output×1000÷(duration−ttft)(v0.2.71,与官方 Token
 *             调试面板 calculateOutputTps 同口径);TTFT = 会话平均;并与 live 字符按
 *             [started_at,completed_at] 时间窗对齐自校准 chars/token 比(初值 3.2,EMA)。
 * 已证伪勿回头:part 表 text/reasoning 行流式期间不增长(完成时一次性落库,实验
 *   part-trans.txt);"db.sqlite/WAL 流式冻结"是文件尺寸观测盲区,但行也不流式。
 * 偏差声明:①实时 token 数=字符/校准比(真值只在调用末);**实时通道已停用**
 *   (UIA 转录层与 stdio wrapper 两案皆败,等官方接口;tok/s 回落链 = live ?? 最近
 *   请求解码率 ?? 会话均值——流式中显示的是**上一完成请求**的解码率,当前请求落库
 *   瞬间刷新,请求级近实时非逐 chunk,调查详见 docs/knowledge/2026-10-11-decode速度数据源调查.md);
 *   ②「当前会话」三信号(v0.13f):(a) **UIA 视图通道为主**——探针扫侧栏选中条目
 *   (bg-selected 的 task-row)写标题到 stats-widget-view.json,本进程查 db
 *   session.title 映射回会话(切回已驻留会话时 app log 静默,UIA 是唯一视图信号);
 *   (b) app log 的 session.resumed(非驻留打开/恢复);(c) 其余会话首个
 *   model.request.started/turn.started 跟随(workflow 子代理 sess_dwf-* 永不接管);
 *   启动引导 = 最近 model_usage 写入者。三者汇入同一"切换 + 按 db 历史重建"。
 * 输出契约 ~/.zcode/stats-widget-metrics.json:
 *   {"t":ms,"phase":"idle|waiting|stream|done","tps":n|null(=live??最近请求??会话均值),"turnAvg":n|null,"ttft":s|null}
 */
import fs from 'node:fs';
import path from 'node:path';
const { DatabaseSync } = await import('node:sqlite');

const dot = path.join(process.env.USERPROFILE, '.zcode');
const outFile = path.join(dot, 'stats-widget-metrics.json');
const liveFile = path.join(dot, 'stats-widget-live.jsonl');
const viewFile = path.join(dot, 'stats-widget-view.json');
const dbPath = path.join(dot, 'cli', 'db', 'db.sqlite');
const logDir = path.join(dot, 'cli', 'log');

// ---- oc-tps 常量 ----
const STREAM_WINDOW_MS = 5000;
const LIVE_STALE_MS = 1500;
const SINGLE_SAMPLE_MS = 1000;

// ---- state ----
let db = null;
let lastMuRid = -1;
let activeSession = '';
let bootRebuilt = false;         // v0.13e:自举后按 db 历史重建一次当前会话聚合

const liveRaw = [];             // {t, chars} 近 10 分钟原始字符样本(校准对时用)
const samples = [];             // {at, tokens} 5s 滑窗(oc-tps)
const turns = new Map();        // turnId -> {out, dec} 真值回合聚合
const tot = { out: 0, dec: 0, ttft: 0, ttftN: 0 };
const ttftWin = [];             // 近期非空 ttft(显示中位数用,≤8)
let lastKnownTtft = null;       // NULL-ttft 行的估算代理(同上下文规模最相近)
let ratio = 3.2;                // chars per token(自校准)
let lastTurnId = null;
let lastReqTps = null;          // v0.2.71:最近完成请求的解码率(单行口径,官方 calculateOutputTps 同款)
let phase = 'idle';
let lastActivity = Date.now();
let logTail = null;
let lastWrite = 0;

function openReader(file, skipExisting) {
  let fd, offset = 0;
  try { fd = fs.openSync(file, 'r'); if (skipExisting) offset = fs.fstatSync(fd).size; } catch { return null; }
  return { file, fd, offset, buf: '' };
}
function readNew(r) {
  if (!r) return [];
  try {
    const st = fs.fstatSync(r.fd);
    if (st.size < r.offset) { r.offset = 0; r.buf = ''; }
    if (st.size === r.offset) return [];
    const buf = Buffer.alloc(st.size - r.offset);
    fs.readSync(r.fd, buf, 0, buf.length, r.offset);
    r.offset += buf.length;
    r.buf += buf.toString('utf8');
    const lines = r.buf.split('\n');
    r.buf = lines.pop() ?? '';
    return lines;
  } catch { return []; }
}

function openDb() {
  try {
    if (db) { try { db.close(); } catch { } db = null; }
    db = new DatabaseSync(dbPath, { readOnly: true });
    lastMuRid = db.prepare('SELECT max(rowid) AS m FROM model_usage').get().m ?? 0;
    // 启动引导:最近 model_usage 写入者为活跃会话(首个 log 事件到来后由 log 接管)
    const b = db.prepare('SELECT session_id AS s FROM model_usage ORDER BY rowid DESC LIMIT 1').get();
    if (b && b.s) activeSession = b.s;
    return true;
  } catch { db = null; return false; }
}

function todayLog() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return path.join(logDir, `zcode-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}.jsonl`);
}

// ---- oc-tps activeDuration(逐字对齐) ----
function activeDuration(ss, tailAt) {
  if (ss.length === 0) return 0;
  if (ss.length === 1) {
    const tail = Math.max(0, tailAt - ss[0].at);
    return Math.min(Math.max(tail, 250), SINGLE_SAMPLE_MS);
  }
  let d = 0;
  for (let i = 1; i < ss.length; i++) d += Math.max(0, ss[i].at - ss[i - 1].at);
  d += Math.max(0, tailAt - ss[ss.length - 1].at);
  return Math.max(d, SINGLE_SAMPLE_MS);
}
function liveTps(now) {
  while (samples.length && now - samples[0].at > STREAM_WINDOW_MS) samples.shift();
  if (samples.length === 0) return null;
  if (now - samples[samples.length - 1].at > LIVE_STALE_MS) return null;
  const tokens = samples.reduce((s, x) => s + x.tokens, 0);
  return tokens / (activeDuration(samples, now) / 1000);
}
function turnAvgOf(id) {
  const t = turns.get(id);
  if (!t || t.dec <= 0) return null;
  return t.out / (t.dec / 1000);
}
function medianTtftSec() {
  // TTFT 显示 = 近期非空值中位数(oc-tps 用累计均值,但 40 万 token 上下文的冷缓存轮
  // 会出现 8-41s 离群值,均值被砸穿;中位数才是"典型等待")
  if (ttftWin.length === 0) return null;
  const a = [...ttftWin].sort((x, y) => x - y);
  const m = a[Math.floor(a.length / 2)];
  return Math.round((m / 1000) * 100) / 100;
}
function writeMetrics(force) {
  const now = Date.now();
  if (!force && now - lastWrite < 250) return;
  lastWrite = now;
  const live = liveTps(now);
  const sessAvg = tot.dec > 0 ? tot.out / (tot.dec / 1000) : null;
  const ta = turnAvgOf(lastTurnId);
  // v0.2.71 回落链:live(已死)→ 最近完成请求解码率 → 会话均值。HTML"速度位合一"
  // (2026-09-29 拍板:流式中显示实时速度=最近完成调用的解码率,done 切 turnAvg)
  // 的原始意图至此闭环——live 死后旧实现回落错档到 sessAvg。
  const j = {
    t: now,
    phase,
    tps: live ?? lastReqTps ?? sessAvg,
    turnAvg: ta === null ? null : Math.round(ta * 100) / 100,
    ttft: medianTtftSec(),
    calls: tot.ttftN,
  };
  try { fs.writeFileSync(outFile, JSON.stringify(j)); } catch { }
}

// ---- 实时通道:live.jsonl(UIA 转录区) + live2.jsonl(stdio wrapper 字符级,含思考) ----
const liveTails = [];
function pollLive() {
  for (const f of [liveFile, path.join(dot, 'stats-widget-live2.jsonl')]) {
    let t = liveTails.find((x) => x && x.file === f);
    if (!t) { t = openReader(f, true); liveTails.push(t); }
    for (const l of readNew(t)) {
      if (!l.trim()) continue;
      try {
        const j = JSON.parse(l);
        if (!(j.chars > 0) || !j.t) continue;
        liveRaw.push({ t: j.t, chars: j.chars });
        while (liveRaw.length && Date.now() - liveRaw[0].t > 600000) liveRaw.shift();
        samples.push({ at: j.t, tokens: Math.max(1, j.chars / ratio) });
        if (phase === 'waiting') phase = 'stream';
        lastActivity = Date.now();
      } catch { }
    }
  }
}

// ---- 真值通道:model_usage(平均/TTFT/校准) ----
// 单行聚合(实时增量与会话重建共用)
function absorbRow(r) {
  // NULL-ttft 估算:纯工具调段无文本 token → first_token_at 为空(实测把整段时长
  // 计入分母会把平均速度从 ~57 稀释到 ~44)。用最近已知 ttft 代理(同上下文规模),
  // oc-tps 语义(时长不含首包等待)得以在这些行同样成立
  const ttftEff = (r.ttft != null && r.ttft > 0) ? r.ttft : lastKnownTtft;
  const dec = Math.max(r.dur - (ttftEff ?? 0), 1);
  const t = turns.get(r.tid) || { out: 0, dec: 0 };
  t.out += r.out; t.dec += dec;
  turns.set(r.tid, t);
  if (turns.size > 20) turns.delete(turns.keys().next().value);
  tot.out += r.out; tot.dec += dec;
  lastReqTps = r.out * 1000 / dec;   // v0.2.71:单行解码率(重建时按 rowid 顺序吸收,终值=该会话最近完成请求)
  if (r.ttft != null && r.ttft > 0) {
    tot.ttft += r.ttft; tot.ttftN++;
    lastKnownTtft = r.ttft;
    ttftWin.push(r.ttft);
    if (ttftWin.length > 8) ttftWin.shift();
  }
  lastTurnId = r.tid;
  // 字符比自校准:live 字符按调用时间窗对齐(重建旧会话时 liveRaw 不覆盖其时间窗,天然跳过)
  if (r.st && r.fin && r.out > 20) {
    let chars = 0;
    for (const s of liveRaw) if (s.t >= r.st && s.t <= r.fin) chars += s.chars;
    if (chars > 200) {
      const nr = chars / r.out;
      if (isFinite(nr) && nr > 0.5 && nr < 12) ratio = ratio * 0.7 + nr * 0.3;
    }
  }
}

function resetAggregates() {
  samples.length = 0; turns.clear();
  tot.out = 0; tot.dec = 0; tot.ttft = 0; tot.ttftN = 0;
  ttftWin.length = 0; lastKnownTtft = null; lastTurnId = null; lastReqTps = null;
}

// v0.13e 会话切换:按 db 历史整体重建目标会话聚合——切换/恢复会话立即显示该会话
// 自己的平均/TTFT/调用数,不等首个请求(修「切换会话仍显示上一会话数据」)。
// lastMuRid 事后对齐到库内最大:重建已吸收的行不得再被增量轮询二次吸收
function rebuildSessionAggregates(sid) {
  resetAggregates();
  if (!db && !openDb()) return 0;
  let n = 0;
  try {
    const rows = db.prepare(
      'SELECT turn_id AS tid, started_at AS st, completed_at AS fin, duration_ms AS dur, ' +
      'time_to_first_token_ms AS ttft, output_tokens AS out FROM model_usage ' +
      'WHERE session_id = ? ORDER BY rowid').all(sid);
    for (const r of rows) {
      if (!r.tid || !(r.out > 0) || !(r.dur > 0)) continue;
      absorbRow(r); n++;
    }
    const mx = db.prepare('SELECT max(rowid) AS m FROM model_usage').get().m;
    if (mx > lastMuRid) lastMuRid = mx;
  } catch { db = null; return 0; }
  return n;
}

function pollModelUsage() {
  if (!db) { if (!openDb()) return; }
  if (!bootRebuilt) {
    // v0.13e 启动自举:确定活跃会话后立即按 db 历史重建其聚合——重启/换代后
    // 胶囊即刻显示该会话真实平均/TTFT,不再从零等待首个请求完成
    bootRebuilt = true;
    rebuildSessionAggregates(activeSession);
  }
  let rows;
  try {
    rows = db.prepare(
      'SELECT rowid AS rid, session_id AS sid, turn_id AS tid, started_at AS st, completed_at AS fin, ' +
      'duration_ms AS dur, time_to_first_token_ms AS ttft, output_tokens AS out FROM model_usage ' +
      'WHERE rowid > ? ORDER BY rowid').all(lastMuRid);
  } catch { db = null; return; }
  for (const r of rows) {
    if (r.rid > lastMuRid) lastMuRid = r.rid;
    if (!r.tid || r.sid !== activeSession || !(r.out > 0) || !(r.dur > 0)) continue;
    absorbRow(r);
    lastActivity = Date.now();
  }
}

// ---- 会话视图通道(v0.13f):探针写的侧栏选中条目标题 → db session.title 映射回会话 ----
// 补 session.resumed 盲区:切回"已驻留"会话 app log 零事件(2026-09-30 实测),
// UIA 侧栏选中态是唯一能看见"用户在看哪个会话"的信号。条目名 = "标题 相对时间",
// 先按全名查,再剥尾部短 token(刚刚/4小时/2天…)查;查不到不切(安全退化)。
let viewNameSeen = '';
let viewTSeen = 0;
let viewResolved = true;   // 上次该名字是否解析成功;失败则等探针 30s 心跳重试
                           // (防改名竞态:侧栏先渲染新标题、db 落库滞后时,一次失败不终身卡死)
function resolveSidByTitle(name) {
  if (!db && !openDb()) return '';
  const cands = [name];
  const cut = name.replace(/\s+\S{1,6}$/, '');
  if (cut && cut !== name) cands.push(cut);
  for (const t of cands) {
    try {
      const r = db.prepare(
        'SELECT id FROM session WHERE title = ? AND task_type = ? ORDER BY time_updated DESC LIMIT 1'
      ).get(t, 'interactive');
      if (r && r.id) return r.id;
    } catch { db = null; return ''; }
  }
  return '';
}
function pollView() {
  let txt;
  try { txt = fs.readFileSync(viewFile, 'utf8'); } catch { return; }
  if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);   // 剥 BOM 再解析
  let j; try { j = JSON.parse(txt); } catch { return; }
  if (!j || !j.name) return;
  const nameChanged = j.name !== viewNameSeen;
  if (!nameChanged && viewResolved) return;               // 同名且已解析 → 无事
  if (!nameChanged && j.t === viewTSeen) return;          // 同名同拍且上次失败 → 等下个心跳
  viewNameSeen = j.name;
  viewTSeen = j.t;
  const sid = resolveSidByTitle(j.name);
  viewResolved = !!sid;
  if (sid && sid !== activeSession) switchToSession(sid);
}

// ---- app log:相位 + 会话归属 ----
function switchToSession(sid) {
  activeSession = sid;
  const n = rebuildSessionAggregates(sid);
  phase = n > 0 ? 'done' : 'idle';
  lastActivity = Date.now();
  writeMetrics(true);
}
function onLogLine(line) {
  if (!line || (line.indexOf('"event":"model.') < 0 && line.indexOf('"event":"turn.') < 0 &&
                line.indexOf('"event":"session.resumed"') < 0)) return;
  let j; try { j = JSON.parse(line); } catch { return; }
  if (!j || !j.sessionId) return;
  if (j.sessionId !== activeSession) {
    if (j.event === 'session.resumed') {
      // v0.13e UI 打开/切换会话(非驻留):立即接管 + 按该会话 db 历史重建聚合
      switchToSession(j.sessionId);
      return;
    }
    // 其他会话的事件:仅跟随其首个请求(原启发式);workflow 子代理永不接管(非用户所看)
    const follows = (j.event === 'model.request.started' || j.event === 'turn.started') &&
                    !j.sessionId.startsWith('sess_dwf-');
    if (!follows) return;
    activeSession = j.sessionId;
    rebuildSessionAggregates(activeSession);   // 跟随切换同样重建(收编此前被跳过的历史)
  }
  const ev = j.event;
  if (ev === 'model.request.started') { phase = (turns.get(j.turnId)?.out ?? 0) ? 'stream' : 'waiting'; lastActivity = Date.now(); writeMetrics(true); }
  else if (ev === 'turn.started') { phase = 'waiting'; lastActivity = Date.now(); writeMetrics(true); }
  else if (ev === 'turn.completed' || ev === 'turn.failed') { phase = 'done'; lastActivity = Date.now(); writeMetrics(true); }
}

// ---- main ----
fs.writeFileSync(outFile, JSON.stringify({ t: Date.now(), phase: 'idle', tps: null, turnAvg: null, ttft: null, calls: 0 }));
setInterval(() => {
  try {
    pollLive();
    pollModelUsage();
    pollView();
    const tl = todayLog();
    if (tl && (!logTail || logTail.file !== tl)) { if (logTail) try { fs.closeSync(logTail.fd); } catch { } logTail = openReader(tl, true); }
    for (const l of readNew(logTail)) onLogLine(l);
    if (phase === 'stream' && Date.now() - lastActivity > 20000) { phase = 'done'; }
    writeMetrics(false);
  } catch { }
}, 250);
