# 首次使用

TideIsland 当前完成首版共享逻辑与原生应用源码，尚未发布可安装版本；真实 hooks / notify 接入和原生编译、安装、灵动岛及触摸行为留待 macOS 27.3 正式环境统一验收。

## 当前开发阶段

可以先检查不依赖原生界面的共享层和合成回放。在仓库根目录运行：

```bash
swift test
swift build --product tide-island-bridge
.build/debug/tide-island-bridge version
.build/debug/tide-island-bridge replay \
  --file Tests/TideIslandCoreTests/Fixtures/Replay/lifecycle.json \
  --scenario permission-wait-resume
.build/debug/tide-island-bridge diagnostics
```

共享层目标为 Swift 6.0 / macOS 14+，具体证据见 [兼容清单](compatibility.md)。若本地 Xcode 许可或工具链阻止构建，记录实际限制，当前阶段可继续依据仓库共享 CI 开发；不需要为原生验收升级 beta。CI 的共享测试、CLI 与工程检查不代表原生目标已编译。

CLI 默认 `diagnostics` 只打印版本，不读取事件或 Codex 配置。`replay` 使用合成场景，不调用模型、Wave 或原生接口。完整检查命令见 [README](../README.md#验证共享层)，fixture 格式见 [事件回放](event-replay.md)。

若需手动验证事件写入，使用已准备好的隔离开发目录：

```bash
.build/debug/tide-island-bridge emit \
  --session isolated-demo --project TideIsland --phase working \
  --inbox /absolute/path/to/development-events
.build/debug/tide-island-bridge diagnostics --inbox /absolute/path/to/development-events
```

`emit` 会创建该目录并写入一条元数据事件；离线诊断只统计文件。首版应用监听自己的默认目录，不会自动切换到这份隔离目录。不要把开发用 `.build` / DerivedData helper 路径装入 Codex；后续真实接入使用稳定应用包内的 helper。

## 正式环境验收后的首次使用

以下是后续使用流程，当前未在本机执行。正式包和验收结论以 [进度台账](development-progress.md)为准。

1. 按 [兼容清单](compatibility.md)核对系统、硬件、Codex / Wave 契约及已验证范围；使用经过验证的 TideIsland.app 并放在稳定路径。构建 / 分发由 [打包](packaging.md)和 [独立原生入口](native-validation.md)记录，checksum 不替代签名或运行验收。
2. 启动应用，从菜单栏「打开会话」进入列表，展开「系统状态」检查来源与独立系统权限。没有新鲜事件时不要求出现活动；系统允许实时活动也不保证当前显示位置。
3. 确认实际使用的 Codex 配置目录，用包内 helper 执行 `integration install` **预览**。核对两份配置、应用路径与总指纹，再按 [接入说明](installation.md#安装与升级)使用 `--apply --expect ... --backup-dir ...`；原始备份保存在自己指定的私有位置。
4. 按当前 Codex 的 `/hooks` 完成信任审查及所需重载 / 重启，在 Wave 中进行一次明确的新会话 / 工具活动与本轮结束。分别核对 hooks 开始、notify 结束和原有通知工具；配置写入成功本身不证明 Codex 已采纳。
5. 在列表查看状态、来源时间和详情；点击「打开 Wave」后在 Wave 中确认目标会话。首版只接入应用级返回，不承诺跨标签 / 窗口精确定位。
6. 需要系统提醒时在「设置 → 会话提醒」主动开启；默认提醒 / 声音关闭。按需调整安静时段、项目名称和历史显示。登录启动由独立开关控制，待批准时使用系统登录项入口。

应用默认事件目录为 `~/Library/Application Support/TideIsland/Events/`，会话 checkpoint 位于同级 `State/`；显示 / 提醒设置在应用 UserDefaults 中。自定义 `--inbox` 用于 CLI 开发，应用目前没有目录选择器。目录、格式和清除语义见 [持久化](session-persistence.md)与 [迁移](migrations.md)。

「加载演示会话」会向默认 inbox 写入一条演示元数据，不是纯视觉预览，也不证明真实 Codex 已接入；不要用演示结果代替端到端验收。

## 阅读状态与返回终端

| 界面状态 / 动作 | 含义 |
| --- | --- |
| 正在工作 | 最近收到符合条件的新鲜工作观察，不保证后台进程仍存活 |
| 等待你处理 | 当前适配器观察到许可请求；普通聊天提问等待仍未覆盖 |
| 本轮已结束 | 收到 `agent-turn-complete`，不等于整个任务完成、测试通过或部署成功 |
| 状态待确认 | 来源不可确认、记录已失去新鲜度或时间异常；先查看原因，保留旧观察 |
| 选择 / 已读 / 忽略 / 置顶 | 显式调整本地注意力；项目筛选和打开详情不会自动已读 |
| 打开 Wave | 请求启动 / 返回应用；请在 Wave 确认具体会话，系统响应不证明目标分屏可见 |

项目名称可隐藏；历史 1 / 6 / 24 小时只过滤界面已解决记录，不删除事件，也不让未知工作会话自动消失。详情展示最近必要元数据，不包含聊天正文。

## 遇到问题、升级或退出使用

先看会话窗口的「系统状态」与操作提示；来源失败时可「重新连接」，系统权限问题可「重新检查系统状态」。恢复不会自动补发旧提醒或清除系统关闭记忆。

需要提供诊断时，在会话窗口「管理 → 导出诊断…」选择应用数据目录之外的新文件。报告只含版本、汇总、时间、固定码与上次实际 Wave 返回路线，不含身份 / 正文 / 路径，也不自动上传。CLI 版、失败含义与回放边界见 [诊断](diagnostics.md)。

升级 / 移动应用后重新预览统一接入；卸载时先关闭登录启动、退出应用，再用仍可运行的 helper 预览 / 应用 `integration uninstall`，最后移除应用。默认保留全部数据；`clear-state` 只清会话状态与会话偏好并保留事件和显示设置，不能代替移除文件。具体步骤见 [安装与卸载](installation.md)、[升级与降级](migrations.md)及 [常见问题](faq.md)。
