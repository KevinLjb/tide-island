# 会话元数据与偏好持久化

T011 将必要的会话状态、轮次保护和展示偏好保存为有界 checkpoint；重启仍须重新读取事件目录，保存的观察不会因加载而变新鲜。

## 保存范围

默认位置是 inbox 父目录的 `State/<inbox 路径摘要>.json`。scope 绑定标准化 inbox 路径；Events 本身删除或重建不删除 checkpoint。自定义 inbox 使用自己的父目录，可通过 CLI 的 `--state-directory` 显式选择状态目录。

当前写 schema v2、读取 v1 / v2，只保存类型明确的元数据：

- 当前展示观察：session ID、项目名称、phase、原事件 UUID / 时间、来源 context、可选 Wave block / 版本化位置与跟踪 turn。
- 既有 512 事件 UUID、64 退役 turn、256 工具状态、64 未绑定观察窗口，以及权限等待、FIFO 槽位与下一次淘汰位置。
- 当前已读 / 忽略事件身份、按会话置顶和全局选择。
- 当前合法事件文件名及内容摘要，作为已经导入的边界，避免重启重新回放旧文件扰乱窗口，也用于主动清除后的抑制。

位置字段与当前观察一起保存，缺字段不沿用旧目标，恢复不刷新位置时间；详情见 [Wave 位置元数据](wave-location.md)。v1 checkpoint 正常读取为无结构化位置，读取本身不改写文件，下次正常保存写 v2；v1 声称带新位置（包括 pending 观察）时拒绝，未来版本仍保留原文件。inspect 返回实际加载版本。

不保存聊天正文、工具输入输出、transcript、令牌、完整 cwd 或整个环境变量集合。checkpoint 不是聊天备份；CLI inspect 仅输出版本、数量与 revision，不输出 session ID、项目名或观察内容。

## 保存与恢复

`SessionCheckpointCodec` 使用明确 schema、大小 / 数量 / 身份验证，重建去重 Set 时校验有序窗口，不直接相信序列化的派生集合。Date 使用私有 checkpoint 的数值格式保留原观察精度，不修改对外事件协议。

`SessionStateFile` 在自有目录内持有描述符，拒绝最终目录 / 文件的符号链接、硬链接、非普通文件及非当前用户所有的文件。状态文件和协作锁为 0600，默认新状态目录为 0700。写入先同步同目录暂存文件，再原子 rename；协作锁独立于被替换的文件。revision 绑定文件身份、属性和摘要，旧写入不能覆盖另一份更新；相同内容不重复发布。

原生接入显式为共享 `InboxReceiver` 启用持久化，其他共享层调用者可省略配置使用内存模式。偏好操作在返回前尝试保存；连续事件最多合并约 300 ms，不不断推迟截止时间。事件文件自身已持久发布，进程在 checkpoint 窗口内退出时，下一次可从未导入的新文件恢复；偏好保存失败会明确提示，不承诺该操作已跨重启保存。stop 会尝试刷出待保存状态，但不能把异步退出处理当作系统终止前必然完成的保证。

启动先完整验证 checkpoint，再读取全部有界候选正文。游标正文缓存不跨进程复用，已导入摘要不代替磁盘检查；只有当前目录仍能确认同一观察、通道健康且时间新鲜，才进入实时计数。损坏、未知版本、scope 不符的数据保留原文件，暂停启动恢复，不静默当作空数据覆盖。没有旧 checkpoint 时正常从 inbox 建立状态。

## 清理与终态保护

应用清理前重新接收完整批次并成功保存、复核 checkpoint revision，再删除已批准历史；即使内存没有新改动，也要确认文件没有被外部替换 / 改坏。CLI `inbox cleanup --apply` 同样先保存观察到的终态和轮次，再执行指纹清理；它需要独立接收者锁，应用打开时应使用应用内清理。

