# 第三方组件与许可清单

核对日期：2026-11-17。本清单针对当前仓库源码及开发工具；原生归档和最终二进制尚未生成，分发包实际内含库仍须在 V003 验收时复核。

## 当前随源码交付的内容

TideIsland 自有源码使用根目录 [MIT License](LICENSE)，Copyright (c) 2026 Kevin.Liao。Swift Package 只有本仓库 target，未声明第三方 package；Xcode 仅引用本地 package，无远程 package 引用。没有内置 Codex / Wave 二进制、下载的 SDK、外部 npm / Python 包或第三方图片 / 字体。

[Codex fixture](Tests/TideIslandCoreTests/Fixtures/Codex/lifecycle.json)与 [回放场景](Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json)为仓库合成测试输入；文件记录审阅版本 / schema 名称，不是上游完整 schema 或用户会话的副本。版本常量与 xcconfig 由本项目脚本生成。当前没有需要随源码附带全文的第三方组件许可。

## 运行环境与外部集成

| 项目 | 关系 / 审阅版本 | 许可来源与当前分发范围 |
| --- | --- | --- |
| Apple 系统框架 / SDK | Foundation、Darwin、Dispatch、CryptoKit、AppKit、Combine、SwiftUI、ActivityKit、WidgetKit、UserNotifications、ServiceManagement、UniformTypeIdentifiers | 使用系统 / Xcode 公开接口，受对应 Apple SDK / 平台条款约束；仓库不复制或重发 SDK。最终归档中的工具链 runtime 需按实际内容复核 |
| Swift 工具链与 Testing | Swift tools 6.0+，编译 / 共享测试 | 工具链由开发者环境提供；不是第三方 Swift Package 引入。工具链本身的许可见 [Swift LICENSE](https://github.com/swiftlang/swift/blob/main/LICENSE.txt)，不能据此预先推断尚未生成的归档内含库 |
| Codex | 0.169.0 固定契约；独立外部程序 | [Apache-2.0 LICENSE（固定 revision）](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/LICENSE)；只对接事件协议，不随 TideIsland 分发程序、凭据或上游源码 |
| Wave | 0.14.5 固定源码审阅；独立外部应用 | [Apache-2.0 LICENSE（固定 revision）](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/LICENSE)；只对接公开能力，不内置应用 / wsh 或其资源 |

外部项目的名称用于说明兼容关系；其许可不自动覆盖本项目，也不表示对本项目作出背书。固定 Codex / Wave 许可已在本轮只读核对；将来实际复制代码或资源时需另外登记路径、来源 revision、修改及所需 NOTICE / 许可全文。

## 开发与 CI 工具

| 工具 | 使用范围 | 来源 |
| --- | --- | --- |
| Python 3 标准库 | 版本 / 工程 / 隔离 CLI / 元数据检查，不随 app / CLI 作为 Python runtime 分发 | [PSF License](https://docs.python.org/3/license.html) |
| GitHub Actions checkout v4 | CI 拉取仓库，不进入 app / CLI | [MIT LICENSE](https://github.com/actions/checkout/blob/v4/LICENSE) |
| GitHub Actions setup-python v6 | CI 提供 Python 3.13，不进入 app / CLI | [MIT LICENSE](https://github.com/actions/setup-python/blob/v6/LICENSE) |
| Xcode 系统工具与 Git | 构建、签名、压缩和版本记录，由执行环境提供 | 各自环境条款；当前没有把这些工具打包进产品 |

## 维护与发布

增加 package / 资源 / 复制源码时，同一提交记录名称、精确版本或 commit、许可证、NOTICE / 修改要求和实际交付路径；不能把“参考思路”当成复制代码的许可。删除依赖时核对最终 app、extension、helper 与 ZIP 是否仍带有对应文件。

正式发布前对实际归档做依赖与资源清点，按所含组件带上许可证、NOTICE 和本项目 LICENSE；[当前打包脚本](scripts/package-artifacts.py)不把本文的存在当作二进制许可检查或自动补齐所有声明。当前没有发布、签名 / 公证或最终包许可验收的结论。支持范围与格式维护见 [兼容清单](docs/compatibility.md)及 [开发进度](docs/development-progress.md)。
