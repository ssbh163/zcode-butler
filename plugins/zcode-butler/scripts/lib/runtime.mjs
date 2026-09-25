/**
 * 悬浮窗运行时 staging + 缓存卫生(v0.2.0 卸载/更新零锁方案,详见仓库开发日志)
 *
 * 背景:悬浮窗曾直接从插件缓存目录 LoadFrom/LoadLibrary WebView2 三件套,
 * ZCode 卸载 = rm(installPath) 遇内存映射 DLL 报 EPERM 且无重试无回滚
 * (zcode.cjs bdn():先删 installed_plugins.json 记录再 rm,失败即半删);
 * 同版本重装的原子换入(rename 旧目录 → backup)同样撞锁。
 * 方案:DLL 只从 %LOCALAPPDATA%\zcode-butler\runtime\webview2\ 加载,
 * 进程对插件缓存目录零句柄 → 卸载/更新随便删;脚本被删自退机制照常收尾。
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');

/** 两个悬浮窗共享的运行时家目录(ps1 侧 instance-*.json stamp 也落在这里,路径约定须与 ps1 一致) */
export const RUNTIME_DIR = path.join(localAppData, 'zcode-butler', 'runtime');
export const WV2_STAGING = path.join(RUNTIME_DIR, 'webview2');

const WV2_FILES = [
  'Microsoft.Web.WebView2.Core.dll',
  'Microsoft.Web.WebView2.Wpf.dll',
  'WebView2Loader.dll',
];

function sha256(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function sameFile(src, dst) {
  try {
    const a = fs.statSync(src), b = fs.statSync(dst);
    return a.size === b.size && sha256(src) === sha256(dst);
  } catch {
    return false;
  }
}

/**
 * 把 vendored webview2 三件套同步到 staging(sha256 增量,变了才拷)。
 * @returns {'ok'|'updated'|'degraded'} degraded = 目标 DLL 被旧实例加载中,
 *   rename 覆盖失败 → 保留 staging 旧文件继续跑;实例换代后下次会话自动追平。
 */
export function ensureWebview2Staging(srcDir) {
  let status = 'ok';
  fs.mkdirSync(WV2_STAGING, { recursive: true });
  for (const name of WV2_FILES) {
    const src = path.join(srcDir, name);
    if (!fs.existsSync(src)) throw new Error(`webview2 source missing: ${src}`);
    const dst = path.join(WV2_STAGING, name);
    if (sameFile(src, dst)) continue;
    const tmp = `${dst}.new`;
    try {
      fs.copyFileSync(src, tmp);
      fs.renameSync(tmp, dst);
      status = 'updated';
    } catch {
      try { fs.unlinkSync(tmp); } catch { /* .new 可能同样没写出来 */ }
      status = 'degraded';
    }
  }
  return status;
}

/**
 * ZCode 更新只写新版本目录、不删旧版本目录(cache 下 superpowers 6.3.0/6.4.1
 * 并存为实证),这里把 zcode-butler 名下未被 installed_plugins.json 引用的
 * 版本目录收走。删不掉(旧实例还锁着/瞬时占用)就静默留给下次。
 */
export function cleanOrphanVersions(scriptsDir) {
  const removed = [];
  // 调用方都是 <pluginRoot>/scripts/<widget-dir>(widget-launch.mjs / stats launch.mjs),
  // 版本目录 = 再上一层,版本目录的父(插件名目录)= 三层
  const versionsDir = path.resolve(scriptsDir, '..', '..', '..');
  const pluginsRoot = path.join(os.homedir(), '.zcode', 'cli', 'plugins');
  let current;
  try {
    const rec = JSON.parse(fs.readFileSync(path.join(pluginsRoot, 'installed_plugins.json'), 'utf8'));
    current = (rec.plugins || []).find(p => p.id === 'zcode-butler@zcode-plugins-personal')?.installPath;
  } catch {
    return removed; // 记录读不到/结构不对:一个都不动(保守)
  }
  if (!current) return removed; // 自己不在册(比如正被卸载):不扫
  for (const name of fs.readdirSync(versionsDir)) {
    if (!/^\d+\.\d+\.\d+/.test(name)) continue; // 只认版本号目录,事务残留交给 ZCode 自带恢复
    const full = path.join(versionsDir, name);
    if (path.resolve(full) === path.resolve(current)) continue;
    try {
      fs.rmSync(full, { force: true, recursive: true });
      removed.push(name);
    } catch { /* 锁着:下次会话再试 */ }
  }
  return removed;
}
