# 性能记录

2026-11-13 在本机（Apple Silicon，macOS 26）对 `dist/Tiny Usage.app` 的 release arm64 构建做的短时测量。原始数据在 [`runtime/`](runtime/)。

> 这些都是几十秒的单次采样，只能说明“当时没有明显问题”，不代表长期稳定性，也不是不同机器之间的可比基准。

## 结果

| 场景 | 物理内存 (footprint) | 峰值 | 平均 CPU（单核 %） | 原始文件 |
|---|---|---|---|---|
| 演示模式：打开面板、切设置、关闭、重开后 | 30.8 MiB | 41.1 MiB | 单次采样 0.0% | `memory-demo.txt`、`smoke-result.json` |
| 正常模式：刚启动，未强制关闭面板 | 32.6 MiB | 34.4 MiB | 3.19%（30 s，含首次取数） | `memory-normal.txt`、`performance-normal.json` |
| 正常模式：面板已关闭，空闲 | 32.5 MiB | 34.4 MiB | **0.17%**（30 s） | `memory-idle.txt`、`performance-idle.json` |
| 同一进程运行约 24 分钟后 | 33.7 MiB | 35.1 MiB | 累计 6.6 s CPU，约 0.47%（含前面的交互与取数） | 手动 `ps` / `vmmap` 读数 |

## 1.1.2–1.2.0 的菜单栏重绘失控

1.1.2 加入菜单栏配色后，App 在菜单栏上会持续占满一个 CPU 核心（本机 M4 实测空闲时约 97%），运行越久越热；1.2.0 同样受影响，1.3.0 修复。原因是同一次改动为"低调"配色引入的 `.labelColor` 让图标依赖外观，于是加了状态栏按钮的 `effectiveAppearance` 订阅：`renderTitle()` 给按钮换图会让按钮重新求值外观，发布者于是再次回调 `renderTitle()`，形成自激循环。逐项关闭订阅做对照后确认：只留这个订阅即复现，只留 `NSApp` 的那个则不复现。`sample` 采样显示一半以上的样本停在 `renderTitle()` 的 CoreText 文字测量上。

修复是在 `renderTitle()` 里比较绘制输入的摘要（`MenuBarRenderer.renderKey`：各服务的百分比/重置时间/可用性、样式、显示口径、颜色、外观名、分钟、宽度预算），摘要未变就不重绘。时间游标每分钟移动一次，所以分钟计入了摘要。

修复后同一构建空闲 60 秒累计 CPU 约 0.1 s（`ps` 读数 0.0%），RSS 稳定在约 77 MiB。回归测试见 `testRenderKeyChangesOnlyWhenTheImageWould`。

## 1.3.0 复测

2026-11-20 在同一台 M4 上对 1.3.0 release 构建复测，面板关闭、正常取数：

| 场景 | 物理内存 (footprint) | 峰值 | 平均 CPU（单核 %） | 原始文件 |
|---|---|---|---|---|
| 空闲，90 秒 | 19.9 MiB | 21.7 MiB | 0.31% | `runtime/performance-1.3.0-idle.json` |
| 空闲，180 秒 | 19.9 MiB | 21.7 MiB | **0.22%** | `runtime/performance-1.3.0-idle-2.json` |

内存比 2026-11-13 那组低（32.5 MiB → 19.9 MiB）：那一组测的是集成 Sparkle 之前的构建。两组都只是短时采样，不代表长期走势。

上表测量于加入 Sparkle 之前的构建（当时包体积 9.4 MiB，无第三方动态库，应用名还是 AY Usage）。1.0.0 的包体积约 3.5 MiB（DMG 约 1 MB），内含 Sparkle.framework；内存和 CPU 尚未在该版本上重新采样。

## 怎么读这些数字

- **footprint 和 RSS 不是一回事。** `performance-*.json` 里记录的是 `ps` 的 RSS（约 100–130 MiB），其中包含与其他进程共享的系统框架页。判断这个 App 自己占多少内存，看 `vmmap -summary` 的 *Physical footprint*（约 32 MiB），这也是活动监视器“内存”列的口径。
- **启动后那 30 秒的 3.19% CPU** 来自首次网络取数、解析和第一次绘制，RSS 也在这段时间从 101 涨到 129 MiB；之后稳定。面板关闭后的空闲段 RSS 在 130.2–130.4 MiB 之间波动，没有持续增长。
- **演示模式**只用合成数据，不联网，不读凭证；它验证的是“面板关闭后释放视图”，所以峰值（41 MiB）出现在面板打开时，关闭后回落到约 31 MiB。

## 复测方法

```sh
# 正常启动 App，关闭面板后：
pgrep -x TinyUsage
python3 -I scripts/profile.py <PID> docs/runtime/performance-idle.json   # 默认 30 秒，5 秒一次
vmmap -summary <PID> > docs/runtime/memory-idle.txt
```

`profile.py` 只读 `ps` 输出，会先确认目标进程是 `TinyUsage` 才采样。

## 没测的

- 数小时以上的长期运行、睡眠/唤醒循环后的内存走势。
- 网络失败、429 退避期间的行为（逻辑由单元测试覆盖，未做运行时采样）。
- 唤醒次数（`powermetrics` 需要 root，本次未运行）。
- Intel 机器（当前只构建 arm64）。
