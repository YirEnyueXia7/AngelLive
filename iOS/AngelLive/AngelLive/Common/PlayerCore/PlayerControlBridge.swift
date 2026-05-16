//
//  PlayerControlBridge.swift
//  AngelLive
//

import Foundation
import SwiftUI
import AngelLiveCore

/// 播放控制兼容层：UI 只依赖这个桥接结构，不直接依赖具体播放器内核。
struct PlayerControlBridge {
    var isPlaying: Bool
    var isBuffering: Bool
    /// 流首次加载中：URL 已就绪但尚未开始播放（initialized/preparing/readyToPlay 等阶段）。
    /// 区别于「用户主动暂停」（state == .paused），用于决定是否展示中间播放按钮 / 加载指示。
    var isInitialLoading: Bool = false
    var supportsPictureInPicture: Bool
    var togglePlayPause: () -> Void
    var refreshPlayback: () -> Void
    var togglePictureInPicture: () -> Void

    // MARK: - 画面缩放

    /// 应用画面缩放模式
    var applyScaleMode: ((VideoScaleMode) -> Void)?

    // MARK: - 控制层状态

    /// 控制层显示/隐藏
    var isMaskShow: Binding<Bool>
    /// 锁定状态（锁定后禁用所有手势和控制按钮）
    var isLocked: Binding<Bool>
}
