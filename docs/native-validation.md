# 独立原生编译与统一验收入口

T027 准备独立的手动 Native compile 工作流与本地执行入口。2026-11-18 初核时，macOS 27.3（26C5047e）搭配旧 Xcode 27.2，SDK 查询被许可阻止。后续按用户授权安装官方 Xcode 27.3 beta 2（27C5035i），用户完成管理员初始化与许可后，已选中新版、实际查到 SDK 27.3，首次初始化状态通过，旧版已移除。本轮准备本地 beta 编译；没有注册或调度 runner，正式验收仍单独记录。

## 与共享 CI 的区别

| 证据 | 能证明的范围 |
| --- | --- |
| Core and project checks | 实际共享 Swift 测试、隔离 CLI、版本 / 工程结构、发布元数据和原生入口保护检查 |
| Native compile (manual) | 指定源码在正式原生环境中的 Debug / Release 无分发签名编译及产物元数据检查；必须有实际报告 |
| 本地 prerelease 编译 | 明确声明 beta 环境后，检查同源 Debug / Release 与产物；报告 validation_channel 为 prerelease，不能记为正式环境验收 |
| V001—V012 | 正式 API、签名安装、真实接入、系统交互 / 触摸 / 无障碍、多屏、恢复和能耗等统一验收 |

共享绿色、手动工作流存在、来源检查通过或 native job 被跳过，都不表示原生目标已编译。即使原生编译通过，也不表示 app / island 已运行、签名或真机验收完成。

## 只读环境预检

```bash
python3 scripts/native_environment.py
```

预检只运行四个固定查询：系统版本、系统 build、Xcode 版本和 macOS SDK 版本。不需要发行渠道声明、源码 clean 或输出目录，不创建构建产物，不接受许可、下载工具、修改 Xcode 选择或启动应用。它不读取 Codex / Wave 配置、会话或凭据。

JSON 同时报告系统 / Xcode / SDK 的数字版本和全部可确认的问题；工具失败只给出固定错误码，不转存原始 stderr。`xcode-license-required` 表示 SDK 查询遇到未确认许可，`version-below-minimum` 表示对应组件低于 27.3；缺失工具、超时和无法识别的版本也分别记录。受许可阻止时 `sdk_version` 是 null，不能据此声称已查到 SDK 版本。

退出 0 / `status: ready` 只表示数字前提与版本查询可用；退出 2 / `status: blocked` 表示环境尚未满足或无法确认。`release_channel` 始终是 `unverified`，`native_compile_verified` / `native_runtime_verified` 始终为 false。数字版本和 build 字符串本身不自动证明正式版。

