# zcode-butler(码管家)- AGENTS.md

## 项目定位

ZCode 插件市场仓库,内含单个插件 zcode-butler(码管家):智谱 GLM Coding Plan 的账号用量 + 多 Key 监控 + 会话归档(Chat2Doc)+ 活动资讯,四合一桌面悬浮窗与对话入口。全量吸收 zcode-usage / zcode-watch / session-doc-prompt 三项目能力,三个源项目继续独立维护。

## 技术栈与版本

- 脚本:Node.js ≥ 18(.mjs,**零 npm 依赖**,仅内置 fetch/fs/child_process)
- Chat2Doc 流水线:Python ≥ 3.10(标准库 only,Windows 上以 `py` 调用)
- 悬浮窗:Windows PowerShell 5+ / WPF(纯渲染壳,不取数);macOS 二期
- 宿主:ZCode 插件机制(skills / commands / hooks / plugin.json)

## 项目目录结构

```
plugins/zcode-butler/
├── skills/butler/          ← 主技能:自然语言入口 + Chat2Doc 流程与文档模板
├── commands/               ← usage / watch / doc / news 四个斜杠命令
├── hooks/hooks.json        ← SessionStart(拉悬浮窗+摘要注入) + UserPromptSubmit(doc-intent)
├── assets/news.json        ← 资讯数据(人工维护)
└── scripts/
    ├── lib/                ← api(cache/protocol)共享库 + runtime.mjs(staging/孤儿清理)+ widget-common.ps1(双悬浮窗公共机制层)
    ├── webview2/           ← vendored WebView2 三件套种子(两悬浮窗共享,v0.2.1 从 widget/ 迁出;运行时只从 %LOCALAPPDATA% staging 加载)
    ├── usage.mjs           ← 账号三环(提炼自 zcode-usage)
    ├── watch.mjs           ← Key 月度+水位线(提炼自 zcode-watch)
    ├── news.mjs            ← 资讯(数据源可插拔)
    ├── status.mjs          ← 聚合器:--json 统一协议 / --hook 摘要
    ├── chat2doc/           ← extract / format_batch / merge_batch(.py)
    ├── widget/             ← 用量面板悬浮窗(与 stats-widget 的公共机制在 lib/widget-common.ps1,C# 合成宿主为同构副本:改 A 必改 B)
    └── stats-widget/       ← 会话统计条悬浮窗(同上)
```

## 插件生命周期纪律(本地 marketplace,v0.2.0 立规)

> 本节是 marketplace.json 的"注释区":**JSON 被 `JSON.parse`+zod `.strict()` 校验,写注释/注释字段会让整个市场解析失败**,所有编辑纪律集中在这里。机制源码级结论详见开发日志 2026-09-25 v0.2.0 条。

