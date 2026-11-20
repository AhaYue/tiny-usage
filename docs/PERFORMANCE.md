# 性能记录

2026-11-20 在本机（Apple Silicon M4，macOS 26）对 1.3.0 release arm64 构建做的短时测量，原始数据在 [`runtime/`](runtime/)。故障经过和定位过程见[事故复盘](POSTMORTEM.md)，这里只留数字。

> 这是几十秒到几分钟的单次采样，只能说明“当时没有明显问题”，不代表长期稳定性，也不是不同机器之间的可比基准。

## 1.3.0

2026-11-20 测量，面板关闭、正常取数：

| 场景 | 物理内存 (footprint) | 峰值 | 平均 CPU（单核 %） | 原始文件 |
|---|---|---|---|---|
| 空闲，90 秒 | 19.9 MiB | 21.7 MiB | 0.31% | `runtime/performance-1.3.0-idle.json` |
| 空闲，180 秒 | 19.9 MiB | 21.7 MiB | **0.22%** | `runtime/performance-1.3.0-idle-2.json` |

## 菜单栏重绘的教训

1.1.2–1.2.0 在空闲时持续占满约一个 CPU 核心（M4 实测约 97%），1.3.0 修复。改动是让 `renderTitle()` 先比较绘制输入摘要（`MenuBarRenderer.renderKey`），摘要未变就不重绘；分钟计入了摘要，所以时间游标仍每分钟移动一次。修复后同一构建空闲 60 秒累计 CPU 约 0.1 s。根因、对照实验和时间线见[事故复盘](POSTMORTEM.md)，回归测试见 `testRenderKeyChangesOnlyWhenTheImageWould`。

## 怎么读这些数字

- **footprint 和 RSS 不是一回事。** `runtime/performance-1.3.0-idle*.json` 记录的是 `ps` 的 RSS（约 80 MiB），其中包含与其他进程共享的系统框架页。判断这个 App 自己占多少内存，看 `vmmap -summary` 的 *Physical footprint*（约 20 MiB），这也是活动监视器“内存”列的口径。

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
