# Wave 定位能力与适配边界

T012 已完成 Wave 0.14.5 的本机只读检查及同版本公开源码核对。可继续实现应用级返回与必要 ID 采集；官方 `wsh focusblock` 只聚焦指定标签的布局，不能据此承诺跨标签 / 窗口切换。TideIsland 的精确定位尚未实现或交互验收。

## 核对版本与证据层次

核对日期：2026-11-17（Asia/Shanghai）。本机 `/Applications/Wave.app` 的 bundle identifier 为 `dev.commandline.waveterm`，应用版本和 bundle version 均为 **0.14.5**；附带 ARM64 `wsh version` 输出 `wsh v0.14.5`。本轮 GitHub latest 查询也返回 [v0.14.5](https://github.com/wavetermdev/waveterm/releases/tag/v0.14.5)，不把该结果推广到其他版本。

公开源码固定到 tag `v0.14.5` 对应 commit **`97e560027f494d20fed347b2d6b72b6bcb3e50e0`**。下载的审阅文件已与该 Git tree 的 blob 身份核对；以下引用均固定到该 commit。源码审阅解释接口行为，真实 GUI 操作仍需单独验收。

| 证据 | 本轮实际范围 | 能证明什么 |
| --- | --- | --- |
| L1 本机安装信息 | Info.plist 的版本、bundle ID、URLTypes；附带 ARM64 helper 的版本、帮助和哈希 | 当前安装与命令表面能力 |
| L2 无 Wave 认证上下文的子进程 | 剥离 `WAVETERM_` / `WAVE_` 环境后执行帮助、普通 version、version JSON | 脱离上下文的行为；不代表原 Wave 会话缺少凭据 |
| S 固定版本源码 | CLI → 认证 / ID 解析 → 标签前端；列表、Electron 窗口 / 标签服务与认证包装 | 路由语义及输出边界 |
| R 真实定位 | 未执行 focusblock、标签切换、窗口聚焦或应用重启 | 没有本轮真实跳转通过的结论，留待 27.3 / V005 |

本机 helper 位于 `Contents/Resources/app.asar.unpacked/dist/bin/wsh-0.14.5-darwin.arm64`，SHA-256 为 `7bccadabdf67af7cc41b1867a923cf861afbc96833bb5daf3d70b10445add3e4`。本轮未执行 x64 helper；该哈希用于定位安装样本，不代表可复现构建验证。

本次 Agent 执行环境的 `command -v wsh` 无命中；这不证明用户交互式 Wave shell 的 PATH 相同。后续应用应通过已确认的安装位置 / helper 解析路径，不能假设登录 shell 的 PATH 对菜单栏应用可用。

## 能力矩阵

| 能力 / 入口 | 0.14.5 核对结果 | TideIsland 决策 |
| --- | --- | --- |
| 应用级返回 | 已确认 bundle ID；当前原生源码使用 NSWorkspace 查找并打开该应用 | 保留首版可靠返回目标；启动 / 激活效果待原生验收 |
| 普通 `wsh version` / 帮助 | 在剥离 Wave 上下文后实际成功 | 可用于版本探测，不能据此声称 RPC 已认证 |
| `wsh version --json` / `-v` | 源码调用认证和 WaveInfo / Electron RPC；剥离上下文的 JSON 调用实际返回 1，提示缺少 WAVETERM_JWT | 不用 JSON version 作为独立应用的无认证探测；输出还含客户端 ID / 配置和数据目录 |
| `wsh focusblock -b …` | 读取 WAVETERM_TABID，解析对象后向 `tab:<TABID>` 发 SetBlockFocus；前端只在该标签的 layout 内查找节点 | 有效上下文中的同标签聚焦是候选路线，T014 仍须实测；不同 / 关闭目标应明确失败 |
| 自动跨标签 | workspace 子命令仅有 list；focusblock 不调用标签切换。修改 TABID 只改变 RPC 目标，不把该标签显示出来 | 当前不承诺；不能把投递到后台标签当作可见定位成功 |
| 自动跨窗口 | 源码存在内部 Electron FocusWindow，但本版没有对应公开 wsh 子命令；内部实现甚至可能重新创建持久窗口的 BrowserWindow | 不作为默认稳定适配，不通过猜测 IPC / 私有 HTTP 自动化实现 |
| block / tab / workspace 发现 | `wsh blocks list --json` 为公开查询，可按 workspace / window / tab / view 过滤；输出的 CLI 对象有 blockid / tabid / workspaceid / view / meta | T013 可在合法上下文按需查询并仅提取 ID；必须校验输出完整性 |
| window 发现 | 后端 BlocksListEntry 含 windowid，但 CLI BlockDetails 丢弃该字段；workspace list 输出另有缺陷 | window ID 保持可选未知，不推断 window 与 workspace / tab 相同 |
| Wave 外部 ID deep link / 启动参数 | 本机 CFBundleURLTypes 无声明；已审阅主入口未发现可作为稳定 ID 定位契约的 URL handler。second-instance 路径创建新窗口 | 不编造 `wave://…` 或 app argv 定位；TideIsland 自身的会话链接仅查自身会话 |

证据分别见 S01—S18。这里只为 **0.14.5** 制定已审阅边界；未来版本须重新核对，不能只比较版本号大小就自动提升能力。

## focusblock 的实际前提

S01—S03 的调用链是：

1. CLI PreRun 要求 WAVETERM_JWT，从 token 获取 RPC context / socket，再向控制路由 Authenticate。服务端会验证签名及上下文（S08、S09）；客户端的未验证解码不等于获得授权。
2. 命令体要求 WAVETERM_TABID。错误信息虽然提到 Wave-managed SSH，准确约束是有效 Wave 认证上下文，不能据此假定只支持远程 SSH。
3. `-b` 默认 `this`。简称、数字和裸 UUID 经 ResolveIds；该 CLI 解析路径还需要 WAVETERM_BLOCKID。完整 `block:<UUID>` ORef 可绕过简称解析，但仍需要 JWT 与 TABID，不会自动产生认证。
4. CLI 向 `tab:<TABID>` 发送请求，超时参数 2,000 ms。标签前端的 `getLayoutModelForStaticTab()` 找到 block 对应节点后调用 focusNode；找不到则抛错。
5. 该链路没有前台窗口激活或标签切换步骤。返回 0 最多代表这次前端聚焦请求获得成功响应，不能据此认定 OS 已前台显示正确窗口和标签。

未来精确路线应使用已验证的完整 block UUID，不持久化易重排的数字、`this`、八位简称或按 view 选择。仅有现有 `waveBlockID` 字符串不足以断言存在可执行的定位路线；旧事件中的非 UUID 值继续保留兼容，不能静默改写旧协议。

## 列表查询的陷阱

这些是固定源码中的行为，不是本轮对真实工作区内容的读取：

- **workspace list 不能直接当可靠 JSON。** S06 使用 Run 而非 RunE，RPC 错误只写 stderr 并 return，可能仍退出 0；workspaceId 被写到 stderr，其余字段写到 stdout，名称等又直接拼接字符串。合并双流也不能当作可靠结构化解析方案。
- **blocks list 的空结果不是 JSON。** 即使指定 `--json`，S05 会先输出 `No blocks found` 并成功返回。
- **blocks list 可能返回部分结果。** 某些 workspace 请求失败时只发 Warning 后继续；至少一个查询成功后可能以退出 0 返回部分列表。缺少目标不能立即解释为目标关闭。
- **输出包含超出需求的内容。** 表格的 CONTENT 可含 cwd / 文件 / URL；JSON 的 meta 是完整元数据。不得把原始输出转存到事件、checkpoint 或诊断报告，只在内存有界解析并提取必要 ID。
- **CLI 和后端 schema 不同。** 后端含 windowid（S07），CLI 的输出类型没有（S05）；不能按后端定义解析 CLI 并自行补出该字段。

后续解析遇到超时、警告、非结构化输出、未知字段类型、重复 / 不唯一 ID 或不完整查询，应输出“无法确认映射”，保留应用级返回。不能仅凭退出码判定映射有效，也不能为凑成功改用第一个 / 当前分屏。

## 内部接口与认证边界

源码中的 `FocusWindowCommand`、WorkspaceService.SetActiveTab 和 Electron `set-active-tab` IPC 说明 Wave 内部具有切换能力，不构成第三方稳定定位接口。SetActiveTab 的后端状态更新、Electron 切换显示和 OS 前台焦点是不同步骤（S10—S12）。

内部 HTTP 使用运行时生成的 X-AuthKey；wsh 的 socket RPC 使用 Wave 签发 token，两者不能互换（S02、S08、S13、S14、S18）。本轮不读取真实 token、AuthKey、进程环境、Wave 私有数据库或终端内容，也不调用内部服务。已有 bundle ID / block ID 不授予这些接口的访问权。

如后续设计上下文内的本地 helper / relay，需单独明确授权来源、生命周期和能力范围，凭据仅在运行时使用；不能为了菜单栏点击把 JWT、AuthKey、socket claim 或整个环境加入事件与 checkpoint。T012 没有启动或安装任何 relay / hooks。

## 对 T013—T015 的开发约束

| 任务 | 接下来可实施的范围 | 必须保留的边界 |
| --- | --- | --- |
| T013 定位元数据 | 设计可选的版本化位置记录：完整 block / tab ID、已确认才填的 workspace / window ID、Wave 版本、观察时间和有效性来源；采集只用 allowlist | 现有事件兼容；缺字段即未知。版本、持久 ID 或 socket 路径不能单独充当当前实例存活证据；不能存凭据 / cwd / 原始 meta |
| T014 条件性精确路线 | 先实现可测试的能力选择与结果：已发送聚焦、已验证可见定位、应用级返回、目标失效 / 上下文不可用分别表达 | 同标签候选也要真实验证；跨标签 / 窗口当前没有可承诺的公开路线，不调用猜测接口、不重选相似会话 |
| T015 应用级返回 | 当前 bundle ID 查询、未安装 / 未启动 / 打开失败和自身深链的错误反馈 | 打开应用只报告应用级结果；不能因此宣称精确分屏跳转 |

T012 研究本身未添加位置或点击路线；后续 T013 已按这些约束实现 [可选位置元数据](wave-location.md) 与纯解析器，不执行真实查询或定位。

## 后置交互验收

V005 继续待 macOS 27.3 正式环境，至少覆盖：同标签多个分屏、切换后不同标签、不同窗口 / workspace、后台或未加载标签、目标关闭 / 重建、Wave 重启 / 升级、上下文缺失 / 失效、列表部分失败、旧行竞争、应用级返回。验证时记录实际窗口 / 标签 / block 与结果，不能只看命令退出码。

原生编译、系统岛点击、触摸及多屏前台行为仍未验证。T012 的源码与帮助核对不替代这些验收，也不改变 27.3 统一验证安排。

## 只读复核入口

在本机同架构、同版本安装路径下，可以重复以下命令；其他版本先从应用包确定实际 helper：

```bash
TIDE_WSH='/Applications/Wave.app/Contents/Resources/app.asar.unpacked/dist/bin/wsh-0.14.5-darwin.arm64'
"$TIDE_WSH" version
"$TIDE_WSH" focusblock --help
"$TIDE_WSH" blocks list --help
"$TIDE_WSH" workspace --help
```

本轮帮助及普通 version 退出 0；剥离 Wave 上下文后 `version --json` 退出 1，固定提示 WAVETERM_JWT not found。未执行任何可能改变当前焦点 / 工作区的命令，未读取真实 block / workspace 列表。没有为文档修改补写镜像单测；现有共享回归和工程结构按项目 CI 独立记录。

## 固定源码引用

- [S01](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/cmd/wsh/cmd/wshcmd-focusblock.go#L15) `cmd/wsh/cmd/wshcmd-focusblock.go:15` — focusblock 的入口、TABID 路由与 2 秒超时。
- [S02](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/cmd/wsh/cmd/wshcmd-root.go#L85) `cmd/wsh/cmd/wshcmd-root.go:85` — JWT 认证、Unix socket 初始化和 ID 解析。
- [S03](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/frontend/app/store/tabrpcclient.ts#L95) `frontend/app/store/tabrpcclient.ts:95` — 指定标签的布局内查找和聚焦节点。
- [S04](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/cmd/wsh/cmd/wshcmd-version.go#L33) `cmd/wsh/cmd/wshcmd-version.go:33` — 普通 version 与需要 RPC 的 JSON / verbose 分支。
- [S05](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/cmd/wsh/cmd/wshcmd-blocks.go#L30) `cmd/wsh/cmd/wshcmd-blocks.go:30` — CLI 分屏列表的字段、过滤、部分失败及空结果。
- [S06](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/cmd/wsh/cmd/wshcmd-workspace.go#L23) `cmd/wsh/cmd/wshcmd-workspace.go:23` — workspace 只有 list；错误退出与双流输出边界。
- [S07](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/wshrpc/wshrpctypes.go#L229) `pkg/wshrpc/wshrpctypes.go:229` — RPC 上下文；同文件 490 行定义带 windowid 的后端列表。
- [S08](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/wshutil/wshrouter_controlimpl.go#L90) `pkg/wshutil/wshrouter_controlimpl.go:90` — 服务端 Authenticate 验证并绑定路由。
- [S09](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/wavejwt/wavejwt.go#L90) `pkg/wavejwt/wavejwt.go:90` — 签名算法与 token 验证，不是只解码 JWT 即授权。
- [S10](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/emain/emain-wsh.ts#L46) `emain/emain-wsh.ts:46` — 内部 focuswindow，可为持久窗口创建 BrowserWindow。
- [S11](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/emain/emain-window.ts#L393) `emain/emain-window.ts:393` — 内部标签切换；同文件 725 行为 Electron IPC 入口。
- [S12](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/service/workspaceservice/workspaceservice.go#L173) `pkg/service/workspaceservice/workspaceservice.go:173` — 内部 SetActiveTab 服务。
- [S13](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/authkey/authkey.go#L17) `pkg/authkey/authkey.go:17` — HTTP 服务使用 X-AuthKey 验证。
- [S14](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/emain/authkey.ts#L9) `emain/authkey.ts:9` — Electron 生成并注入运行时 AuthKey。
- [S15](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/emain/emain.ts#L389) `emain/emain.ts:389` — 再次启动进程的处理为创建新窗口，不是 ID 定位契约。
- [S16](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/waveobj/waveobj.go#L80) `pkg/waveobj/waveobj.go:80` — 完整 ORef 的类型与 UUID 校验。
- [S17](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/docs/docs/wsh-reference.mdx#L979) `docs/docs/wsh-reference.mdx:979` — 官方 blocks list 命令文档。
- [S18](https://github.com/wavetermdev/waveterm/blob/97e560027f494d20fed347b2d6b72b6bcb3e50e0/pkg/web/web.go#L411) `pkg/web/web.go:411` — HTTP 认证包装；同文件 459 行注册内部 service 入口。
