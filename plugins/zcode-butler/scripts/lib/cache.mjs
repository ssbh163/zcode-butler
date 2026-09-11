/**
 * lib/cache.mjs —— ~/.zcode/butler-cache.json 读写(机器生成勿手改,坏文件当不存在)
 *
 * 顶层结构(watch 维护,version 3 沿用 zcode-watch 语义,漂移可对照):
 *   { version: 3, month: 'YYYY-MM', accounts: { customerId: {...} },
 *     keyAccount: { keyId: customerId }, lastResult: { ts, month, payload } }
 * usage 的三环数据走 lastResult;hook 零请求摘要读它(≤60 分钟新鲜)。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readJsonDefensive } from './api.mjs';

export const CACHE_FILE = path.join(os.homedir(), '.zcode', 'butler-cache.json');

export const LAST_RESULT_FRESH_MS = 60 * 60 * 1000; // hook 零请求窗口

/** 读缓存:结构不对/版本不符返回骨架,不抛(缓存坏不能拖垮查询) */
export function loadButlerCache() {
  const obj = readJsonDefensive(CACHE_FILE);
  if (!obj || typeof obj !== 'object' || obj.version !== 3) {
    return { version: 3, month: '', accounts: {}, keyAccount: {}, lastResult: null };
  }
  if (!obj.accounts || typeof obj.accounts !== 'object') obj.accounts = {};
  if (!obj.keyAccount || typeof obj.keyAccount !== 'object') obj.keyAccount = {};
  if (!obj.lastResult || typeof obj.lastResult !== 'object') obj.lastResult = null;
  return obj;
}

/** 写缓存:失败静默(缓存写失败不影响本次输出),目录不存在自动建 */
export function saveButlerCache(cache) {
  try {
    fs.mkdirSync(path.dirname(CACHE_FILE), { recursive: true });
    fs.writeFileSync(CACHE_FILE, JSON.stringify(cache, null, 2) + '\n', 'utf8');
  } catch { /* 缓存写失败不影响本次输出 */ }
}

/** lastResult 是否仍新鲜(hook 零请求用);monthKey 给定时还须同月 */
export function freshLastResult(cache, nowMs = Date.now(), monthKey = null) {
  const lr = cache?.lastResult;
  if (!lr || typeof lr.ts !== 'number') return null;
  if (monthKey && lr.month !== monthKey) return null;
  if (nowMs - lr.ts >= LAST_RESULT_FRESH_MS) return null;
  return lr;
}
