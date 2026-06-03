//
//  OperationOutcome.swift
//  AngelLiveCore
//
//  单次同步/写操作的结果。让调用方能在页面上明确反馈「成功 / 失败(原因+码)」,
//  取代过去 async->Void + Logger.warning 吞错导致的「假报成功」。
//

import Foundation

/// 一次操作(加收藏 / 删收藏 / 上传 / 下载 / 同步)的结果。
public enum OperationOutcome: Sendable, Equatable {
    /// 完全成功。
    case success
    /// 完全失败。
    case failure(SyncError)
    /// 批量操作中部分成功、部分失败。
    case partial(SyncError)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// 失败 / 部分失败时的错误,成功为 nil。
    public var error: SyncError? {
        switch self {
        case .success: return nil
        case .failure(let e), .partial(let e): return e
        }
    }
}
