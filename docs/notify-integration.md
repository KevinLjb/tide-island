# 完成 notify 共存

T025 正在开发。共享 argv 信封和顶层 TOML notify 计划已通过 394 项共享回归；文件预览 / 写入命令及回调源码已接入，等待补充 CI。统一安装 / 卸载入口待接续，不表示真实 Codex 已启用完成通知。

## 固定契约

按 [Codex 0.169.0](codex-events.md)固定 revision 的 [legacy_notify.rs](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/legacy_notify.rs)重新核对：notify 是命令 argv，Codex 将 JSON 追加为最后一个参数，stdin / stdout / stderr 置空，启动子进程后返回，不等待通知完成。

本项目继续只把 `agent-turn-complete` 作为本轮结束，不将它当成任务成功。上游 JSON 可能含正文；转换器只保留必要状态元数据，dispatcher 不把正文写入日志、诊断或另一个配置存储。

## 共存信封

`NotifyDispatchConfiguration` 将原有 argv 原样保留在同一个 notify 数组的明确计数区间内，不拼接 shell 文本，不额外保存到应用数据。它区分原 notify 缺失与显式空数组，以便卸载恢复对应语义。

受管格式使用 `notify-dispatch` 和保留标记 `--tide-island-notify-v1`，固定恢复类型、inbox 参数、原命令参数个数及末尾 `--payload`。回调再接收 Codex 追加的一个 JSON 参数；原参数自身即使为 `--payload`、空字符串或 shell 特殊字符，也保持参数边界。

完整格式才算本项目配置；不符合格式、未知版本或嵌套自身的信封拒绝自动覆盖。最多保留 64 个原参数 / 合计 64 KiB，拒绝空命令名和 NUL，不改变外部命令的参数值。

## TOML 编辑范围

`TOMLNotifyDocument` 是保守的单字段编辑器，不是通用 TOML 校验器。它逐字节定位顶层 notify，跳过其他值的多行 basic / literal 字符串、嵌套数组 / inline table 和注释；表内的 profile notify 不作为顶层 notify。

只接收由单行 basic / literal 字符串组成的数组，数组自身可以跨行并带注释 / 尾逗号。顶层 quoted / Unicode 转义键按同一 notify 识别。重复、dotted notify、同名 table、无效定位语法、未知值类型、字符串中的 NUL、BOM 及超限输入明确拒绝，原文保留。三引号形式的 notify 参数字符串尚不支持，不静默转写。

安装只替换 notify 值，其他前后字节保持；缺失时在文件开头插入顶层设置。该值内部的格式 / 注释可被标准化，原始字节由文件写入层备份。卸载恢复原参数值，或移除本项目新增的赋值，保留旁边注释 / 空白，不自动删除配置文件。profile、内联 hooks、模型及其他配置不反序列化重写，编辑器不宣称验证了其全部 TOML 语义。

`CodexNotifyConfiguration` 的计划绑定显式 config.toml 路径、原字节、拟写结果与 [包内 bridge](bridge-delivery.md)的摘要 / 应用版本；同路径应用升级即使不改变命令，也会改变预览依据。共享计划不做文件写入、执行通知或修改信任。

## 独立配置命令

包内 helper 提供以下入口，默认只预览；下列路径均为后续实际应用交付时使用的示例：

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" notify-config install \
  --config /absolute/path/to/codex/config.toml --app /Applications/TideIsland.app

# 核对本次 plan_fingerprint；参数与预览相同
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" notify-config install \
  --config /absolute/path/to/codex/config.toml --app /Applications/TideIsland.app \
  --apply --expect FINGERPRINT --backup-dir /absolute/path/to/retained-backups
```

`--inbox /absolute/path` 可显式指定本项目事件目录，不改变原通知命令的参数或工作目录。预览只输出归属、是否转发已有命令、路径、指纹等必要元数据，不回显原 notify 参数或 TOML 正文。

`NotifyConfigurationFile` 以普通文件 / 有界读取、同目录锁和原字节 / 文件身份复核管理写入。先保存 `0700` 的 `tide-island-notify-<UUID>` 备份目录，其中 `config.toml.before` 和 receipt 为 `0600`；原文件不存在时只记录不存在。新配置为 `0600`，已有配置保留原 POSIX 权限。备份是完整原配置，仅作为用户保留的回退资料。

当前 bundle 重新检查也覆盖 no-op；发布前再查配置和 bundle。失败保留已有备份、清理暂存，不静默恢复旧文件覆盖后来编辑。外部编辑器与应用替换不遵守本锁，因此仍不提供跨文件 CAS，请勿在同一预览 / 应用期间修改这些目标。

```bash
"/Applications/TideIsland.app/Contents/Helpers/tide-island-bridge" notify-config uninstall \
  --config /absolute/path/to/codex/config.toml
# 核对卸载预览后，追加 --apply --expect FINGERPRINT --backup-dir /absolute/path
```

卸载无需读取旧应用包，仍只处理明确的受管信封；未归属的 notify 原样保留。它不删除 inbox、会话状态或显示设置，六类 hooks 由独立 hooks 命令管理；统一流程由本任务后续模块接续。

## 观察与转发

内部 `notify-dispatch` 先调用既有转换器写本项目元数据，再以原 argv 加原始 JSON 单参数执行原通知命令。原输入解析 / inbox 写入失败仍转发，原通知命令失败不撤回已写入的状态事件；不从其退出码推断开发任务结果。

转发使用 Process，不使用 shell；继承调用者工作目录及环境，stdio 置空，只在解析裸命令名时读取 PATH，不采集环境集合。不会根据 payload 中的 cwd 切换目录。callback 等待自己的子进程结束，而 Codex 已在启动 callback 后返回，不等待它完成。没有自动重试、超时杀死原通知程序或回显其输出。

callback stdout 始终为空，可捕获失败返回 0，stderr 仅有固定的不完整提示。未知 / 损坏 JSON 也只作为一个不透明参数交给原通知命令，不写入本项目正文历史；管理命令的失败继续返回非零。缺失或无法启动的 helper 无法通过 callback 自行处理，仍需交付 / 安装验证。

## 当前验证范围

共享测试覆盖逐字节保留、已有 argv 共存、幂等、移动、可撤销恢复、缺失 / 空数组、quoted 键、多行陷阱、非法 / 超限输入、Unicode、严格信封、原始备份 / 权限、过期计划、锁、链接 / FIFO 和 no-op bundle 重验。

[隔离检查](../scripts/check-notify.py)使用 Python 3.13 的独立 tomllib 解析实际配置结果，执行当前编译的 bridge 与本地合成 notifier，验证原参数 / payload 摘要、工作目录、PATH、彼此失败隔离和恢复。只在临时合成目录中运行，不执行用户的既有 notifier。执行结果见 [开发进度](development-progress.md)，真实接入与原生效果继续待统一验收。
