# 完成 notify 共存

T025 正在开发。当前已准备共享 argv 信封和顶层 TOML notify 编辑计划；文件预览 / 写入命令、回调执行及统一安装 / 卸载入口尚未接入，不表示真实 Codex 已启用完成通知。

## 固定契约

按 [Codex 0.169.0](codex-events.md)固定 revision 的 [legacy_notify.rs](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/legacy_notify.rs)重新核对：notify 是命令 argv，Codex 将 JSON 追加为最后一个参数，stdin / stdout / stderr 置空，启动子进程后返回，不等待通知完成。

本项目继续只把 `agent-turn-complete` 作为本轮结束，不将它当成任务成功。上游 JSON 可能含正文；现有转换器只保留必要状态元数据，后续 dispatcher 不得把正文写入日志、诊断或另一个配置存储。

## 共存信封

`NotifyDispatchConfiguration` 将原有 argv 原样保留在同一个 notify 数组的明确计数区间内，不拼接 shell 文本，不额外保存到应用数据。它区分原 notify 缺失与显式空数组，以便卸载恢复对应语义。

受管格式使用 `notify-dispatch` 和保留标记 `--tide-island-notify-v1`，固定恢复类型、inbox 参数、原命令参数个数及末尾 `--payload`。回调再接收 Codex 追加的一个 JSON 参数；原参数自身即使为 `--payload`、空字符串或 shell 特殊字符，也保持参数边界。

完整格式才算本项目配置；被修改、未知版本或嵌套自身的信封拒绝自动覆盖。最多保留 64 个原参数 / 合计 64 KiB，拒绝空命令名和 NUL，不改变外部命令的参数值。

## TOML 编辑范围

`TOMLNotifyDocument` 是保守的单字段编辑器，不是通用 TOML 校验器。它逐字节定位顶层 notify，跳过其他值的多行 basic / literal 字符串、嵌套数组 / inline table 和注释；表内的 profile notify 不作为顶层 notify。

只接收由单行 basic / literal 字符串组成的数组，数组自身可以跨行并带注释 / 尾逗号。顶层 quoted / Unicode 转义键按同一 notify 识别。重复、dotted notify、同名 table、无效定位语法、未知值类型、字符串中的 NUL、BOM 及超限输入明确拒绝，原文保留。三引号形式的 notify 参数字符串尚不支持，不静默转写。

安装只替换 notify 值，其他前后字节保持；缺失时在文件开头插入顶层设置。该值内部的格式 / 注释可被标准化，原始字节由后续文件写入层备份。卸载恢复原参数值，或移除本项目新增的赋值，保留旁边注释 / 空白，不自动删除配置文件。profile、内联 hooks、模型及其他配置不反序列化重写，编辑器不宣称验证了其全部 TOML 语义。

`CodexNotifyConfiguration` 的计划绑定显式 config.toml 路径、原字节、拟写结果与 [包内 bridge](bridge-delivery.md)的摘要 / 应用版本；同路径应用升级即使不改变命令，也会改变预览依据。共享计划不做文件写入、执行通知或修改信任。

## 当前验证范围

新增共享测试覆盖逐字节保留、已有 argv 共存、幂等、移动、可撤销恢复、缺失 / 空数组、quoted 键、多行陷阱、非法 / 超限输入、Unicode 和严格信封解析。执行结果记录在 [开发进度](development-progress.md)。完整文件操作及实际 callback 仍待 T025 后续模块，真实接入与原生效果继续待统一验收。
