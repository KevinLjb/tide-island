# 支持版本与兼容边界

本清单记录当前源码目标、已审阅外部契约和实际证据；最低版本声明不等于安装、原生岛或触摸验收通过。

2026-11-18 核对。本机开发包为 0.1.0 / build 15。海獭会话封面资源随原生扩展安装。单会话和总览已通过同源布局渲染、深链解析及隔离 AppKit 点击检查。原生岛宿主显示、输入和公开分发继续单独验收。见 [VERSION.json](../VERSION.json)和[活动视图](activity-views.md)。

## 环境与外部集成

| 范围 | 当前目标 / 已审阅版本 | 已有证据与边界 |
| --- | --- | --- |
| 共享 Swift Package / bridge | Swift tools 6.0；macOS 14+ | [Package.swift](../Package.swift) 声明最低版本。共享 CI 在 `macos-15-intel`，本机 ARM64 / 27.3 beta 的 437 项及 10 组 CLI 已通过。最低 macOS 14 仍待实测 |
| 原生应用 / 扩展 | macOS / Xcode / SDK 27.3+ | 本机 beta arm64 Debug / Release 已通过；正式环境、完整接口与系统场景仍分别复验 |
| 原生岛与触摸 | 支持相应公开接口的兼容 Mac | 已有用户演示 / 真实工作状态确认与前台合成 SDK 生命周期证据；新布局、触摸、多屏及无障碍不由这些证据自动覆盖 |
| ARM64 / universal 交付 | 手动入口为专用 ARM64 runner，打包支持 arm64 / universal 参数 | 本机 arm64 archive、ad hoc 签名包与 build 15 更新已验证。专用 runner、universal、Developer ID、公证与公开分发继续验收 |
| Codex hooks / notify | 固定 0.169.0 契约；本机 0.169.1 相关上游 hook / schema blob 已复核一致 | 已按授权安装，用户审查后已观察真实开始 / 工具 / 完成事件及原生工作状态；许可等待 / 中断等生命周期另验，见 [事件契约](codex-events.md) |
| Codex 额度 | 已运行且支持 `account/rateLimits/read` 的本机 Codex App Server | 已在 CLI 0.169.1 与 daemon 0.170.0 的组合读取实际 7 天窗口。账号、服务版本和启动方式影响窗口与接口可用性。见 [额度设置](preferences.md#codex-额度) |
| Wave | 已审阅 0.14.5，源码 `97e560027f494d20fed347b2d6b72b6bcb3e50e0` | 固定 bundle 应用级返回源码；条件性同标签策略未接真实 driver，无跨标签 / 窗口定位承诺，见 [能力矩阵](wave-capabilities.md) |
| Python 开发检查 | Python 3.11+，CI 固定 3.13 | 隔离配置检查使用标准 `tomllib`；应用 / bridge 运行不依赖 Python |

`version` 只报告自身生成版本；`capabilities` / `diagnostics` 中的 Codex 与 Wave 版本是已审阅契约，不探测当前安装。Wave 版本未知或不同会使精确路线降为待确认 / 应用级回退，不能根据版本字符串制造认证连接。

27.3 数字门禁不能证明正式版。[原生入口](native-validation.md)要求完整 reviewed SHA 与显式环境声明；本地 beta 使用独立 prerelease 声明，手动工作流仍只用于正式环境。共享 CI、原生编译、本机签名、分发公证和真实运行分别记录。

## 数据与配置格式

| 对象 | 当前写入 / 输出 | 可读范围与变化策略 |
| --- | --- | --- |
| 事件 | v2，单文件最大 16 KiB | 读 v1 / v2；v1 不补造 source / turn；未知版本保留并报告拒绝，不改成失败事件 |
| 可选 Wave 位置 | 独立 schema v1，附在事件 v2 | 缺省 / legacy block 可读但不满足精确定位条件；不自动补 tab / window / 认证 |
| 会话 checkpoint | kind `tide-island-session-state`，v2，最大 32 MiB | 读 v1 / v2；读旧版不写文件，后续必要保存使用 v2；scope / 去重窗口 / 清除导入边界均保留 |
| 应用显示与提醒偏好 | kind `tide-island-preferences`，v1，最大 16 KiB | 独立 UserDefaults 键 `tide-island.preferences.v1`；未知 / 损坏时保留，用户明确恢复默认值才替换 |
| hooks 配置 | Codex `hooks.json`，最大 1 MiB | 只维护完整 TideIsland observer v1 标记及引用格式；保留外部字段，不迁移 Codex 信任或其他配置层 |
| notify 配置 | `config.toml` 顶层 notify，最大 1 MiB | 保守局部 TOML 编辑，不是通用校验器；wrapper marker `--tide-island-notify-v1`；原 argv 保留在同一设置中 |
| 配置备份回执 | version 1，`before-change-backup` | hooks / notify 各自保存原始字节、原存在与权限；无自动跨文件回退或降级迁移 |
| 包内 bridge 清单 | version 1，`tide-island-embedded-bridge` | 固定 Helpers 路径 / 可执行名与 SHA-256；不把摘要当系统签名，未知格式拒绝 |
| 版本 / 发布清单 | `VERSION.json` schema 1 / release manifest schema 1 | 生成常量 / xcconfig；manifest 区分 metadata、checksum、签名、公证与 runtime，见 [打包](packaging.md) |
| 诊断 / 合成回放 | 报告 schema 1 / fixture schema 1 | 诊断只输出必要汇总，不能当回放输入；回放只读显式合成场景，见 [诊断](diagnostics.md) |

详细迁移及恢复步骤见 [升级与格式迁移](migrations.md)。事件、checkpoint、应用偏好和 Codex 配置各有边界，不共用一个版本号；应用版本提升不会自动升级全部数据。

## 变更版本时

新 Codex / Wave 版本先固定源码、核对字段 / 身份 / 失败语义，再增加独立合成反例；不能只改版本常量。新增数据格式要明确可读版本、失败保留、保存时机和回退范围，同时更新本清单、[迁移说明](migrations.md)、[许可清单](../THIRD_PARTY_NOTICES.md)及 [开发进度](development-progress.md)。

T029 的清单随新证据维护，历史测试与最新构建分开。实际验收、安装及仍未通过的场景统一见 [开发进度](development-progress.md)，不从版本或配置写入推断全部能力已通过。
