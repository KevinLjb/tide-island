# 独立原生编译与统一验收入口

T027 准备独立的手动 Native compile 工作流与本地执行入口。2026-11-18 初核时，macOS 27.3（26C5047e）搭配旧 Xcode 27.2，SDK 查询被许可阻止。后续按用户授权安装官方 Xcode 27.3 beta 2（27C5035i），用户完成管理员初始化与许可后，已选中新版、实际查到 SDK 27.3，首次初始化状态通过，旧版已移除。本地 beta 双配置编译已通过；没有注册或调度 runner，正式验收仍单独记录。

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

## 显式 Debug SDK 生命周期测试

独立的 `--native-sdk-smoke-background` 测试菜单栏后台请求：保留一个诊断菜单项，不主动激活窗口，并核对应用确实不在前台。它与前台参数互斥，仍隔离正常模型、只管理内存合成会话及 ownedOnly 活动。报告新增 validation_mode；SDK request 失败仅附带 ActivityAuthorizationError 的固定枚举名和数字代码，不输出 localizedDescription、userInfo、任意错误域或活动 ID。两个参数在 Release 都不读取。

开发态及 clean `e7d84c46b0f7788f7d343d9af0a3bcf6be10d1fd` 后台测试均实际调用 SDK，返回 visibility / 7；共享错误保留为 foregroundRequired，四项操作 false、cleanup true，正常退出且 inbox 元数据不变。这确认了本次后台创建被系统拒绝，完整创建 / 更新 / 结束仍未通过。Apple 的 [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent)说明由系统执行 intent 的后台启动路线；该路线需要独立实现与真实系统执行验收，本轮未接入。

