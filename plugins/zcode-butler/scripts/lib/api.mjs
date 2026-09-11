/**
 * lib/api.mjs —— 智谱 API 共享层:凭据解析链 + 请求工厂(usage / watch 共用,零依赖)
 *
 * 提炼自 zcode-usage v0.0.6 / zcode-watch v0.4.0,对外差异:
 *   - 手动配置文件改为 ~/.zcode/butler-manual.json(兼容读旧的 zcode-usage-manual.json)
 *   - 凭据优先级(AGENTS.md):CLI 参数 → 环境变量 → 手动配置 → ZCode 配置全 provider 扫描
 *   - 只接受 open.bigmodel.cn / api.z.ai 两个域名(监控接口所在),跳过 zcode.z.ai
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// ---------- 域名常量(watch 按 provider 取账单/监控 origin) ----------
export const PROVIDER_ORIGIN = {
  bigmodel: 'https://open.bigmodel.cn',
  zai: 'https://api.z.ai',
};
export const FINANCE_ORIGIN = {
  bigmodel: 'https://bigmodel.cn', // 账单接口在裸域(无 open.)
  zai: 'https://api.z.ai',         // 未验证,失败自动降级为错误卡
};
// 监控接口(/api/monitor)只存在于两个官方域名;zcode.z.ai(启动版套餐)没有,跳过
const MONITOR_HOSTS = ['open.bigmodel.cn', 'api.z.ai'];

const zcodeDir = () => path.join(os.homedir(), '.zcode');

/** 读 JSON 文件:剥 UTF-8 BOM、容忍 CRLF;读不了返回 null(防御性,不抛) */
export function readJsonDefensive(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return null;
  }
}

// ---------- 凭据解析链(每级返回 { token, base, from } 或 null) ----------
export function credentialFromArgs(getFlag) {
  // getFlag(name) → 参数值;Key 一律不落命令行,仅调试用,正常走环境变量/配置文件
  const key = getFlag('--key');
  const base = getFlag('--base');
  return key && base ? { token: key, base, from: 'args' } : null;
}

export function credentialFromEnv(env = process.env) {
  const token = env.ANTHROPIC_AUTH_TOKEN || env.ZAI_API_KEY || '';
  // ZAI_API_KEY 单独出现时默认国际站;ANTHROPIC_AUTH_TOKEN 可能指向任意代理,没 base 不瞎猜
  const base = env.ANTHROPIC_BASE_URL
    || (!env.ANTHROPIC_AUTH_TOKEN && env.ZAI_API_KEY ? 'https://api.z.ai/api/anthropic' : '');
  return token && base ? { token, base, from: 'env' } : null;
}

/** 手动配置:悬浮窗「配置 API Key」界面写入;兼容旧 zcode-usage 的文件名 */
export function credentialFromManualFile() {
  const files = [
    path.join(zcodeDir(), 'butler-manual.json'),
    path.join(zcodeDir(), 'zcode-usage-manual.json'),
  ];
  for (const file of files) {
    const obj = readJsonDefensive(file);
    const key = typeof obj?.apiKey === 'string' ? obj.apiKey.trim() : '';
    const base = typeof obj?.apiBase === 'string' ? obj.apiBase.trim() : '';
    if (key && base) return { token: key, base, from: `manual:${path.basename(file)}` };
  }
  return null;
}

/** ZCode 配置扫描:全部已启用 provider,凭据字段兼容 options 层与顶层两种写法 */
export function credentialFromZcodeConfig() {
  const files = [
    path.join(zcodeDir(), 'v2', 'config.json'), // 当前 ZCode
    path.join(zcodeDir(), 'config.json'),       // 兼容其他版本的布局
  ];
  // 同域名内按 编程套餐 > 通用 优先;列表外的自定义 provider 排最后兜底
  const prefer = [
    'builtin:bigmodel-coding-plan', 'builtin:zai-coding-plan',
    'builtin:bigmodel', 'builtin:zai',
  ];
  for (const file of files) {
    if (!fs.existsSync(file)) continue;
    const cfg = readJsonDefensive(file);
    const providers = cfg?.provider || cfg?.providers;
    if (!providers || typeof providers !== 'object') continue;
    const found = [];
    for (const [name, pv] of Object.entries(providers)) {
      const key = pv?.options?.apiKey ?? pv?.options?.api_key ?? pv?.apiKey;
      const base = pv?.options?.baseURL ?? pv?.options?.base_url ?? pv?.baseURL ?? pv?.base;
      if (pv?.enabled === false || !key || !base) continue;
      let host;
      try { host = new URL(base).host; } catch { continue; }
      if (!MONITOR_HOSTS.includes(host)) continue;
      const rank = prefer.indexOf(name);
      found.push({ name, token: key, base, rank: rank < 0 ? 9 : rank });
    }
    found.sort((a, b) => a.rank - b.rank); // sort 稳定,同分保持配置文件里的先后
    if (found.length) {
      return { token: found[0].token, base: found[0].base, from: `zcode:${found[0].name}` };
    }
  }
  return null;
}

