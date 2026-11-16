# 实时活动展示与客户端边界

T016 将 Activity 展示数据、时间检查和基本自有活动控制移到共享层，以测试替身验证；ActivityKit 只留在原生适配中，真实 SDK、授权和系统显示仍待 macOS 27.3 统一验收。

## 共享展示数据

`IslandActivityContent` 延续原有六字段 wire shape：sessionID、projectName、phase、workingCount、waitingCount、updatedAt。`TideIslandAttributes.ContentState` 直接别名到该共享类型，应用与扩展继续使用同一份声明，不新建第二套字段。

展示只包含必要状态，不包含事件 context、工具名 / 正文、Wave 位置、认证、完整路径或原始环境。ID / 项目名沿用事件协议的 UTF-8 和控制字符约束，允许合法中文及特殊字符，不通过截断改变会话身份。内容解码也校验 phase、非负计数、总数溢出、选中 phase 的计数和字段约束。

`IslandActivityPresentation` 在 state 外保留 staleAt 和自身会话链接；这个截止时间没有加入旧 ContentState 字段。原观察 updatedAt 不因投影、偏好或 SDK 请求变成当前时钟。

## 时间与聚合

`IslandActivityPresentationPolicy` 以显式 now 检查 `SessionSnapshot`：

- 候选仍沿用 [注意力规则](session-attention.md)：新鲜待处理优先，再选当前选择 / 置顶的新鲜工作。没有参与活动的会话则返回空展示。
- 通道或原观察不确认、已忽略、本轮空闲 / 退出及过期状态不进入实时计数，规则与 [会话投影](session-status.md) 一致。
- staleAt 取全部参与计数会话的最早 freshUntil，而不是仅选中会话的期限。
- 缓存快照若已有任一参与者到期，整份旧聚合不再发送；应向接收器获取新的完整快照，不能保留包含旧会话的总数。未来观察 / 时钟回退也保守停止旧展示，非法 now 返回固定错误。

共享 JSON 编码使用 **3 KiB 开发预算**，帮助限制后续字段增长；这是本项目的临时开发约束，不是已核实的 macOS 27.3 SDK 传输上限。T017 / V001 必须按正式 SDK 核对实际序列化口径和限制，不能把该预算或共享测试视作原生 payload 已验收。

## 客户端与基本控制

`IslandActivityClient` 只暴露授权查询、request、update、end。活动 ID 是由客户端返回的不透明、自有标识，不作为路径、进程身份或会话证明；SDK 对象不进入共享层。

`IslandActivityController` 当前执行基本的单活动流程：

1. 空展示不查询授权；有自有活动时尝试立即结束。
2. 非空展示查询授权，返回后检查取消和原截止时间，再决定是否发送。
3. 尚无自有 ID 时 request，已有 ID 时 update；不在 update 失败后创建重复活动。
4. request 成功返回合法 ID 后，先记录所有权，再检查取消，避免调用者取消时遗忘刚创建的活动。无法取得返回 ID 的不确定请求仍需后续系统列表协调，不能声称已自动清理。
5. end 成功才清空 ID；失败保留原所有权，供下一次明确操作重试。已发送后取消不会声称撤销成功。
6. request / update / end 的未知客户端异常分别转为固定错误，不输出原异常。并发调用当前返回 busy，不重叠执行 SDK 操作；原生调用方已有串行合并，T017 将把完整去重 / 节流 / 合并移入共享层。

授权在查询后仍可能变化；T018 将处理授权变化、系统已结束活动、重启 / 遗留活动关联及退出清理。当前禁用错误不表示所有系统活动已被清理，也不提供跨进程事务或崩溃清理保证。

## 原生适配源码

`NativeActivityController` 委托共享控制器；`NativeActivityKitClient` 在主 actor 使用公开 ActivityAuthorizationInfo、Activity.request、update、end，并仅保留本次请求得到的 SDK 对象。ContentState 与 staleDate 直接取共享投影，不在适配层重新计算计数或刷新时间。

没有新增 Native 文件，两个 target 的共享声明和本地 package 依赖保持现有结构。原生类型别名、客户端隔离、授权、系统生命周期和显示效果均未编译 / 运行；工程结构检查只确认文件和 target，不代替这些验收。

## 验证与后续

新增 17 项共享测试覆盖优先级及最早截止、来源 / 忽略 / 空闲过滤、旧聚合和时钟、六字段兼容与隐私、非法数据解码、合法 Unicode、客户端基本流程、失败保留所有权、授权等待过期、取消以及并发排斥。具体执行证据见 [开发进度](development-progress.md)。

CLI 的 `island_activity` 能力说明明确区分共享预算与未验证的正式 SDK；CLI 不调用原生活动。下一步 T017 完善共享层合并 / 去重 / 串行更新，T018 完整处理系统活动生命周期，T019 完善视图与交互。
