# 统一播放恢复协调器(PlaybackRecoveryCoordinator)设计

> 状态:设计 v1 · 2026-06-03
> 范围:三端(iOS / macOS / tvOS)直播播放的「卡顿检测 + 自动恢复」链路
> 目标:修掉「切到正常源仍无限刷新」的确定性 bug,并把散落在 6 处的恢复逻辑收成一个可测的状态机。
> **Supersede**:本文取代 `PlaybackResilienceRoadmap.md` §3 的 ⑥(放弃合并)与 §0.1 的「HLS 默认走 KSAVPlayer」内核结论(见 §1)。

---

## 0. 现状盘点

### 0.1 三套恢复机制,散在 6 个地方

| 机制 | 位置 | 阈值 | 性质 |
|---|---|---|---|
| 起播 watchdog | `PlayerContainerView.swift:678`(iOS)/ macOS `RoomPlayerView` / tvOS `DetailPlayerView` —— **三端 View 各一份**,状态在 `@State watchdogRetried` | 20s | 一次性首帧超时 |
| 零吞吐 stall watchdog | `RoomInfoViewModel.swift:928` —— **三端 VM 各一份** | 8s | 持续采样 bytes+playhead |
| managed retry | `RoomInfoViewModel.swift:794` | 退避 1/2/4s | finish(error) 路径 |

三端 `RoomInfoViewModel` 各 ~1070 行、各 48 处 watchdog 相关代码,基本是三份拷贝;起播 watchdog 又在三端 View 各写一份。**同一套恢复逻辑活在 6 处,且每端内部被 View / VM 切成两半。**

### 0.2 两个会导致「无限刷新」的确定性 bug

**Bug A — 起播 watchdog 没有跨 refresh 的全局熔断。**
`runStartupWatchdog` 用 `watchdogRetried` 实现「每条 URL 最多重试 1 次」(`PlayerContainerView.swift:681-686`)。但 `refreshPlayback()`→`loadPlayURL(force:)` 对带 token 的源**每次生成新 URL**,`.task(id: currentPlayURL)` 重跑 → `watchdogRetried` 复位 → 重新武装。
→ 「每 URL 一枪」在 token 滚动下 = **无上限**。只要源起播慢于 20s 或 `bytesRead` 不走字,就每 20s 刷一次,无限循环。**用户手动切到正常源也救不了**:切源 = 新 URL = 又武装一次。

**Bug B — stall watchdog 的熔断预算被 readyToPlay 复位。**
`attemptStallRecovery` 设了 `maxPlaybackRetries / 60s` 预算(`RoomInfoViewModel.swift:986`),但 `player(layer:state:)` 在每次 `.readyToPlay`/`.bufferFinished` 调 `resetPlaybackRetryBudget()`(`:744`)。
→ 流只要短暂到达过 readyToPlay 就把预算清零 → watchdog 8s 后又误判 → 刷新 → 又 readyToPlay → 预算又清零。**熔断器被自己废掉,变成无限刷。**

### 0.3 共性根因 — 判活信号不可靠

两套 watchdog 都单押 `dynamicInfo.bytesRead`(+ stall 加 playhead)。代码自己的注释已承认(`RoomInfoViewModel.swift:930-932`):`bytesRead` 仅在分片边界(4–10s)跳变、`currentPlaybackTime` 在部分直播流推进不稳。stall 的 8s 阈值 **< 单个 HLS 分片时长**,大分片正常流必被误判。KSAVPlayer 路径已被整段豁免(`:937`),但 KSMEPlayer 主路仍留着误判面。

---

## 1. 内核策略(先定调,supersede 旧 roadmap)

经确认:**KSMEPlayer 实战表现优于 AVPlayer,AVPlayer 仅在 LL-HLS 占优**。与最近 commit 一致:

- 低延迟 HLS(LL-HLS / 多档位 master)→ AVPlayer 主路,KSME 兜底(`RoomPlaybackResolver` 已实现,commit `24ecad4`)。
- 其余直播 HLS / FLV / DASH → **KSMEPlayer 主路**(commit `4cecd09`)。