- **每次改动必升 version**:`marketplace.json` 的 `plugins[].version` 与 `plugins/zcode-butler/.zcode-plugin/plugin.json` 同步升。directory 源没有 git sha,directory 源唯一更新信号就是 version——不升 = 用户端永远不出更新按钮
- 更新链路:本仓库 →(marketplace 刷新,每日 ~02:30 自动)→ `~/.zcode/cli/plugins/marketplaces/zcode-plugins-personal/` 镜像 →(UI 点更新,原子换入)→ `…/cache/zcode-plugins-personal/zcode-butler/<版本>/`。**安装/更新的拷贝源是镜像不是本仓库**;手动同步镜像可让更新按钮立即出现
- 三份副本:仓库(正本)↔ 镜像 ↔ 缓存;改仓库后需手动同步缓存(代码立即生效)与镜像(按钮立即生效),ZCode 只在自动刷新时同步镜像
- **悬浮窗进程必须对插件缓存目录零句柄**:WebView2 DLL 只从 `%LOCALAPPDATA%\zcode-butler\runtime\webview2\` staging 加载(`scripts/lib/runtime.mjs` 维护)。任何"直接从插件目录 LoadFrom/LoadLibrary/打开文件长持句柄"的新代码都违反本纪律——ZCode 卸载=rm 缓存目录,遇锁 EPERM 且无重试无回滚,必留半删残尸
- **hook 拉起常驻进程一律走 .vbs 中转**(wscript 的 `WScript.Shell.Run`):exec/hook 链的 Windows Job 会连坐 node 直 spawn 的子进程(秒退 EXIT 0 连脚本都没执行,表象="启动了但没起来")
- 悬浮窗换代对账:实例 stamp 在 `%LOCALAPPDATA%\zcode-butler\runtime\instance-*.json`,动互斥量逻辑前先读两个 ps1 的 mutex 段注释
- 卸载后残留仅 `%LOCALAPPDATA%\zcode-butler\`(几 MB,刻意幂等保留);config.json 的 `enabledPlugins` 显式条目永远压过默认启用,卸载会写 `false` 且**重装不清除**——重装后插件"在册但全不加载"先查这里

## 编码规范

- 零 npm 依赖;测试用 Node 内置 `node:test` 与 Python `unittest`,不引框架
- API Key 一律不进命令行参数(环境变量传递);一切输出脱敏为尾号 4 位
- `status.mjs` 聚合时各模块独立 try/catch:单模块失败写 `errors[]`,不得拖垮整体
- WPF 悬浮窗是纯渲染壳:数据只来自 `node status.mjs --json`,禁止在 .ps1 内实现取数/认证
- 时间口径:高峰判定基于服务端北京时间字符串,不依赖本机时区;小时桶左闭右开
- 纯函数(加权/高峰拆分/解析)与 I/O 分离,可独立单测
- 用户可见文案一律中文;编码政策:全仓 UTF-8,**`*.ps1` 例外带 BOM**(否则 PowerShell 5.1 中文乱码),**`*.vbs` 例外必须 ASCII 无 BOM**(wscript 不认 BOM,带 BOM 静默失败,实测事故),其余文件一律无 BOM
- 悬浮窗单实例:互斥量 + 唤醒文件机制,沿用 zcode-usage 已验证实现

## 环境配置

- 运行时:Node ≥ 18、Python ≥ 3.10(`py` 可用)、Windows(悬浮窗需 PowerShell/WPF)
- 凭证(自动探测,顺序):CLI 参数 → `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL`(或 `ZAI_API_KEY`)→ `~/.zcode/butler-manual.json` → `~/.zcode/v2/config.json` 全 provider 扫描;跳过 `zcode.z.ai`
- 用户配置:`~/.zcode/butler.json`(Key 列表兼容导入 zcode-watch.json);缓存 `~/.zcode/butler-cache.json`(机器生成勿手改)
- 会话转录数据源:`~/.zcode/cli/rollout/model-io-sess_*.jsonl`(ZCode 内部格式,解析只允许集中在 `chat2doc/extract.py`)

## 开发命令

```
node plugins/zcode-butler/scripts/status.mjs --json     # 聚合协议输出(悬浮窗同源)
node plugins/zcode-butler/scripts/status.mjs            # 终端卡片
node --test "plugins/zcode-butler/scripts/**/*.test.mjs"  # Node 单测(目录形式在 Windows 不可用,须递归 glob)
py -m unittest discover -s plugins/zcode-butler/scripts/chat2doc -p "*_test.py"
node -e "const a=require('./marketplace.json').plugins[0].version,b=require('./plugins/zcode-butler/.zcode-plugin/plugin.json').version;a===b?console.log('version 一致:',a):(console.error('version 不一致:',a,b),process.exit(1))"  # 提交前必跑
```

安装验证:ZCode → 插件市场 → 本地目录 → 选仓库根;新开对话 `/butler:usage` 应出卡片并拉起悬浮窗。

## 文档更新规则(v2 体系,2026-09-14 迁移)

- 分工:PROJECT.md=设计方案("曾计划这样做",开发中冻结,变更不改它)/ **开发日志.md=唯一时间线**("发生过什么、怎么变的",实时倒序追加,永久维护,历史的唯一真相源;曾用名 DEV RECORD.md,已吸收原 WIKI 变更历史)/ WIKI.md=现状("现在长什么样",**唯一真相源**,纯现在时,只留版本一览索引)/ README.md=门面(只导航不复制)/ docs/knowledge/=知识地图(技术岔路口写,含可证伪的显式预测,决策后冻结)/ docs/retrospectives/=复盘(技术弧终局写,写后冻结)
- 内容判定:换一个功能也适用的规则 → AGENTS.md;只对当前功能有意义 → PROJECT.md;过程与踩坑(事件)→ 开发日志.md;现状描述 → WIKI.md;选型认知与预测 → docs/knowledge/;跨事件规律与教训 → docs/retrospectives/
- 每次代码调整必须同步:①调整前先 commit;②开发日志顶部追加条目(问题/背景→根因→改动→验证→commit;影响范围/回滚方案为条件字段,`git revert` 一句能说清则省);③WIKI 现状解读同步(只写现在时);文档与代码同 commit
- 开发中的问题按"问题→根因→解决方案→耗时→commit"记开发日志,条目带类型标签([问题][修复][改进][实现][回退][ADR][调整]);关键技术选型记 ADR(背景/选项/决策/后果)
- 开发日志中反复出现的同类踩坑 → 提炼为规范写入本文件
- 技术岔路口(选型/换轨/陌生域)先写 docs/knowledge/ 知识地图;里程碑/换轨完成后写 docs/retrospectives/ 复盘(对预测逐条打分)
- 各文档视角不同,不互相复制内容

## AI 协作红线(不要做什么)

- 不提交任何真实 API Key / 凭证 / 用户本机配置内容到仓库
- 不删测试来"通过";不注释掉降级逻辑(errors[] 机制)来"修好"聚合
- 不改 `status.mjs --json` 协议字段不同步四端(悬浮窗 .ps1 / 命令 / SKILL.md / 文档 §5)
- 不引入任何 npm / pip 第三方依赖
- 不在 `lib/` 之外的地方直接发智谱 API 请求;不在 .ps1 里写取数逻辑
- 改 `~/.zcode/` 下 ZCode 自身文件(v2/config.json 等)前必须向用户确认;butler 自有文件除外
- 回退代码前确认用户已提交
- 悬浮窗三桥改动不守《三桥铁律》(见下节):形状上报桥出现设计坐标常量即 bug;新增交互面未扩桥(拖动排除+shape 采样)不许交付

## 三桥铁律(butler-widget.html)

- 三桥 = 页面(`chrome.webview` 守卫段)↔ 宿主(`butler-widget.ps1`)的三条通道:数据(ready/data)、拖动(pointerdown→drag)、形状上报(shape→NCHITTEST 掩码)。合入新视觉时桥块原样保留,不因几何变化改动;宿主侧仅消息协议变更时才动
- **形状上报桥零设计坐标常量**:圆心/半径/描边宽/元素舞台偏移一律运行时实测(`getBoundingClientRect`/`getComputedStyle`/`getPointAtLength`/viewBox),挪动或缩放 fab、改描宽后掩码自动跟随。发现硬编码视为 bug(2026-09-15 锚点实测化改造立此规矩,掩码点数基线 `mask pts=810`)
- 新增交互面才扩桥:新可见形状加入 shape 采样、新可交互区加入拖动排除(`.fab-zone` 同款),否则点击穿透错位/点按钮变拖窗
- 合入验收客观信号:`%TEMP%\butler-widget-debug.log` 的 `mask pts=N` 与改前一致(同 UI 结构)

## 跨平台纪律(Windows ⇄ macOS)

> 沉淀自 zcode-usage 的真实事故(Mac 用户 CRLF 编译失败、BOM 乱码、双副本静默漂移、全局事件处理器吞点击)。规则母版:`D:\Java\ai-coding-workflow\跨平台开发避坑清单.md`。

**换行与编码(最高优先级)**
- 换行/编码由 `.gitattributes` + `.editorconfig` 定死:文本入库一律 LF;`*.ps1`/`*.vbs` 检出 CRLF + UTF-8 BOM,其余无 BOM;编辑既有文件保持其原有风格,禁止混用
- 写完文件核验字节:`git ls-files --eol`,或直接数 CR/验 BOM——"内容看着对"不算数,字节对了才算
- 读用户手写的 JSON/配置:先剥 UTF-8 BOM 再解析,容忍 CRLF,解析失败给明确报错不崩溃

**副本与路径**
- 仓库内禁止手工维护内容重复的副本:共享逻辑单份正本;确需副本由构建脚本生成并 gitignore(与 zcode-usage/zcode-watch 的**跨仓库** vendored 副本不受此限,其漂移风险见 PROJECT.md §13)
- 文件路径一律用 API 拼接(`path.join()` 等),禁止手写 `/` 或 `\` 拼接;注意 Windows 文件名大小写不敏感、Linux 敏感

**运行时防御**
- 假设脚本可能被非 shell 环境拉起(PATH 为空):查找 node 等外部依赖时内置多候选路径探测,不只试 PATH
- 任何失败路径给出"缺什么、去哪装、点哪里"的明确指引,禁止静默吞错或返回神秘错误码
- 悬浮窗新增交互控件时,检查窗口级全局事件(拖拽 DragMove / 热键 / 事件冒泡)是否拦截该控件的点击
- **Agent 工具链自陷阱(悬浮窗 v0.2~v0.3 反复发生,全部实测)**:
  - bash 调 PowerShell 内联命令,双引号嵌套转义会静默弄坏命令且看起来"跑过了"——复杂调用一律 `-File` 脚本文件,内联只允许单行无嵌套引号
  - **禁止用 py heredoc / `py -c` 做文件内容替换**(转义与编码双重陷阱,三次事故);改文件只用编辑工具,改完核验
  - `powershell -File` 起新脚本偶尔报"在创建管道时出错"(系统瞬时压力),重试即可,不代表脚本有错
  - 窗口坐标/尺寸的验证探针必须与目标进程同 DPI 感知级别,否则读数被虚拟化(÷scale)误导结论;查窗口用 EnumWindows+GetClassName,FindWindow/Get-Process.MainWindowTitle 不可靠
  - CodeDom(`Add-Type -TypeDefinition`)把 C# 源按无 BOM 临时文件喂 csc:**C# 源内非 ASCII 字面量会被按 ANSI 误读**——内联 C# 一律 ASCII;`-ReferencedAssemblies` 里 WPF 程序集(WindowsBase 等)必须给已加载程序集的 `Location` 全路径,csc 不探测 WPF 子目录
  - WebView2 的 vendored DLL 与系统 Runtime **必须同构建号代际**(如 SDK 1.0.4191 ↔ Runtime 152.0.4191),Raw 接口 IID 跨代不兼容直接报 cast 失败

**验证**
- 改完必须跑检查:Node 用 `node --check` 且实际执行关键路径;PowerShell 用 `[scriptblock]::Create` 语法检查,内嵌 XAML 要真实 `XamlReader.Parse`;sh 改动要真实执行关键行(`bash -n` 查不出运行时错误)
- 涉及另一平台、本机无法验证的改动(编译/快捷键/焦点),交付说明里列"需真机验证"清单,不许默认它能工作
- 行为变更或 bug 修复同步 bump 版本号并写更新日志
- 同色/近色图形的可见性验证必须换色或强制态,不能靠阈值数像素(黑弧贴黑胶囊曾误判"弧线丢失")
- **位置/尺寸/颜色类需求,用户给的参考图就是地面真相**(2026-09-23 v0.4.6 锚点返工立规,复盘见 docs/retrospectives/):实现前先量图(像素级),验收必须"参考图 vs 实况"同尺像素对照;公式自洽、视觉模型转述、目测都不算验收
- **歧义需求口径当场摊开**:需求词有多解时(如"4环"),要么问用户、要么按最合理理解全域实现,并在交付说明首行显式标注理解口径

## 注意事项

- 三个源项目独立存续:修 butler 内同名逻辑时,评估是否需同步回源项目(漂移控制)
- 智谱监控/账单接口无公开文档,字段含义以 zcode-usage/zcode-watch 仓库注释为准
- rollout JSONL 为 ZCode 内部实现,版本升级后优先跑 `extract` 单测确认格式未变
