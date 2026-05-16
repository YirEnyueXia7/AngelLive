//
//  PluginSourceManager.swift
//  AngelLiveCore
//
//  管理用户添加的插件源 URL，拉取远程索引，安装插件。
//

import Foundation
import Observation

/// 单个插件的安装状态
public enum PluginInstallState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)
}

/// 带安装状态的远程插件条目
@Observable
public final class RemotePluginDisplayItem: Identifiable, @unchecked Sendable {
    public let item: LiveParseRemotePluginItem
    public var installState: PluginInstallState = .notInstalled

    public var id: String { item.pluginId }
    public var displayName: String { item.platformName ?? item.pluginId }

    public init(item: LiveParseRemotePluginItem) {
        self.item = item
    }
}

@Observable
public final class PluginSourceManager: @unchecked Sendable {

    /// 用户保存的插件源 URL 列表
    public private(set) var sourceURLs: [String] = []

    /// 当前拉取的远程插件列表
    public private(set) var remotePlugins: [RemotePluginDisplayItem] = []

    /// 各插件在订阅源中的最新版本（按 pluginId 索引）
    public private(set) var latestRemoteItemsByPluginId: [String: LiveParseRemotePluginItem] = [:]

    /// 是否正在拉取索引
    public private(set) var isFetchingIndex: Bool = false

    /// 是否正在检查更新
    public private(set) var isCheckingUpdates: Bool = false

    /// 正在更新中的插件 ID
    public private(set) var updatingPluginIds: Set<String> = []

    /// 批量安装进度：已完成数量
    public private(set) var installCompletedCount: Int = 0

    /// 批量安装进度：总数量
    public private(set) var installTotalCount: Int = 0

    /// 错误信息
    public var errorMessage: String?

    /// 每个订阅源对应的插件 ID 集合（用于删除订阅源时联动删除插件）
    private var sourcePluginIds: [String: Set<String>] = [:]

    /// 是否有插件正在安装
    public var isInstalling: Bool {
        remotePlugins.contains { $0.installState == .installing }
    }

    @ObservationIgnored
    private let sourceURLsKey = "AngelLive.PluginSource.URLs"

    @ObservationIgnored
    private let sourcePluginIdsKey = "AngelLive.PluginSource.PluginIds"

    @ObservationIgnored
    private let updater: LiveParsePluginUpdater

    /// 网络请求超时时间（秒）
    @ObservationIgnored
    private let fetchTimeoutSeconds: UInt64 = 30

    /// 安装确认请求器:由各端在 app 启动时注入。
    /// nil 时所有确认默认通过(便于单元测试或纯命令行调用)。
    @ObservationIgnored
    public var consentRequester: (any PluginInstallConsentRequesting)?

    public init() {
        self.updater = LiveParsePluginUpdater(
            storage: LiveParsePlugins.shared.storage,
            session: LiveParsePlugins.shared.session
        )
        loadSourceURLs()
        loadSourcePluginIds()
    }

    // MARK: - 插件源管理

    private func loadSourceURLs() {
        sourceURLs = UserDefaults.standard.stringArray(forKey: sourceURLsKey) ?? []
    }

    private func saveSourceURLs() {
        UserDefaults.standard.set(sourceURLs, forKey: sourceURLsKey)
        // 同步到 CloudKit
        let urls = sourceURLs
        Task {
            await PluginSourceSyncService.syncToCloudStatic(sourceURLs: urls)
        }
    }

    /// 从 UserDefaults 恢复 source→pluginId 映射,用于源不可达时仍能联动卸载插件。
    private func loadSourcePluginIds() {
        let raw = UserDefaults.standard.dictionary(forKey: sourcePluginIdsKey) as? [String: [String]] ?? [:]
        sourcePluginIds = raw.mapValues { Set($0) }
    }

    private func saveSourcePluginIds() {
        let serialized = sourcePluginIds.mapValues { Array($0) }
        UserDefaults.standard.set(serialized, forKey: sourcePluginIdsKey)
    }

    public func addSource(_ urlString: String) {
        persistSourceIfNeeded(urlString)
    }

    /// 添加用户输入的订阅源：支持 key 解析和直接 URL，只有校验成功后才会持久化并同步到 CloudKit。
    /// 返回实际添加或重新加载成功的 URL 列表。
    public func addSourceFromInput(_ input: String) async -> [String] {
        await validateAndLoadSource(input, allowDirectInput: true)
    }

