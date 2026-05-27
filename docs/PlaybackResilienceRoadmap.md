# 播放链路韧性改进路线图

> 状态:草案 · 2026-05-28
> 范围:三端(iOS / macOS / tvOS)直播播放链路
> 目标:把"弱网/CDN 不稳/平台兼容差"这三类常见痛点的体验降到可接受线

---

## 0. 现状盘点

### 0.1 今天补的洞

| 改动 | 文件 | 解决 |
|---|---|---|
| HLS 默认走 KSAVPlayer,KSMEPlayer 兜底 | `RoomPlaybackResolver.swift` | 部分 m3u8 直播流 KSME/FFmpeg 解析卡第一帧 |
| Startup watchdog 加 bytes 进度门 + 12s | `RoomPlayerView` / `PlayerContainerView` / `DetailPlayerView` | 弱网下"还在缓冲就被 refresh kill"的死循环 |
| URLCache 清缓存后强制刷计数 | `CacheMaintenanceService.swift` | 设置页第一次点清缓存大小不变 |
| 远程输入事件 id 化 + `.config` 合并 | `RemoteInputService.swift` 等 4 处 | 标题+URL 一起提交丢 URL / 同 URL 重复提交不触发 |

### 0.2 当前播放链路的"韧性栈"

```
┌───────────────────────��──────────────────┐
│  View 层:Startup Watchdog                │  ← 起播 12s 超时 + bytes 进度门
├──────────────────────────────────────────┤
│  ViewModel 层:Stall Watchdog             │  ← 1Hz 采样 bytes+playhead,8s 触发 CDN failover/refresh
├──────────────────────────────────────────┤
│  FFmpeg 层:KSOptions.rw_timeout (9s)     │  ← I/O 级握手超时,走 .failed 错误路径
└──────────────────────────────────────────┘
+ Managed retry: maxPlaybackRetries=3 / 60s 窗口共享预算
```

三层独立,行为有重叠,跨平台还各写一遍。这是后面 ⑥ 要收的债。

---

## 1. 第一档 · 高 ROI / 1-2 次提交可落

### ① Stall watchdog 加指数退避

**问题**
`stallThresholdSeconds = 8s` 触发 → CDN failover。弱网下 8s 零吞吐其实很常见:
- TCP RTT 高时,FFmpeg 的 av_read_frame 自然空窗
- KSPlayer 缓冲打满(`loadedTime > maxBufferDuration`)→ `MEPlayerItem.send(.pause)` → bytesRead 不动但 playhead 仍消耗(已被 `stallPlayheadProgressTolerance` 覆盖)
- 服务端 keep-alive 心跳期

→ 容易把"慢但正常"误判成 stall,触发 CDN 切换浪费一次预算。

**改动**
```swift
private static let stallBackoffSeconds: [Int] = [8, 16, 32]
// playbackRetryAttempts 直接索引这个数组,超过最后一档保持 32s

let threshold = Self.stallBackoffSeconds[
    min(playbackRetryAttempts, Self.stallBackoffSeconds.count - 1)
]
if stallNoChangeTicks >= threshold { ... }
```

**预算**:`maxPlaybackRetries=3 / 60s` 不变。
**风险**:CDN 真死时第一次切换变慢(从 8s → 8s,实际不变;第二次从 8s → 16s,首次切换不影响)。
**位置**:`RoomInfoViewModel.swift`(三端,后续被 ⑥ 收编)。

---

### ② 加载状态文字反馈

**问题**
现在 loading overlay = 转圈 + "加载中"一句。watchdog 触发 refresh / CDN 切换时用户无感知 → 体感是"卡了又自动好了",或者"卡了越来越久"(看不到补救动作)。

**改动**
1. ViewModel 暴露 `playbackPhase: PlaybackPhase` 状态机:
   ```swift
   enum PlaybackPhase {
       case fetchingPlayArgs     // 拉播放地址中
       case connecting           // URL 已下发,等首字节
       case bufferingFirstFrame  // 收到字节但 player 还没进 readyToPlay
       case switchingCDN(from: String, to: String, attempt: Int)
       case retrying(attempt: Int)
       case playing
       case error(message: String)
   }
   ```

2. View 层把 `phase` 渲染成具体文字 + 副标题:
   - 连接中 · 服务器响应慢...
   - 切换线路 · 1/3
   - 重新加载 · 当前线路无响应

3. CDN failover / managed retry 触发时 toast 1.5s:
   - "网络较慢,正在切换线路"

**收益**:用户感觉系统在主动处理,不是"卡死"。客服反馈类问题应该会少。

**位置**:三端 ViewModel + Player 加载 overlay 视图。

---

### ③ 失败前先降清晰度,不直接报错

**问题**
现 stall recovery 链:
```
stall → 切 CDN → CDN 都切完 → refreshPlayback → playArgs 拉到 → 还不行 → 错误页
```

