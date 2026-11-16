# Codex 生命周期事件契约

本轮开发范围：进度任务 T001—T003。接入形态为观察型 command hook 与 legacy notify，不修改 Codex 的许可决定、提示上下文或控制流程。

## 核对基线

- 本机实际命令 `codex --version` 返回 `codex-cli 0.169.0`。
- [官方版本记录](https://learn.chatgpt.com/docs/changelog) 中 0.169.0 的发布日期为 2026-11-13。
- 输入字段及语义按官方 tag `rust-v0.169.0` 固定到 revision [`d32063f`](https://github.com/openai/codex/tree/d32063f96c2dff1dc96af839b3952abb6acfeda4)。不将 main 分支的新字段自动当作本机能力。
- 主要来源：[command hook 输入 schema](https://github.com/openai/codex/tree/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/schema/generated)、[legacy notify 序列化](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/legacy_notify.rs)、[Hooks 使用说明](https://learn.chatgpt.com/docs/hooks)。
- 通过本机 CLI 导出了 app-server schema，用于交叉核对类型和能力；本轮未连接 app-server 监听真实会话，也未启动模型请求。
- [合成 fixture](../Tests/TideIslandCoreTests/Fixtures/Codex/lifecycle.json) 包含 9 个自建输入，均按该 revision 对应的完整输入 schema 校验通过。它们是协议测试数据，不是真实用户会话的运行证据。

## 转换矩阵

| 来源 | 上游事件 | TideIsland kind / phase | 说明 |
| --- | --- | --- | --- |
| command hook | `UserPromptSubmit` | `turnStarted` / `working` | 用户提交一轮输入；保留 `turn_id`，忽略 prompt |
| command hook | `PreToolUse` | `toolStarted` / `working` | 保留工具名称与调用 ID，忽略工具参数 |
| command hook | `PermissionRequest` | `permissionRequested` / `needsInput` | 表示出现许可请求；不批准或拒绝，决定仍留给 Codex |
| command hook | `PostToolUse` | `toolFinished` / `working` | 工具已返回；非零退出码不能直接证明整轮失败 |
| command hook | `Interrupt` | `turnInterrupted` / `interrupted` | 用户中断当前轮次，不记成失败 |
| command hook | `SessionEnd` | `sessionEnded` / `ended` | 当前契约的 reason 为 `other`；会话结束，不等同任务成功 |
| legacy notify | `agent-turn-complete` | `turnCompleted` / `completed` | 本轮结束；读取 `thread-id`，可选读取 `turn-id` 以兼容旧 notify |
| command hook | `Stop` | 忽略，不产生事件 | 其他 Stop hook 可以要求继续执行；不能在此确认本轮最终结束 |
| command hook | `SessionStart` | 忽略，不产生事件 | `compact` 也会触发，不能把上下文恢复当成重新工作或空闲 |
| command hook | 带 `agent_id` 或 `agent_type` 的输入 | 忽略，不产生事件 | 标记的是子代理上下文，避免覆盖主会话；当前不做父子会话聚合 |
| command hook | 其他事件或未来未知事件 | 忽略，不产生事件 | 不从不明确的来源猜测状态 |

原始 `notify` 没有明确的父子代理身份字段；当前只按其 `thread-id` 保存，不推断父子关系。T006 使用 turn 身份及有界历史处理跨轮与乱序；没有 turn 的通知不能覆盖已经识别轮次的会话，具体边界见 [会话状态](session-state.md)。

### 尚未覆盖的自动状态

- 普通问答的确切等待状态：`request_user_input` 在不同模式下具有不同语义，异步询问工具可能立即返回。工具名本身不作为确认等待用户的依据。
- 整轮最终失败：`PostToolUse` 的失败结果只说明工具调用结果；不会通过正文关键词或单个退出码推断 `failed`。
- 运行中进程的真实存活与长期停滞：本轮不扫描进程或读取聊天历史，后续由会话管理与适配能力研究处理。

这些边界也由 `tide-island-bridge capabilities` 输出，不会将契约版本标记当作运行时自动探测结果。普通问答和最终失败的补充来源由进度任务 T031 跟踪。

## 事件协议 v2 与兼容

继续读取原有 v1 事件。新 CLI、hook 和 notify 输出 v2；不会把包含新状态的事件伪装为 v1。

| 范围 | v1 | v2 |
| --- | --- | --- |
| 顶层字段 | 原有 id / sessionID / projectName / phase / occurredAt / waveBlockID | 保留上述字段，新增必需的 `context`，可选 `waveLocation`（独立 schema v1） |
| phase | working / needsInput / completed / failed | 增加 interrupted / ended |
| 来源 | 未记录，保持未知 | context.source = manual / codexHook / codexNotify |
| 事件语义 | 未记录 | context.kind，且与 phase 校验一致性 |
| 轮次 / 工具 | 未记录 | 可选 turnID / toolName / toolUseID；需要这些身份的 hook 缺失时拒绝转换 |
| 时间 | occurredAt | 保留 occurredAt，新增 receivedAt / 可选 sourceOccurredAt |

0.169.0 的这些 hook / notify 输入没有源时间字段，因此本适配器保持 `sourceOccurredAt = nil`，使用 bridge 接收时间作为 `receivedAt` 与 `occurredAt`。不会把额外名为 timestamp 的字段直接提升为可信源时间，也不把接收时间当成上游执行时间。

Wave 位置只作为可选元数据由 allowlist / 显式参数采集，hook / notify 不查询 Wave 或保存凭据，字段、兼容和有效性见 [位置协议](wave-location.md)。

该版本兼容是“新读取器可读取旧记录”；旧 v1 读取器不能消费 v2，需要同步升级。状态机分开保存跟踪 turn 和当前观察 context，不向没有身份的旧事件补造来源；旧记录可以建立独立状态，不能猜测归属并替换已有明确轮次。

## CLI 与 Hook 输出约束

```bash
# 输出本桥接程序支持的契约和边界，不探测 / 更改用户配置
swift run tide-island-bridge capabilities

# command hook 从 stdin 接收一个 JSON 对象；输入示例须使用脱敏数据
tide-island-bridge hook --inbox /absolute/path/to/isolated-inbox < hook-input.json
```

- `emit` / `notify`：写入本地 inbox，向 stdout 输出标准化事件；参数错误返回非零。
- `hook`：从 stdin 有界读取，成功、忽略事件和可捕获错误均不向 stdout 输出事件或控制 JSON。
- `hook` 对可捕获的输入 / 写入错误返回 0，stderr 只输出固定诊断消息。它不返回许可决定、上下文或阻断退出码 2。
- hook 输入最大 1 MiB；标准化事件最大 16 KiB。大段 prompt / tool response 即使被接收也只存在于本次解析内存中，不写入事件、诊断或测试输出。
- 只保留项目目录末级名称、线程 / 轮次身份、状态、时间和必要工具 / Wave 定位元数据。不保存完整 cwd、模型名、transcript_path、prompt、工具输入输出或 assistant reply。

## 配置与验证边界

本机尚未安装或修改正在使用的 `~/.codex/hooks.json`、`~/.codex/config.toml` 或项目活动 `.codex/` 配置。T004 的独立 [hooks 配置管理](codex-hooks.md)只编辑显式 hooks.json，既有 notify 与内联 hooks 保持原样。T025 已加入 [notify 共存](notify-integration.md)和 [统一配置流程](installation.md)源码；启用后的 live 运行仍单独验收。

本轮验证覆盖固定版本协议 fixture、v1 / v2 兼容、转换含义、数据排除、CLI 的 stdin / stdout / 退出码及隔离 inbox。单测与 CLI 检查通过不表示用户当前 Codex 已启用这些 hooks，也不代表 27.3 原生扩展验证完成。
