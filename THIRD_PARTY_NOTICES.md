# 第三方组件与许可清单

核对日期：2026-11-18。本清单针对当前仓库源码、开发工具和已生成的 beta arm64 Release 包。首次实际 ZIP 清点只有本项目的 app / extension / helper 三份代码，没有另附 Frameworks 或动态库；其余架构、正式分发及新增依赖仍须单独复核。

## 当前随源码交付的内容

TideIsland 自有源码使用根目录 [MIT License](LICENSE)，Copyright (c) 2026 Kevin.Liao。Swift Package 只有本仓库 target，未声明第三方 package；Xcode 仅引用本地 package，无远程 package 引用。没有内置 Codex / Wave 二进制、下载的 SDK、外部 npm / Python 包或第三方图片 / 字体。

`Tests/TideIslandCoreTests/Fixtures/Codex/lifecycle.json` 与 `Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json` 为仓库合成测试输入；文件记录审阅版本 / schema 名称，不是上游完整 schema 或用户会话的副本。版本常量与 xcconfig 由本项目脚本生成。当前没有需要随源码附带全文的第三方组件许可。

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

构建阶段把本项目 LICENSE 与本清单写入 app 的 Contents/Resources，归档检查要求两份有界普通 UTF-8 文件；签名覆盖这些资源。独立 CLI ZIP 同样带上这两份文件，发布清单记录其 SHA-256 / 大小。首次 ZIP 缺少许可证的问题已由此流程修复，仍须用同源实际包验证。

正式发布前继续按实际内含组件复核许可证、NOTICE 和修改要求；[打包脚本](https://github.com/KevinLjb/tide-island/blob/main/scripts/package-artifacts.py)不会因这两份文件存在就自动证明全部组件声明完整。当前已有 beta 本机 ad hoc 包及初步清点，尚未执行 Developer ID、公证或公开发布。支持范围与格式维护见[兼容清单](https://github.com/KevinLjb/tide-island/blob/main/docs/compatibility.md)及[开发进度](https://github.com/KevinLjb/tide-island/blob/main/docs/development-progress.md)。
