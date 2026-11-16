# Codex hooks 配置管理

应用交付源码已提供 `hooks install --app /absolute/path/TideIsland.app`，从包内固定 Helpers 目录检查 bridge，并在移动 / 升级后重新预览修复受管路径；与 `--bridge` 互斥。完整性、指纹和原生构建边界见 [应用内 bridge 交付](bridge-delivery.md)。

T004 提供 `hooks.json` 的预览、幂等安装、路径升级、备份和卸载。命令默认只预览，必须同时提供 `--apply`、本次预览的 `--expect` 指纹和 `--backup-dir` 才写入。

本轮仅用隔离目录测试，尚未安装到本机正在使用的 Codex。原生界面与真实会话链路仍按 [开发进度](development-progress.md) 单独验收。

## 配置范围

- 只编辑显式 `--config /absolute/path/hooks.json` 指定的文件，不推断全局或项目层。非 `hooks.json` 文件名、相对路径和文件符号链接均拒绝。
- 保留已有 hooks、描述、未知 JSON 字段及数值字面量。变更时重新排版和排序对象键，原始字节另存备份；没有变更时保留原始字节。保留未知字段不代表当前 Codex 能接受这些字段。
- `config.toml`、既有 notify、内联 hooks、Codex 的信任与禁用状态均不读取或修改。单独安装这六类 hook 不会自动接入完成通知；`agent-turn-complete` 仍需 notify 入口，完整接入与共存策略由 T025 处理。
- 安装六类事件：`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`Interrupt`、`SessionEnd`。不安装 `Stop` 或 `SessionStart`，转换边界见 [事件契约](codex-events.md)。
- 输入上限 1 MiB、嵌套深度上限 64；重复键、损坏 JSON 和不支持的 hooks 结构会阻止修改，不尝试修复用户配置。

目标应位于 Codex 正在使用的配置层旁边。常见位置是 `~/.codex/hooks.json` 或项目 `.codex/hooks.json`；自定义 Codex home、项目是否受信任、组织策略及运行中的会话是否已重载，均须在实际启用时核对。

## 预览与应用

以下路径是占位示例。可通过 T024 的 `--app` 使用 [包内 bridge](bridge-delivery.md)，或自行把 bridge 放到稳定位置。`.build`、`DerivedData` 下的可执行文件及解析到这些目录的链接不能用于实际安装。

```bash
# 只读预览：不创建配置、目录、锁文件或备份
/stable/path/tide-island-bridge hooks install \
  --config /absolute/path/to/codex/hooks.json \
  --bridge /stable/path/tide-island-bridge
```

预览输出目标路径、`plan_fingerprint`、TideIsland 条目数量、事件名及将要写入的观察命令，不输出用户原有 hook 正文。`--inbox /absolute/path` 可指定事件目录；省略时由 bridge 使用应用默认 inbox。

```bash
# 参数与预览保持一致，复制本次预览的 plan_fingerprint
/stable/path/tide-island-bridge hooks install \
  --config /absolute/path/to/codex/hooks.json \
  --bridge /stable/path/tide-island-bridge \
  --apply --expect '<plan_fingerprint>' \
  --backup-dir /absolute/path/to/retained-backups
