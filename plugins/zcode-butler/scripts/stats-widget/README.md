# 码管家·会话统计条(stats-widget)v0.10

zcode-butler 双悬浮窗之二(另一个是右缘「用量面板」butler-widget)。在 ZCode 输入框
正下方空带居中显示一行会话数据:

```
首token 1.62s · 实时 105 tok/s · 平均 98 tok/s　缓存命中 30%
```

当前为**假数据**(页面内每 2.5s 温和漂移)。真数据接入点见文末。

## 定位(v0.10 定稿)

- **垂直**:锚 DWM 可视帧底边(ExtendedFrameBounds)——窗口矩形含不可见缩放边框
  (最大化超出可视区 ~12px / 普通态内缩 ~8px),拿矩形当锚会随缩放状态漂移。
  输入框下空带实测 35px(= 20css 固定内边距,状态无关),文字 19px,
  **bottomMargin=8** → 空带垂直居中,与全屏/非全屏无关。
- **水平**:窗口中心 + 63(输入框在内容区的偏心,侧栏所致;侧栏折叠改 0,配置可调)。
- **跟随**:WinEvent LOCATIONCHANGE 的 C# 回调只 PostMessage、WndProc 里移动
  (回调内禁同步消息 API,重入契约),帧级零残影;移动/缩放/换屏实测精确。

## 样式

| 项 | 值 |
|---|---|
| 字号 | 12px 定死(改字号同改 html `font-size` 与 ps1 `$stripCssPx`) |
| 颜色 | `#D4D4D4`(胶囊文字像素采样) |
| 字重 | 400,system-ui 栈(Segoe UI + 微软雅黑) |
| 对齐 | 文字底对齐(flex-end),整窗点击穿透 |

## 文件

| 文件 | 职责 |
|---|---|
| `stats-widget.ps1` | 宿主:透明窗口 + DComp/WebView2 合成、帧级跟随、生死绑定(UTF-8 **带 BOM**) |
| `stats-widget.html` | 视觉层:单行文字条(12px)+ 假数据发生器 |
| `launch.mjs` | SessionStart 钩子启动器(免黑窗冷启动,单实例安全) |
| `stop.ps1` | 按窗口类枚举并结束宿主进程 |
| `../widget/webview2/` | 复用 butler-widget 的 vendored WebView2 DLL(本目录无副本时也可自带) |

## 启动 / 停止

- **自启**:插件 hooks.json 的 SessionStart 钩子 → `launch.mjs`(每会话一次,
  已有实例在互斥量 `Global\ZCode-Stats-Widget` 处静默退出)
- 手动:`powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File stats-widget.ps1`
- 停止:`stop.ps1`;显隐:**Ctrl+Alt+S**
- 行为:跟随 ZCode 移动/缩放;最小化/隐藏同步;owned 同层;ZCode 退出或本目录被删(插件卸载)自退

## 微调

`~/.zcode/stats-widget.json`(可选):`centerXOffset`(默认 63)、`bottomMargin`(默认 8)、
`winW`/`winH`(0=自动 840×44)。WebView2 用户数据:`~/.zcode/stats-widget-wv2/`。

## 真数据接入(待办)

数据源 `~/.zcode/cli/rollout/model-io-sess_<会话ID>.jsonl`(每行一次请求,含
durationMs 与 response.usage 四个 token 字段)→ 宿主 tail 计算 → `PostJson` →
页面 `chrome.webview` message(通道已验证)替换假数据:
首token≈请求延迟、实时=output÷durationMs、平均=会话累计、缓存命中=Σcache_read÷Σ(cache_read+input)。

## 迭代史速查(详见 zcode-butler 开发日志)

v0.10 底边 DWM 锚+空带居中(修状态漂移)→ v0.9 帧级跟随 → v0.8 纯矩形锚定(删全部
像素扫描)→ v0.6 字号定死 12px(跟随三连败)→ v0.1~v0.5 绿点/色带伺服与字号测量
(教训:能在锚定几何上用常量解决的,不要做运行时感知)。
