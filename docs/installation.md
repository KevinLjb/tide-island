# 安装、升级与卸载流程

T025 提供明确目录内的 hooks + notify 统一配置入口。源码及隔离检查不代表当前用户配置已启用；最新 beta 本机包已完成 ad hoc 签名安装，真实 Codex 链路、分发签名及完整卸载继续分别验收，见 [当前进度](development-progress.md)。

第一次了解使用顺序见 [首次使用](getting-started.md)；版本、格式迁移与常见问题分别见 [兼容清单](compatibility.md)、[升级 / 降级](migrations.md)和 [FAQ](faq.md)。本文命令用于后续明确启用，不会因为阅读说明自动执行。

## 本机接入实测（2026-11-18）

用户明确选择接入当前 Codex 后，已使用签名验证的 `b6f6ff2` 包内稳定 helper，对 `~/.codex/hooks.json` 与 `config.toml` 执行最新预览及统一应用。六类观察 hook、完成 notify 已写入；原有 hook 分组 / 其他 JSON 字段、非 notify TOML 字段、原通知 argv 与文件权限逐项核对保留，两份私有备份与应用前原始字节一致。原通知命令为空时仅建立本地完成观察，不生成额外外部通知命令。

再次预览确认 hooks / notify 均无需修改。没有变更 Codex 信任、事件文件、会话状态或显示设置；当前继承的 Codex home 与上述目录一致，hooks feature 为 stable / true。安装报告 integration-install-audit.json 与原始配置备份保存在本机私有辅助目录，不进入仓库。用户仍需在当前 Codex 的 `/hooks` 审查条目，并确认当前会话实际加载；文件已写入不是 live 运行通过。真实链路进度以 [统一验收](development-progress.md#6-macos-273-正式环境统一验收)为准。

## 使用前提

- 使用已构建、验证的 TideIsland.app，保持在稳定路径；本机测试包位于 `/Applications/TideIsland.app`，[交付说明](bridge-delivery.md)区分摘要完整性与系统签名。
- 确认要修改的 Codex 配置目录。工具只处理该目录的 hooks.json 和 config.toml，不搜索其他配置层、项目目录、用户正文或信任记录。
- 原生应用要求 macOS / Xcode 27.3+；当前本机验证使用已安装的 27.3 beta 工具链，beta 结果与正式环境复验分别记录。以下接入命令仍需明确启用后才执行。

先停止对目标文件的并发编辑；真实接入时需核对 Codex 使用的是哪个配置层，并在重启 / 重载后按 `/hooks` 完成信任审查。文件写入不表示 Codex 已采纳或信任。

## 安装与升级

以下示例用于后续实际交付，默认只预览，不创建配置、备份、inbox 或安装 hooks：

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" integration install \
  --codex-directory /absolute/path/to/codex --app /Applications/TideIsland.app
```

预览将两份配置、相同 bundle / inbox 及数据选择绑定为一个 plan_fingerprint，分别显示 hooks / notify 是否需要变化。app 在两份预览之间改变、目录 / 操作 / inbox 不一致时拒绝组合。报告不输出旧 hook / notify 参数或 config.toml 正文。

核对后使用相同参数和指纹：

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" integration install \
  --codex-directory /absolute/path/to/codex --app /Applications/TideIsland.app \
  --apply --expect FINGERPRINT --backup-dir /absolute/path/to/retained-backups
```

安装先应用六类观察 hooks，再配置完成 notify 共存；各文件先备份原始字节，再通过原有锁 / 指纹 / 身份检查发布。重复安装返回 unchanged，内容一致的文件不重写、不增加备份。完成 notify 使用 [argv 共存](notify-integration.md)转发原通知工具，其他 hooks、TOML 字段、profile 和内联配置保留。

相同路径升级后重新预览，bundle 版本 / helper 摘要改变使旧指纹失效，即使命令文本不变。移动应用后，使用新包内 helper 和新的 `--app` 路径重新预览 / 应用，更新自身 handler 及 notify wrapper，原通知工具参数保留。

首版原生接收器监听默认 `~/Library/Application Support/TideIsland/Events/`。`--inbox /absolute/path` 同时配置两类观察，但自定义目录目前用于 CLI 隔离开发，应用不会自动切换监听路径。

## 卸载与数据选择

完整卸载时，先在应用设置关闭登录启动，再退出应用；配置工具不操作系统登录项。使用当前可运行的 helper 预览移除接入，最后再删除应用包。

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" integration uninstall \
  --codex-directory /absolute/path/to/codex
# 核对后追加 --apply --expect FINGERPRINT --backup-dir /absolute/path
```

卸载先恢复原 notify，再移除自身六类 hook；没有受管配置时保持原文件。无需读取旧应用包，不删除配置文件、其他工具条目或信任数据。

| 选择 | 实际行为 |
| --- | --- |
| 默认 / `--data keep` | 保留事件、会话 checkpoint、已读 / 忽略 / 置顶 / 选择和应用显示 / 提醒设置 |
| `--data clear-state` | 使用现有 fingerprint / 接收者 lease 清除指定 inbox 的会话状态和会话偏好，保存旧文件导入边界；原始事件和应用显示 / 提醒 / 登录设置保留 |

清除状态必须显式指定已经由 TideIsland 管理的绝对 inbox。没有该目录时不创建空通道冒充清除；默认 keep 不读取或维护事件目录。

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" integration uninstall \
  --codex-directory /absolute/path/to/codex \
  --data clear-state --inbox /absolute/path/to/TideIsland/Events
# 预览包含事件数量与 state_path；核对后追加 apply / expect / backup-dir
```

自定义 checkpoint 可附带 `--state-directory`。清除预览受默认扫描预算约束，必要时显式提供 `--scan-limit` / `--read-budget-bytes`；超限不接受不完整批次。保持 keep 时不接受这些清除选项。

清除状态先于两份配置变更执行。接收者 lease 忙时会在配置变更前失败；事件或 checkpoint 在预览后改变会使总指纹失效。清除不删除事件文件，不触碰 Codex 聊天或项目文件，不把显示设置的 UserDefaults 当成会话偏好。

## 中断恢复与回退

多个文件之间没有原子事务。某一步失败时返回非零及 JSON `mode: incomplete`、completed_steps、failed_step、固定 failure_code 和已完成步骤的备份路径；阶段完成不一定代表文件写过，具体是否变化由预览及备份记录区分。

例如 hooks 已更新而 notify 的锁忙时，报告只确认 hooks，保留它的备份；解除繁忙后重新预览当前状态，会显示只需更新 notify，再应用新的总指纹。不会用自动回滚覆盖并发编辑，也不会把部分成功报告成安装完成。

备份根目录下按操作保存独立的 hooks / notify 原始字节与 receipt；资料权限与说明见 [hooks 配置](codex-hooks.md)和 [notify 配置](notify-integration.md)。若需要完整回退某文件，对照 receipt、当前差异及原权限后恢复对应 before 文件；原文件原本不存在时，先确认没有后续内容再决定是否删除。状态清除不是自动回退配置的替代，事件文件始终保留。

## 验证边界

共享测试核对跨文件 scope、操作、bundle / inbox 一致性，以及配置和状态变更对总指纹的影响。[隔离 CLI 检查](../scripts/check-integration.py)执行安装 / no-op / 移动 / 升级 / notify 锁造成的部分成功及重试，再验证默认数据保留、事件变化使预览失效、接收锁忙先失败和显式清除状态。

上述配置检查只在合成应用、Codex 目录和 inbox 中运行。另行完成的 beta 原生构建、本机 ad hoc 安装、应用包更新 / 移除重装不证明真实 hooks / notify、Codex 信任 / 重载或完整配置卸载；这些链路仍须 V003 / V004 / V010 验收。