清晰度从来不变。但弱网用户的实际诉求是"流畅 > 高清"。

**改动**
recovery 链增加一档:
```
stall → 切 CDN → 都切完 → 降清晰度(下一档低)→ 重新选 CDN[0] 试一遍 →
仍不行 → refreshPlayback → 错误页
```

具体:
- `RoomPlaybackResolver` 加 `nextLowerQualityIndex(currentCdnIndex:currentQualityIndex:)`
- `attemptStallRecovery` 走完 CDN 后调它
- UI 显示 toast:"当前清晰度网络承受不住,已降到 720P"

**风险**:用户可能在意"我明明选了 1080P"。配套加一个设置:`自动降码`(默认开)。

**位置**:`RoomPlaybackResolver` + 三端 ViewModel + Settings。

---

## 2. 第二档 · 一个版本周期 / 需要基础设施

### ④ 内核选择记忆 + 平台白名单

**背景**
今天的 KSME m3u8 不兼容是全局回退到 AV 解决,但有些平台 KSME 是必须的:
- 国外 CDN(需要 rw_timeout + 自定义 UA 头)
- 需要统计面板 byteRate/networkSpeed 的场景

粒度太粗。

**改动**
1. `PlatformCapability` 加字段:
   ```swift
   enum PreferredKernel { case auto, ksavFirst, ksmeFirst, ksmeOnly }
   static func preferredKernel(for liveType: LiveType) -> PreferredKernel
   ```

2. `RoomPlaybackResolver.resolvePlan` 在决定 `playerKinds` 时查这张表先。

3. 同时本地记 `KernelObservationStore`:
   ```swift
   key: "\(liveType):\(cdnHost):\(streamFormat)"
   value: { ksavSuccessCount, ksavFailCount, ksmeSuccessCount, ksmeFailCount, lastUpdate }
   ```
   成功:首帧起播在 5s 内;失败:走到 finish 错误回调或 stall watchdog 触发。

4. resolver 决策优先级:
   - pinned by user(调试设置)
   - platform whitelist
   - 历史观测分数 > threshold
   - 默认 fallback

5. 调试设置加"手动 pin 内核 for 当前房间"。

**风险**:观测数据冷启动期不准 → 用阈值过滤,样本 < 3 时按默认走。
**位置**:`AngelLiveCore`(新模块 `PlaybackPreferenceStore`)。

---

### ⑤ CDN 偏好学习

**背景**
进直播间永远从 `CDN[0]` 起,平台返回顺序未必反映用户当前的可达性。

**改动**
1. 记 `CDNObservationStore`:
   ```swift
   key: "\(liveType):\(cdnHost)"
   value: {
       startupAttempts: Int,
       startupSuccesses: Int,
       avgFirstFrameMillis: Double,
       lastSuccessAt: Date?
   }
   ```

2. 进直播间时,`RoomInfoViewModel.applyPlayURL` 之前对 `playArgs` 重排:
   ```swift
   score = success_rate * 0.7 + (1 / max(avg_first_frame_ms, 500)) * 0.3
   ```

3. 用户手动切换的 CDN 仍优先按用户意图。

**与 ④ 的共用**:同一套持久化基础(`PlaybackPreferenceStore`),同一个观测点(KSPlayerLayerDelegate 的 state 变化)。

**风险**:用户换网络环境(家 → 4G)历史数据不再适用 → 数据带 `validityWindow=7days`,过期清掉。
**位置**:`AngelLiveCore` 同 ④。

---

### ⑥ 三个 watchdog 合并成 PlaybackResilienceController

**问题**
今天三端各写一份 startup watchdog,stall watchdog 也是三份(虽然逻辑相同)。三层独立的判定容易行为重叠:
- rw_timeout 已经 9s 触发了一次,startup watchdog 还在 sleep
- stall watchdog 切了 CDN,managed retry 也同时排队 → 之前已经有"必须 cancel managed retry"的兜底,但暴露了职责重叠

**改动**
1. 新建 `PlaybackResilienceController`(放 `AngelLiveCore`,跨平台):
   ```swift
   actor PlaybackResilienceController {
       weak var playerCoordinator: KSVideoPlayerCoordinatorProtocol?
       weak var viewModel: PlaybackHostProtocol?

       func attach(coordinator:..., viewModel:...)
       func detach()
       func observe(state: KSPlayerState)
       func notifyURLChanged(_ url: URL)

       // 内部:统管 startup / stall / 退避 / 预算
   }
   ```

2. 三端 View 层只做:
   ```swift
   .task(id: url) { controller.notifyURLChanged(url) }
   .onChange(of: coordinator.state) { controller.observe(state: $0) }
   ```

3. 现有的 `runStartupWatchdog` / `restartStallWatchdog` / `attemptStallRecovery` / `attemptManagedPlaybackRetry` 全部撤掉,迁移到 Controller。

