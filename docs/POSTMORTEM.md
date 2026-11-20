# 事故复盘：菜单栏重绘失控（1.1.2–1.2.0）

- **状态**：已修复，1.3.0 发布
- **影响版本**：1.1.2、1.1.3、1.2.0
- **修复版本**：1.3.0
- **最后更新**：2026-11-20

## 摘要

1.1.2 为「低调」配色新增了状态栏按钮的 `effectiveAppearance` 订阅。`renderTitle()` 给按钮赋新图片会让按钮重新求值外观，发布者因此再次回调 `renderTitle()`，形成自激循环。App 从启动起持续占满约一个 CPU 核心，运行时越长机器越热。1.3.0 在 `renderTitle()` 里加入绘制输入摘要（`MenuBarRenderer.renderKey`），摘要未变即跳过重绘，问题消除。

## 影响

- 1.1.2–1.2.0 的每个实例从启动起约 97% 单核 CPU（M4 实测），面板关闭也不会停。
- 用户可感知的后果是发热、耗电和风扇声；功能、数据和授权不受影响，没有崩溃或数据损坏。
- 用户反馈的表述是「运行一天后电脑发热」，实际不是运行久了才出现，而是启动即开始，只是短时间内不易察觉。

## 时间线

| 日期 | 事件 |
| --- | --- |
| 2026-11-16 | 1.1.2 发布（`d3af2de`），同时引入按钮外观订阅 |
| 2026-11-16 | 1.1.3 发布（`bbb3d57`），设置页调整，问题未变 |
| 2026-11-18 | 1.2.0 发布（`e9de65c`），移除悬停提示，问题未变 |
| 2026-11-20 | 用户反馈发热；当天完成复现、定位、修复、发版（1.3.0，`565a129`） |

## 根因

`effectiveAppearance` 订阅本身不是问题——`NSApp` 的同名订阅在 1.1.2 之前就存在，从未引发循环。新增的是按钮这一层：

```swift
item.button?.publisher(for: \.effectiveAppearance, options: [.new])
    .sink { [weak self] _ in self?.renderTitle() }
```

1.1.2 的「低调」配色让图标颜色取自 `.labelColor`，绘制结果依赖外观。于是 `renderTitle()` 在 `button.image = image` 之后，按钮需要按菜单栏材质重新解析外观并发布变化，订阅回调 `renderTitle()`，又一次赋图。循环没有止点，重绘频率远高于 60 秒定时器。

`sample` 采样时一半以上的样本停在 `renderTitle()` 内部的 CoreText 文字测量（`NSAttributedString.size()`）上，与这个推断一致。

## 定位过程

逐项关闭订阅、构建后实测空闲 CPU：

| 改动 | 空闲 CPU |
| --- | --- |
| 两个外观订阅都关闭 | 0.0% |
| 只关按钮的订阅 | 0.0% |
| 只关 `NSApp` 的订阅 | 约 98% |
| 原样（1.2.0 安装版） | 约 97% |

只保留按钮订阅即可复现，只保留 `NSApp` 订阅则不复现，把循环定位到按钮外观这一层。release 构建已去符号，`atos` 无法还原采样栈，结论来自上述对照实验而非符号解析。

## 为什么没被发现

- 单元测试覆盖的是绘制结果和取值逻辑，没有覆盖「一次重绘会不会引发下一次重绘」这类运行时反馈。
- 仓库里有 `scripts/profile.py`，但发布流程没有强制执行空闲采样；97% 的空闲 CPU 用 30 秒采样就能看出。
- 开发时常开着面板、频繁交互，菜单栏附近的异常开销不容易被注意到。

## 修复

`renderTitle()` 在绘制前计算输入摘要，与上次相同则直接返回：

```swift
let key = MenuBarRenderer.renderKey(services: services, style: style, remaining: remaining,
                                    colors: colors, appearanceName: button.effectiveAppearance.name.rawValue,
                                    minute: Int(now.timeIntervalSince1970 / 60), budget: budget)
guard key != lastRenderKey else { return }
lastRenderKey = key
```

摘要包含各服务的百分比、重置时间、可用性与陈旧标记，以及样式、显示口径、颜色、外观名、分钟和宽度预算。分钟在摘要里，因为时间游标每分钟移动一次。字符串比较的开销远低于一次 CoreText 排版。

订阅被保留而不是删除：菜单栏材质变化时图标颜色仍需更新，守卫让它只在新外观真正改变绘制结果时重绘。

## 验证

- 回归测试 `testRenderKeyChangesOnlyWhenTheImageWould`：输入不变时摘要不变；百分比、重置时间、陈旧标记、服务数量、样式、显示口径、外观名、分钟、宽度预算、颜色任一变化都必须改变摘要。故意把摘要实现改坏后测试确实失败。
- 修复后同一构建空闲 60 秒累计 CPU 约 0.1 秒（`ps` 读数 0.0%）。
- 1.3.0 发布构建复测：90 秒 0.31%、180 秒 0.22%（单核），物理内存 19.9 MiB，峰值 21.7 MiB。数据见 [`runtime/`](runtime/) 与 [性能记录](PERFORMANCE.md)。
- 全量测试 176 个通过；维护者本机 Homebrew 从 1.2.0 升级到 1.3.0 后空闲 CPU 为 0.0%。

## 教训与跟进

**教训**

- 任何「在响应某个通知时修改可能再次触发该通知的状态」的代码，都要先证明循环会收敛，而不是假设它不会。
- 性能问题属于功能缺陷。发布前应把空闲采样当作和测试同等的一步，而不是出问题后的调查手段。

**跟进项**

- 发布前对 release 构建执行一次 `python3 -I scripts/profile.py <PID> docs/runtime/<版本>-idle.json --seconds 30`，空闲 CPU 明显高于 1% 就不发。
- 长期运行、睡眠唤醒后的走势仍未采样（见[性能记录](PERFORMANCE.md)的「没测的」），需要时再补。
