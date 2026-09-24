#!/usr/bin/env node
/**
 * 会话统计条启动器(SessionStart hook 每会话调用一次)
 *
 * 免黑窗冷启动 stats-widget.ps1;已有实例在互斥量 Global\ZCode-Stats-Widget
 * 处静默退出(单实例安全,重复调用无副作用)。其他平台静默跳过。
 */
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'win32') process.exit(0);

const dir = path.dirname(fileURLToPath(import.meta.url));
const ps1 = path.join(dir, 'stats-widget.ps1');
spawn('powershell.exe',
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ps1],
  { detached: true, stdio: 'ignore', windowsHide: true }).unref();
process.exit(0);