/**
 * 凭据全链解析。找不到返回 null(调用方负责给"缺什么、去哪装"指引);
 * 抛错场景不存在——找不到凭据不算异常,是可预期的未配置状态。
 */
export function resolveCredential(getFlag) {
  return credentialFromArgs(getFlag)
    || credentialFromEnv()
    || credentialFromManualFile()
    || credentialFromZcodeConfig();
}

// ---------- 请求工厂 ----------
/**
 * 建 GET 客户端:Authorization 头直传(401 时自动补 Bearer 重试一次)、
 * AbortSignal 超时、业务码(code!=200/0)转异常;返回 body.data ?? body。
 */
export function makeGet(origin, token, timeoutMs) {
  let tok = token;
  let bearerTried = false;
  return async function get(p) {
    let res;
    try {
      res = await fetch(origin + p, {
        headers: {
          Authorization: tok,
          'Accept-Language': 'zh-CN,zh',
          'Content-Type': 'application/json',
        },
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      throw new Error(e.name === 'TimeoutError' || e.name === 'AbortError'
        ? `请求超时(${timeoutMs / 1000}s):${origin} 无响应,请检查网络`
        : `网络错误,无法连接 ${origin}:${e.message}`);
    }
    if (res.status === 401 && !bearerTried && !tok.startsWith('Bearer ')) {
      bearerTried = true;
      tok = `Bearer ${tok}`;
      return get(p);
    }
    if (!res.ok) throw new Error(`${p} -> HTTP ${res.status}`);
    const body = await res.json();
    if (body.code !== undefined && body.code !== 200 && body.code !== 0) {
      throw new Error(`${p} -> ${body.msg || body.code}`);
    }
    return body.data ?? body;
  };
}

/** 终端着色开关:真终端且支持 ANSI 才着色(Git Bash 有 TERM,WT_SESSION 为 Windows Terminal);NO_COLOR 可强制关 */
export function makeColorKit() {
  const supportsAnsi = process.platform !== 'win32'
    || !!process.env.TERM
    || !!process.env.WT_SESSION
    || process.env.ConEmuANSI === 'ON';
  const useColor = !process.env.NO_COLOR && process.stdout.isTTY && supportsAnsi;
  const c = (code, s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : s);
  return {
    c,
    bold: (s) => c('1', s),
    dim: (s) => c('2', s),
    // 用量越高越醒目:<50% 绿,50-80% 黄,>=80% 红加粗
    rateStyle: (p) => (p >= 80 ? '1;31' : p >= 50 ? '33' : '32'),
  };
}

/** 显示宽度:中日韩全角/emoji 按 2 列计,用于对齐 */
export function displayWidth(s) {
  let w = 0;
  for (const ch of String(s)) {
    const cp = ch.codePointAt(0);
    const wide = (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf)
      || (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff)
      || (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60)
      || (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1faff)
      || (cp >= 0x20000 && cp <= 0x3fffd);
    w += wide ? 2 : 1;
  }
  return w;
}

export const padEndW = (s, width) => String(s) + ' '.repeat(Math.max(0, width - displayWidth(s)));

/** token 数值显示:亿(2 位小数)/ 万(1 位小数)/ 千分位 */
export function fmtTokens(n) {
  const v = Number(n) || 0;
  if (v >= 1e8) return (v / 1e8).toFixed(2) + ' 亿';
  if (v >= 1e4) return (v / 1e4).toFixed(1) + ' 万';
  return v.toLocaleString('zh-CN');
}

export const fmtNum = (n) => Number(n || 0).toLocaleString('zh-CN');

/** Key 脱敏:只露尾号 4 位(红线:一切输出脱敏) */
export function maskKey(key) {
  const k = String(key || '');
  return k.length <= 4 ? '····' : '····' + k.slice(-4);
}
