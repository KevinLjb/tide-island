# 实时活动生命周期与恢复

T018 在共享控制器中协调公开活动清单、授权、用户关闭及退出；原生适配使用公开 ActivityKit 监听信号，再向接收器重新取得来源确认。共享替身验证与 macOS 27.3 原生验收分别记录。

## 清单与所有权

`IslandActivityClient.activities(scope:)` 返回可由当前实例管理的完整清单；nil 表示客户端没有清单能力，空数组才表示该范围确实为空。共享层只处理不透明 ID、六字段状态、staleAt 和 active / stale / ended / dismissed 状态，不保存 SDK 对象、聊天内容或认证信息。

- ownedOnly 仅包含当前进程创建或已接管的句柄。
- application 允许接管应用遗留活动，调用者必须具有当前主接收器的权威。原生只在 inbox 帧健康时提交该范围，并在 SDK 读取时通过 NSWorkspace 排除另一个仍运行的同 bundle 实例；bundle 身份不可用时不导入。
- 新实例接收器占用 / 不健康时只使用 ownedOnly，不能因为自己的空快照结束主实例的系统活动。已接管句柄在来源中断后仍可清理。

清单最多 64 条，ID 有界、非空白、无控制字符且唯一；内容沿用共享校验，截止时间必须有限。重复、超限、非法或未知未来状态使整份协调失败，保留系统活动，不截断前缀后删除其他记录。适配器仅导入 `TideIslandAttributes.name == TideIsland` 的记录，不改其他属性类型或名称的活动。

SDK 列表、进程观察和 inbox 锁并非同一个系统事务。上述规则是协作实例的防误接管边界，不能声称已经证明跨进程原子接管或原生多实例行为；相关实测仍由 V002 / V008 完成。

## 接管、更新与结束

1. 每次实际交付先读取并校验清单。仍存活的自有主 ID 优先保留；否则优先选择当前目标会话的活动，再按 ID 排序确定唯一主活动。只复用句柄，展示始终重新取当前确认的 SessionSnapshot，不信任旧 SDK 状态作为事件来源。
2. 结束其他 active / stale 重复活动后再更新主活动；没有活动才 request。重复清理失败时保留失败句柄，尝试其他待清理 ID，然后报告固定 endFailed；本次不再 request / update 掩盖失败。
3. ended / 清单中已消失的句柄释放所有权；新的明确输入可以创建替代。update 失败不直接新建；request 响应丢失时，后续完整清单可以找到实际已创建活动。
4. 空展示 / 到期 / 失去来源时清理当前范围，不查询授权。非空且授权关闭时先尝试结束所有管理中的活动，再报告 disabled。清理失败保留固定错误和可重试状态。
5. 清单、授权和重复清理的 await 后重新检查原期限；不因恢复或 SDK 更新刷新 updatedAt，不发送包含过期计数的旧聚合。

不支持清单的客户端继续保留 T016 的本进程 ID 行为；它不能声称能恢复丢失响应或重启遗留记录。未知客户端错误只转为固定 inventoryFailed / requestFailed / updateFailed / endFailed，错误正文不会进入 UI 或响应流。

## 系统关闭与授权变化

公开 activityEnablementUpdates、activityUpdates 和每个已管理活动的 activityStateUpdates 仅触发重新协调。原生先重读 inbox，使用重新确认的帧和源端序号提交 `forceReconciliation`，不直接拿唤醒前缓存当成当前来源。监听使用可取消任务，没有固定轮询。

强制标志与 scope 绑定同一有序输入：迟到序号不能改变权威；pending 被更晚普通快照替换时保留强制协调。强制协调绕过去重及普通限频，已发出 SDK 操作仍先完成，随后串行处理最新输入。

检测到当前活动 dismissed，或发现与当前展示内容相同的 dismissed 遗留记录时，在进程内记住原状态，结束其他重复活动，按 sessionID、phase、计数和原观察时间抑制相同观察的立即重建，忽略显示名差异。临时空来源、清单移除记录后仍保留该抑制。新的观察 / 聚合状态（包含原观察时间）可恢复活动，T021 的显示名切换不重建刚关闭的相同观察，不修改会话忽略 / 已读偏好。

此关闭记忆只在内存，不冒充永久关闭策略；系统重启后的 dismissed 保留范围取决于 SDK 清单。完整 [提醒策略](session-reminders.md)与 [持久化偏好](preferences.md)分别由 T020 / T021 提供。授权恢复或系统 ended 后的重建仍须有新鲜、确认的来源。

## 正常退出

共享 scheduler 的 shutdown 立即拒绝新提交、丢弃 pending、取消限频等待，等待已经分派的操作返回，再以新的未取消任务结束自有活动。即使退出调用者取消，也不能遗忘刚成功创建的 ID。失败清理保留所有权，可显式再次 shutdown；停止后永不重新创建。

原生应用通过 NSApplicationDelegate 的 terminateLater 走同一清理路径，先停止监听和 UI 操作，清理完成后才停止接收器、释放 lease。正常退出最多等 5 秒；SDK 不响应、强制退出或崩溃时不保证清理完成，下一主实例从公开清单恢复。超时是尽力退出上限，不是完成清理的证明。

## 验证边界

新增 24 项共享测试覆盖确定性接管、重复清理及失败、scope、禁用 / 重新授权、系统结束 / 丢失、用户关闭 / 新观察恢复、非法 / 未来清单保留、请求响应丢失、await 期间到期、强制刷新合并、迟到权威拒绝、限频打断、进行中退出、取消和失败后清理重试。

两项既有接收器到期测试使用受控逻辑时钟，在启动后推进期限，继续等待真实一次性计时器的流通知，隔离并行 CI 启动耗时与事件新鲜度；不通过轮询 getter 制造到期帧。[开发进度](development-progress.md)记录实际共享 CI。T018 当时的六个原生 Swift 文件仅做工程成员检查，ActivityKit 清单 / 监听、隔离、系统关闭语义、5 秒退出窗口和多实例行为尚未编译或运行，继续待 27.3 正式环境。公开接口参考：[activities](https://developer.apple.com/documentation/activitykit/activity/activities)、[ActivityState](https://developer.apple.com/documentation/activitykit/activitystate)、[状态监听](https://developer.apple.com/documentation/activitykit/activity/activitystateupdates)、[授权监听](https://developer.apple.com/documentation/activitykit/activityauthorizationinfo/activityenablementupdates)。本轮成功读取的 Apple 元数据仅确认 activities / content / ActivityState 的 macOS 27.3 beta 标记；监听文档未成功读取，不将其源码接入视作正式 SDK 可用性证明。
