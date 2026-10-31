// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum SystemDataCommand {
    struct CommandResult {
        let output: String
        let error: String
        let status: Int32
        let timedOut: Bool
        var succeeded: Bool { !timedOut && status == 0 }
        var failureDescription: String {
            if timedOut { return "命令执行超时，请确认相关工具状态后重试。" }
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "命令执行失败（退出码 \(status)）。" : String(detail.prefix(2000))
        }
    }

    /// Reuse the project's bounded runner, keeping stderr separate for JSON probes.
    static func result(_ executable: String, _ arguments: [String], timeout: Double = 20, cancellation: BoundedProcessCancellation? = nil) -> CommandResult {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("vorssaint-systemdata-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: directory) }
            let errorURL = directory.appendingPathComponent("stderr")
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            // Paths and arguments are positional parameters, never interpolated shell code.
            let result = BoundedProcessRunner.run("/bin/sh",
                ["-c", "error_path=$1; shift; exec \"$@\" 2>\"$error_path\"", "system-data", errorURL.path, executable] + arguments,
                timeout: timeout, maxOutputBytes: 32 * 1_048_576, environment: environment,
                cancellation: cancellation)
            let errorHandle = try? FileHandle(forReadingFrom: errorURL)
            defer { try? errorHandle?.close() }
            let errorData = (try? errorHandle?.read(upToCount: 8192)) ?? Data()
            return CommandResult(output: String(decoding: result.output, as: UTF8.self),
                                 error: String(decoding: errorData, as: UTF8.self),
                                 status: result.status, timedOut: result.timedOut)
        } catch {
            return CommandResult(output: "", error: error.localizedDescription, status: -1, timedOut: false)
        }
    }

}

extension SystemDataService {
    /// Scan-local cancellation is passed explicitly to the independent runner.
    static func runCommand(_ executable: String, _ arguments: [String], timeout: Double = 20) -> String? {
        let result = SystemDataCommand.result(executable, arguments, timeout: timeout, cancellation: scanCache?.cancellation)
        return result.succeeded ? result.output : nil
    }
}
