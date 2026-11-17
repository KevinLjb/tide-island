# 版本、构建产物与打包

T026 提供可追溯的原生归档与应用 / CLI ZIP。已在用户授权的 macOS / Xcode 27.3 beta 环境执行首次 arm64 Release archive；后续 ad hoc 签名暴露 Helpers 中 JSON 的布局问题，已修正为 Resources 清单，签名安装继续验证。尚未执行 Developer ID、公证或发布 release；正式分发仍需正式环境复验。

## 单一版本来源

根目录 [VERSION.json](../VERSION.json)保存 schema version 1、三段数字版本和正整数 build。当前为 0.1.0 / 1。修改它后运行：

```bash
python3 scripts/sync-version.py --write
python3 scripts/sync-version.py
```

脚本生成 Config/Version.xcconfig 和共享 TideIslandVersion.swift。Xcode 项目 Debug / Release 使用同一 base configuration，应用 / 扩展继承其版本；CLI `version` 输出 JSON，`--version` 输出简短文本。CI 默认只检查生成物，不在检查时自动改文件。

发布归档还把当前 clean Git HEAD 传入应用和扩展的 TideIslandSourceRevision；普通开发构建默认 development。版本、提交标记和摘要用于追溯，不证明编译源码或签名的外部可信性。

## 原生归档入口

先完成 V001 的接口 / 最低版本核对。正式分发使用正式环境；本机 beta 测试须明确记录其渠道，再执行：

```bash
bash scripts/build-release.sh --output /absolute/path/to/NEW-output \
  --architectures universal --signing unsigned
```

入口要求 clean 仓库、新的绝对输出目录及正确的生成版本，父目录需已存在，输出放在仓库外或忽略的构建目录；归档后再次复核提交和 clean 状态，变化即停止打包。运行现有 SDK 27.3+ 检查后才创建输出。它不下载 SDK、接受许可、安装应用或写 Codex 配置；SDK 数字检查本身不能区分 beta / 正式，操作者须另行记录发行渠道。

Release archive 使用 Xcode app / extension 与 T024 的包内 bridge 构建阶段。默认 universal，另外可显式选择 arm64 / x86_64；scratch、DerivedData、xcarchive 和 native-build.log 都保留在指定输出中。本机首次 beta arm64 archive 已成功；不代表另两种架构或后续签名 / 运行通过。

## 签名方式

| 选项 | 记录与范围 |
| --- | --- |
| `--signing unsigned` | 不执行分发签名；链接器可能仍带 ad hoc 签名，不当作 Developer ID |
| `--signing adhoc` | 在本机构建产物上签署并验证代码完整性，不能证明外部分发身份 |
| `--signing developer-id --identity ID` | 必须显式指定身份；检查 app / extension / helper 同一 team 且均为 Developer ID Application |

签名顺序为 helper → 重建 Resources 中签名后摘要清单 → extension → app，再逐项与 deep / strict 验证。Helpers 只保存可执行代码，详见 [bridge 布局修复](bridge-delivery.md)。公证和 runtime 验收独立，签名成功不表示灵动岛可用。

外部分发准备可显式附带 `--notarize-profile PROFILE`，仅允许 Developer ID。脚本将应用 ZIP 提交 notarytool，要求 Accepted，再 staple / validate 应用并运行 Gatekeeper assess，重新生成含票据的应用 ZIP。这个选项会向 Apple 上传应用；当前开发没有执行，也未查询本机证书或公证凭据。

命令行 executable 不单独 staple；CLI ZIP 使用同一个 helper 代码。其外部分发、隔离属性、在线 / 离线 Gatekeeper 行为仍需 V003 分别验证，不把应用公证自动标记为所有交付路线已验收。

## 归档检查与输出

package-artifacts.py 只用于自己构建并审阅的 xcarchive，会检查 app / extension 身份、版本、同一提交和最低系统、三份代码的 Mach-O 架构及 helper 清单。若 host 支持目标架构，还会运行 helper 的只读 version 命令；跨架构无法运行时明确记录，没有用真实 UI 代替检查。

检查器的 Mach-O 处理限定 64 位 arm64 / x86_64 及有界 universal 表，校验重复 / 交叠 / 越界和 slice CPU。它检查头部元数据，不能证明 loader、原生 API 或应用运行有效。

成功输出包含：

- TideIsland.app：应用与嵌入扩展 / helper。
- TideIsland-VERSION-BUILD-macos-ARCH.zip：可解压后移至稳定位置的应用归档。
- TideIsland-bridge-VERSION-BUILD-macos-ARCH.zip：同一 helper 的独立命令行归档及版本标记。
- release-manifest.json：版本、Git revision、SDK、架构、签名 / 公证步骤、组件和两个 ZIP 的 SHA-256 / 大小；不记录构建绝对目录或环境集合。

只有成功写出 release-manifest 才表示打包步骤完成。失败保留中间输出供检查，下一次使用新目录，不自动覆盖或把半成品发布。脚本不创建 GitHub release、tag，也不执行安装；当前源代码提交不等于已经交付可安装版本。

校验下载的归档一致性：

```bash
python3 scripts/verify-artifacts.py --manifest /absolute/path/release-manifest.json
```

这个入口只读取清单对应的两个 ZIP，拒绝路径越界、链接、重复键、无效大小和摘要。输出 checksums-only，始终不把清单声明当作系统签名、公证或真机通过。

## 验证范围

本地执行 `check-release.py --metadata-only` 的 11 项检查，覆盖版本生成漂移、错误 / 重复元数据、合成 Mach-O header、架构 / 提交 / 扩展版本不一致、helper 损坏 / 链接、ZIP 摘要和范围；没有执行任何合成二进制。

共享 CI 另外用实际编译的 bridge 核对 version / --version 和代码架构，合计 12 项发布元数据检查。原生 archive、签名、公证、安装与完整包运行继续待 [统一验收](development-progress.md#6-macos-273-正式环境统一验收)；T027 已准备 [独立手动原生编译入口](native-validation.md)，当前仍未调度或执行。
