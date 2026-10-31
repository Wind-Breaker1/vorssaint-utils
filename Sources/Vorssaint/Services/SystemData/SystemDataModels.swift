// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct SystemDataItem: Identifiable, Equatable {
    let id: String
    let category: SystemDataCategory
    let name: String
    let path: URL
    let detail: String
    let size: Int64
    let safety: SystemDataSafety
    let permanent: Bool
    let identity: SystemDataFileSupport.FileIdentity?
    var selected: Bool
    var additionalClaims: [URL] = []
    var cleanup: SystemDataCleanupAction = .path
    var sizeIsUnknown = false
    var cleanupIdentities: [URL: SystemDataFileSupport.FileIdentity] = [:]

    var claimedPaths: [URL] {
        (path.path == "/" ? [] : [path]) + additionalClaims + cleanup.paths
    }
}

enum SystemDataCleanupAction: Equatable {
    case administrator(SystemDataPrivilegedOperation)
    case commands([[String]])
    case remove([URL], contentsOnly: Bool, shutdownSimulators: Bool = false)
    case path

    var paths: [URL] {
        if case .remove(let paths, _, _) = self { return paths }
        return []
    }
}
