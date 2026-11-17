# 独立原生编译与统一验收入口

T027 准备独立的手动 Native compile 工作流与本地执行入口。当前只做来源 / workflow / 默认保护条件检查，没有注册或调度 runner，没有查询本机 SDK / 许可，也没有执行原生编译。

## 与共享 CI 的区别

| 证据 | 能证明的范围 |
| --- | --- |
| Core and project checks | 实际共享 Swift 测试、隔离 CLI、版本 / 工程结构、发布元数据和原生入口保护检查 |
| Native compile (manual) | 指定源码在正式原生环境中的 Debug / Release 无分发签名编译及产物元数据检查；必须有实际报告 |
| V001—V012 | 正式 API、签名安装、真实接入、系统交互 / 触摸 / 无障碍、多屏、恢复和能耗等统一验收 |

共享绿色、手动工作流存在、来源检查通过或 native job 被跳过，都不表示原生目标已编译。即使原生编译通过，也不表示 app / island 已运行、签名或真机验收完成。

## 本地执行

正式 macOS / Xcode 27.3+ 环境准备后，由操作者确认版本、完成必要的 Xcode 首次启动 / 许可，再执行：

```bash
python3 scripts/native-validation.py \
  --expected-revision REVIEWED_FULL_40_CHARACTER_SHA \
  --output /absolute/path/to/NEW-native-output \
  --configuration both --architectures arm64 --stable-environment-confirmed
```

脚本要求完整小写 40 位 SHA、当前 HEAD 精确一致和 clean worktree。输出目录必须新建且位于仓库之外或已忽略构建目录中。未明确确认正式环境时，在任何 native tool 调用前阻止执行；不会升级系统、下载 SDK、接受许可或打开应用。

确认标记是操作者声明，不是工具自动证明 beta / 正式。脚本另行核对 host macOS、SDK 和 Xcode 数字版本均 27.3+，仍需 V001 核对正式接口。

每个配置独立记录 xcodebuild 输出、xcresult、derived data 和产物身份 / 版本 / 提交 / 架构 / helper 完整性。架构支持 arm64、x86_64 和 universal；host 能执行时只运行 helper 的只读 version 命令。每轮编译前后重查 source，变化即停止；T026 的 archive 入口同样补齐构建后源码复核。

只运行 `--configuration Debug` 或 Release 时，成功仅覆盖该配置；V002 完整编译要求 both。不会启动 TideIsland.app、切换 Wave、安装 hooks、申请权限 / 登录项或运行签名 / 公证。

## 手动 CI

[native.yml](../.github/workflows/native.yml)只接受 workflow_dispatch，默认的正式环境确认值为 false；没有 push、PR 或定时触发。工作流必须指定维护者已经审阅的完整 SHA，checkout 精确 ref 且不保留 GitHub 凭据。

后续为专用 ARM64 macOS runner 配置以下标签，再由维护者手动运行：

```text
self-hosted, macOS, ARM64, tide-island-native-27.3
```

本轮没有安装或注册 runner。只运行已经审阅的源码，不增加公开 PR 自动触发。工作流先复核源码 / 版本 / 工程和入口条件，再分别编译 Debug / Release；它只具备 contents: read，不包含分发签名身份、notary profile 或配置安装命令。

未勾选正式环境确认时 native job 会跳过，这不是验证通过。没有匹配 runner 时任务可能排队，同样没有原生执行证据。若要保存失败，工作流尽力保留已生成的 JSON、日志和 xcresult，保留期 7 天；前置门禁尚未创建输出时，只有固定阻止原因和未验证状态。

## 报告与验收

native-validation.json 只有在环境 / 版本门禁通过并开始编译后创建。它记录精确 revision、版本、系统 / SDK / Xcode、操作者的正式环境声明、架构和逐配置结果。失败保留已完成范围，native_compile_verified 仅在所有请求配置检查成功后为 true；both_configurations_verified 单独表明双配置完整性。

native_runtime_verified 始终为 false，signing_requested 为 false。归档元数据不能验证 loader / 正式 API 语义；编译 / CLI version 成功也不能填上系统岛、触摸、VoiceOver 或性能结果。将实际报告及其 commit 关联回 [统一验收清单](development-progress.md#6-macos-273-正式环境统一验收)，再继续 V003—V012。

`--check-request-only` 只核对来源，输出 scope: source-request-only，两个 native 标记均为 false。共享 CI 的 [入口检查](../scripts/check-native-entry.py)通过 Ruby 标准 YAML parser核对手动 / 默认关闭 / runner / read-only 权限结构，并实际检查精确 SHA、无效 / 错误 SHA 和未确认时先阻止；这些检查不探测 SDK，不执行 xcodebuild。
