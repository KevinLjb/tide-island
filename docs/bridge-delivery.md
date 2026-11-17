# 应用内 bridge 交付

T024 将 `tide-island-bridge` 放到应用包内固定的 `Contents/Helpers/`，摘要清单位于 `Contents/Resources/`，并提供应用完整性检查和受管 hooks 路径修复。beta 环境已完成原生双配置编译；实际签名安装继续由 V003 验证。

## 构建位置

应用 target 的 `Embed event bridge` 阶段调用 [构建脚本](../scripts/build-embedded-bridge.sh)：

1. 按 Xcode 当前 Debug / Release 配置及 `ARCHS` 构建 SwiftPM bridge；只处理 arm64 / x86_64，未识别架构明确失败。
2. 每个架构使用独立的 `DERIVED_FILE_DIR/bridge-<arch>` scratch，避免与 Xcode 自身 package 构建共用缓存。
3. 合并目标架构，若 Xcode 允许签名则先签署 helper；无签名编译不会申请签名身份。
4. [嵌入脚本](../scripts/embed-bridge.py)复制 helper 到 `Contents/Helpers/tide-island-bridge`，在 `Contents/Resources/bridge-manifest.json` 生成清单；随后 Xcode 签署外层应用。

清单是 version 1 的 `tide-island-embedded-bridge`，只含固定文件名和签名后的 SHA-256，不保存构建目录、用户名或时间。两文件分别原子发布，中断时检查器拒绝不完整配对；它不是跨文件事务。

首次真实签名发现 Helpers 中的 JSON 被当作未签署嵌套代码。按 [Apple 的包布局规则](https://developer.apple.com/library/archive/technotes/tn2206/)，数据移入 Resources，helper 的稳定执行路径保持不变。嵌入时清除本项目旧位置的普通清单文件，拒绝资源目录、清单或 helper 链接；增量构建也会生成可签署布局。

原生 target 仍只有应用 / 扩展两个。应用 target 为嵌套 SwiftPM 构建关闭 Xcode 的用户脚本 sandbox，扩展设置不变；脚本的构建产物和暂存均位于 DerivedFileDir。该流程没有执行 hooks 安装、读取 Codex 配置或启动应用。

## 从应用安装 hooks

后续有实际应用包时，使用当前应用包里的 helper。下列命令先预览，只处理显式的 hooks.json：

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" hooks install \
  --config /absolute/path/to/codex/hooks.json \
  --app /Applications/TideIsland.app
```

`--app` 与 `--bridge` 互斥。`BundledBridge.inspect` 不执行 helper，检查固定的应用包标识、类型、执行文件名、数字版本，以及真实目录、有界普通可执行文件和清单摘要。Info.plist 上限 64 KiB、清单 16 KiB、helper 64 MiB；链接 / 特殊文件、损坏、未知清单或 `.build` / `DerivedData` 路径均拒绝。应用根路径别名先解析，不能借别名绕过临时构建目录限制。

摘要用于交付完整性，不能证明 Apple 签名、公证、来源可信或 CLI 行为。正式分发仍需 T026 / V003 的独立签名和运行验收。

预览返回现有六类 handler 数量、是否需要变更及 `bridge_delivery` 的已检查路径 / 版本 / 摘要。指纹绑定 hooks 目标 / 原字节 / 拟写内容，同时绑定 helper 摘要和应用版本。应用后续移动、升级或 helper 内容变化，都需要重新预览：

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" hooks install \
  --config /absolute/path/to/codex/hooks.json \
  --app /Applications/TideIsland.app \
  --apply --expect FINGERPRINT --backup-dir /absolute/path/to/retained-backups
```

应用阶段重新检查 bundle，即使 hooks 命令无变化，也不能用旧预览确认已替换的 helper。写入前还会再次检查；与非协作的应用替换 / 文件编辑之间仍不是跨文件 CAS，请勿在同一次预览与应用期间移动或升级应用。

## 移动、升级与恢复

升级保持相同应用路径时，hooks 命令通常不变，新的预览只更新检查依据；不会为无变化的配置制造备份或写入。应用移动到新路径后，旧命令可能已不可执行，需要用新包内 helper 和新 `--app` 路径重新预览；它会报告受管配置需要修复，再显式应用。

这个 hooks 命令只更新本项目完整保留标记识别的 handler，保留其他命令、matcher、字段和空分组；原始字节先备份。既有 notify、config.toml 和 Codex 信任状态继续保持；T025 的 [统一安装 / 卸载](installation.md)另外接入完成 notify 共存。[hooks 配置管理](codex-hooks.md)说明并发、回退与信任审查。

未安装或检查失败时，不使用搜索到的同名可执行文件，不自动改配置，也不退回 `.build/debug` 路径。修复前六类观察可能无法送达，列表保留状态不能被当成当前活动证据。

## 验证范围

共享测试覆盖路径及清单校验、有界读取、链接 / 临时目录隔离、摘要 / 版本绑定、移动修复、保留外部条目及变更后不写文件。CI 的 [隔离交付检查](../scripts/check-delivery.py)复制并实际运行当次编译的 bridge，验证 capability、预览 / 幂等、移动 / 升级及错误配置不写入。

本地只执行 Python / shell 语法、隔离复制 / 摘要 / 链接拒绝和工程结构检查，未构建 Swift 或运行原生阶段。Xcode shell phase、各架构产物、签名顺序 / 安装、应用移动后的真实 Codex 调用继续待 [统一验收](development-progress.md#6-macos-273-正式环境统一验收)。
