# Wave 位置元数据

T013 为当前会话观察附带可选的 Wave 位置记录，并单独投影其有效性；不执行 Wave 查询、认证或窗口跳转。公开命令边界见 [Wave 定位能力](wave-capabilities.md)。

## 事件与兼容

外层 `AgentEvent` 继续读取 v1 / v2，新 CLI 仍输出 v2；只在 v2 中允许可选的 `waveLocation`。位置对象使用独立的 `version: 1`：

| 字段 | 约束 |
| --- | --- |
| `blockID` | 必需的完整 UUID；不接受 this、简称、数字或 block: 前缀 |
| `tabID` | 可选 UUID，缺失不猜测当前标签 |
| `workspaceID` / `windowID` | 可选 UUID，只由掌握对应关系的来源填写；默认环境 / 参数采集不产生这两个字段 |
| `waveVersion` | 可选、最多 64 字节的版本字符串；当前只审阅精确版本 0.14.5，其他合法版本不会自动提升能力 |
| `observedAt` | 有限时间值；使用事件 ISO 8601 格式，checkpoint 内保留数值日期精度 |
| `source` | environment、explicitArguments、blockListing；描述采集来源，不证明认证或当前可见焦点 |

原 `waveBlockID` 保持兼容，旧记录中的 `block-1` 等不透明值仍可读取，不能作为结构化定位目标。两个字段同时存在时必须指向同一完整 block UUID。结构化对象已出现但损坏、未知 schema / source 或与旧字段冲突时，拒绝该事件。

新读取器兼容旧记录；旧程序可能忽略新增字段，桥接程序与应用应配套升级。checkpoint 改为写 v2、读 v1 / v2，避免旧程序把位置字段丢弃后重存。迁移与损坏保留规则见 [会话持久化](session-persistence.md)。

## 采集入口

`emit`、`hook`、`notify` 默认仅逐项读取 `WAVETERM_BLOCKID`、`WAVETERM_TABID`、`WAVETERM_VERSION`。不读取整个环境集合，不采集 JWT、AuthKey、socket claim、cwd、URL 或原始 meta。环境中的无效可选 tab / version 作为缺失处理；损坏的 block 值丢弃，不因此阻断生命周期事件。

```bash
# 位置参数可用于三个事件入口；这里只演示手动事件
swift run tide-island-bridge emit \
  --session demo --project tide-island --phase working \
  --wave-block 10000000-0000-0000-0000-000000000001 \
  --wave-tab 20000000-0000-0000-0000-000000000001 \
  --wave-version 0.14.5
```

任何显式位置参数都会选择独立的参数组，不继承环境中的 tab 或版本。新增 `--wave-tab` / `--wave-version` 要求同时给出完整的 `--wave-block` UUID。只有旧 `--wave-block` 时仍允许不透明字符串；只有完整 block 时生成部分位置记录。显式的新字段无效时返回通用错误，不回显输入；hook 仍保持 stdout 为空、观察错误退出 0。

桥接入口为位置、适配器和事件使用同一次时钟取值。重新读取事件或恢复 checkpoint 不刷新 `observedAt`。没有自动安装 hook、relay 或修改 Codex 配置。

## 有界列表解析

`WaveBlockListing` 是供未来合法查询调用者使用的纯解析器，当前 CLI 不会启动 wsh。调用者提供 stdout / stderr、退出码、完整目标 block、已知查询范围、版本和观察时间。

- 只接受已审阅的 Wave 0.14.5、退出 0、严格为空的 stderr 和 JSON 数组；警告、文本空结果、空数组、无目标或不完整行都表示无法确认，不表示目标已关闭。
- stdout 最多 1 MiB / 4,096 行；复用严格 JSON 解析，拒绝重复键、重复 block、无效 ID 类型、同 tab 不同 workspace 和与已知查询范围冲突的行。先验证整个结果，再返回唯一目标。
- 只提取 block / tab / workspace ID，丢弃 meta、view、cwd、URL 及未知字段。0.14.5 CLI 不提供已核实的 windowid，解析器即使看见该字段也不采集。
- 原始双流只在调用内存中处理，不写事件、checkpoint 或诊断。解析成功仍不证明调用者已认证、目标存活或窗口可见。

## 当前观察与失效

`AgentSession.waveLocation` 只属于当前已应用的观察。重复、过旧、退役轮次或尚未绑定的事件不能替换位置；尚未绑定观察后来按既有状态机正式应用时，位置与该观察一起生效。新应用的事件缺少位置时清为空，不沿用旧目标。不另建无限历史映射表。

`SessionStatus.waveLocation` 使用独立的 5 分钟期限：

| validity | 含义 |
| --- | --- |
| unknown | 没有位置元数据 |
| legacyOnly | 只有旧 block 字符串，无法确认结构化位置 |
| partial | 近期记录缺 tab 或版本 |
| recent | 近期、block / tab 完整且版本为已审阅的 0.14.5；不表示可以跳转 |
| stale | 到达 observedAt + 300s，恰好到期也视为过期 |
| clockSkew | 观察时间晚于当前时钟或当前时钟无效，等待新输入 / 唤醒复核 |
| unreviewedWaveVersion | 近期记录的版本合法但不在已审阅范围 |
| unconfirmedSource | 通道异常，或当前目录无法确认同一完整事件观察 |

缺失字段和未知版本的结构化记录也会到期。有效性不改变原 phase、注意力、工作 / 待处理计数或 Activity 选择；这些仍遵循生命周期与来源规则。位置截止时间合入现有一次性投影任务，到期会推送新帧，不依赖下一个文件事件，也不轮询 Wave。

## 验证与后续

合成测试覆盖事件兼容、隐私 allowlist、参数隔离、来源复核、独立期限、实际帧通知、列表异常、checkpoint v1 → v2 及确定性回放。新增 [位置回放 fixture](../Tests/TideIslandCoreTests/Fixtures/Replay/wave-location.json) 包含 3 个场景 / 7 步，保留原 24 场景 / 116 步生命周期基线。

具体执行结果以 [开发进度](development-progress.md) 为准。T014 继续设计能力选择与结果，T015 完善应用级返回。真实 Wave 查询 / 跳转、多窗口、原生编译与交互均未验证，继续待 macOS 27.3 正式环境。