推论:**watchdog 是承重墙,不能砍** —— 当家的 FFmpeg 路径就是有「静默卡死不冒泡 error」的毛病,这正是 watchdog 的存在理由。所以方向是**把它修对、收口**,而非用 AVPlayer 绕开。这条推翻了旧 roadmap §0.1「HLS 默认走 KSAVPlayer」的结论。

---

## 2. 是否整体重写:是(只重写恢复层,不碰播放引擎)

**判断:重写恢复层为一个协调器,放 `AngelLiveCore` 共享。** 理由:
- 缺陷是结构性的 —— 起播状态锁在 View `@State`、VM 够不着,所以两套 watchdog 无法共享熔断;不统一所有权,Bug A/B 修不干净。
- 打补丁 = 改 6 处同样的脆弱修复,必然漂移(这本身就是维护痛点的现场)。
- 6 处塌成 1 个组件,**同时**解决无限刷 bug + 三端三份的去重。

**边界**:重写的是**恢复层**;播放引擎(`KSCorePlayerView` / 内核选择 / `RoomPlaybackResolver`)原封不动。

**澄清旧 ⑥ 的放弃理由**:旧 roadmap 否决合并,理由是「三端 VM diff 不只 watchdog,抽 protocol 成本大」。但那混淆了「合并 watchdog」与「合并 VM / 抽 VM protocol」。本协调器是**自包含状态机**:VM 只是持有它、喂事件、读决策,**VM 不需要 conform 任何 protocol**,所以 ⑥ 的成本理由不成立。

---

## 3. 设计

### 3.1 接口(事件进,决策出)

```swift
@MainActor
public final class PlaybackRecoveryCoordinator {
    public init(config: RecoveryConfig, actions: RecoveryActions)

    // —— View / VM 往里喂的事件 ——
    public func episodeChanged(streamKey: String)   // 进入直播间 / 切源 / 切 CDN(token 滚动不算新 episode)
    public func urlChanged(URL)                      // 实际播放 URL 变化(可能只是 token 刷新)
    public func stateChanged(KSPlayerState)
    public func sample(bytesRead: Int64, playhead: TimeInterval, buffered: TimeInterval, isPlaying: Bool)
    public func finished(error: Error?)

    public private(set) var phase: RecoveryPhase     // 供 UI 显示(连接中/重连中/已降级/失败)
}

// 协调器要执行的动作,由 VM 注入(协调器不直接依赖 VM)
public struct RecoveryActions {
    var refreshSameURL: () -> Void
    var switchCDN: (_ next: Int) -> Void
    var reloadPlayArgs: () -> Void
    var kickPipeline: () -> Void          // 收编 play-pause-play 的 m3u8 hack
    var reportFailed: (_ error: Error) -> Void
}
```

### 3.2 状态机

```
healthy ──(持续零进度 > 阈值 / 起播超时)──▶ suspect
suspect ──(确认)──▶ recovering ──(动作发出)──▶ degraded
recovering ──(持续健康 N 秒)──▶ healthy        ★ 唯一能清熔断的转移
degraded ──(熔断预算用尽)──▶ failed ──▶ reportFailed
```

### 3.3 ★ 熔断 keyed on「逻辑会话」,不是 URL(修 Bug A)

- 熔断计数器挂在 `streamKey`(roomId + 选定档位)上,**token 滚动产生的新 URL 属于同一会话**,refresh 不重置计数。
- 起播超时收编进协调器:不再用 View 的 `@State watchdogRetried`(那是按 URL 身份复位的根源),改由协调器按会话记次。
- 用户手动切源 = 新 `streamKey` = 干净计数(符合预期);自动 refresh = 同会话 = 累加 → 到上限走 `failed`,不再无限。

### 3.4 ★ 预算只在「持续健康 N 秒」后清零(修 Bug B)

- 删除「`.readyToPlay` 即 `resetPlaybackRetryBudget()`」(`RoomInfoViewModel.swift:744`)。
- 改为:`recovering`/`degraded` → 必须观测到**连续 N 秒(建议 15–30s)playhead 单调推进**才回 `healthy` 并清熔断。
- 短暂 readyToPlay 不再清零 → 抖动流会消耗预算 → 到上限 `failed`,循环有终点。