```

指纹绑定目标路径、操作、原始字节和拟写入内容。配置或安装参数变化后，旧指纹不能用于新的计划，需重新预览。重复安装先重新预览，若内容一致则返回 `mode: unchanged`，不重写文件或增加备份。

`--bridge` 只检查所选 bridge 是可执行的普通文件，`--app` 还检查应用元数据与摘要清单；两者都不执行该程序来探测版本。实际启用前应使用自己构建或验证的 TideIsland bridge。新建配置为 `0600`，已有配置保留原 POSIX 权限。

## 与原有 hooks 共存

TideIsland 使用专用分组及两项保留标记识别自己的条目：`statusMessage = "TideIsland lifecycle observer v1"`，以及 command 开头的 `: tide-island-observer-v1;`。识别还要求完整字段集合、3 秒 timeout 和自身生成的命令引用格式匹配，不通过路径中的 `tide-island` 子串判断归属。

- 新装条目加入专用分组或复用空的专用形状分组，已有命令内容及相对顺序保留；正常升级原地替换自己的 handler。
- 卸载只移除可确认归属的 handler，保留旁边的命令、matcher、其他事件与描述。空分组和事件数组保留，以减少其他条目的索引变化，不删除配置文件。
- 用户修改自身 handler 的字段、命令或 timeout 后，会提示冲突并停止操作，不自动删除或覆盖它。需要先核对差异，恢复生成格式或手动处理该条目。
- 不要将保留标记用于其他工具。它是配置归属约定，不是 Codex 的企业 managed hook 或信任凭据。

观察命令对每个参数使用 POSIX 单引号引用，stdout 丢弃，非零返回由 `|| :` 收敛为 0。bridge 缺失或输入错误不会产生许可决定；等待超过 3 秒仍由 Codex 的 hook timeout 规则处理。

## Codex 的信任审查

Codex 0.169.0 会合并各配置层的 hooks，并在同层同时使用 JSON 和内联 TOML 时给出提示。非企业 managed hook 需要审查并信任具体定义；文件已写入不等于 hook 已经运行。

实际启用后，在 Codex CLI 的 `/hooks` 中核对来源、启用状态和待审查条目。升级命令路径会改变定义，可能需要重新审查。若手动把 TideIsland 与其他 handler 放进同一分组，卸载后的 handler 索引也可能变化，以 Codex 显示的审查结果为准。工具不会绕过或代填信任记录。

固定版本依据：[配置文件结构](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/config/src/hook_config.rs)、[handler 与分组类型](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/protocol/src/hooks.rs)、[发现与信任逻辑](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/engine/discovery.rs)。

## 卸载与回退

```bash
/stable/path/tide-island-bridge hooks uninstall \
  --config /absolute/path/to/codex/hooks.json

/stable/path/tide-island-bridge hooks uninstall \
  --config /absolute/path/to/codex/hooks.json \
  --apply --expect '<uninstall_preview_fingerprint>' \
  --backup-dir /absolute/path/to/retained-backups
```

每次实际变更先在备份根目录下创建独立的 `tide-island-hooks-<UUID>/`：目录为 `0700`，`hooks.json.before` 和 `receipt.json` 为 `0600`。前者保存原始字节，后者记录目标、操作、指纹、原文件是否存在及原 POSIX 权限。原文件不存在时只生成 receipt，不伪造空文件备份。备份可能含用户原有命令，应作为保留数据管理。

常规卸载保留用户在安装后新增的条目。只有需要完整回退文件时，才对照 receipt 和当前差异恢复 `hooks.json.before`，并恢复记录中的权限；原文件原本不存在时，也须确认没有后来添加的内容再决定是否删除。T004 不提供覆盖当前文件的自动 restore 命令。

同一目标的 TideIsland 写入使用文件锁，并在发布前复核原始字节和文件身份。现有文件以同目录 staging 文件原子替换，新文件以不覆盖已有目标的方式发布。外部编辑器不遵守本锁，现有文件的最终复核与 rename 之间仍有竞争窗口；应用期间不要同时编辑该文件。失败时保留已生成的备份，临时 staging 文件会清理。

## 验证

```bash
swift test
swift build --product tide-island-bridge
python3 scripts/check-bridge.py
python3 scripts/check-hooks.py --temporary-root /absolute/path/to/test-temporaries
python3 scripts/check-project.py
```

配置测试覆盖预览无副作用、既有 notify / hooks 保留、重复安装、路径升级、卸载、备份原始字节与权限、过期指纹、并发锁、无效配置、符号链接 / FIFO，以及带引号和 shell 特殊字符的路径。测试生成的命令只在隔离 inbox 中执行，不修改运行中的 Codex 配置，也不代表原生或真实会话验收通过。
