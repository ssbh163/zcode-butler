#!/usr/bin/env node
/**
 * 悬浮窗启动分发器(SessionStart hook 每会话调用一次)
 *
 * Windows 语义(zcode-usage 已验证链路):
 *   1. touch 唤醒文件 → 运行中的悬浮窗 250ms 内唤回(不新起进程)
 *   2. 写 host.json(本次进程的父 pid,正常即 ZCode 主进程)→ 悬浮窗据此精确定位
 *      ZCode 主窗口做右缘跟随(验证进程名,不盲信;失败退回按进程名枚举)
 *   3. 经 widget-launch.vbs 免黑窗兜底冷启动(无实例时启动;已有实例在互斥量处静默退出)
 * 其他平台:静默跳过(macOS 二期)。
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'win32') process.exit(0);

const dir = path.dirname(fileURLToPath(import.meta.url));
const dotZcode = path.join(os.homedir(), '.zcode');

// 1. 唤醒文件
const wakeFile = path.join(dotZcode, 'butler-widget.wake');
const now = new Date();
try {
  fs.utimesSync(wakeFile, now, now);
} catch {
  try { fs.mkdirSync(dotZcode, { recursive: true }); fs.writeFileSync(wakeFile, ''); } catch { }
}

// 2. 父 pid 提示(SessionStart hook 由 ZCode 拉起,ppid 即 ZCode 主进程)
try {
  fs.writeFileSync(path.join(dotZcode, 'butler-widget-host.json'),
    JSON.stringify({ pid: process.ppid, ts: Date.now() }) + '\n');
} catch { /* 失败无害:悬浮窗会退回按进程名枚举 */ }

// 3. 免黑窗冷启动
const vbs = path.join(dir, 'widget-launch.vbs');
if (fs.existsSync(vbs)) {
  spawn('wscript.exe', [vbs], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
}
process.exit(0);
