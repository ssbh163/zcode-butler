// 用量面板双修测试(v0.6.18):
//  bug1 Ctrl+Shift+G 隐藏后"侧边继续对话"面板复活(SessionStart 唤醒双通道不感知手动意愿)
//      → 单测:userHidden 持久态契约(缺省/读写往返/损坏 fail-open/不可写不抛)
//      → E2E:  手动隐藏后重放 wake 文件 + Show 事件双通道,面板不得复活;清旗标后唤醒不回归
//  bug2 侧边聊天贴面板文字无法拖选(窗口透明条带仅靠 HTTRANSPARENT 穿透,跨进程无保证)
//      → 单测:Get-ButlerRegionSpec 区域图元几何(包围盒外扩/夹取/要素开关/退化丢弃)
//      → E2E:  实例启动后 GetWindowRgn 生效——条带点在区域外、面板带点在区域内
// 运行:node --test scripts/widget/widget-fix.test.mjs
// E2E 需活体环境(ZCode 运行中,会重启用量面板实例),默认跳过:
//      BUTLER_E2E=1 node --test scripts/widget/widget-fix.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const harness = path.join(here, 'widget-fix-cases.ps1');
const isWin = process.platform === 'win32';
const psTest = isWin ? test : test.skip;
const e2eTest = (isWin && process.env.BUTLER_E2E) ? test : test.skip;

function runCase(name, timeoutMs = 120000) {
  const r = spawnSync('powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', harness, '-Case', name],
    { encoding: 'utf8', timeout: timeoutMs });
  return { code: r.status, out: ((r.stdout || '') + (r.stderr || '')).trim() };
}

const OK_LINES = {
  userhidden: [
    'ok missing-file-false', 'ok set-true-returns-ok', 'ok read-true',
    'ok set-false-returns-ok', 'ok read-false', 'ok corrupt-false',
    'ok wrong-shape-false', 'ok unwritable-no-throw',
  ],
  region: [
    'ok band-rect-outset-clamped', 'ok fab-ellipse', 'ok strip-point-not-covered',
    'ok band-point-covered', 'ok pop-on-adds-rect', 'ok pop-area-covered',
    'ok toast-on-adds-rect', 'ok no-shape-empty-spec', 'ok negative-clamped-to-zero',
    'ok fully-outside-dropped', 'ok mismatched-xy-no-shape',
  ],
  e2e: [
    'ok region-applied', 'ok region-excludes-strip', 'ok region-covers-band-right',
    'ok pt-in-band', 'ok pt-strip-out', 'ok alive-after-region',
    'ok wake-suppressed-when-userhidden', 'ok wake-works-when-not-hidden',
    'ok final-state-hidden-and-sticky',
  ],
};

for (const [cs, expected] of Object.entries(OK_LINES)) {
  const gated = cs === 'e2e' ? e2eTest : psTest;
  gated(`harness:${cs}`, () => {
    const { code, out } = runCase(cs, cs === 'e2e' ? 180000 : 120000);
    if (out.includes('SKIP ')) {
      // E2E 前置不满足(ZCode 未运行):按跳过处理而非失败
      return;
    }
    assert.equal(code, 0, `harness exit=${code}\n${out}`);
    assert.ok(!out.includes('FAIL'), out);
    for (const line of expected) {
      assert.ok(out.includes(line), `missing "${line}"\n${out}`);
    }
  });
}
