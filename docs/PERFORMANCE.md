# 性能记录

2026-11-13 在本机（Apple Silicon，macOS 26）对 `dist/AY Usage.app` 的 release arm64 构建做的短时测量。原始数据在 [`runtime/`](runtime/)。

> 这些都是几十秒的单次采样，只能说明“当时没有明显问题”，不代表长期稳定性，也不是不同机器之间的可比基准。

## 结果

| 场景 | 物理内存 (footprint) | 峰值 | 平均 CPU（单核 %） | 原始文件 |
|---|---|---|---|---|
| 演示模式：打开面板、切设置、关闭、重开后 | 30.8 MiB | 41.1 MiB | 单次采样 0.0% | `memory-demo.txt`、`smoke-result.json` |
| 正常模式：刚启动，未强制关闭面板 | 32.6 MiB | 34.4 MiB | 3.19%（30 s，含首次取数） | `memory-normal.txt`、`performance-normal.json` |
| 正常模式：面板已关闭，空闲 | 32.5 MiB | 34.4 MiB | **0.17%**（30 s） | `memory-idle.txt`、`performance-idle.json` |
| 同一进程运行约 24 分钟后 | 33.7 MiB | 35.1 MiB | 累计 6.6 s CPU，约 0.47%（含前面的交互与取数） | 手动 `ps` / `vmmap` 读数 |

App 包体积 9.4 MiB，没有第三方动态库依赖。

## 怎么读这些数字

- **footprint 和 RSS 不是一回事。** `performance-*.json` 里记录的是 `ps` 的 RSS（约 100–130 MiB），其中包含与其他进程共享的系统框架页。判断这个 App 自己占多少内存，看 `vmmap -summary` 的 *Physical footprint*（约 32 MiB），这也是活动监视器“内存”列的口径。
- **启动后那 30 秒的 3.19% CPU** 来自首次网络取数、解析和第一次绘制，RSS 也在这段时间从 101 涨到 129 MiB；之后稳定。面板关闭后的空闲段 RSS 在 130.2–130.4 MiB 之间波动，没有持续增长。
- **演示模式**只用合成数据，不联网，不读凭证；它验证的是“面板关闭后释放视图”，所以峰值（41 MiB）出现在面板打开时，关闭后回落到约 31 MiB。

## 复测方法

```sh
# 正常启动 App，关闭面板后：
pgrep -x AYUsage
python3 -I scripts/profile.py <PID> docs/runtime/performance-idle.json   # 默认 30 秒，5 秒一次
vmmap -summary <PID> > docs/runtime/memory-idle.txt
```

`profile.py` 只读 `ps` 输出，会先确认目标进程是 `AYUsage` 才采样。

## 没测的

- 数小时以上的长期运行、睡眠/唤醒循环后的内存走势。
- 网络失败、429 退避期间的行为（逻辑由单元测试覆盖，未做运行时采样）。
- 唤醒次数（`powermetrics` 需要 root，本次未运行）。
- Intel 机器（当前只构建 arm64）。
