// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum SystemDataCleanup {
    static func administratorScript(_ items: [SystemDataItem], marker: String) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return items.enumerated().compactMap { index, item in
            guard case .administrator(let operation) = item.cleanup else { return nil }
            return """
            output=$(/bin/sh -c \(quote(operation.script)) 2>&1)
            status=$?
            /usr/bin/printf '%s\\t%d\\t' \(quote(marker + "-" + String(index))) "$status"
            /usr/bin/printf '%s' "$output" | /usr/bin/base64 | /usr/bin/tr -d '\\n'
            /usr/bin/printf '\\n'
            """
        }.joined(separator: "\n")
    }

    static func appleScript(_ script: String) -> String {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"" + escaped + "\""
    }

    static func cleanAdministrators(_ items: [SystemDataItem]) -> [String: String] {
        guard !items.isEmpty else { return [:] }
        let marker = UUID().uuidString
        let result = SystemDataCommand.result("/usr/bin/osascript",
            ["-e", appleScript(administratorScript(items, marker: marker)) + " with administrator privileges"],
            timeout: 600 * Double(items.count + 1))
        guard result.succeeded else {
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, result.failureDescription) })
        }
        var outcomes: [Int: (Int, String)] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = String(line).components(separatedBy: "\t")
            guard parts.count == 3, parts[0].hasPrefix(marker + "-"),
                  let index = Int(parts[0].dropFirst(marker.count + 1)), let status = Int(parts[1]),
                  let data = Data(base64Encoded: parts[2]) else { continue }
            outcomes[index] = (status, String(decoding: data, as: UTF8.self))
        }
        var failures: [String: String] = [:]
        for (index, item) in items.enumerated() {
            guard let (status, output) = outcomes[index] else {
                failures[item.id] = "无法确认清理结果，请重新扫描。"
                continue
            }
            if status != 0 { failures[item.id] = output.isEmpty ? "管理员清理失败。" : String(output.prefix(2000)) }
        }
        return failures
    }

    private static func validate(_ path: URL, identity: SystemDataFileSupport.FileIdentity?) throws {
        guard let identity, SystemDataFileSupport.fileIdentity(at: path) == identity,
              !SystemDataFileSupport.isSymbolicLink(path) else {
            throw NSError(domain: "SystemData", code: 1, userInfo: [NSLocalizedDescriptionKey: "路径已变化或无法验证，请重新扫描：" + path.path])
        }
    }

    private static func execute(_ command: [String]) throws {
        guard let executable = command.first else { return }
        let result = SystemDataCommand.result(executable, Array(command.dropFirst()), timeout: 600)
        guard result.succeeded else {
            throw NSError(domain: "SystemData", code: 1, userInfo: [NSLocalizedDescriptionKey: result.failureDescription])
        }
    }

    static func clean(_ item: SystemDataItem) throws {
        let fm = FileManager.default
        switch item.cleanup {
        case .administrator:
            if let error = cleanAdministrators([item])[item.id] {
                throw NSError(domain: "SystemData", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
        case .commands(let commands):
            for command in commands { try execute(command) }
        case .remove(let paths, let contentsOnly, let shutdownSimulators):
            if shutdownSimulators { try execute(["/usr/bin/xcrun", "simctl", "shutdown", "all"]) }
            // Validate every root before starting a multi-root operation.
            for path in paths { try validate(path, identity: item.cleanupIdentities[path]) }
            for path in paths {
                try validate(path, identity: item.cleanupIdentities[path])
                let targets = contentsOnly ? try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) : [path]
                for target in targets {
                    if contentsOnly && SystemDataFileSupport.isSymbolicLink(target) { continue }
                    if contentsOnly && item.permanent { try fm.removeItem(at: target) }
                    else { try fm.trashItem(at: target, resultingItemURL: nil) }
                }
            }
        case .path:
            try validate(item.path, identity: item.identity)
            if item.category == .temp {
                let cutoff = Date().addingTimeInterval(-3 * 86_400)
                let walker = fm.enumerator(at: item.path, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [])
                while let file = walker?.nextObject() as? URL {
                    guard !SystemDataFileSupport.isSymbolicLink(file),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                          values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff else { continue }
                    try fm.trashItem(at: file, resultingItemURL: nil)
                }
            } else if item.permanent { try fm.removeItem(at: item.path) }
            else { try fm.trashItem(at: item.path, resultingItemURL: nil) }
        }
    }

}
