# 返回 Wave 与会话链接

T015 将应用级返回作为明确的用户动作：核对当前会话、选择已支持的路线，区分 Wave 未安装、尚未运行、已运行及打开失败。共享流程可用测试替身验证，原生适配源码使用公开 NSWorkspace，尚未完成 27.3 编译或交互验收。

## 会话链接

`SessionLink` 只接受 `tide-island://session?id=...`：

- session ID 与事件协议一致：非空白、最多 256 个 UTF-8 字节、无控制字符；生成器与读取器使用同一约束，保留合法空格、中文与已编码的特殊字符。
- URL 最多 4,096 字节；拒绝其他 scheme / host、路径、用户信息、端口、fragment、重复或未声明 query 字段。错误提示不回显 URL 或 ID。
- `resolve` 只查当前可见、未忽略、未展示过期的唯一会话，捕获当时的 `SessionReference`；不把旧链接导向名字相近的项目或其他分屏，也不把链接参数传给 shell / Wave。
- 无效链接、会话不可用与不唯一分别返回 `SessionLinkError`，原生入口展示对应提示。链接保留原有仅按 session ID 查当前观察的语义；捕获后发生的事件变化由动作前复核拒绝。

## 共享返回流程

`WaveReturnCoordinator` 组合 [导航编排](wave-navigation.md) 与独立的 `WaveApplicationDriver`，一次只接受一个用户请求：

1. 核对原 `SessionReference` 当前仍可见且未过期。
2. 执行导航策略。旧行、busy 或取消不会触发应用级回退；元数据 / 上下文不足则保留固定原因并继续应用级返回。
3. 查询应用状态，然后再次取最新快照核对原观察。查询期间会话变化时拒绝打开，不改选新观察。
4. 未安装时只返回提示；已安装时请求打开 / 激活同一个 bundle identifier：`dev.commandline.waveterm`。
5. 记录实际尝试路线及请求结果，不盲目重试。取消或错误发生在打开请求后仍保留已尝试 application 路线，不能声称撤销了系统动作。

仅有标签布局聚焦响应时，返回用户到 Wave 仍需要应用打开请求；结果保留 `[tabLayoutFocus, application]` 两个实际尝试，不能把它们组合为已验证的可见精确定位。

会话来源暂不可确认或位置过期时，当前仍可见的观察可以明确退回应用；这不恢复实时计数、不改写位置，也不声称目标仍存在。展示过期、忽略或旧行则拒绝整个动作。

## 结果与提示

`WaveReturnResult` 绑定原观察，保留导航原因、应用探测状态、`applicationAttempted`、`attemptedRoutes` 和 outcome：

| outcome | 含义 |
| --- | --- |
| applicationRequested | 系统打开请求得到响应；探测时未运行则提示已请求启动，已运行则提示已请求返回，并请使用者在 Wave 中确认目标会话 |
| notInstalled | 探测或发送时找不到 Wave；不自动安装 |
| openFailed | 打开失败或 driver 异常；只给固定提示，不输出原异常或路径 |
| staleSelection | 原观察已经变化、被忽略或展示过期；不自动替用户选择其他观察 |
| busy | 已有返回请求；不排队抢焦点 |
| cancelled | 不继续动作，不显示成功提示；已发出的动作不能撤销 |

“未运行 / 已运行”是打开前的状态观察，不是进程生命周期保证。系统接受打开请求不证明正确窗口、标签或分屏已可见；Wave 跨窗口 / 标签的公开能力边界继续按 [能力矩阵](wave-capabilities.md)处理。

## 原生接入源码

`SessionModel` 为按钮和深链使用同一路径，先用原观察身份选择会话，再交给共享返回协调器。重复点击不会并行发起打开请求；结果再次核对当前行，旧请求不能覆盖后来无效链接的提示。

`NativeWaveApplicationDriver` 在主 actor 使用 NSWorkspace 的 bundle 查询、运行应用列表和 openApplication。发送前重新解析安装位置，显式请求激活；传给应用的配置不包含 session、block、外部 URL 参数或认证上下文。本轮没有真实 focus driver，CLI 也不启动 Wave。

返回提示独立保留，普通 inbox 帧不会立即清空；保存 / 通道及偏好错误优先占用操作提示，恢复后再显示返回结果。T023 将活动 / 提醒的能力及上次错误放在独立的 [系统状态区域](system-status.md)，多个问题可同时查看。原生交互、消息优先级、取消与打开回调仍需 V005 / V009 验收；静态工程检查不替代这些验收。

## 验证与后续

新增 16 项共享测试覆盖链接字符 / 字节边界、拒绝路由、当前观察解析、安装 / 运行状态、打开失败、实际路线、查询竞态、并发、取消及错误脱敏。`capabilities.wave_application_return` 分别声明共享范围、原生源码、CLI 不启动应用及原生尚未验证。

实际共享执行结果见 [开发进度](development-progress.md)。本轮没有启动 / 切换真实 Wave、读取凭据或修改 Codex 配置；原生验证继续待 macOS 27.3 正式环境。下一阶段 T016 抽出可测试的原生活动展示状态与客户端接口。
