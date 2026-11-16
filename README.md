# TideIsland · 潮汐岛

A native macOS Dynamic Island companion for Codex and AI coding agents.

让 AI 的工作状态，在岛上一目了然。面向 Wave + Codex 的本地开发伴随工具，使用系统原生实时活动展示会话状态。

> 当前阶段：原生展示逻辑开发。已提供 v1 / v2 事件协议、轮次状态、新鲜度投影、会话注意力、增量 inbox、可预览清理、通道恢复与会话持久化、观察型 hook / notify CLI、hooks 配置管理、确定性回放、菜单栏及原生扩展源码。本机真实接入和原生运行尚未验证，暂未发布可安装版本。

## 开发进度

完整任务、优先级、开发 / 验证状态及交付记录统一维护在 [开发计划与进度](docs/development-progress.md)。T019 已加入 [共享视图投影与无障碍源码](docs/activity-views.md)：统一各尺寸的状态 / 计数 / 链接，stale 降级、窄布局与完整读屏文案。新增 8 项共享测试，全量声明 275 项，等待严格 CI。原生编译、签名、显示和输入验收继续待 macOS 27.3 正式环境。

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
```

Swift Package 没有第三方依赖。Xcode 工程通过本地 package 依赖共享数据层，无需安装工程生成器。

## 验证共享层

```bash
swift test
swift build --product tide-island-bridge
python3 scripts/check-bridge.py
python3 scripts/check-hooks.py
python3 scripts/check-replay.py
python3 scripts/check-inbox.py
python3 scripts/check-state.py
python3 scripts/check-project.py
```

`check-project.py` 核对 plist、target、扩展嵌入、共享源码和版本约束，仅代表工程结构检查，不替代原生编译。GitHub Actions 使用标准 `macos-15-intel` runner 运行共享层及结构验证；Intel 共享检查不替代本机架构或 macOS 27.3 原生验证。

需要指定测试临时目录时，设置 `TIDE_ISLAND_TEST_TMPDIR`；SwiftPM 构建目录可通过 `--scratch-path` 指定。

## 构建原生应用

```bash
bash scripts/check-native-sdk.sh
open TideIsland.xcodeproj
```

在 Xcode 选择 `TideIsland` scheme、`My Mac`，为应用和扩展选择自己的签名团队后运行。首次启动 Xcode 时，由使用者本人阅读并确认许可协议。

使用支持的 SDK 进行无签名编译验证：

```bash
xcodebuild -project TideIsland.xcodeproj -scheme TideIsland \
  -configuration Debug -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build
```

原生构建使用 `MACOSX_DEPLOYMENT_TARGET=27.3`，不会回退为模拟刘海浮层。

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

事件契约按本机 Codex CLI 0.169.0 核对，详细字段、合成测试数据与能力边界见 [Codex 事件契约](docs/codex-events.md)。`swift run tide-island-bridge capabilities` 可查看本程序支持的契约。

`hooks install` / `hooks uninstall` 默认只预览，显式应用时备份并合并 `hooks.json`，保留已有条目。用法、指纹、回退和 Codex `/hooks` 信任审查见 [hooks 配置管理](docs/codex-hooks.md)。本轮尚未应用到用户的真实配置。

配置工具保持 `config.toml`、既有 notify 和内联 hooks 原样。完成通知仍需将稳定路径的桥接程序配置为 notify 命令，并让 Codex 追加 JSON 参数；与既有 notify 共存的完整接入流程由 T025 继续实现：

```toml
# 仅为接入示意。使用实际的稳定绝对路径，并合并已有配置。
notify = ["/absolute/path/to/tide-island-bridge", "notify", "--payload"]
```

单独配置 notify 只覆盖本轮结束；其他已支持事件需要相应 hooks。`Stop`、压缩触发的 `SessionStart` 和子代理输入不会直接改变主会话状态。普通问答的准确等待与整轮最终失败尚无本适配器确认的自动来源；真实配置安装、完整会话恢复和后续来源适配仍待开发。

## 当前能力与后续计划

- 已实现：v1 / v2 元数据事件、可选 Wave 位置与有效性投影、定位路线策略与可注入请求编排、应用级返回流程和严格会话链接、共享实时活动展示 / 客户端 / 更新调度、增量 inbox、可预览历史清理、通道恢复与单接收者、会话 / 偏好持久化和清除、轮次状态机、有界重复 / 退役轮次 / 工具窗口、会话新鲜度与展示过期、已读 / 忽略 / 置顶 / 选择与可解释排序、Codex hook / notify 转换、hooks 配置管理、确定性回放与逐步断言、隔离 CLI 检查、菜单栏与原生扩展源码。
- 待验证：macOS 27.3 原生编译、签名安装、灵动岛更新与点击、触摸交互及系统活动协调。
- 待开发：完整接入与 notify 共存、普通问答 / 最终失败补充来源、可靠进程存活证据、Wave 精确定位、额度信息与小宠物。

原生界面的尺寸、动画、更新频率由系统约束；小宠物和高频动画需通过实机验证后再确定。

## 许可

TideIsland 使用 [MIT License](LICENSE)。未来引用第三方代码、字体或素材时逐项保留许可和来源；不能直接把 GPL 代码混入并当作仅 MIT 分发。
