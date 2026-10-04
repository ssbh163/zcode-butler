#!/usr/bin/env node
// sync-mirror.mjs — SessionStart 钩子:同步本插件的市场镜像,把滞后窗口压到"一个会话"
//
// 背景与契约(2026-10-04 用户拍板):卸载/重装不触发镜像刷新,镜像自动刷新(每日
// ~02:30)实测经常不跑 → 重装装回旧版(2026-10-01 事故:镜像停在 0.2.27 三天)。
// 本脚本在每次 SessionStart 顺带同步镜像。边界:只刷镜像(安装源),不碰缓存
// (已安装文件)——是否升级由使用者在插件市场自行点更新,尊重 ZCode 安装管理权。
//
// 双形态兼容(2026-10-04 实测:ZCode 的市场刷新/重加会把镜像重新展开为纯文件
// 目录,.git 丢失):
//   有 .git  → git fetch + merge --ff-only origin/main(温和快进;分叉/冲突立即放弃零改动)
//   无 .git  → git init + remote + fetch + checkout -f(把展开目录重新纳入 git 管理,
//              内容强制对齐远端最新——展开目录本就无本地历史,强制无损失;此后走快进)
// 全路径静默(git 不可用/网络失败/超时 → exit 0,绝不拖累会话启动);10 分钟节流防重入。
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));   // ESM 无 __dirname,手动等价物

// 本插件市场与仓库一一对应(分发事实,硬编码;换仓库时同步改)
const REPO_URL = 'https://github.com/ssbh163/zcode-butler.git';
const BRANCH = 'main';
const SILENT = { stdio: 'ignore', timeout: 15000 };

// 从自身路径推镜像:.../cache/<marketplace>/<plugin>/<version>/scripts/lib/sync-mirror.mjs
// 镜像 = <zcodeRoot>/plugins/marketplaces/<marketplace>/
function mirrorDir() {
  const parts = __dirname.split(path.sep);
  const ci = parts.lastIndexOf('cache');
  if (ci < 0 || ci + 1 >= parts.length) return null;
  const marketplace = parts[ci + 1];
  if (!marketplace || marketplace === '.') return null;
  return path.join(os.homedir(), '.zcode', 'cli', 'plugins', 'marketplaces', marketplace);
}

function git(dir, ...args) {
  return execFileSync('git', ['-C', dir, ...args], SILENT);
}

function main() {
  const DBG = process.env.BUTLER_SYNC_DEBUG;
  const stamp = path.join(process.env.LOCALAPPDATA || os.tmpdir(), 'zcode-butler', 'runtime', 'mirror-sync-stamp');
  if (DBG) console.error('D1 mirrorDir=', mirrorDir());
  try {
    const last = Number(fs.readFileSync(stamp, 'utf8').trim());
    if (Date.now() - last < 10 * 60 * 1000) return;   // 10 分钟节流
  } catch { /* 无 stamp = 首次 */ }

  const dir = mirrorDir();
  if (!dir || !fs.existsSync(dir)) { if (DBG) console.error('D2 no dir'); return; }

  const isGit = fs.existsSync(path.join(dir, '.git'));
  if (DBG) console.error('D3 isGit=', isGit);
  if (isGit) {
    git(dir, 'fetch', '-q', 'origin');
    if (DBG) console.error('D4 fetched');
    git(dir, 'merge', '--ff-only', '-q', `origin/${BRANCH}`);   // 快进;分叉/无更新 → 失败即静默放弃
    if (DBG) console.error('D5 merged');
  } else {
    // ZCode 重新展开后的纯文件镜像:重新 git 化并强制对齐远端(下次起走快进)
    execFileSync('git', ['init', '-q', '-b', BRANCH, dir], SILENT);
    git(dir, 'remote', 'add', 'origin', REPO_URL);
    git(dir, 'fetch', '-q', 'origin', BRANCH);
    git(dir, 'checkout', '-f', '-q', '-B', BRANCH, `origin/${BRANCH}`);
  }

  try { fs.mkdirSync(path.dirname(stamp), { recursive: true }); fs.writeFileSync(stamp, String(Date.now())); } catch { }
}

try { main(); } catch (e) { if (process.env.BUTLER_SYNC_DEBUG) console.error('sync-mirror FAIL:', e && e.message); /* 默认静默:同步失败不拖累会话启动 */ }
