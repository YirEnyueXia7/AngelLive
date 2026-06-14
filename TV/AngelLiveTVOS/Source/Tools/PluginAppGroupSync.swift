//
//  PluginAppGroupSync.swift
//  AngelLiveTVOS
//
//  将主 App 沙盒中的插件同步到 App Group 共享容器，
//  供 TopShelf 扩展访问。
//

import Foundation
import AngelLiveCore

enum PluginAppGroupSync {

    static let appGroupIdentifier = "group.dev.idog.angellivetvos"

    /// 将主 App 的插件和状态文件同步到 App Group 容器。
    /// 直接读取 LiveParsePlugins.shared.storage 的实际路径（可能是 Application Support 或 Caches）。
    /// 采用全量覆盖策略：删除旧的 App Group 插件目录，整体复制新的。
    static func syncToAppGroup() {
        let fm = FileManager.default

        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            Logger.warning("[PluginSync] App Group container not available, skipping sync.", category: .sync)
            return
        }

        let sourceLiveParseDir = LiveParsePlugins.shared.storage.baseDirectory
        let sourcePluginsDir = sourceLiveParseDir.appendingPathComponent("plugins", isDirectory: true)

        guard fm.fileExists(atPath: sourcePluginsDir.path) else {
            Logger.debug("[PluginSync] No plugins directory at \(sourceLiveParseDir.path), nothing to sync.", category: .sync)
            return
        }

        let destLiveParseDir = containerURL.appendingPathComponent("LiveParse", isDirectory: true)
        let destPluginsDir = destLiveParseDir.appendingPathComponent("plugins", isDirectory: true)

        do {
            // 确保目标父目录存在
            try fm.createDirectory(at: destLiveParseDir, withIntermediateDirectories: true)

            // 同步 plugins 目录（整体替换）
            if fm.fileExists(atPath: destPluginsDir.path) {
                try fm.removeItem(at: destPluginsDir)
            }
            try fm.copyItem(at: sourcePluginsDir, to: destPluginsDir)

            // 同步 state.json
            let sourceState = sourceLiveParseDir.appendingPathComponent("state.json")
            let destState = destLiveParseDir.appendingPathComponent("state.json")
            if fm.fileExists(atPath: sourceState.path) {
                if fm.fileExists(atPath: destState.path) {
                    try fm.removeItem(at: destState)
                }
                try fm.copyItem(at: sourceState, to: destState)
            }

            Logger.debug("[PluginSync] Successfully synced plugins to App Group container.", category: .sync)
        } catch {
            Logger.warning("[PluginSync] Sync failed: \(error)", category: .sync)
        }
    }
}
