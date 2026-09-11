#!/usr/bin/env node
/**
 * doc-intent.mjs —— 归档意图检测 hook(PROJECT.md §7.3 触发链路)
 *
 * 悬浮窗「开始归档」写 ~/.zcode/butler-doc-intent.json;本 hook 检测到未过期 intent 时
 * 注入归档任务上下文,让用户"发任意消息"即启动 Chat2Doc;执行后删除 intent 防重复触发。
 *
 * 用法(hooks.json):
 *   UserPromptSubmit: node doc-intent.mjs            ← 主链路:注入归档任务,删 intent
 *   SessionStart:     node doc-intent.mjs --startup  ← 兜底:若 ZCode 不支持 UserPromptSubmit,
 *                                                      新会话首条注入提示(不删 intent,留给 UserPromptSubmit)
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const INTENT_FILE = path.join(os.homedir(), '.zcode', 'butler-doc-intent.json');
const INTENT_TTL_MS = 10 * 60 * 1000; // 10 分钟过期,防陈旧误触发
const asStartup = process.argv.includes('--startup');

function readIntent() {
  try {
    const obj = JSON.parse(fs.readFileSync(INTENT_FILE, 'utf8').replace(/^\uFEFF/, ''));
    if (!obj || typeof obj !== 'object') return null;
    const created = Number(obj.createdAt) || 0;
    if (!created || Date.now() - created >= INTENT_TTL_MS) {
      fs.rmSync(INTENT_FILE, { force: true }); // 过期即清,不留垃圾
      return null;
    }
    return obj;
  } catch {
    return null;
  }
}

function emit(eventName, additionalContext) {
  console.log(JSON.stringify({
    hookSpecificOutput: { hookEventName: eventName, additionalContext },
  }));
}

const intent = readIntent();
if (!intent) {
  // 无意图:输出空上下文(hook 静默,不阻塞用户消息)
  emit(asStartup ? 'SessionStart' : 'UserPromptSubmit', '');
} else if (asStartup) {
  // 兜底链路:提示用户发消息触发(不删 intent,主链路在 UserPromptSubmit)
  emit('SessionStart',
    '【码管家】检测到会话归档意图(悬浮窗发起)。发送任意消息(如「归档」)即开始 Chat2Doc 归档;10 分钟内有效。');
} else {
  // 主链路:注入完整归档任务并消费 intent
  fs.rmSync(INTENT_FILE, { force: true });
  const out = typeof intent.outputDir === 'string' && intent.outputDir.trim()
    ? intent.outputDir.trim() : '~/Desktop/归档';
  emit('UserPromptSubmit',
    `【码管家·Chat2Doc 归档任务】用户已通过悬浮窗发起会话归档,请立即按 skills/butler 的「能力三:会话归档 Chat2Doc」执行流水线:\n`
    + `1) py <插件>/scripts/chat2doc/extract.py ${intent.sessionId || 'auto'} 生成 turns.json\n`
    + `2) py <插件>/scripts/chat2doc/format_batch.py 分批\n`
    + `3) 逐批读 hints-N.txt 写 repl-N.txt 摘要(规则见 assets/templates/素材文档.md)\n`
    + `4) py <插件>/scripts/chat2doc/merge_batch.py 合并,按模板拼最终素材文档(头部+概览+批次)\n`
    + `输出目录:${out}\n完成后向用户汇报产物路径与回合/工具统计。`);
}
