# 诊断与回放

T028 提供按需生成的必要元数据报告，诊断不采集聊天、会话身份、项目名、路径、位置 ID、工具名、原始错误或环境变量，不自动上传或保留诊断历史。

## CLI 诊断

使用已构建的 `tide-island-bridge`：

```bash
tide-island-bridge diagnostics
tide-island-bridge diagnostics --inbox /absolute/path/to/Events
tide-island-bridge diagnostics --inbox /absolute/path/to/Events \
  --output /absolute/path/to/diagnostics/tide-report.json
```

默认 `versionsOnly` 不读取 inbox / checkpoint，也不查询已安装的 Codex / Wave。版本字段区分 TideIsland 自身版本、可读事件版本、当前输出版本、固定 Codex 契约和已审阅 Wave 版本；它们不证明本机集成版本或实际运行成功。

只有显式 `--inbox` 才读取指定目录。`offlineInventory` 用完整有界扫描统计有效事件文件、来源、原观察时间范围、拒绝与不安全文件数量；不重建会话、不读 checkpoint、不恢复中断操作、不获得接收者 lease、不运行 Wave / wsh。扫描沿用现有普通文件、链接、身份、锁及总预算检查；预览锁使用已有 marker，不创建文件。历史可以包含清除后被抑制的事件，**文件数量不是当前会话或实时计数**。

扫描失败仍输出结构化报告，`inventory.state=unavailable` 和固定 `problem` 说明原因，计数缺省，避免把部分结果当完整清单。报告生成成功返回 0；无效参数、编码或导出失败返回非零，错误不回显路径或原始内容。可用 `--scan-limit`（1–65,536）和 `--read-budget-bytes`（1–256 MiB）显式调整扫描预算，默认分别为 16,384 和 64 MiB；完整报告最多 16 KiB。

`--output` 要求新文件和已存在的父目录，以 0600 权限创建，不覆盖文件 / 链接。目标须在应用数据根目录、显式 inbox 及其默认 State 目录之外。stdout 只返回固定导出回执；不指定输出时报告写 stdout，由调用方决定是否保存。人工分享前仍可查看汇总数量、时间和版本是否合适。

## 应用诊断

共享投影已准备，原生管理菜单接入由 T028 后续提交完成；交互待 27.3 正式环境验收。

`cachedReceiverFrame` 保存收到帧的时间、来源最后成功时间、通道状态 / 固定问题码、持久化问题和当前汇总。导出时刻与帧接收时刻分开，导出不会更新来源新鲜度、确认已读、重新连接或重放旧提醒。尚无帧用 `liveUnavailable`，不冒充“已确认的空会话”。系统权限与交付问题来自现有缓存，不主动请求权限或查询系统。

Wave 只保留上次已完成返回动作的时间、实际尝试路线、返回结果和导航原因；不导出 `SessionReference` / location，也不把“建议应用级回退”算成执行。应用请求与布局聚焦响应均不证明可见焦点，`visibleWaveFocusVerified` / `nativeRuntimeVerified` 持续为 false；没有动作时不生成路线。

## 确定性回放

报告不是回放输入，不从实际 inbox 生成带身份的 fixture。使用仓库合成场景检查适配器、事件编解码与状态机：

```bash
tide-island-bridge replay \
  --file Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json \
  --scenario permission-wait-resume
tide-island-bridge replay --file Tests/TideIslandCoreTests/Fixtures/Replay/wave-location.json
```

回放不读写用户配置或事件目录，不执行 Wave / 原生 API；显式 ID、时钟与完整预期确保结果可重复，不匹配返回非零。格式及范围见 [事件回放](event-replay.md)、[会话状态](session-state.md)。诊断、共享回放、真实集成及原生验收分别取证；统一进度见 [开发计划](development-progress.md)。
