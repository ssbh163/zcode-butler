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
    ├── lib/                ← api(cache/protocol)共享库,usage/watch 共用
    ├── usage.mjs           ← 账号三环(提炼自 zcode-usage)
    ├── watch.mjs           ← Key 月度+水位线(提炼自 zcode-watch)
    ├── news.mjs            ← 资讯(数据源可插拔)
    ├── status.mjs          ← 聚合器:--json 统一协议 / --hook 摘要
    ├── chat2doc/           ← extract / format_batch / merge_batch(.py)
    └── widget/             ← WPF 悬浮窗 + 启动分发器
```

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
```

安装验证:ZCode → 插件市场 → 本地目录 → 选仓库根;新开对话 `/butler:usage` 应出卡片并拉起悬浮窗。

## 文档更新规则

- 四文档分工:PROJECT.md=设计方案("曾计划这样做",开发中冻结,变更不改它)/ DEV RECORD.md=开发记录("当时发生了什么",实时倒序追加)/ WIKI.md=现状("现在长什么样",**唯一真相源**)/ README.md=门面(只导航不复制)
- 内容判定:换一个功能也适用的规则 → AGENTS.md;只对当前功能有意义 → PROJECT.md;过程与踩坑 → DEV RECORD.md;现状描述 → WIKI.md
- 每次代码调整必须同步:①更新 WIKI 现状解读(只写现在时)②WIKI 变更历史追加一条,含四要素:背景/改动/影响范围/回滚方案 ③调整前先 commit
- 开发中的问题按"问题→根因→解决方案→耗时→commit"记 DEV RECORD;关键技术选型记 ADR(背景/选项/决策/后果)
- DEV RECORD 中反复出现的同类踩坑 → 提炼为规范写入本文件
- 三文档视角不同,不互相复制内容

## AI 协作红线(不要做什么)

- 不提交任何真实 API Key / 凭证 / 用户本机配置内容到仓库
- 不删测试来"通过";不注释掉降级逻辑(errors[] 机制)来"修好"聚合
- 不改 `status.mjs --json` 协议字段不同步四端(悬浮窗 .ps1 / 命令 / SKILL.md / 文档 §5)
- 不引入任何 npm / pip 第三方依赖
- 不在 `lib/` 之外的地方直接发智谱 API 请求;不在 .ps1 里写取数逻辑
- 改 `~/.zcode/` 下 ZCode 自身文件(v2/config.json 等)前必须向用户确认;butler 自有文件除外
- 回退代码前确认用户已提交

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

**验证**
- 改完必须跑检查:Node 用 `node --check` 且实际执行关键路径;PowerShell 用 `[scriptblock]::Create` 语法检查,内嵌 XAML 要真实 `XamlReader.Parse`;sh 改动要真实执行关键行(`bash -n` 查不出运行时错误)
- 涉及另一平台、本机无法验证的改动(编译/快捷键/焦点),交付说明里列"需真机验证"清单,不许默认它能工作
- 行为变更或 bug 修复同步 bump 版本号并写更新日志

## 注意事项

- 三个源项目独立存续:修 butler 内同名逻辑时,评估是否需同步回源项目(漂移控制)
- 智谱监控/账单接口无公开文档,字段含义以 zcode-usage/zcode-watch 仓库注释为准
- rollout JSONL 为 ZCode 内部实现,版本升级后优先跑 `extract` 单测确认格式未变
