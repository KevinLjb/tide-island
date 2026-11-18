# TideIsland · 潮汐岛

A native macOS Dynamic Island companion for Codex and AI coding agents.

让 AI 的工作状态，在岛上一目了然。面向 Wave + Codex 的本地开发伴随工具，使用系统原生实时活动展示会话状态。

> 当前阶段：原生验证与交付准备。macOS / Xcode 27.3 beta 的原生 Debug / Release、本机 ad hoc 签名安装及前台合成 SDK 生命周期已通过，build 3 布局已由用户实机截图确认。真实 Codex 接入已审查启用，开始 / 工具 / 完成回调已观察到；其他交互继续分项验证，暂未发布可下载版本。

第一次使用请看 [开始指南](docs/getting-started.md)。[常见问题](docs/faq.md)说明状态、提醒、Wave 返回、诊断和卸载的实际边界；完整接入命令见 [安装、升级与卸载](docs/installation.md)。

## 开发进度

完整任务、优先级、开发 / 验证状态及交付记录统一维护在 [开发计划与进度](docs/development-progress.md)。当前已安装 `ded4986` 的 0.1.0（7）：原生活动采用项目 / 轻量计数 / 小箭头，会话窗口采用深色卡片，当前引用和状态逻辑保持原有流程。beta arm64 Debug / Release、ad hoc 包及许可、425 项共享测试和 10 组 CLI 通过，[同源 CI](https://github.com/KevinLjb/tide-island/actions/runs/44261522389)七项通过；16 组实际活动 / 卡片组件渲染及 20 组窗口辅助区域测量通过。build 6 的健康来源重查修复保留，用户已确认当时的设置摘要稳定。build 7 的实际系统宿主显示、点击 / 触摸和读屏继续分别核对。独立历史 SDK 生命周期见 [原生验证入口](docs/native-validation.md)。

后台 SDK 实测仍返回 `visibility / 7`，保留前台要求并提供“打开会话”恢复动作。用户前台操作后的独立诊断已通过创建、同 ID 更新、结束及退出清理；可见截图与 SDK 结果分别取证。真实开始、工具和完成回调已有观察，许可等待 / 中断、Wave 返回、其他系统场景及分发签名继续待验。

T029—T030 的兼容 / 迁移 / 许可和开始指南 / FAQ 已完成，[精确提交 CI](https://github.com/KevinLjb/tide-island/actions/runs/43991766217)实际执行 419 项测试与七项检查通过。T031 的 [公开 app-server 研究](docs/app-server-research.md)完成，暂不接入运行时；没有为观察状态连接或恢复用户现有会话。

## 环境要求

| 范围 | 要求 |
| --- | --- |
| 共享数据层、事件 CLI、单测 | Swift 6.0+；Mac 上最低 macOS 14 |
| 菜单栏应用和原生实时活动扩展 | Xcode 27.3+、macOS 27.3+；27.3 当前为 beta |
| 系统原生灵动岛展示 | 带原生灵动岛的兼容 Mac；系统决定最终展示位置 |

Apple 的 [ActivityKit](https://developer.apple.com/documentation/activitykit) 和 [ActivityConfiguration](https://developer.apple.com/documentation/widgetkit/activityconfiguration) 文档将 Mac 支持标为 **macOS 27.3 beta**。[Touch on Mac 开发入口](https://developer.apple.com/touch-on-mac/)提供对应工具。已有灵动岛硬件不表示较早系统 / SDK 已开放第三方原生接口。macOS 27.2 / Xcode 27.2 可用于共享层开发，不能据此验证原生目标。

## 工程结构

```text
TideIsland.xcodeproj/          Mac 应用与实时活动扩展，共享 TideIsland scheme
Native/
  App/                        菜单栏入口、会话列表、共享帧订阅、Activity 生命周期
  ActivityExtension/          系统原生实时活动 / Dynamic Island 视图
  Shared/                     两个 target 共用的 ActivityAttributes
Sources/
  TideIslandCore/              事件编解码、会话状态、Codex 映射、inbox 接收 / 监听 / 恢复
  TideIslandBridge/            tide-island-bridge 命令行入口
Tests/TideIslandCoreTests/     协议、乱序事件、会话隔离、路由和 inbox 测试
scripts/                      工程结构检查与原生 SDK 检查
docs/architecture.md          架构、能力边界与后续步骤
docs/development-progress.md  开发计划、任务进度与 27.3 统一验收清单
docs/codex-events.md          固定版本的 Codex 事件契约、转换矩阵与兼容范围
docs/codex-hooks.md           hooks 配置预览、合并、备份、卸载与信任审查
docs/event-replay.md          确定性回放、逐步状态断言与跨轮回归
docs/session-state.md         轮次状态、重复窗口、时间冲突与事件处理结果
docs/session-status.md        会话存活边界、新鲜度、展示过期与恢复
docs/session-attention.md     已读、忽略、置顶、选择与注意力排序
docs/inbox-maintenance.md     增量游标、受保护历史与预览 / 应用清理
docs/inbox-recovery.md        通道健康、监听重连、单接收者与中断恢复
docs/session-persistence.md   会话 / 偏好 checkpoint、跨重启保护与主动清除
docs/wave-capabilities.md     Wave 版本、公开定位入口、认证与列表输出边界
docs/wave-location.md         可选位置协议、allowlist、失效判断与 checkpoint 迁移
docs/wave-navigation.md       定位路线、运行时 / 目标复核、请求编排与结果边界
docs/wave-return.md           应用级返回、严格会话链接、安装 / 运行与错误反馈
docs/activity-presentation.md 实时活动共享投影、客户端边界与验证范围
docs/activity-delivery.md     来源顺序、最新状态合并、去重、限频与响应流
docs/activity-lifecycle.md    遗留清单、授权 / 系统关闭、scope 与退出清理
docs/activity-views.md        各尺寸状态 / 数量 / 点击一致性、窄布局与无障碍
docs/session-reminders.md     提醒周期、安静时段、可信查看、权限与不确定失败
docs/preferences.md           有界偏好、主动授权、名称 / 历史显示与登录启动
docs/session-metadata-history.md  当前引用的只读观察、记忆 / 清除边界和数量限制
docs/session-browser.md       项目筛选、匿名标签、只读详情与空状态恢复
docs/system-status.md         独立系统权限、上次错误与菜单栏恢复入口
docs/bridge-delivery.md       应用包内 bridge、完整性与移动 / 升级路径修复
docs/notify-integration.md    完成 notify 共存、argv 边界与可撤销局部编辑
docs/installation.md          统一配置安装 / 升级 / 卸载、数据选择与回退
docs/packaging.md             版本生成、归档 / 签名 / 公证与 ZIP 一致性
docs/native-validation.md     独立手动原生编译、来源保护和实际报告范围
docs/performance.md           本机空闲资源基线、计数单位与未验证负载
docs/diagnostics.md           按需元数据诊断、离线清单、私有导出与合成回放
docs/compatibility.md         平台、固定外部契约与各项数据格式版本
docs/migrations.md            升级、未知格式保留、清除边界与降级限制
docs/getting-started.md       当前共享开发与后续正式环境的首次使用顺序
docs/faq.md                   状态、集成、提醒、Wave、诊断和卸载常见问题
```

Swift Package 没有第三方依赖。Xcode 工程通过本地 package 依赖共享数据层，无需安装工程生成器。

版本、平台和外部契约范围见 [兼容清单](docs/compatibility.md)，升级及数据格式规则见 [迁移说明](docs/migrations.md)，源码 / 系统框架 / 外部应用与 CI 工具的分发关系见 [许可清单](THIRD_PARTY_NOTICES.md)。

## 验证共享层

```bash
swift test
swift build --product tide-island-bridge
python3 scripts/check-bridge.py
python3 scripts/check-diagnostics.py
python3 scripts/check-hooks.py
python3 scripts/check-delivery.py
python3 scripts/check-notify.py
python3 scripts/check-integration.py
python3 scripts/sync-version.py
python3 scripts/check-release.py
python3 scripts/check-native-entry.py
python3 scripts/check-replay.py
python3 scripts/check-inbox.py
python3 scripts/check-state.py
python3 scripts/check-project.py
python3 scripts/swift_test_summary.py --check-fixtures
```

`check-project.py` 核对 plist、target、扩展嵌入、共享源码和版本约束，仅代表工程结构检查，不替代原生编译。GitHub Actions 使用标准 `macos-15-intel` runner 运行共享层及结构验证；Intel 共享检查不替代本机架构或 macOS 27.3 原生验证。

共享测试保留 Swift 的原始退出码，并通过 `swift_test_summary.py` 核对正向实际执行数量与源码声明数量；兼容带 / 不带 suites 的 Swift Testing 摘要，XCTest 的零测试提示不能替代这项证据。

隔离 CLI 验证使用 Python 3.11+；CI 固定 Python 3.13，以标准 tomllib 独立核对 notify 配置。应用与 bridge 本身不依赖 Python。

需要指定测试临时目录时，设置 `TIDE_ISLAND_TEST_TMPDIR`；SwiftPM 构建目录可通过 `--scratch-path` 指定。

## 构建原生应用

```bash
python3 scripts/native_environment.py
bash scripts/check-native-sdk.sh
open TideIsland.xcodeproj
```

只读环境预检一次列出系统、Xcode 和 SDK 的数字版本及缺项；它不升级工具或接受许可，`ready` 也不代表正式版、原生编译或运行已经验证。当前环境与公开 API 核对见 [原生验收入口](docs/native-validation.md)。

在 Xcode 选择 `TideIsland` scheme、`My Mac`，为应用和扩展选择自己的签名团队后运行。首次启动 Xcode 时，由使用者本人阅读并确认许可协议。

使用支持的 SDK 进行无签名编译验证：

```bash
xcodebuild -project TideIsland.xcodeproj -scheme TideIsland \
  -configuration Debug -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build
```

原生构建使用 `MACOSX_DEPLOYMENT_TARGET=27.3`，不会回退为模拟刘海浮层。应用构建阶段会在独立 scratch 中构建目标架构的 bridge 并嵌入 `Contents/Helpers`，摘要清单写入 `Contents/Resources`，再由 Xcode 处理应用签名；流程及尚未验证范围见 [bridge 交付](docs/bridge-delivery.md)。

版本从 VERSION.json 生成应用 / 扩展共享 xcconfig 和 CLI 常量。Release archive、应用 / CLI ZIP、签名、公证及摘要记录使用 [打包入口](docs/packaging.md)；本机 beta arm64 archive / ad hoc 包及本机安装启动已通过，正式交付尚未完成。

应用 Resources 与独立 CLI ZIP 均附带项目 LICENSE 和 THIRD_PARTY_NOTICES.md；归档检查两份许可文本，发布清单记录其摘要，实际组件范围见[许可清单](THIRD_PARTY_NOTICES.md)。

独立 [Native compile 手动工作流](docs/native-validation.md)需要专用正式环境 runner、审阅后的完整 SHA 与操作者确认；workflow 已注册，专用 runner 未注册且未调度原生任务。共享 CI 只检查来源和默认保护，不能据此宣称原生 Debug / Release 编译通过。

本地已明确采用 beta 环境测试时，可使用验收脚本的 `--prerelease-environment-confirmed`，结果单独记录为 prerelease。它保留 clean SHA、SDK 和输出目录门禁；正式环境手动工作流继续只接受正式环境声明，具体用法见 [显式 beta 编译](docs/native-validation.md#显式-beta-编译)。

显式 Debug 的 `--native-sdk-smoke` 与 `--native-sdk-smoke-background` 分别测试前台 / 菜单栏后台的 SDK 生命周期，隔离正常接收器与显示偏好。前台合成生命周期已通过；后台实测被系统 visibility 拒绝时，应用显示前台要求并提供“打开会话”恢复动作。签名、条件和结果边界见 [SDK 测试说明](docs/native-validation.md#显式-debug-sdk-生命周期测试)；Release 不包含测试驱动。

原生活动展开后，上排显示状态图标、项目名和状态，下排显示计数和会话入口。四边采用 16 点内容边距，行间保留 10 点间隔。空间不足时，计数可以分行，会话入口可以缩为箭头。系统可用高度较小时使用单行内容块，完整名称和数字仍可由读屏读取。详见 [活动视图](docs/activity-views.md)。

会话窗口采用深色卡片和统一的字号层级，项目 / 状态 / 原观察信息分层，次要操作收进会话菜单。选择、活动候选和底部提示保留稳定空间，避免来源重确认或操作提示变化时列表整体跳动；长提示可悬停查看全文。默认高度增至 560 点，列表内容继续实时更新，详见 [会话浏览](docs/session-browser.md)。

菜单栏弹出菜单采用固定标题和操作入口，不跟随实时状态反复改写文字或禁用选项；详细状态与检查进度在会话窗口和设置中更新。岛的出现 / 收起及前台创建限制见 [常见问题](docs/faq.md#什么时候会出现或收起)。

健康来源重查只发布最后核验结果，避免“系统允许实时活动 / 等待来源确认”因临时中间帧来回切换；真正的读取失败仍会告警并暂停实时计数。权限查询保留上次结果，设置与会话窗口使用相同的稳定状态组件，见 [系统状态](docs/system-status.md)。

## 发送一个事件

```bash
swift run tide-island-bridge emit \
  --session demo-session --project tide-island --phase working

swift run tide-island-bridge emit \
  --session demo-session --project tide-island --phase needsInput

swift run tide-island-bridge emit \
  --session demo-session --project tide-island --phase completed
```

CLI 将事件原子写入 `~/Library/Application Support/TideIsland/Events/`，并输出一行 v2 JSON。运行中的应用监听该目录。状态包括 `working`、`needsInput`、`completed`、`failed`、`interrupted` 和 `ended`；`completed` 只表示本轮结束。新读取器继续兼容已有的 v1 记录。

`--inbox <目录>` 可隔离调试数据；默认只采集 `WAVETERM_BLOCKID`、`WAVETERM_TABID`、`WAVETERM_VERSION`。`--wave-block <ID>`、`--wave-tab <UUID>`、`--wave-version <版本>` 可显式提供独立的位置参数组，不与环境混用，详见 [位置元数据](docs/wave-location.md)。应用通过 [应用级返回](docs/wave-return.md)请求启动 / 返回 Wave，链接失效或打开失败有明确提示；原生行为仍待验证。共享层另有 [条件性同标签请求编排](docs/wave-navigation.md)，尚未接入真实聚焦 driver 或验证精确可见定位。已核对的 Wave 0.14.5 `focusblock` 只处理标签内布局，需要认证和 tab 上下文；跨标签 / 窗口没有本轮可承诺的公开路线，详见 [Wave 定位能力](docs/wave-capabilities.md)。

## 回放生命周期事件

按需诊断可使用 `tide-island-bridge diagnostics`，默认只报告版本；显式 inbox 才检查离线文件汇总，不生成实时会话或导出身份。应用「管理 → 导出诊断…」源码使用当前缓存，私有新文件导出、错误码及回放边界见 [诊断与回放](docs/diagnostics.md)。419 项共享测试和隔离 CLI 通过 CI，原生菜单交互待 27.3。

```bash
swift run tide-island-bridge replay \
  --file Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json \
  --scenario permission-wait-resume
```

回放使用固定身份和时间，经实际适配器、事件编解码与 registry 检查状态；只输出元数据报告。生命周期基线 24 场景 / 116 步，另有 `Fixtures/Replay/wave-location.json` 的位置基线 3 场景 / 7 步；预期不匹配时返回非零。格式见 [事件回放](docs/event-replay.md)，窗口与时间冲突规则见 [会话状态](docs/session-state.md)。

## 预览历史清理

```bash
swift run tide-island-bridge inbox cleanup --inbox /absolute/path/to/TideIsland/Events
# 核对具体回收文件和 fingerprint 后，再应用相同策略
swift run tide-island-bridge inbox cleanup --inbox /absolute/path/to/TideIsland/Events \
  --apply --expect FINGERPRINT
```

只回收已过期且可确认的整会话历史，完整保留未结束 / 无法归属的事件链，不清理提供方聊天文件。默认年龄目标 7 天、容量目标 4,096 文件 / 32 MiB，受保护数据不会为满足容量目标而被删除。增量读取、管理标记、资源上限、软目标和部分失败边界见 [inbox 维护](docs/inbox-maintenance.md)。

## 恢复事件通道

```bash
swift run tide-island-bridge inbox recover --inbox /absolute/path/to/TideIsland/Events
# 完成此前已开始的写入 / 已批准的清理
swift run tide-island-bridge inbox recover --inbox /absolute/path/to/TideIsland/Events --apply
```

应用接收器会自动完成安全的既有操作；损坏、冲突或超限时保留文件并暂停实时计数。目录重建后重新监听，旧记录必须在当前目录得到确认才能恢复为实时状态。诊断、重试、锁和恢复边界见 [通道故障恢复](docs/inbox-recovery.md)。

## 保存与清除本地会话

原生接入源码已启用必要元数据和偏好的本地 checkpoint，保留原事件时间、轮次及去重窗口；重启后重新确认当前事件来源。清理历史前先保存状态。保存失败或数据损坏时会给出提示，不静默覆盖原文件。

```bash
swift run tide-island-bridge state inspect --inbox /absolute/path/to/TideIsland/Events
swift run tide-island-bridge state clear --inbox /absolute/path/to/TideIsland/Events
# 核对清除 fingerprint 后再应用；原始事件文件保留
swift run tide-island-bridge state clear --inbox /absolute/path/to/TideIsland/Events \
  --apply --expect FINGERPRINT
```

清除会话 / 偏好与导入边界一起原子保存，已有文件不会马上恢复旧列表。独立 CLI 清除或清理历史需要关闭应用，打开时使用应用内入口；恢复边界和容量限制见 [会话持久化](docs/session-persistence.md)。

## Codex 接入边界

CLI 提供两个独立入口：

- `hook`：读取 stdin，转换工作开始、工具活动、许可等待、中断及会话结束；保持 stdout 为空，不参与 Codex 的控制决定。
- `notify --payload '<JSON>'`：转换 `agent-turn-complete`，读取线程与可用的 turn 身份，忽略聊天正文。

事件契约固定于 Codex CLI 0.169.0 的已审阅源码；当前本机 0.169.1 的相关上游 hook 实现 / schema blob 已直接复核一致，真实执行另验，详见 [Codex 事件契约](docs/codex-events.md)。`swift run tide-island-bridge capabilities` 可查看本程序支持的契约。

`hooks install` / `hooks uninstall` 默认只预览，显式应用时备份并合并 `hooks.json`，保留已有条目。用法、指纹、回退和 Codex `/hooks` 信任审查见 [hooks 配置管理](docs/codex-hooks.md)。本机已按明确授权完成六类 hooks 与完成 notify 的统一安装，配置写入不代表当前会话已经加载或信任。

原生构建产物可用 `hooks install --app /Applications/TideIsland.app` 检查固定包内 bridge；移动 / 升级后重新预览修复受管路径。该参数与 `--bridge` 互斥，校验清单不替代签名 / 公证验证；安装包当前仍未发布。

hooks 工具保持 `config.toml`、既有 notify 和内联 hooks 原样。独立 `notify-config` 工具只编辑明确指定 config.toml 的顶层 notify，保留并转发原命令参数，卸载恢复旧 notify，详见 [完成通知共存](docs/notify-integration.md)。完整接入使用 [统一配置流程](docs/installation.md)，默认预览、显式应用，总指纹覆盖两个文件：

```bash
# 首次启用、移动或升级应用时，先检查最新预览。
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" integration install \
  --codex-directory /absolute/path/to/codex --app /Applications/TideIsland.app
```

单独配置 notify 只覆盖本轮结束；其他已支持事件需要相应 hooks。`Stop`、压缩触发的 `SessionStart` 和子代理输入不会直接改变主会话状态。普通问答的准确等待与整轮最终失败尚无本适配器确认的自动来源；完整真实链路、会话恢复和后续来源适配继续分别推进。

## 当前能力与后续计划

- 已实现：v1 / v2 元数据事件、可选 Wave 位置与有效性投影、定位路线策略与可注入请求编排、应用级返回流程和严格会话链接、共享实时活动展示 / 客户端 / 更新调度、增量 inbox、可预览历史清理、通道恢复与单接收者、会话 / 偏好持久化和清除、轮次状态机、有界重复 / 退役轮次 / 工具窗口、会话新鲜度与展示过期、已读 / 忽略 / 置顶 / 选择与可解释排序、Codex hook / notify 转换、hooks 配置管理、确定性回放与逐步断言、隔离 CLI 检查、菜单栏与原生扩展源码。
- 已验证：macOS / Xcode 27.3 beta 的 arm64 原生 Debug / Release 编译；正式环境仍待复验。
- 已验证：beta arm64 本机 ad hoc 包、安装、首次启动、扩展注册及正常退出；不代表外部分发或可见岛通过。
- 待验证：灵动岛更新与点击、触摸交互、系统活动协调、真实接入和正式环境。
- 交付入口就绪：诊断菜单、打包和独立手动原生 CI；Developer ID、公证与公开发布继续单独验收。
- 待开发：普通问答 / 最终失败补充来源、可靠进程存活证据、Wave 精确定位、额度信息与小宠物。

原生界面的尺寸、动画、更新频率由系统约束；小宠物和高频动画需通过实机验证后再确定。

## 许可

TideIsland 使用 [MIT License](LICENSE)。未来引用第三方代码、字体或素材时逐项保留许可和来源；不能直接把 GPL 代码混入并当作仅 MIT 分发。