磁盘事件已清理后，已保存的终态 / 退役窗口继续约束迟到事件，展示过期不清空这些保护。低层 `EventInbox.applyCleanup` 不会隐式写其他目录；自定义调用者须自行使用 `SessionStateFile` / receiver 的维护入口。升级前已经缺失且从未进入 checkpoint 的历史不能凭摘要还原，窗口外的因果与来源限制仍见 [会话状态](session-state.md)。

## 主动清除

应用的“清除会话与偏好…”先生成预览，再由确认框使用同一 fingerprint 应用。CLI：

```bash
# 都是只读，不为缺失路径创建目录 / 标记 / checkpoint
swift run tide-island-bridge state inspect --inbox /absolute/path/to/TideIsland/Events
swift run tide-island-bridge state clear --inbox /absolute/path/to/TideIsland/Events

# 核对 fingerprint 后，应用必须使用相同 inbox / 状态目录及扫描预算
swift run tide-island-bridge state clear --inbox /absolute/path/to/TideIsland/Events \
  --apply --expect FINGERPRINT
```

清除用一次原子发布同时写入空会话 / 偏好和当前导入边界。旧事件字节保持原样，但当前合法文件不在重启、目录重建或重复读取时重新生成已清除列表；新有效事件可重新显示会话，并使用默认偏好。移走后重新投递的文件、后来修复的损坏文件或尚未发布的暂存可被视为新输入，这不是永久屏蔽 session ID。

fingerprint 绑定 inbox / 标记身份、候选文件属性 / 摘要及状态 revision；预览后有新事件、偏好变化或外部状态更新时拒绝旧操作，不扩大清除范围。CLI 应用须获得接收者锁，避免打开的应用用旧内存状态重新写回。无法解析但安全且有界的旧 checkpoint 可以经明确的清除预览替换；不安全或超大文件仍须先由用户移走 / 归档后重试。清除会丢弃已保存的终态保护，事件磁盘删除仍使用独立的 [历史清理](inbox-maintenance.md)。

## 上限与失败

每份 checkpoint 最多 32 MiB、2,048 个会话状态 / 偏好及 65,536 个已导入文件摘要；每会话窗口仍遵守原有上限。超过限制不截断未结束会话、不覆盖上一份完整状态，当前内存操作可继续但标记尚未保存；可主动清除已有记录重新建立边界。原始 inbox 默认读取预算与上限仍独立生效，`--scan-limit` / `--read-budget-bytes` 的边界见 [inbox 维护](inbox-maintenance.md)。

保存失败不阻止已确认新事件的内存展示；启动恢复失败则暂停通道确认。历史删除必须等待保存成功。目录中的写入草稿不参与恢复；原子发布提供进程中断时完整旧 / 新文件，不是跨文件事务或断电一致性保证。其他不参与锁的工具不要并发改写同一目录。

## 验证边界

共享测试覆盖两次接收者启动、偏好 / 时间 / 来源确认、窗口与并行权限恢复、清理前保存、损坏及未来版本保留、scope / schema / 预算校验、冲突 / 锁 / 链接、主动清除与实际保存通知。`check-state.py` 仅在隔离目录验证 inspect、预览、指纹应用、源字节保留和错误码，和 inbox 检查一起纳入现有七项 CI。

新增 24 项及全部 143 项共享测试在标准 Intel runner 实际执行通过，七项检查成功，见 [严格 CI](https://github.com/KevinLjb/tide-island/actions/runs/43886424014)与[开发进度](development-progress.md)。原生保存配置、确认框、错误提示与生命周期尚未编译 / 运行，继续待 macOS 27.3 正式环境统一验证；未改真实 Codex 配置、启用 hooks 或清除用户数据。

T022 的 [最近元数据](session-metadata-history.md)只从当前会话已记住的 UUID / 当前锚点与确认缓存的交集取值；清除前保留但受导入边界抑制的文件不自动重新成为历史，重启不改变该边界。读取接口沿用 checkpoint v2。