在已经授权启动本机原生活动的测试环境中，可对本次 Debug 产物启用 `--native-sdk-smoke`。先退出其他 TideIsland 实例，以 clean reviewed SHA 构建并完成本机签名，再从包内执行文件启动并保存 stdout / stderr。使用 ad hoc 时，为这次构建设置 `ENABLE_DEBUG_DYLIB=NO`，生成单体 Debug 代码；否则默认的预览动态库可能被 hardened runtime 的 Team ID 检查拒绝。该选项只作用本次测试构建，未修改项目默认值；含义见 [Apple 构建设置](https://developer.apple.com/documentation/xcode/build-settings-reference)。

```bash
xcodebuild -project TideIsland.xcodeproj -scheme TideIsland -configuration Debug \
  -derivedDataPath /absolute/path/NEW-derived-data ARCHS=arm64 \
  ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO \
  TIDE_ISLAND_SOURCE_REVISION=REVIEWED_FULL_40_CHARACTER_SHA build
```

将产物复制至本次测试目录，依 [签名顺序](packaging.md#签名方式)签署 helper、重建 Resources 清单、携带现有 sandbox entitlements 签署 extension，再签署 app，完成 deep / strict 验证；然后执行：

```bash
/absolute/path/TideIsland.app/Contents/MacOS/TideIsland --native-sdk-smoke
```

该参数仅在 Debug 读取。测试界面替代正常列表，普通菜单栏内容和设置不加载，SessionModel 延迟构造且此模式不访问它；不创建正常 inbox 接收器、读取或保存应用显示偏好、安装 Codex 配置、操作 Wave、申请通知或注册登录项。Release 不包含测试驱动，也不读取此开关。SwiftUI 自身的窗口状态由系统管理。

测试用随机的内存合成会话，经真实 NativeActivityController、共享投影及串行调度创建活动，将工作更新为待处理，再以终态结束；另建一次活动验证 shutdown 清理。范围始终 ownedOnly，不导入其他实例或应用遗留。仅此模式将自身 activation policy 设为 regular 并激活，以满足前台 SDK 条件；前台观察与授权失败分别给出固定原因。普通菜单栏及后台自动创建仍由真实集成验证。

各次提交等待真实调度工作完成，并读取 SDK 活动 ID、phase、计数与状态核对请求和同 ID 更新。观察等待使用单调时钟，单步最多五秒；这只是测试驱动的有界 SDK 查询，不会刷新来源时间。stdout 的单行 JSON 包含 source_revision、逐项结果、cleanup_verified 和固定问题码，不包含会话 ID、项目路径或原始 SDK 错误。测试正常结束及失败都会尝试清理自己创建的活动，标记测试结束后再请求退出；这个已清理的 Debug 分支同步返回 terminateNow，避免 AppKit 的嵌套退出循环再次等待被阻塞的 Swift 主 actor 任务。普通应用仍沿用正常异步退出清理。外部执行器需对 SDK 调用不返回设置超时，并把被强制终止的清理记为未知。

只有 JSON 的 status 为 passed 且五项验证均为 true 才表示这个前台合成生命周期已通过。visible_island_verified 和 real_session_integration_verified 持续为 false；扩展实际渲染、点击 / 触摸、真实 Codex 链路、背景创建、睡眠 / 重启和能耗仍分别执行 V004—V011。

本机开发态及 clean SHA `e9ce743386d38942cd2a97bf084d2bf11319637f` 重跑均确认：ad hoc 单体 Debug 能加载并正常退出，inbox 文件元数据未改变；当前自动启动未能在五秒内确认应用进入前台，报告 foreground-activation-timeout、cleanup_verified 为 true、四项 SDK 操作为 false，尚未请求活动。clean 报告 sdk-e9ce743386d3-a4120918/native-smoke-validation.json 保留实际 SDK status failed；验收只将这次前置条件报告与正常退出记为已观察，SDK 生命周期持续 blocked。没有确认前台不可用的系统原因，不能把这项门禁检查通过写成生命周期通过。

2026-11-18 最新 clean 修复 `e7d84c46b0f7788f7d343d9af0a3bcf6be10d1fd` 的前后台测试按顺序执行，均为单独签名的单体 Debug，未同时启动普通应用。前台报告 sdk-e7d84c46b0f7-9f48e0f9/native-smoke-validation.json 仍为上述前台超时且未请求；后台报告 sdk-e7d84c46b0f7-57feb647/native-smoke-validation.json 为实际 visibility / 7 拒绝及 delivery-foregroundRequired。两次均 cleanup true、退出 0、inbox 元数据不变。检查通过的范围是条件报告、错误分类、隔离和退出，SDK 生命周期仍未通过，恢复按钮的真实交互也未完成。

## 报告与验收

native-validation.json 只有在环境 / 版本门禁通过并开始编译后创建。它记录精确 revision、版本、系统 / SDK / Xcode、validation_channel、操作者互斥的正式 / prerelease 声明、架构和逐配置结果。失败保留已完成范围，native_compile_verified 仅在所有请求配置检查成功后为 true；both_configurations_verified 单独表明双配置完整性。

native_runtime_verified 始终为 false，signing_requested 为 false。归档元数据不能验证 loader / 正式 API 语义；编译 / CLI version 成功也不能填上系统岛、触摸、VoiceOver 或性能结果。将实际报告及其 commit 关联回 [统一验收清单](development-progress.md#6-macos-273-正式环境统一验收)，再继续 V003—V012。

`--check-request-only` 只核对来源，输出 scope: source-request-only，两个 native 标记均为 false。共享 CI 的 [入口检查](../scripts/check-native-entry.py)通过 Ruby 标准 YAML parser 核对手动 / 默认关闭 / runner / read-only 权限结构，并实际检查精确 SHA、无效 / 错误 SHA 和未确认时先阻止；另用 10 组隔离替身覆盖环境就绪、多项版本不足、许可、工具缺失、超时、未知版本 / build、超量输出、非 Mac 与其他工具错误，4 组独立声明检查覆盖 stable、prerelease、缺失与冲突，并验证环境被拒时仍保留渠道、未创建编译输出。CI 中这些检查不查询真实 SDK、不执行真实 xcodebuild，也不接受许可。

Xcode 27.3 的 Swift 6.4 会输出带 `in 0 suites` 的成功摘要。本机首次实际运行已执行 419 项，但旧计数检查未识别新格式；现由 CI 与本机共用 [摘要校验工具](../scripts/swift_test_summary.py)，用 9 组 fixture 保留零测试、未完整执行和失败摘要的拒绝条件，不放松实际数量守卫。该兼容修复本身不证明原生应用已编译。

首次真实 Debug 编译在 `NativeActivityController` 的 update / end 处因发送主 actor 隔离句柄失败，Release 尚未执行。已对照安装 SDK 的 ActivityKit swiftinterface：Activity 没有 Sendable 声明，并发方法需在调用域中持有句柄。修复通过非隔离辅助方法仅接收 Sendable 的 ID / 展示值、按 ID 重新取得句柄并复核状态；保留主 actor 的归属与监听、共享串行和取消规则，不降低 Swift 并发检查。SDK 的 pending 状态显式映射为共享 unknown。该改动继续以新的同源双配置编译报告及后续运行验收为准。

2026-11-18，修复提交 `72fa654b092492357579077171db9c6756f44256` 的 clean 源码在上述 beta 系统 / Xcode / SDK 上完成 arm64 Debug 和 Release。`native-72fa654b0924-3869e4f2/native-validation.json` 记录两项 build_completed、产物与包内 bridge 校验通过，渠道为 prerelease；signing_requested 和 native_runtime_verified 均为 false。同源本机实际执行 419 / 声明 419 项共享测试及 10 组 CLI 检查，[精确提交 CI](https://github.com/KevinLjb/tide-island/actions/runs/44152163319)同样实际 419 项和七项检查通过。完整日志与 xcresult 保留在本机验证证据目录；此后源变更需重新执行受影响检查。

最新 `e7d84c4` 已重新完成同源 arm64 Debug / Release（native-e7d84c46b0f7-863e7c22/native-validation.json）、实际 archive 与 ad hoc 三组件签名、两个 ZIP 及四份许可文本校验（release-e7d84c46b0f7-4068647a/Package）。本机 423 / 声明 423 项共享及 10 组 CLI、[精确提交 CI](https://github.com/KevinLjb/tide-island/actions/runs/44168068545)七项通过；已更新本机应用并观察 12 秒、扩展注册、稳定 bridge version 和正常退出通过，更新期间应用数据元数据不变。final-installed-result.json 记录安装范围；Developer ID / 公证、完整 SDK 生命周期、可见岛和真实接入均未由这些结果覆盖。
