// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum SystemDataPrivilegedOperation: String, Codable, CaseIterable {
    case unifiedLogs, diagnosticReports, legacyASL, sharedCaches, localSnapshots
}


extension SystemDataPrivilegedOperation {
    var script: String {
        switch self {
        case .unifiedLogs: return "/usr/bin/log erase --all"
        case .diagnosticReports: return "/bin/rm -rf /Library/Logs/DiagnosticReports/*"
        case .legacyASL: return "/bin/rm -f /private/var/log/asl/*.asl"
        case .sharedCaches:
            let root = URL(fileURLWithPath: "/Library/Caches")
            let entries = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { entry in
                var info = stat()
                return lstat(entry.path, &info) == 0 && info.st_flags & (UInt32(SF_RESTRICTED) | UInt32(UF_DATAVAULT)) == 0
            }
            guard !entries.isEmpty else { return ":" }
            return "/bin/rm -rf -- " + entries.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        case .localSnapshots: return "/usr/bin/tmutil deletelocalsnapshots / ; /usr/bin/tmutil thinlocalsnapshots / 9999999999999 4"
        }
    }
}