4. 抽两个协议跨平台共享:`KSVideoPlayerCoordinatorProtocol`(已经隐式存在)、`PlaybackHostProtocol`(暴露 refreshPlayback / changePlayUrl / nextCdnIndex 给 Controller 回调)。

**收益**
- 三端只有一份代码
- 行为统一,容易调参
- 调参集中,测试也好写

**风险**:大手术,需要灰度验证。建议拆两步:
- step 1:抽 Controller,只接管 startup watchdog
- step 2:把 stall watchdog 收编进来

**位置**:`Shared/AngelLiveCore/Sources/AngelLiveCore/Playback/PlaybackResilienceController.swift`(新文件)。

---

## 3. 第三档 · 长期 / 需要架构准备

### ⑦ 网络质量探针 + 自适应清晰度

**思路**
进直播间瞬间,对 playArgs 里的每个 CDN(最多前 3 个)异步发一个 HEAD 或前 64KB 的 GET 探针:
- 测 RTT、首字节延迟、初始吞吐
- 用结果排序 CDN(覆盖 ⑤ 的冷启动场景)
- 根据吞吐选最高能扛的清晰度

**收益**
- 替换"用默认清晰度起播了再说"
- 海外用户/弱 4G 用户首帧体验明显改善

**风险/复杂度**
- 探针流量(每个 CDN ~64KB)需告知用户(隐私 + 流量提示)
- 探针的网络条件 ≠ 实际播放时的网络条件,有偏差
- 各平台 CDN 是否允许 HEAD 请求需 case-by-case 测

**位置**:新增 `Playback/NetworkProbeService.swift`。

---

### ⑧ 预热(Pre-fetch playArgs)

**思路**
房间列表上 hover(macOS)/ focus(tvOS)/ long-press(iOS)> 300ms 就后台拉 playArgs,进详情页直接命中缓存。

**收益**
- 首屏少 1-2s
- tvOS 遥控停留特别明显(高频使用)

**风险**
- playArgs 通常有时效性(直播 token / 签名),缓存窗口要短(60s 内)
- 预热请求消耗服务端配额,需限流(同时最多 1-2 个 in-flight)

**位置**:`Playback/PlayArgsPrefetcher.swift`,三端 Card 视图加 hover/focus hook。

---

### ⑨ DevConsole 加 PlaybackTimeline

**思路**
DevConsole 已经有日志流。补一个时间轴视图:
- 横轴:时间(进入直播间到现在)
- 纵轴:事件类型(URL set / state change / watchdog tick / refresh / CDN switch / Managed retry / Error)
- 点击事件展开详情

**收益**
- 调参直接看曲线(比如 stall 触发时 bytes / playhead 历史)
- 用户上报问题一键导出 timeline JSON
- 内部 dogfooding 效率提升

**风险**:低,纯调试工具。
**位置**:`Shared/AngelLiveCore/.../DevConsole/PlaybackTimelineService.swift`。

---

## 4. 落地建议

### 第一波(本周可做)
**① + ② + ③** —— 互相独立,直接提升弱网体验。
- 估时:1-2 次提交,每个 2-4 小时
- 风险:低
- 收益:全用户可感

### 第二波(下个版本周期)
**④ + ⑤ + ⑥** —— ④⑤ 共用持久化层,⑥ 顺手收掉三端重复代码。
- 估时:一个迭代(2 周左右)
- 风险:中(⑥ 需要灰度)
- 收益:工程债务下降 + 海外/弱网用户体验大幅改善

### 第三波(看后续优先级)
**⑦ ⑧ ⑨** —— 工程量大,逐个评估。⑦ ROI 最高,⑧⑨ 视使用数据决定。

---

## 5. 度量

为了知道改动到底有没有用,做之前先把这几个指标埋上(可以借 Bugsnag breadcrumbs / 自建埋点):

| 指标 | 含义 | 期望方向 |
|---|---|---|
| `time_to_first_frame_ms` | URL set 到 isPlaying=true 的耗时 | 下降 |
| `watchdog_refresh_count_per_session` | 单场观看里 startup watchdog 触发 refresh 的次数 | 下降至 0-1 |
| `stall_recovery_count_per_session` | 单场观看里 stall watchdog 触发 CDN/refresh 的次数 | 下降 |
| `cdn_failover_success_rate` | failover 后 5s 内起播成功的比例 | 上升 |
| `playback_abandon_rate` | 进入详情页但 30s 内未起播就退出的比例 | 下降 |
| `kernel_first_choice_success_rate` | 主路内核(不走 fallback)直接起播的比例 | 上升至 > 95% |

后两个等 ④⑤⑥ 落了再看。

---

## 6. 不在此规划内

- 播放器 UI 重设计(控制栏 / 弹幕 / 设置面板)—— 单独议题
- 音频独立模式(audio-only fallback)—— 需求待定
- 全屏 / PiP / AirPlay 现有问题 —— 列待办,不在韧性范畴
- 弹幕通道稳定性 —— 单独议题
