// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Darwin

/// Local filesystem checks; the System Data feature does not depend on Uninstall.
enum SystemDataFileSupport {
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    static func fileIdentity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
