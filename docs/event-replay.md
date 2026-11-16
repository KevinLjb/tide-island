# 确定性事件回放

T005 提供 `replay --file`：读取合成场景，通过实际 Codex 适配器、事件编解码和 `SessionRegistry`，逐步比较完整会话快照。回放固定事件 ID 和接收时间，在内存中运行，不写 inbox、配置、信任记录或原生 Activity。

## 运行

```bash
# 运行全部基线场景
swift run tide-island-bridge replay \
  --file Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json

# 单独检查权限等待与恢复
swift run tide-island-bridge replay \
  --file Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json \
  --scenario permission-wait-resume
```

输出为 JSON 元数据报告。`passed` 为 true 时返回 0；预期不匹配时先输出报告，再返回 1；文件或 fixture 定义无效时返回 1 且不输出报告。即使输入源按预期被拒绝，场景仍可通过，拒绝结果与错误码会保留在步骤中。

相同 fixture 的报告字节保持一致，包含固定 ID、时间、步骤顺序和状态快照；不包含生成时刻、随机报告 ID、运行耗时或输入文件绝对路径。Wave 环境变量和工作目录不会进入回放事件，Wave block 元数据须由 fixture 显式指定。

## 基线场景

合成数据统一位于 [Replay fixtures](../Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json)，现有 24 个场景、116 步。原始 Codex payload 基于 T001 的固定 0.169.0 契约；预期状态独立编写，不从程序输出生成。

| 场景 | 检查内容 |
| --- | --- |
| `normal-turn` | 开始、工具前后、本轮结束与 Wave 元数据 |
| `permission-wait-resume` | 权限请求进入待处理，工具返回恢复工作，notify 结束 |
| `interrupt-and-session-exit` | 中断与会话退出分别展示 |
| `tool-error-is-not-turn-failure` | 工具报错后仍为工作中，完成由 notify 提供 |
| `manual-failure` | 显式手动状态中的 failed；不代表自动 Codex 整轮失败检测 |
| `rejected-input-recovery` | 损坏 hook、缺少 turn、未知 notify、未知协议和 ID 不一致被拒绝后仍可继续 |
| `duplicate-and-late-v1` | 相邻重复与更早 v1 事件被现有 registry 丢弃 |
| `legacy-to-v2` | v1 与 v2 混合，旧事件的来源和 turn 保持未知 |
| `multi-session-attention` | 会话隔离、注意力排序和同项目的多个线程 |
| `ignored-and-question-tools` | Stop、压缩恢复、子代理、未知 hook 过滤；问答工具名不自动表示正在等待 |

T006 新增：迟到上一轮通知、旧轮工具 / 开始、未知轮次与无身份通知、新开始被旧活动时间阻挡、终态防回退、同时间戳、并行工具下的权限等待、非相邻 UUID 重复、手动新轮、退出恢复及忽略事件不推进当前时钟。`completion-before-delayed-next-turn-start` 与 `tools-before-delayed-next-turn-start` 检查下一轮观察先到、开始后到时的暂存绑定回放。轮次规则及窗口边界见 [会话状态](session-state.md)。

## fixture 格式 v1

新增 `Fixtures/Replay/wave-location.json` 的 3 场景 / 7 步位置基线，覆盖 hook → notify 清空、手动事件保留和退役观察不改址；原生命周期基线保持 24 场景 / 116 步。预期会话可以包含 `waveLocation`，定义仍拒绝未知字段；字段与边界见 [位置协议](wave-location.md)。

顶层包含 `schemaVersion: 1` 和非空 `scenarios` 数组，可选 `description`。每个场景包含唯一的 `name`、非空 `steps` 和可选说明。所有场景先完成定义校验，再选择 `--scenario` 指定的场景执行。

| 步骤字段 | 含义 |
| --- | --- |
| `id` | 必需的 UUID；hook / notify 转换后使用该 ID，支持重复事件回放 |
| `at` | 必需的 ISO 8601 接收时间，不读取系统时钟 |
| `source` | `hook` / `notify` / `event` |
| `payload` | 原始 JSON 值；与 `payloadJSON` 二选一 |
| `payloadJSON` | 原始 JSON 文本，可表达损坏输入等负向场景 |
| `waveBlockID` | hook / notify 的可选旧 Wave 元数据；event 来源保留 payload 中的值 |
| `waveLocation` | hook / notify 的可选版本化位置；event 来源只从 payload 读取，不采环境、不更新观察时间 |
| `expect` | 必需的 disposition、完整 sessions 数组；可选 errorCode / registryDecision |

`event` 来源按现有协议读取，payload 的 ID 必须与步骤 ID 相同；其 `occurredAt` 和 context 来自原始事件，不由步骤的接收时间替换。hook / notify 保留真实适配器结果，只替换接收端 UUID，然后经过与 inbox 相同的事件编解码边界。

步骤按数组中的到达顺序执行，不按时间排序。每个场景使用独立 registry；场景内逐步检查按实际注意力顺序排列的完整会话列表，包括 id、项目、phase、更新时间、最后事件 ID、跟踪的 turnID、原始 context 及 Wave 元数据。旧 v1 快照的 context 保持缺失；读取旧 fixture 时，可从 context 的 turnID 补齐跟踪身份。SessionEnd 等没有 turn 的原始 context 不会被改写。

结果 disposition 包含：

- `applied`：事件被 registry 接受。
- `filtered`：适配器明确忽略此输入，不产生事件。
- `discarded`：事件有效，但 registry 因当前状态规则未接受。
- `rejected`：输入解码或校验失败；固定错误码为 `invalid-hook-input`、`invalid-notify-input`、`invalid-agent-event` 或 `event-id-mismatch`。

报告仅包含标准化事件、实际与预期快照、registryDecision 及差异字段名（`disposition`、`errorCode`、`sessions`、可选的 `registryDecision`），不复制原始 payload、聊天正文或底层解码错误文本。fixture 定义的未知字段、重复键、缺少身份 / 时钟 / 预期、空场景和重复场景名会被拒绝。

资源限制：fixture 最大 1 MiB、最多 32 个场景、总计 256 步；一次回放累计实际快照中的会话条目最多 1024 个，编码后的报告最多 4 MiB。单个标准化事件继续遵守 16 KiB 上限。文件入口只接受普通文件，FIFO 不会作为输入读取。

## T006 的跨轮回归

```bash
swift run tide-island-bridge replay \
  --file Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json \
  --scenario late-previous-turn-notify
```

该回归保留 T005 的正确预期：新一轮开始后，接收时间更晚的上一轮完成 notify 应被丢弃，并保持当前轮工作状态。T006 已将原 pending 场景迁入通过集合；预期返回 0，最后一条通知的 registryDecision 为 `retired-turn`，前后当前轮快照保持一致。

原 pending 文件已移除，历史反例保留在 T005 的 Git 提交中。CLI 检查已移除“仍复现缺口”的失败断言，并单独确认这项回归通过；错误预期的负向测试继续检查回放的失败报告与退出码。

## 验证入口

```bash
swift test
swift build --product tide-island-bridge
python3 scripts/check-replay.py --temporary-root /absolute/path/to/test-temporaries
```

检查覆盖完整预期、重复运行字节一致、切换工作目录 / Wave 环境、场景选择、错误报告与退出码、无效定义、资源限制和配置哨兵文件保留。共享层与 CLI 通过不表示用户已安装真实 hooks，也不表示 macOS 27.3 原生验证完成。