### 3.5 判活信号(修共性根因)

- 弃用「单押 bytesRead」。健康判定 = **playhead 单调推进 OR (buffered 非空 AND isPlaying)**;两者皆死才算 stall。
- stall 阈值抬到 **> 最大分片时长 × N**(建议按最近观测分片间隔自适应,下限远大于现 8s)。
- KSAVPlayer 路径维持豁免(它有清晰 `.failed`,走 fallback 链);协调器主要服务 KSME 主路。

### 3.6 升级阶梯(degraded 内,OPEN 后不自动滚动复位)

```
kickPipeline(play-pause)  →  refreshSameURL  →  switchCDN(next)  →  reloadPlayArgs  →  failed/reportFailed
```
- `kickPipeline` 把散落的 m3u8「播放暂停播放」hack 收编成阶梯第一档,显式、可观测。
- CDN 选择沿用 `nextCdnIndex()` 逻辑;无可切则 refresh / reloadPlayArgs。

### 3.7 UI 反馈

`phase` 暴露给 View 渲染文字(对接旧 roadmap ② 的 `PlaybackPhase` 想法):连接中 / 重连中(第 n/N 次)/ 正在切线路 / 已降级 / 失败 + 原因。让用户感知系统在主动处理。

---

## 4. 接入三端

1. 先 iOS 跑通:VM 持有 `PlaybackRecoveryCoordinator`,把现有 `KSPlayerLayerDelegate` 回调与 `PlayerContainerView` 的采样改为喂事件;删除 VM 内 `stallWatchdog*`/`playbackRetry*`/`attemptStallRecovery`/`attemptManagedPlaybackRetry`,删除 View 的 `runStartupWatchdog`/`watchdogRetried`。
2. macOS / tvOS 平推(同协调器,各自 VM/View 接线)。
3. 常量沿用/合并旧 roadmap §2 的 `PlaybackTuning` 命名空间。

**净删除**:6 处旧逻辑 → 1 个协调器 + 三端薄接线。

---

## 5. 可测试性(这次必须补)

协调器是近乎纯函数的状态机,用合成事件序列单测:
- **回归 Bug A**:`episodeChanged` 后反复 `urlChanged`(模拟 token 滚动)+ 持续零进度 → 断言到上限进入 `failed`,而非无限发 `refresh`。
- **回归 Bug B**:`readyToPlay` 与零进度交替 → 断言预算被消耗、最终 `failed`,而非被 readyToPlay 清零。
- **健康恢复**:动作后持续 N 秒推进 → 断言回 `healthy` 且熔断清零。
- **大分片正常流**:分片边界零字节但 playhead 推进 → 断言**不**触发恢复。

> 这两个 bug 一直没被抓住,正因为恢复逻辑散在 View/VM、无法单测。收成协调器后才测得了。

---

## 6. 落地顺序与估时

| # | 项 | 估时 |
|---|---|---|
| 1 | `PlaybackRecoveryCoordinator` + `RecoveryConfig/Actions` + 单测 | 2d |
| 2 | iOS 接入(删 6 处旧逻辑中 iOS 那份,接线) | 1.5d |
| 3 | `phase` → UI 文字反馈 | 0.5d |
| 4 | macOS / tvOS 平推 | 1.5d |

**总估时**:约 1 周(单人)。可先交付 1+2(iOS 验证无限刷被根治)再平推。

**止血选项**:若想先压住线上无限刷,可先只做 §3.3(起播按会话记次)+ §3.4(删 readyToPlay 清零),几行即见效,再做完整协调器。

---

## 7. 不在本设计内

- 播放器 UI / 控制栏 / 弹幕重设计
- CDN 偏好学习(见旧 roadmap ⑤)、PlaybackTimeline(⑨)—— 可在协调器落地后复用其事件流另行接入
- 内核选择策略本身(已定,见 §1)
