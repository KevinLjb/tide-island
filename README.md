# TideIsland · 潮汐岛

A native macOS Dynamic Island companion for Codex and AI coding agents.

让 AI 的工作状态，在岛上一目了然。面向 Wave + Codex 的本地开发伴随工具，使用系统原生实时活动展示会话状态。

> 当前阶段：Codex 生命周期桥接开发。已提供 v1 / v2 事件协议、会话共享层、观察型 hook / notify CLI、菜单栏及原生扩展源码。真实 hooks 配置安装和原生运行尚未完成，暂未发布可安装版本。

## 开发进度

完整任务、优先级、开发 / 验证状态及交付记录统一维护在 [开发计划与进度](docs/development-progress.md)。生命周期转换已通过共享层与 CLI 检查，下一步推进 hooks 配置管理与确定性回放；macOS 27.3 正式版发布前持续开发，原生编译、签名和真机验收集中到正式环境可用后执行。

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
  App/                        菜单栏入口、会话列表、事件目录监听、Activity 生命周期
  ActivityExtension/          系统原生实时活动 / Dynamic Island 视图
  Shared/                     两个 target 共用的 ActivityAttributes
Sources/
  TideIslandCore/              事件编解码、会话状态、Codex hook / notify 映射、本地 inbox
  TideIslandBridge/            tide-island-bridge 命令行入口
Tests/TideIslandCoreTests/     协议、乱序事件、会话隔离、路由和 inbox 测试
scripts/                      工程结构检查与原生 SDK 检查
docs/architecture.md          架构、能力边界与后续步骤
docs/development-progress.md  开发计划、任务进度与 27.3 统一验收清单
docs/codex-events.md          固定版本的 Codex 事件契约、转换矩阵与兼容范围
```

Swift Package 没有第三方依赖。Xcode 工程通过本地 package 依赖共享数据层，无需安装工程生成器。

## 验证共享层

```bash
swift test
swift build --product tide-island-bridge
python3 scripts/check-bridge.py
python3 scripts/check-project.py
```

`check-project.py` 核对 plist、target、扩展嵌入、共享源码和版本约束，仅代表工程结构检查，不替代原生编译。GitHub Actions 目前只运行共享层及结构验证。

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

`--inbox <目录>` 可隔离调试数据；`--wave-block <ID>` 可显式携带分屏标识。在 Wave 中运行时，默认读取 `WAVETERM_BLOCKID`。应用当前只唤起 Wave，**尚未实现或验证精确分屏定位**。

## Codex 接入边界

CLI 提供两个独立入口：

- `hook`：读取 stdin，转换工作开始、工具活动、许可等待、中断及会话结束；保持 stdout 为空，不参与 Codex 的控制决定。
- `notify --payload '<JSON>'`：转换 `agent-turn-complete`，读取线程与可用的 turn 身份，忽略聊天正文。

事件契约按本机 Codex CLI 0.169.0 核对，详细字段、合成测试数据与能力边界见 [Codex 事件契约](docs/codex-events.md)。`swift run tide-island-bridge capabilities` 可查看本程序支持的契约。

当前工程不会自动修改 `~/.codex/config.toml` 或安装 hooks。后续接入可将已构建的桥接程序配置为 notify 命令，并让 Codex 追加 JSON 参数：

```toml
# 仅为接入示意。使用实际的稳定绝对路径，并合并已有配置。
notify = ["/absolute/path/to/tide-island-bridge", "notify", "--payload"]
```

单独配置 notify 只覆盖本轮结束；其他已支持事件需要相应 hooks。`Stop`、压缩触发的 `SessionStart` 和子代理输入不会直接改变主会话状态。普通问答的准确等待与整轮最终失败尚无本适配器确认的自动来源；真实配置安装、完整会话恢复和后续来源适配仍待开发。

## 当前能力与后续计划

- 已实现：v1 / v2 元数据事件、本地 inbox、基础事件去重 / 时间过滤、多会话注意力排序、Codex hook / notify 转换、隔离 CLI 检查、菜单栏与原生扩展源码。
- 待验证：macOS 27.3 原生编译、签名安装、灵动岛更新与点击、触摸交互及系统活动协调。
- 待开发：hooks 配置安装 / 卸载、普通问答 / 最终失败补充来源、跨轮状态与存活判断、Wave 精确定位、事件保留策略、额度信息与小宠物。

原生界面的尺寸、动画、更新频率由系统约束；小宠物和高频动画需通过实机验证后再确定。

## 许可

TideIsland 使用 [MIT License](LICENSE)。未来引用第三方代码、字体或素材时逐项保留许可和来源；不能直接把 GPL 代码混入并当作仅 MIT 分发。