    /// 仅处理 key 形式的订阅源输入。
    /// 若输入不是 key，则返回空数组，交由调用方按普通视频链接处理。
    public func addSourceWithKeyResolution(_ input: String) async -> [String] {
        await validateAndLoadSource(input, allowDirectInput: false)
    }

    private func validateAndLoadSource(_ input: String, allowDirectInput: Bool) async -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        errorMessage = nil
        await PluginSourceKeyService.shared.fetchKeys()

        let resolvedCandidates = await PluginSourceKeyService.shared.resolveKey(trimmed)
        if resolvedCandidates == nil, !allowDirectInput {
            return []
        }

        let candidates = resolvedCandidates ?? [trimmed]
        var lastError: Error?

        isFetchingIndex = true
        defer { isFetchingIndex = false }

        for candidate in candidates {
            guard let url = URL(string: candidate) else {
                lastError = URLError(.badURL)
                continue
            }

            do {
                let index = try await fetchIndexWithTimeout(url: url)

                // 索引里至少有一个 auth.required == true 的插件,才弹凭证泄露风险确认。
                // 发布器约定:只要 manifest 含 loginFlow,索引会把 auth.required 标为 true。
                let containsLoginPlugin = index.plugins.contains { $0.auth?.required == true }
                if containsLoginPlugin, let requester = consentRequester {
                    let approved = await requester.requestConsent(
                        reason: .addingSubscriptionSource(url: candidate)
                    )
                    if !approved {
                        Logger.info("User declined subscription source: \(candidate)", category: .plugin)
                        return []
                    }
                }

                persistSourceIfNeeded(candidate)
                applyFetchedIndex(index, sourceURL: candidate)
                return [candidate]
            } catch {
                lastError = error
                Logger.warning("Source validation failed for \(candidate): \(Self.detailedErrorDescription(error))", category: .plugin)
            }
        }

