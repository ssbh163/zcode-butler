#!/usr/bin/env node
/**
 * 会话统计条启动器(SessionStart hook 每会话调用一次)
 *
 * 免黑窗冷启动 stats-widget.ps1;已有实例在互斥量 Global\ZCode-Stats-Widget
 * 处静默退出(单实例安全,重复调用无副作用)。其他平台静默跳过。
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureWebview2Staging, cleanOrphanVersions } from '../lib/runtime.mjs';

if (process.platform !== 'win32') process.exit(0);

const dir = path.dirname(fileURLToPath(import.meta.url));

// 运行时卫生(v0.2.0):webview2 同步到 %LOCALAPPDATA% staging(与 widget 共用一份),
// 收走旧版本孤儿目录。失败不阻塞启动:ps1 侧另有 staging 兜底拷贝。
const wv2Src = path.join(dir, '..', 'widget', 'webview2');
try { ensureWebview2Staging(fs.existsSync(wv2Src) ? wv2Src : path.join(dir, 'webview2')); } catch { }
try { cleanOrphanVersions(dir); } catch { }

// 免黑窗冷启动:必须经 wscript/vbs 中转 —— hook/exec 环境的 Job(kill-on-job-close)
// 会连坐 node 直 spawn 的 powershell(秒退 EXIT 0 连脚本都没执行,v0.2.0 实测),
// WScript.Shell.Run 是 ShellExecute 系,由 shell 代启才能逃出 Job 存活。
const vbs = path.join(dir, 'stats-launch.vbs');
if (fs.existsSync(vbs)) {
  spawn('wscript.exe', [vbs], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
} else {
  const ps1 = path.join(dir, 'stats-widget.ps1');
  spawn('powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ps1],
    { detached: true, stdio: 'ignore', windowsHide: true }).unref();
}
process.exit(0);
