// 用量面板修复测试(随修复逐案扩充,一案一档):
//  v0.6.18(#2)Ctrl+Shift+G 隐藏后"侧边继续对话"面板复活(SessionStart 唤醒双通道不感知手动意愿)
//      → 单测:userHidden 持久态契约(缺省/读写往返/损坏 fail-open/不可写不抛)
// 运行:node --test scripts/widget/widget-fix.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const harness = path.join(here, 'widget-fix-cases.ps1');
const isWin = process.platform === 'win32';
const psTest = isWin ? test : test.skip;

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
};

for (const [cs, expected] of Object.entries(OK_LINES)) {
  psTest(`harness:${cs}`, () => {
    const { code, out } = runCase(cs);
    assert.equal(code, 0, `harness exit=${code}\n${out}`);
    assert.ok(!out.includes('FAIL'), out);
    for (const line of expected) {
      assert.ok(out.includes(line), `missing "${line}"\n${out}`);
    }
  });
}