初次预检同时记录了 Xcode 27.2 和 SDK 许可问题，后续升级 / 初始化后实测三项数字均为 27.3，预检变为 ready。Apple 的 [发布记录](https://developer.apple.com/news/releases/?id=11162026c)将 26C5047e 标为 **macOS 27.3 beta 2**；[Xcode 27.3 beta 2 说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_3-release-notes)与 [SDK 对照表](https://developer.apple.com/xcode/system-requirements/)说明 27.3 SDK 随对应 Xcode 提供。升级 macOS 不会自动完成 Xcode / SDK 升级。预检自身不安装工具或接受协议；本次安装是用户另外授权的动作，管理员认证及许可由使用者本人完成。ready 仍不是正式版或原生运行证据。

## V001 公开 API 初核

2026-11-18 核对 Apple 当前公开说明；以下均是文档证据，不能替代对应 SDK 的编译和运行。

| 源码入口 | 公开文档核对 | 保留的验证边界 |
| --- | --- | --- |
| ActivityKit 与授权查询 | [ActivityKit](https://developer.apple.com/documentation/activitykit)、[ActivityAuthorizationInfo](https://developer.apple.com/documentation/activitykit/activityauthorizationinfo)列出 macOS 27.3 支持 | 允许授权不证明界面显示或硬件布局；V001 / V009 核对实际 SDK 与系统状态 |
| 标准活动创建 | [request(attributes:content:pushType:)](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:))的声明与现有三个参数一致，列出 macOS 27.3 | 文档要求从前台创建；菜单栏应用首次接入、登录启动及后台到前台的实际行为由 V004 / V006 验证，不承诺后台自动创建一定成功 |
| 活动配置与岛布局 | [ActivityConfiguration](https://developer.apple.com/documentation/widgetkit/activityconfiguration)、[DynamicIsland](https://developer.apple.com/documentation/widgetkit/dynamicisland)列出 macOS 27.3，包含现有 content / dynamicIsland 和各尺寸布局入口 | 扩展发现、各尺寸实际展示、点击、触摸与无障碍仍由 V002 / V007 / V008 验证 |
| 支持标记与内容预算 | [NSSupportsLiveActivities](https://developer.apple.com/documentation/bundleresources/information-property-list/nssupportsliveactivities)说明开启标记；[活动指南](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)描述静态与动态合计 4 KB 的限制 | 标记页的 availability 尚只列 iOS / iPadOS；Mac 的配置要求和编码总量仍需正式 SDK / 实际产物核对。现有共享 3 KiB 预算保留为开发约束 |

当前 V001 仍未完成正式 SDK 核对。用户本轮已明确要求安装 Xcode 并在现有 27.3 beta 系统继续测试；V002 的 beta 实测使用下述独立声明，正式环境清单保留后续复验。环境预检暴露的问题不通过改低部署目标或把 beta 记为正式验收来消除。

## 本地执行

正式 macOS / Xcode 27.3+ 环境准备后，由操作者确认版本、完成必要的 Xcode 首次启动 / 许可，再执行：

```bash
python3 scripts/native-validation.py \
  --expected-revision REVIEWED_FULL_40_CHARACTER_SHA \
  --output /absolute/path/to/NEW-native-output \
  --configuration both --architectures arm64 --stable-environment-confirmed
```

脚本要求完整小写 40 位 SHA、当前 HEAD 精确一致和 clean worktree。输出目录必须新建且位于仓库之外或已忽略构建目录中。未明确确认正式环境时，在任何 native tool 调用前阻止执行；不会升级系统、下载 SDK、接受许可或打开应用。

确认标记是操作者声明，不是工具自动证明 beta / 正式。脚本复用上述只读环境预检，核对 host macOS、SDK 和 Xcode 数字版本均 27.3+；失败在 stdout JSON 中附带 environment、声明渠道和固定问题码，不创建编译输出，仍需 V001 核对正式接口。

每个配置独立记录 xcodebuild 输出、xcresult、derived data 和产物身份 / 版本 / 提交 / 架构 / helper 完整性。架构支持 arm64、x86_64 和 universal；host 能执行时只运行 helper 的只读 version 命令。每轮编译前后重查 source，变化即停止；T026 的 archive 入口同样补齐构建后源码复核。

只运行 `--configuration Debug` 或 Release 时，成功仅覆盖该配置；V002 完整编译要求 both。不会启动 TideIsland.app、切换 Wave、安装 hooks、申请权限 / 登录项或运行签名 / 公证。

### 显式 beta 编译

已确认使用 beta 系统或 Xcode，且本轮已授权执行 beta 验证时，改用：

```bash
python3 scripts/native-validation.py \
  --expected-revision REVIEWED_FULL_40_CHARACTER_SHA \
  --output /absolute/path/to/NEW-prerelease-native-output \
  --configuration both --architectures arm64 --prerelease-environment-confirmed
```

两个渠道选项互斥；默认仍不运行原生工具，没有声明时报告 `environment-attestation-required`。beta 模式继续要求精确 clean SHA、27.3+ 数字前提、新输出目录和构建前后来源复核，不降低部署目标。报告 `validation_channel: prerelease`、`operator_attested_stable_environment: false` 和 `operator_attested_prerelease_environment: true`；只有实际编译通过才设置 native_compile_verified，原生运行、签名及正式环境验收分别取证。用户本次要求新版 Xcode 校验安装成功后直接替换旧版，不保留旧版备份。

## 手动 CI

[native.yml](../.github/workflows/native.yml)只接受 workflow_dispatch，默认的正式环境确认值为 false；没有 push、PR 或定时触发。工作流必须指定维护者已经审阅的完整 SHA，checkout 精确 ref 且不保留 GitHub 凭据。

后续为专用 ARM64 macOS runner 配置以下标签，再由维护者手动运行：

```text
self-hosted, macOS, ARM64, tide-island-native-27.3
```

本轮没有安装或注册 runner。只运行已经审阅的源码，不增加公开 PR 自动触发。工作流先复核源码 / 版本 / 工程和入口条件，再分别编译 Debug / Release；它只具备 contents: read，不包含分发签名身份、notary profile 或配置安装命令。

手动工作流继续只用于正式环境，不添加 beta 开关；共享检查核对编译步骤不使用 prerelease 参数。未勾选正式环境确认时 native job 会跳过，这不是验证通过。没有匹配 runner 时任务可能排队，同样没有原生执行证据。若要保存失败，工作流尽力保留已生成的 JSON、日志和 xcresult，保留期 7 天；前置门禁尚未创建输出时，只有固定阻止原因和未验证状态。

## 报告与验收

native-validation.json 只有在环境 / 版本门禁通过并开始编译后创建。它记录精确 revision、版本、系统 / SDK / Xcode、validation_channel、操作者互斥的正式 / prerelease 声明、架构和逐配置结果。失败保留已完成范围，native_compile_verified 仅在所有请求配置检查成功后为 true；both_configurations_verified 单独表明双配置完整性。

native_runtime_verified 始终为 false，signing_requested 为 false。归档元数据不能验证 loader / 正式 API 语义；编译 / CLI version 成功也不能填上系统岛、触摸、VoiceOver 或性能结果。将实际报告及其 commit 关联回 [统一验收清单](development-progress.md#6-macos-273-正式环境统一验收)，再继续 V003—V012。

`--check-request-only` 只核对来源，输出 scope: source-request-only，两个 native 标记均为 false。共享 CI 的 [入口检查](../scripts/check-native-entry.py)通过 Ruby 标准 YAML parser 核对手动 / 默认关闭 / runner / read-only 权限结构，并实际检查精确 SHA、无效 / 错误 SHA 和未确认时先阻止；另用 10 组隔离替身覆盖环境就绪、多项版本不足、许可、工具缺失、超时、未知版本 / build、超量输出、非 Mac 与其他工具错误，4 组独立声明检查覆盖 stable、prerelease、缺失与冲突，并验证环境被拒时仍保留渠道、未创建编译输出。CI 中这些检查不查询真实 SDK、不执行真实 xcodebuild，也不接受许可。

Xcode 27.3 的 Swift 6.4 会输出带 `in 0 suites` 的成功摘要。本机首次实际运行已执行 419 项，但旧计数检查未识别新格式；现由 CI 与本机共用 [摘要校验工具](../scripts/swift_test_summary.py)，用 9 组 fixture 保留零测试、未完整执行和失败摘要的拒绝条件，不放松实际数量守卫。该兼容修复本身不证明原生应用已编译。
