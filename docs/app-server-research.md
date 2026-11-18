# app-server 补充来源研究

T031 研究结论：公开 app-server v2 提供结构化阻塞提问与最终轮次状态，但不能直接当成现有 Wave + Codex 会话的无干扰旁观接口。当前继续使用 hooks / notify，**不启用独立 app-server 适配器**；普通聊天提问等待与整轮失败的自动检测能力保持未实现。

## 研究范围与证据

核对日期：2026-11-17。固定现有契约的 Codex revision `d32063f96c2dff1dc96af839b3952abb6acfeda4`，不使用浮动 main。公开下载文件与该 Git tree 的 blob SHA-1 按 Git blob 编码逐一核对；只读源码 / schema，没有运行 daemon、app-server、模型、thread start / resume、真实会话查询或用户日志采集。

| 编号 | 固定来源 | 核对内容 / Git blob |
| --- | --- | --- |
| S01 | [protocol/common.rs](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/src/protocol/common.rs#L1906) | `item/tool/requestUserInput` 为有响应类型的 server request；turn / resolved 方法；`52ed76c60687defce3f3405148ff15b44769d433` |
| S02 | [v2/item.rs](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L1905) | thread / turn / item 身份、questions、`isBlocking` 与弃用的 timer；`c4cdf60e77e94c21ee6e12d40b8f6d02c5e5a283` |
| S03 | [Turn](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/Turn.ts)、[TurnStatus](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/TurnStatus.ts)、[完成通知](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/TurnCompletedNotification.ts) | 最终状态及 thread / turn；blob 分别 `ce309330d5ec8aa62597c470cabc786fce64304f` / `476922edc203cb00e94119507bd7036de5baef7a` / `e1b151bfa7157b8549899c0fed12f358fcdf837b` |
| S04 | [事件转换实现](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server/src/bespoke_event_handling.rs#L848) | 提问与 pending guard；完成时根据 summary 发 terminal status；`485f8e144532ffcb67f89b48aeaaf8a7388f7b58` |
| S05 | [请求回放实现](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server/src/outgoing_message.rs#L525)、[resume 后回放](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server/src/request_processors/thread_lifecycle.rs#L1283) | 订阅 / 重连会收到 pending server requests；blob `e1a0151eac03c1ec1dae7747ef958a80e464cfcf` / `b9062d6e7a9d15ec5f79a7858993051bb7509e7a` |
| S06 | [in-process client](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-client/README.md)、[daemon](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-daemon/README.md) | CLI 可用进程内 typed channels，也有实验性共享 daemon / 远程路径；blob `c5c0d827ba32f0fde164eb619086461acd975b1e` / `c0877c5ba8a2e7f991246e4827e3c660f694243b` |
| S07 | [Thread](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/Thread.ts)、[resume params](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/ThreadResumeParams.ts) | thread ID、session tree / parent 与 rejoin / cold resume；blob `9a0f865d7b42a489063b07324d6f5c6b0c4a29c3` / `4da03970e9f2f0d7b5e796c4dd0ea96fda69a95e` |

上游源码审阅只证明该 revision 的定义 / 实现，未编译或执行上游测试，不代表本机当前会话采用哪一种 transport。

## 提问与真正阻塞

`item/tool/requestUserInput` 带 JSON-RPC request ID，params 含 `threadId`、`turnId`、`itemId` 和 `isBlocking`。这是需要客户端响应的请求，不是普通被动日志。questions 中还有正文、选项与 secret 标记，不能整体存到 TideIsland 事件、checkpoint、诊断或 fixture。

未来仅在已确认当前连接 / 原 thread / turn、有未解决请求且 `isBlocking=true` 时，才能作为“正在等待输入”的候选。`isBlocking=false` 只能说明请求输入，不表示 agent 已停止工作；`autoResolutionMs` 已弃用，不能从是否有超时或工具名猜测阻塞。上游 Rust 对旧反序列化有默认值，这是上游兼容逻辑，不自动成为我们的缺字段兼容承诺。

另一个反例是 `thread/status/changed` 的 `waitingOnUserInput`：S04 在接到提问时增加 pending guard，没有按 `isBlocking` 分支；因此这个 flag 本身不足以证明整轮停止。线程级 flag 也没有 turn / item 身份，不能直接替换当前会话观察。

待回答生命周期需用 [serverRequest/resolved](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/ServerRequestResolvedNotification.ts)的 thread / request ID、原请求索引、轮次结束 / 中断及连接代次共同确认；多个 pending 不能因其中一个解决就全部清掉。重连回放仍是同一请求，不能制造新的提醒周期。断线、漏消息或只有历史条目时降为未知，不自行回答、取消或发送空结果。

纯自然语言的“你希望选择哪一个？”若只是普通 agent message，并没有上述结构化 pending 请求，仍不能靠正文准确识别等待；本研究不承诺覆盖所有问句。

## 整轮最终失败

`turn/completed` 是结束通知名称，必须检查 `turn.status`；可能为 completed、failed、interrupted，不能只看方法名就当 completed。候选终态绑定 `threadId + turn.id`，与当前来源身份和轮次一致后才可应用；inProgress / 未知状态不能当最终结果。

[ErrorNotification](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/app-server-protocol/schema/typescript/v2/ErrorNotification.ts)含 `willRetry`。可重试错误不是失败终态；即使 `willRetry=false` 也不应抢先代替最终 `turn/completed` 状态。工具 exit code、Stop、进程消失或断流同样不能替代终态。S04 会汇总错误并发出最终状态，支持从终态枚举取元数据的研究方向；错误 message / additionalDetails / items / 最后消息均不需要进入我们的数据。

## 身份与非干扰接入成本

app-server 的 thread ID、同 session tree 的 sessionId、parentThreadId，以及 hooks / notify 已保存的 session 身份不能未经确认直接互换。未来需明确 root thread 与现有来源的关联、排除子代理、复核 turn、连接 / 服务实例代次和重连去重；当前没有读取用户会话来验证这份关联。

| 方案 | 可行性与成本判断 |
| --- | --- |
| 新启动独立 app-server | 能创建自己管理的会话，不能据此观察另一个进程的现有 in-process 会话；会改变用户启动方式及会话管理，不纳入首版 |
| 连接已有共享 daemon 并 resume | S06 存在该路径，不能断言“Codex 一定没有可连端点”；但端点、配置 / 环境、权限和版本需由现有宿主明确提供。resume 在已运行 thread 中 rejoin，在未运行时可以加载 / 恢复；S05 又会重放有响应能力的请求，尚无本轮验证的只观察角色 |
| 现有宿主转发必要元数据 | 优先的后续方向：宿主在自己的事件流中过滤 source / root / turn / blocking / terminal 枚举，再向现有 bridge 发状态；需要明确支持接口、身份与生命周期，不读原始 stdio、不扫描认证或原文日志 |

`thread/read` 有 metadata-only 选项，但读存储状态不等于订阅实时 pending；轮询历史不能证明此刻阻塞。`thread/resume` 的 `excludeTurns` 只减少历史返回，不把带副作用的 resume 变成无干扰观察。仅“不发送答复”也不足以证明新连接不会改变请求路由、回放或生命周期；需在合成隔离宿主中证明。

现有 TideIsland v2 的 source / kind 也未包含 app-server 提问 / 解决 / 最终失败语义。后续若接入，须设计独立来源与等待身份、兼容 / 协议升级、与 hooks / notify 的权威和重复规则、持久化及清除边界，不能把提问伪装成 PermissionRequest 或把失败伪装成完成 notify。

## 结论与后续条件

会话来源研究完成。后续若有明确授权的会话事件来源，先在隔离环境验证其对原宿主交互和恢复的影响，再考虑独立适配器。[Codex 额度读取](preferences.md#codex-额度)使用独立的只读账号接口。会话来源适配至少需要验证以下场景。

- 同 / 不同 root thread 与 turn、子代理排除、多个 pending 和部分解决；
- blocking / nonblocking、纯自然语言问题、旧 timer / 缺字段 / 未知事件；
- 可重试错误后成功、最终 failed / interrupted、迟到旧终态；
- 重连回放 / 漏消息 / 断流、身份改变、清除后抑制及数据预算；
- 忽略 questions / answers / error / history 正文，以及原宿主仍独占真实交互决定。

这些是未来实现条件，不是本轮执行过的测试。首版保留 [现有事件契约](codex-events.md)与 [兼容清单](compatibility.md)，主线继续等待 [27.3 统一验收](development-progress.md#6-macos-273-正式环境统一验收)。