        if let lastError {
            errorMessage = "拉取插件索引失败: \(Self.detailedErrorDescription(lastError))"
        } else if resolvedCandidates != nil {
            errorMessage = "所有候选源地址均不可用"
        } else if allowDirectInput {
            errorMessage = "无效的 URL"
        }
        return []
    }

    private func persistSourceIfNeeded(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sourceURLs.contains(trimmed) else { return }
        sourceURLs.append(trimmed)
        sourcePluginIds[trimmed] = sourcePluginIds[trimmed] ?? Set<String>()
        saveSourceURLs()
        saveSourcePluginIds()
    }

    private func applyFetchedIndex(_ index: LiveParseRemotePluginIndex, sourceURL: String) {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        sourcePluginIds[trimmed] = Set(index.plugins.map(\.pluginId))
        saveSourcePluginIds()
        remotePlugins = index.plugins.map(makeRemoteDisplayItem)
        mergeLatestRemoteItems(index.plugins)
    }

    private func makeRemoteDisplayItem(from item: LiveParseRemotePluginItem) -> RemotePluginDisplayItem {
        let displayItem = RemotePluginDisplayItem(item: item)
        if installedVersion(for: item.pluginId) != nil {
            displayItem.installState = .installed
        }
        return displayItem
    }

    public func removeSource(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceURLs.removeAll { $0 == trimmed }
        sourcePluginIds.removeValue(forKey: trimmed)
        saveSourceURLs()
        saveSourcePluginIds()
    }

    /// 删除订阅源并移除该源对应的已安装插件
    public func removeSourceAndAssociatedPlugins(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var pluginIds = sourcePluginIds[trimmed] ?? Set<String>()
        if pluginIds.isEmpty, let url = URL(string: trimmed) {
            do {
                let index = try await fetchIndexWithTimeout(url: url)
                pluginIds = Set(index.plugins.map(\.pluginId))
            } catch {
                // 源不可达时仍然继续,后续会用其它源覆盖关系兜底
                Logger.warning(
                    "Source unreachable while removing, fallback to cached mapping: \(trimmed)",
                    category: .plugin
                )
            }
        }

        // 兜底:其它源也声明过同一个 pluginId 时,这些插件不应被卸载。
        let coveredByOtherSources = sourcePluginIds
            .filter { $0.key != trimmed }
            .values
            .reduce(into: Set<String>()) { $0.formUnion($1) }
        let pluginsToUninstall = pluginIds.subtracting(coveredByOtherSources)

        removeSource(trimmed)

        for pluginId in pluginsToUninstall {
            _ = uninstallPlugin(pluginId: pluginId)
        }
    }

    // MARK: - 拉取远程索引

    public func fetchIndex(from urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = "无效的 URL"
            return
        }

        isFetchingIndex = true
        errorMessage = nil
        defer { isFetchingIndex = false }

        do {
            let index = try await fetchIndexWithTimeout(url: url)
            applyFetchedIndex(index, sourceURL: trimmed)
        } catch {
            errorMessage = "拉取插件索引失败: \(Self.detailedErrorDescription(error))"
        }
    }

    /// 从所有订阅源检查可更新版本
    public func refreshAvailableUpdates() async {
        guard !sourceURLs.isEmpty else {
            latestRemoteItemsByPluginId = [:]
            sourcePluginIds = [:]
            saveSourcePluginIds()
            return
        }

        errorMessage = nil
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        var latest: [String: LiveParseRemotePluginItem] = [:]
        var pluginIdsBySource = sourcePluginIds.filter { sourceURLs.contains($0.key) }

        for source in sourceURLs {
            guard let url = URL(string: source) else { continue }
            do {
                let index = try await fetchIndexWithTimeout(url: url)
                pluginIdsBySource[source] = Set(index.plugins.map(\.pluginId))
                for item in index.plugins {
                    guard let existing = latest[item.pluginId] else {
                        latest[item.pluginId] = item
                        continue
                    }
                    if semverCompare(item.version, existing.version) > 0 {
                        latest[item.pluginId] = item
                    }
                }
            } catch {
                // 单个源失败不影响其它源；保留最后一次错误用于页面提示
                errorMessage = "检查更新失败: \(Self.detailedErrorDescription(error))"
            }
        }

        latestRemoteItemsByPluginId = latest
        sourcePluginIds = pluginIdsBySource
        saveSourcePluginIds()
    }

    // MARK: - 安装插件

    /// 从所有已添加的订阅源拉取索引并合并到 remotePlugins（不覆盖，按 pluginId 去重）
    public func fetchAllSourceIndexes() async {
        isFetchingIndex = true
        errorMessage = nil
        defer { isFetchingIndex = false }

        var allItems: [LiveParseRemotePluginItem] = []
        var seenPluginIds = Set<String>()

        for source in sourceURLs {
            guard let url = URL(string: source) else { continue }
            do {
                let index = try await fetchIndexWithTimeout(url: url)
                sourcePluginIds[source] = Set(index.plugins.map(\.pluginId))
                for item in index.plugins {
                    if !seenPluginIds.contains(item.pluginId) {
                        seenPluginIds.insert(item.pluginId)
                        allItems.append(item)
                    }
                }
                mergeLatestRemoteItems(index.plugins)
            } catch {
                errorMessage = "拉取插件索引失败: \(Self.detailedErrorDescription(error))"
            }
        }

        saveSourcePluginIds()
        remotePlugins = allItems.map(makeRemoteDisplayItem)
    }

    public func installPlugin(_ displayItem: RemotePluginDisplayItem) async -> Bool {
        displayItem.installState = .installing

        // manifest 落地后、smoke test 之前调用,只对真有登录的插件弹确认。
        let displayName = displayItem.displayName
        let consentHook: (@Sendable (LiveParsePluginManifest) async -> Bool)?
        if let requester = consentRequester {
            consentHook = { @Sendable manifest in
                guard manifest.requiresLogin else { return true }
                return await requester.requestConsent(
                    reason: .installingLoginPlugin(
                        pluginId: manifest.pluginId,
                        displayName: displayName
                    )
                )
            }
        } else {
            consentHook = nil
        }

        do {
            try await updater.installAndActivate(
                item: displayItem.item,
                manager: LiveParsePlugins.shared,
                afterInstallConsent: consentHook
            )
            displayItem.installState = .installed
            return true
        } catch is PluginInstallConsentError {
            Logger.info("User declined login plugin install: \(displayItem.id)", category: .plugin)
            displayItem.installState = .notInstalled
            return false
        } catch {
            Logger.error(
                error,
                message: "安装插件失败: \(displayItem.id)@\(displayItem.item.version)",
                category: .general
            )
            displayItem.installState = .failed(error.localizedDescription)
            return false
        }
    }

    /// 安装所有未安装的插件。
    ///
    /// 三阶段:
    /// 1. 根据远程索引中的 auth.required 元数据,在下载前先做一次批量登录确认;
    ///    用户取消则跳过所有登录类插件,继续安装非登录类插件;
    /// 2. 下载 + 解压用户同意安装的插件;
    /// 3. 激活已下载的插件并写 last-good。
    ///
    /// 这样把原来"安装完全部再弹登录确认"的体验前置到点击"全部安装"瞬间,
    /// 避免用户白等下载时间后才发现需要登录。
    public func installAll() async -> Int {
        let toInstall = remotePlugins.filter { $0.installState == .notInstalled }
        installTotalCount = toInstall.count
        installCompletedCount = 0
        defer {
            installTotalCount = 0
            installCompletedCount = 0
        }

        // Phase 1: 下载前先弹一次批量登录确认 — 利用索引中的 auth.required 元数据。
        // 发布器约定: 只要 manifest 含 loginFlow, 索引会把 auth.required 标为 true。
        let loginPlugins = toInstall.filter { $0.item.auth?.required == true }
        var declinedIds: Set<String> = []
        if !loginPlugins.isEmpty, let requester = consentRequester {
            let payload = loginPlugins.map {
                LoginPluginEntry(
                    pluginId: $0.item.pluginId,
                    displayName: $0.displayName
                )
            }
            let approved = await requester.requestConsent(
                reason: .installingLoginPluginsBatch(plugins: payload)
            )
            if !approved {
                Logger.info(
                    "User declined batch login plugin install: \(loginPlugins.count) plugins",
                    category: .plugin
                )
                for plugin in loginPlugins {
                    plugin.installState = .notInstalled
                    declinedIds.insert(plugin.id)
                    installCompletedCount += 1
                }
            }
        }

        struct Staged {
            let displayItem: RemotePluginDisplayItem
            let manifest: LiveParsePluginManifest
        }

        // Phase 2: 下载 + 解压用户同意的插件。
        var staged: [Staged] = []
        for plugin in toInstall where !declinedIds.contains(plugin.id) {
            plugin.installState = .installing
            do {
                let manifest = try await updater.install(item: plugin.item)
                staged.append(Staged(displayItem: plugin, manifest: manifest))
            } catch {
                Logger.error(
                    error,
                    message: "下载插件失败: \(plugin.id)@\(plugin.item.version)",
                    category: .general
                )
                plugin.installState = .failed(error.localizedDescription)
                installCompletedCount += 1
            }
        }

        // Phase 3: 激活已下载的插件
        var successCount = 0
        for entry in staged {
            do {
                try await updater.activateInstalled(
                    manifest: entry.manifest,
                    manager: LiveParsePlugins.shared
                )
                entry.displayItem.installState = .installed
                successCount += 1
            } catch {
                Logger.error(
                    error,
                    message: "激活插件失败: \(entry.manifest.pluginId)@\(entry.manifest.version)",
                    category: .general
                )
                entry.displayItem.installState = .failed(error.localizedDescription)
            }
            installCompletedCount += 1
        }

        return successCount
    }

    // MARK: - 版本与更新状态

    public func installedVersion(for pluginId: String) -> String? {
        let versions = LiveParsePlugins.shared.storage.listInstalledVersions(pluginId: pluginId)
            .map(\.lastPathComponent)
            .filter { !$0.isEmpty }
            .sorted { semverCompare($0, $1) > 0 }
        return versions.first
    }

    public func hasUpdate(for pluginId: String) -> Bool {
        guard let installedVersion = installedVersion(for: pluginId),
              let remoteVersion = latestRemoteItemsByPluginId[pluginId]?.version else {
            return false
        }
        return semverCompare(remoteVersion, installedVersion) > 0
    }

    public func latestVersion(for pluginId: String) -> String? {
        latestRemoteItemsByPluginId[pluginId]?.version
    }

    @discardableResult
    public func updatePlugin(pluginId: String) async -> Bool {
        guard let item = latestRemoteItemsByPluginId[pluginId] else { return false }
        if updatingPluginIds.contains(pluginId) { return false }

        errorMessage = nil
        updatingPluginIds.insert(pluginId)
        defer { updatingPluginIds.remove(pluginId) }

        do {
            try await updater.installAndActivate(item: item, manager: LiveParsePlugins.shared)
            if let remoteItem = remotePlugins.first(where: { $0.id == pluginId }) {
                remoteItem.installState = .installed
            }
            return true
        } catch {
            errorMessage = "更新插件失败: \(error.localizedDescription)"
            return false
        }
    }

    private func mergeLatestRemoteItems(_ items: [LiveParseRemotePluginItem]) {
        var merged = latestRemoteItemsByPluginId
        for item in items {
            guard let existing = merged[item.pluginId] else {
                merged[item.pluginId] = item
                continue
            }
            if semverCompare(item.version, existing.version) > 0 {
                merged[item.pluginId] = item
            }
        }
        latestRemoteItemsByPluginId = merged
    }

    @discardableResult
    public func uninstallPlugin(pluginId: String) -> Bool {
        let storage = LiveParsePlugins.shared.storage
        let pluginDirectory = storage.pluginDirectory(pluginId: pluginId)

        // 1. 先从内存中驱逐插件，防止卸载过程中被调用
        LiveParsePlugins.shared.evict(pluginId: pluginId)

        // 2. 先更新持久化状态（标记移除），确保即使后续步骤崩溃，
        //    重启后也不会再加载该插件
        do {
            var state = storage.loadState()
            state.plugins.removeValue(forKey: pluginId)
            try storage.saveState(state)
        } catch {
            errorMessage = "删除插件状态失败: \(error.localizedDescription)"
            Logger.error(error, message: "Failed to update state for plugin uninstall: \(pluginId)", category: .plugin)
            return false
        }

        // 3. 删除文件（状态已安全，文件删除失败不影响一致性）
        do {
            if FileManager.default.fileExists(atPath: pluginDirectory.path) {
                try FileManager.default.removeItem(at: pluginDirectory)
            }
        } catch {
            Logger.warning("Failed to delete plugin files for \(pluginId): \(error.localizedDescription)", category: .plugin)
            // 文件删除失败不视为致命错误，状态已正确更新
        }

        // 4. 刷新运行时
        try? LiveParsePlugins.shared.reload()
        PlatformCapability.invalidateCache()

        if let item = remotePlugins.first(where: { $0.id == pluginId }) {
            item.installState = .notInstalled
        }
        return true
    }

    // MARK: - Error Description Helper

    /// 将错误转为更具体的描述，方便排查问题
    static func detailedErrorDescription(_ error: Error) -> String {
        if let fetchError = error as? LiveParsePluginIndexFetchError {
            switch fetchError {
            case .nonJSONResponse(let diagnostics):
                return "返回的不是 JSON。\(responseDiagnosticsDescription(diagnostics))"
            case .decodingFailed(let diagnostics, let decodingError):
                return "\(detailedDecodingErrorDescription(decodingError))。\(responseDiagnosticsDescription(diagnostics))"
            }
        }

        if let decodingError = error as? DecodingError {
            return detailedDecodingErrorDescription(decodingError)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "请求超时"
            case .notConnectedToInternet:
                return "无网络连接"
            case .cannotFindHost:
                return "无法解析域名"
            case .secureConnectionFailed:
                return "SSL 连接失败"
            default:
                return "网络错误(\(urlError.code.rawValue)): \(urlError.localizedDescription)"
            }
        }

        return error.localizedDescription
    }

    private static func detailedDecodingErrorDescription(_ decodingError: DecodingError) -> String {
        switch decodingError {
        case .typeMismatch(let type, let context):
            return "类型不匹配: 期望 \(type), 路径 \(codingPathDescription(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "缺少值: \(type), 路径 \(codingPathDescription(context.codingPath))"
        case .keyNotFound(let key, let context):
            return "缺少字段: \(key.stringValue), 路径 \(codingPathDescription(context.codingPath))"
        case .dataCorrupted(let context):
            return "数据损坏: \(context.debugDescription), 路径 \(codingPathDescription(context.codingPath))"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private static func responseDiagnosticsDescription(_ diagnostics: LiveParsePluginIndexResponseDiagnostics) -> String {
        let statusText = diagnostics.statusCode.map(String.init) ?? "n/a"
        let contentTypeText = diagnostics.contentType ?? "unknown"
        return "URL \(diagnostics.url.absoluteString), HTTP \(statusText), Content-Type \(contentTypeText), 响应片段 \(diagnostics.bodyPreview)"
    }

    private static func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "<root>" : path
    }

    // MARK: - Timeout Helper

    private func fetchIndexWithTimeout(url: URL) async throws -> LiveParseRemotePluginIndex {
        let timeout = fetchTimeoutSeconds
        let localUpdater = updater
        return try await withThrowingTaskGroup(of: LiveParseRemotePluginIndex.self) { group in
            group.addTask {
                try await localUpdater.fetchIndex(url: url)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }
    }

}
