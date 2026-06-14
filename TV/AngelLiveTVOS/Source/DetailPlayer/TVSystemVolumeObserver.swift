//
//  TVSystemVolumeObserver.swift
//  AngelLiveTVOS
//
//  监听 AVAudioSession.outputVolume(tvOS 9.0+ 官方 KVO 支持)。
//  触发条件:音频路由经 Apple TV 自身控制(HomePod / AirPods / AirPlay 2)。
//  HDMI-CEC 让电视自管音量时,系统不会回传给 App,这是平台限制。
//

import Foundation
import AVFoundation
import Combine
import AngelLiveCore

@MainActor
final class TVSystemVolumeObserver: ObservableObject {

    /// 当前系统输出音量(0.0 - 1.0)
    @Published private(set) var volume: Float

    /// 每次音量变化都会更新的标识(用 .onChange 监听这个值即可触发 UI 反馈)
    @Published private(set) var changeTick: Int = 0

    /// 是否已收到过非 .initial 的真实变更回调(可用于诊断订阅是否生效)
    @Published private(set) var hasReceivedRealChange: Bool = false

    private var observation: NSKeyValueObservation?
    private let session = AVAudioSession.sharedInstance()

    init() {
        let initial = session.outputVolume
        self.volume = initial
        Logger.debug("[VolumeHUD] observer init, initial outputVolume=\(initial)", category: .ui)
        installObservation()
    }

    deinit {
        observation?.invalidate()
        Logger.debug("[VolumeHUD] observer deinit", category: .ui)
    }

    private func installObservation() {
        // 显式 options:[.new] —— 不要 .initial,避免误把订阅时的快照当成"用户调音量"
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.handle(newValue: newValue)
            }
        }
        Logger.debug("[VolumeHUD] KVO observation installed on AVAudioSession.outputVolume", category: .ui)
    }

    private func handle(newValue: Float) {
        let clamped = max(0.0, min(1.0, newValue))
        let previous = volume
        volume = clamped
        hasReceivedRealChange = true
        changeTick &+= 1
        Logger.debug("[VolumeHUD] outputVolume \(previous) -> \(clamped) tick=\(changeTick)", category: .ui)
    }
}
