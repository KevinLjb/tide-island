# 本机运行资源验证

V011 分别记录空闲、持续开发、多会话突发及能耗结果。短时进程采样不替代完整负载或系统能耗验收；当前只有下面的空闲基线。

## 2026-11-18 beta 空闲基线

源码 `e9ce743386d38942cd2a97bf084d2bf11319637f`，arm64 Release、ad hoc 签名，安装于 `/Applications/TideIsland.app`。系统 macOS 27.3 beta 2（26C5047e），Xcode 27.3 beta 2（27C5035i），SDK 27.3。应用启动后空闲；未安装真实 Codex hooks / notify，也未运行 Wave 操作或原生活动。离线 diagnostics 接受事件数为 0，仍明确 runtimeStateAssessed 为 false，不能据此推断原生列表的实际显示。

使用本机 SDK 的 `proc_pid_rusage` / rusage_info_v4，每秒采样一次，共 121 个样本，单调时钟覆盖 120.715 秒。每次核对可执行文件路径和进程启动时间，拒绝 PID 被重用或进程退出；采样器与数据保留在本机验证证据目录，不进入产品包。

| 指标 | 本次观察 |
| --- | --- |
| CPU 时间增量 | 0.009084 秒 |
| CPU 占一个核心的平均比例 | 约 0.0075% |
| resident 内存峰值 | 90.55 MiB |
| physical footprint 峰值 | 31.41 MiB |
| 两项内存的首末增量 | 均为 0 字节 |
| package idle wakeups 增量 | 0 |
| interrupt wakeups 增量 | 4 |
| 进程磁盘读 / 写增量 | 均为 0 字节 |
| logical writes 增量 | 0 字节 |

CPU 原始计数先按本机 mach_timebase_info 的 125 / 3 转成纳秒，再按采样实际时长计算一个核心的比例。本机另外用独立的 0.3 秒计算循环，与 POSIX getrusage 的秒 / 微秒字段校准；两种 CPU 时间的比值为 1.000035。不能直接把原始计数当作纳秒，也不能把采样器自身的 CPU 计入目标应用。相关 SDK 结构见 [Apple rusage_info_v4](https://developer.apple.com/documentation/kernel/rusage_info_v4)；这些是进程计数，不能换算为电池能耗或等同于系统面板的能耗评分。

证据包括 idle-120-process-samples.jsonl、cpu-time-calibration.json、idle-baseline.json、原始采样器源码和本机编译结果。共享 CI、原生双配置与包来源见[原生验收入口](native-validation.md)和[开发进度](development-progress.md)。

本次没有观察到持续的空闲 CPU 或磁盘写入增长。应用前台未由自动测试确认；未验证可见岛、持续开发、真实多会话突发、内外屏、睡眠恢复或电池条件。V011 保留这些后续项目，当前不做全场景低功耗承诺。
