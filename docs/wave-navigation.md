# Wave 定位路线与结果

T014 提供共享路线策略与可注入的请求编排器，先验证当前观察、运行时上下文和完整目标，再请求同标签布局聚焦。当前未安装真实 driver，应用继续使用既有 Wave 应用级返回，精确可见定位仍待真实环境确认。

## 能力边界

已审阅的 Wave 0.14.5 `focusblock` 只操作指定标签布局，不切换标签或 OS 窗口。完整 `block:<UUID>` 免去简称解析，仍须使用 Wave 已认证上下文；修改 TABID 不会让后台标签显示出来。版本与固定源码证据见 [能力矩阵](wave-capabilities.md)，记录字段见 [位置协议](wave-location.md)。

共享模块不包含凭据、认证发现、wsh 子进程或 relay 安装，不修改真实 hooks、Wave 焦点或 Codex 配置。`WaveNavigationContext` 不可序列化，仅由受信 driver 在完成服务端认证后提供；环境里的 TABID / JWT 是否存在不能充当这个证据。`connectionID` 是 driver 的临时连接代次标识，不是令牌，也不独立证明存活。

## 路线选择

`WaveNavigationPolicy.plan` 接收用户看到的 `SessionReference`、当前快照、可选运行时上下文和显式时钟：

| 条件 | 决策 |
| --- | --- |
| 行缺失、事件 ID 已更新、忽略或展示过期 | rejected / staleSelection；不替用户打开其他目标 |
| 通道或完整观察未确认 | applicationFallback / sourceUnconfirmed |
| 无位置、只有旧 block、字段不全 | applicationFallback / locationMissing、legacyLocation、partialLocation |
| 位置过期、未来时钟或未审阅版本 | applicationFallback / locationExpired、clockSkew、unreviewedVersion |
| 没有已认证运行时上下文 | applicationFallback / contextUnavailable |
| 运行时版本未审阅、上下文到期或 tab 不同 | applicationFallback；不改写 TABID、不尝试跨标签 / 窗口 |
| 位置及同标签上下文完整且近期 | verifyTarget；仍须完成目标查询，尚未发送聚焦 |

每次按动作时钟重新判断原位置，不信任缓存快照中较早的“近期有效”。工作或空闲 phase 不决定定位权限；例如近期的本轮结束记录也可成为查看终端的候选，不因此宣称进程仍存活。

## 请求前复核

`WaveNavigationCoordinator` 接收一个可选 `WaveNavigationDriver`、异步最新快照闭包和时钟。无 driver 时直接返回需要应用级返回的结果。一个协调器同时只接受一个请求，后续并发点击返回 busy，不排队延迟抢焦点。

1. 核对点击的当前观察与位置；元数据不满足时不调用 driver。
2. 获取已认证的上下文，重新获取快照，核对同一事件与 tab。
3. 在该连接上查询完整、唯一的目标。driver 使用 [严格列表解析器](wave-location.md#有界列表解析)提取 ID；警告、非 JSON、重复目标或没有匹配结果都保持未知，不能解释为已确认关闭。
4. 查询结束后再次获取上下文与最新快照，核对同一连接代次、tab、版本、观察和动作时间。
5. 目标必须来自完整列表，block / tab 与请求一致，workspace 必须已知；记录中已有的 workspace / window 也必须一致。0.14.5 列表不能证实 window 字段时，含 window 约束的请求保守回退。
6. 运行时上下文和查询证据都必须在各自观察后的 10 秒内，未来时钟及恰好到期均拒绝。它们不延长位置原有的 5 分钟期限。
7. 唯一候选通过后，调用 driver 的 focus。参数固定为数组 `focusblock -b block:<完整 UUID>`，RPC 预算为 2 秒，不拼接 shell 命令。

driver 是执行边界：必须固定已核实的 helper / 版本，在实际发出命令前原子核对连接代次及原 tab，拒绝变化或过期上下文；落实 IO 总预算、RPC 预算和任务取消。共享协调器处理 driver 回报的超时，不自行强杀一个不遵守契约的实现。当前只有测试替身，没有把可伪造的 JSON / 环境字段自动接为 driver。

所有发出前的异步边界完成后都会复核；发出后发生的会话、窗口变化及取消不能撤销已经送达的命令。完整 UUID 防止改选其他 block，但公开接口不能提供与会话更新、用户标签操作之间的跨进程事务保证；真实 driver 和竞态仍须单独验收。

## 结果语义

`WaveNavigationResult` 绑定原 `SessionReference`，不修改 session、位置记录或注意力偏好：

| 字段 / outcome | 说明 |
| --- | --- |
| attemptedRoute = none | 没有调用聚焦执行边界 |
| attemptedRoute = tabLayoutFocus | 已调用同标签聚焦执行边界；即使超时或抛错也保留实际尝试 |
| applicationFallbackRequired | 建议下一步应用级返回；fallbackRoute = application，不声称已打开 Wave |
| focusAcknowledged | driver 报告聚焦请求获得响应；不声称正确窗口 / 标签已在前台可见 |
| rejected | 原观察已失效；不自动改选新观察或发起应用级返回 |
| busy | 当前协调器已有请求；不排队或触发回退 |
| cancelled | 停止继续动作；发出后取消仍记录 attemptedRoute，不声称撤销成功 |

缺少 / 冲突 / 到期的目标，以及 focusRejected、focusTimedOut、driverUnavailable、driverFailure 都返回明确原因。丢失响应可能已经产生效果，不盲目重试聚焦，也不改用第一个、当前或名字相似的分屏。任意 driver 错误转为固定错误码，原始异常、stdout / stderr 和凭据不进入结果。

T014 不产生“已验证可见定位”结果，因为当前没有经核实的公开可见焦点证据。T015 已接入 [应用级返回和反馈](wave-return.md)，打开前复核原观察，并保留实际尝试路线；未来真正接入 focus driver 时，调用方仍须核对结果绑定的请求，避免旧请求完成后覆盖新行提示。

## 验证与后续

22 项新增共享测试使用合成位置、受信 driver 替身和明确时钟，覆盖路线拒绝、精确目标 / 列表、双重上下文复核、查询期间会话 / 通道变化、独立期限、实际尝试路线、失败脱敏、并发、取消及 gate 释放。既有生命周期和位置回放保持兼容。

本轮未执行真实 Wave 列表或聚焦；应用 / 扩展也未编译、签名或运行。共享 Swift / CLI 结果见 [开发进度](development-progress.md)，真实 driver、同标签效果、跨窗口返回及系统岛交互继续按 V005 留待 macOS 27.3 正式环境验证。`capabilities.wave_navigation` 明确声明共享范围、默认回退、没有生产 driver，以及不能确认可见定位。
