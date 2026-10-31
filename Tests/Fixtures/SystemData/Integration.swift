// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import Darwin
import ServiceManagement

/// Compiles the production module directly. Only temporary fixtures are cleaned;
/// the full system inventory and administrator cleanup are never run.
@main
struct SystemDataIntegrationTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("systemdata-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try commands(root)
        try sizes(root)
        try cleanup(root)
        try models(root)
        let cancelled = BoundedProcessCancellation()
        cancelled.cancel()
        expect(SystemDataService.inventory(cancellation: cancelled).isEmpty, "cancelled scan returns without probing")
        let trash = SystemDataProbeRegistry.all.first { $0.id == "trash" }!
        expect(trash.category == .trash && trash.safety == .safe && trash.permanent, "trash remains safe with permanent cleanup")
        let logs = SystemDataProbeRegistry.all.first { $0.id == "user-logs" }!
        expect(logs.category == .logs && logs.minimumBytes == 1 && logs.safety == .safe, "application logs keep reference classification and threshold")
        print("PASS: System Data integration (\(checks) checks)")
    }

    static func commands(_ root: URL) throws {
        let result = SystemDataCommand.result("/bin/sh", ["-c", "printf '{\"ok\":true}'; printf 'notice' >&2"])
        expect(result.succeeded && result.output == "{\"ok\":true}" && result.error == "notice", "stderr must not contaminate JSON stdout")
        let literal = "a b\n'\"`$(echo unexpected);\\路径"
        expect(SystemDataService.runCommand("/usr/bin/printf", ["%s", literal]) == literal, "arguments are passed literally, not interpreted by the adapter shell")
        let failure = SystemDataCommand.result("/bin/sh", ["-c", "echo test-error >&2; exit 7"])
        expect(!failure.succeeded && failure.status == 7 && failure.failureDescription.contains("test-error"), "command status and error are retained")
        expect(!SystemDataCommand.result("/missing/systemdata-command", []).succeeded, "missing executable is a failure")
        let start = ProcessInfo.processInfo.systemUptime
        let timeout = SystemDataCommand.result("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        expect(timeout.timedOut && !timeout.succeeded, "SIGTERM-ignoring commands time out")
        expect(ProcessInfo.processInfo.systemUptime - start < 4, "SIGKILL fallback bounds timeout")
        let inherited = SystemDataCommand.result("/bin/sh", ["-c", "sleep 2 & echo done"], timeout: 0.3)
        expect(inherited.succeeded && inherited.output.contains("done"), "inherited output handles cannot block collection")
        let marker = root.appendingPathComponent("must-not-launch")
        let cache = SystemDataService.ScanCache()
        let cancellation = BoundedProcessCancellation()
        cancellation.cancel()
        cache.cancellation = cancellation
        Thread.current.threadDictionary[SystemDataService.scanCacheKey] = cache
        defer { Thread.current.threadDictionary.removeObject(forKey: SystemDataService.scanCacheKey) }
        let cancelled = SystemDataService.runCommand("/usr/bin/touch", [marker.path])
        expect(cancelled == nil && !FileManager.default.fileExists(atPath: marker.path), "cancelled probes never launch")
    }

    static func sizes(_ root: URL) throws {
        let fm = FileManager.default
        let scan = root.appendingPathComponent("scan")
        let package = scan.appendingPathComponent("Fixture.app/Contents")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let hidden = scan.appendingPathComponent(".hidden")
        let payload = package.appendingPathComponent("payload")
        try Data(repeating: 17, count: 16_384).write(to: hidden)
        try Data(repeating: 19, count: 32_768).write(to: payload)
        func allocated(_ url: URL) throws -> Int64 {
            Int64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }
        let expected = try allocated(hidden) + allocated(payload)
        expect(SystemDataService.directorySize(scan) == expected, "hidden and package files use allocated bytes")
        try fm.createSymbolicLink(at: scan.appendingPathComponent("link"), withDestinationURL: package)
        expect(SystemDataService.directorySize(scan) == expected, "directory symlinks are not traversed")
        expect(SystemDataService.directorySize(scan, olderThan: Date(timeIntervalSince1970: 0)) == 0, "recent temporary files are excluded")
        let sizes = SystemDataService.folderSizes(scan, skipping: [SystemDataService.realPath(package)])
        let hiddenBytes = try allocated(hidden)
        expect(sizes[SystemDataService.realPath(scan)] == hiddenBytes, "claimed subtrees are excluded from ancestor sizes")
    }

    static func cleanup(_ root: URL) throws {
        let fm = FileManager.default
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for path in [first, second] {
            try fm.createDirectory(at: path, withIntermediateDirectories: false)
            try Data([1]).write(to: path.appendingPathComponent("keep"))
        }
        var item = SystemDataService.Item(id: "fixture", category: .logs, name: "fixture", path: first,
            detail: "", size: 1, safety: .safe, permanent: true,
            identity: SystemDataFileSupport.fileIdentity(at: first), selected: false)
        item.cleanup = .remove([first, second], contentsOnly: true)
        for path in item.cleanup.paths { item.cleanupIdentities[path] = SystemDataFileSupport.fileIdentity(at: path) }
        try fm.moveItem(at: second, to: root.appendingPathComponent("old-second"))
        try fm.createDirectory(at: second, withIntermediateDirectories: false)
        try Data([1]).write(to: second.appendingPathComponent("replacement"))
        do { try SystemDataCleanup.clean(item); expect(false, "replaced directory must reject cleanup") }
        catch { expect(true, "identity mismatch rejects cleanup") }
        expect(fm.fileExists(atPath: first.appendingPathComponent("keep").path), "all roots are validated before any deletion")
        expect(fm.fileExists(atPath: second.appendingPathComponent("replacement").path), "replacement content remains untouched")
        item.cleanup = .remove([first], contentsOnly: true)
        try SystemDataCleanup.clean(item)
        let remaining = try fm.contentsOfDirectory(atPath: first.path)
        expect(remaining.isEmpty && fm.fileExists(atPath: first.path), "contents cleanup preserves the root directory")
        let link = root.appendingPathComponent("cleanup-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: second)
        item.cleanup = .remove([link], contentsOnly: true)
        item.cleanupIdentities[link] = SystemDataFileSupport.fileIdentity(at: link)
        do { try SystemDataCleanup.clean(item); expect(false, "symlink root must be rejected") }
        catch { expect(true, "symlink root is rejected even with a matching lstat identity") }
        expect(fm.fileExists(atPath: second.appendingPathComponent("replacement").path), "symlink target remains untouched")
        // Command steps stop after the first failure.
        let marker = root.appendingPathComponent("must-not-execute")
        item.cleanup = .commands([["/usr/bin/false"], ["/usr/bin/touch", marker.path]])
        do { try SystemDataCleanup.clean(item); expect(false, "failed command must reject cleanup") }
        catch { expect(true, "command failure is propagated") }
        expect(!fm.fileExists(atPath: marker.path), "later command steps do not run after failure")
    }

    static func models(_ root: URL) throws {
        let fm = FileManager.default
        let models = root.appendingPathComponent("models")
        let manifests = models.appendingPathComponent("manifests/registry.ollama.ai/library")
        for name in ["one", "two"] {
            let folder = manifests.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let json: [String: Any] = ["layers": [["digest": "sha256:" + name, "size": 200_000_000], ["digest": "sha256:shared", "size": 150_000_000]]]
            try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("latest"))
        }
        let previous = ProcessInfo.processInfo.environment["OLLAMA_MODELS"]
        setenv("OLLAMA_MODELS", models.path, 1)
        defer {
            if let previous { setenv("OLLAMA_MODELS", previous, 1) }
            else { unsetenv("OLLAMA_MODELS") }
        }
        let cache = SystemDataService.ScanCache()
        cache.tools["ollama"] = "/usr/bin/true"
        Thread.current.threadDictionary[SystemDataService.scanCacheKey] = cache
        defer { Thread.current.threadDictionary.removeObject(forKey: SystemDataService.scanCacheKey) }
        let items = SystemDataService.modelInventory().filter { $0.id.hasPrefix("ai-ollama") }
        expect(items.count == 3, "two exclusive model rows and one shared row")
        expect(items.reduce(Int64(0)) { $0 + $1.size } == 550_000_000, "shared model layers count once")
        expect(items.first { $0.id == "ai-ollama-shared" }?.safety == .manual, "shared layers remain manual-only")
        expect(items.filter { $0.id != "ai-ollama-shared" }.allSatisfy { $0.safety == .review }, "individual models require review when Ollama is available")
        cache.tools.removeValue(forKey: "ollama")
        cache.missingTools.insert("ollama")
        let unavailable = SystemDataService.modelInventory().filter { $0.id.hasPrefix("ai-ollama") }
        expect(unavailable.allSatisfy { $0.safety == .manual }, "models remain manual-only when Ollama is unavailable")
    }
}
