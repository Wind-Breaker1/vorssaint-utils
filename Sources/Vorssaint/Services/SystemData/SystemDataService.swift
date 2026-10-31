// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Darwin

/// A focused, read-only inventory of the places macOS commonly counts as
/// System Data. It is deliberately separate from JunkCleaner: both tools may
/// inspect the same paths, but each owns its own result and cleanup policy.
final class SystemDataService: ObservableObject {
    typealias Item = SystemDataItem
    typealias Safety = SystemDataSafety
    private static var instance: SystemDataService?
    static var shared: SystemDataService {
        if let instance { return instance }
        let service = SystemDataService()
        instance = service
        return service
    }

    static func stopIfLoaded() { instance?.suspend() }

    private let queue = DispatchQueue(label: "com.vorssaint.system-data", qos: .utility)
    private var generation = 0
    private var cancellation: BoundedProcessCancellation?

    /// Scan commands can stop immediately. Cleanup finishes its current item;
    /// no further item starts, and obsolete results never reach the view.
    func suspend() {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
        items = []
        lastError = nil
        lastNotice = nil
        progress = nil
        phase = .idle
    }

    enum Phase { case idle, scanning, results, cleaning }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var progress: String?
    @Published private(set) var lastNotice: String?
    @Published private(set) var lastError: String?

    private init() {}

    var selectedCount: Int { items.filter { $0.selected && $0.safety != .manual }.count }

    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }

    func selectSafeItems() {
        guard phase != .scanning && phase != .cleaning else { return }
        let safe = items.indices.filter { items[$0].safety == .safe }
        guard !safe.isEmpty else { return }
        let shouldSelect = safe.contains { !items[$0].selected }
        for index in safe { items[index].selected = shouldSelect }
    }

    func scan() {
        guard phase != .scanning && phase != .cleaning else { return }
        generation += 1
        let request = generation
        let cancellation = BoundedProcessCancellation()
        self.cancellation = cancellation
        phase = .scanning
        lastError = nil
        lastNotice = nil
        progress = nil
        queue.async(execute: DispatchWorkItem { [weak self] in
            let combined = Self.inventory(cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self, self.generation == request, !cancellation.isCancelled else { return }
                self.items = combined.sorted {
                    if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                    return $0.size > $1.size
                }
                self.cancellation = nil
                self.phase = .results
            }
        })
    }

    static func inventory(cancellation: BoundedProcessCancellation? = nil) -> [Item] {
        guard cancellation?.isCancelled != true else { return [] }
        let cache = ScanCache()
        cache.cancellation = cancellation
        Thread.current.threadDictionary[scanCacheKey] = cache
        defer { Thread.current.threadDictionary.removeObject(forKey: scanCacheKey) }
        var found = SystemDataProbeRegistry.all.flatMap { Self.measure($0) }
        found = Self.packagePolicies(found)
        if let unifiedLogs = Self.unifiedLogItem() { found.append(unifiedLogs) }
        if let snapshot = Self.localSnapshotItem() { found.append(snapshot) }
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.runtimeInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.packageInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.dockerInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.deviceInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.componentInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.modelInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.ideInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.xcodeInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.systemComponentInventory())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.developerItems())
        guard cancellation?.isCancelled != true else { return [] }
        found.append(contentsOf: Self.systemItems())
        var claimed = found.filter { $0.id != "snapshots" && $0.path.path != "/" }.flatMap(\.claimedPaths).map(Self.realPath)
        if found.contains(where: { $0.id == "unified-logs" }) {
            claimed.append("/private/var/db/uuidtext")
        }
        let dynamic = Self.appDataItems(claimed: claimed) + Self.temporaryItems(claimed: claimed)
        let dynamicClaimed = claimed + dynamic.map { $0.path.standardizedFileURL.path }
        let projects = Self.projectItems(claimed: dynamicClaimed)
        let specific = Self.withoutOverlaps(found + dynamic + projects)
        let combined = specific + Self.largeFolderItems(claimed: specific.filter { $0.id != "snapshots" && $0.path.path != "/" }.flatMap(\.claimedPaths).map(Self.realPath) + (found.contains { $0.id == "unified-logs" } ? ["/private/var/db/uuidtext"] : []))
        guard cancellation?.isCancelled != true else { return [] }
        var inventory = combined
        var spotlight = Item(id: "sys-spotlight", category: .system, name: "Spotlight 索引", path: URL(fileURLWithPath: "/.Spotlight-V100"),
                             detail: "仅管理员可读取，大小未知；可通过系统设置管理索引。", size: 0, safety: .manual,
                             permanent: false, identity: nil, selected: false)
        spotlight.sizeIsUnknown = true
        inventory.append(spotlight)
        return inventory.map { original in
            var item = original
            for path in item.cleanup.paths {
                if let identity = SystemDataFileSupport.fileIdentity(at: path), !SystemDataFileSupport.isSymbolicLink(path) {
                    item.cleanupIdentities[path] = identity
                }
            }
            return item
        }
    }

    func setSelected(_ selected: Bool, id: String) {
        guard phase != .scanning && phase != .cleaning else { return }
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].safety != .manual else { return }
        items[index].selected = selected
    }

    func cleanSelected() {
        guard phase != .scanning && phase != .cleaning else { return }
        let selected = items.filter { $0.selected && $0.safety != .manual }
        guard !selected.isEmpty else { return }
        generation += 1
        let request = generation
        let cancellation = BoundedProcessCancellation()
        self.cancellation = cancellation
        phase = .cleaning
        lastError = nil
        lastNotice = nil
        progress = nil
        queue.async(execute: DispatchWorkItem { [weak self] in
            var failures: [String] = []
            var failedItems: [Item] = []
            var administratorsHandled = false
            for item in selected {
                DispatchQueue.main.async {
                    guard let self, self.generation == request else { return }
                    self.progress = "正在清理：" + item.name
                }
                guard !cancellation.isCancelled else { return }
                if case .administrator = item.cleanup {
                    guard !administratorsHandled else { continue }
                    administratorsHandled = true
                    let administrators = selected.filter {
                        if case .administrator = $0.cleanup { return true }
                        return false
                    }
                    let errors = SystemDataCleanup.cleanAdministrators(administrators)
                    for administrator in administrators {
                        if let error = errors[administrator.id] {
                            failures.append(administrator.name + "：" + error)
                            failedItems.append(administrator)
                        }
                    }
                    continue
                }
                do { try SystemDataCleanup.clean(item) }
                catch {
                    failures.append(item.name + "：" + error.localizedDescription)
                    failedItems.append(item)
                }
            }
            guard !cancellation.isCancelled else { return }
            let cleanupErrors = failures.isEmpty ? nil : failures.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.lastError = cleanupErrors
                self.phase = .scanning
                self.progress = "清理执行已结束，正在重新扫描容量…"
            }
            var refreshed = Self.inventory(cancellation: cancellation)
            // Keep failed rows visible even if a partial cleanup took them below the scan threshold.
            for item in failedItems where !refreshed.contains(where: { $0.id == item.id }) { refreshed.append(item) }
            let results = refreshed
            let failedIDs = Set(failedItems.map(\.id))
            let remainingCommands = selected.filter { item in
                guard !failedIDs.contains(item.id), case .commands = item.cleanup else { return false }
                return results.contains { $0.id == item.id && $0.size > 0 }
            }
            let notice = remainingCommands.isEmpty ? nil : remainingCommands.map { item in
                item.id == "pkg-pnpm" ? "pnpm store prune 已执行完成。此项显示整个存储的占用，并非全部可回收容量；命令保留的内容不会强制删除。" : item.name + "：清理命令已执行，仍有保留内容。"
            }.joined(separator: "\n")
            let message = failures.isEmpty ? nil : failures.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self, self.generation == request, !cancellation.isCancelled else { return }
                self.cancellation = nil
                self.items = results.sorted {
                    if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                    return $0.size > $1.size
                }
                self.progress = nil
                self.lastNotice = notice
                self.lastError = message
                self.phase = .results
            }
        })
    }

    private static func unifiedLogItem() -> Item? {
        let diagnostics = URL(fileURLWithPath: "/private/var/db/diagnostics")
        let uuidtext = URL(fileURLWithPath: "/private/var/db/uuidtext")
        guard FileManager.default.fileExists(atPath: diagnostics.path) else { return nil }
        let size = directorySize(diagnostics) + directorySize(uuidtext)
        guard size > 0, let identity = SystemDataFileSupport.fileIdentity(at: diagnostics) else { return nil }
        return Item(id: "unified-logs", category: .logs, name: "系统统一日志",
                    path: diagnostics, detail: "系统 Unified Log 数据，使用 log erase --all 清理。",
                    size: size, safety: .safe, permanent: false, identity: identity, selected: true, cleanup: .administrator(.unifiedLogs))
    }

    private static func measure(_ spec: SystemDataProbeSpec) -> [Item] {
        guard scanCache?.cancellation?.isCancelled != true else { return [] }
        let fm = FileManager.default
        if !hasFullDiskAccess && ["Library/Containers", "Library/Group Containers"].contains(where: {
            spec.url.path.hasPrefix(SystemDataProbeRegistry.home.appendingPathComponent($0).path + "/")
        }) { return [] }
        guard fm.fileExists(atPath: spec.url.path), !SystemDataFileSupport.isSymbolicLink(spec.url) else { return [] }
        let size = directorySize(spec.url)
        guard size >= spec.minimumBytes, SystemDataFileSupport.fileIdentity(at: spec.url) != nil else { return [] }
        var item = Item(id: spec.id, category: spec.category, name: spec.name, path: spec.url,
                        detail: spec.detail, size: size, safety: spec.safety,
                        permanent: spec.permanent, identity: SystemDataFileSupport.fileIdentity(at: spec.url), selected: false)
        if ["trash", "user-logs", "mail-downloads", "unity-cache"].contains(spec.id) || spec.category == .packages {
            item.cleanup = .remove([spec.url], contentsOnly: true)
        }
        return [item]
    }

    private static func localSnapshotItem() -> Item? {
        guard let text = runCommand(SystemDataProbeRegistry.snapshotCommand, ["listlocalsnapshots", "/"]) else { return nil }
        let count = text.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        guard count > 0 else { return nil }
        var item = Item(id: "snapshots", category: .snapshots, name: "Time Machine 本地快照（\(count) 个）",
                    path: URL(fileURLWithPath: "/"), detail: "APFS 快照大小无法由文件遍历准确测量，需使用 tmutil 处理。",
                    size: 0, safety: .safe, permanent: false, identity: nil, selected: false)
        item.sizeIsUnknown = true
        item.cleanup = .administrator(.localSnapshots)
        return item
    }

    /// Walks the same boot-volume roots as the reference catch-all, skips
    /// protected personal libraries and never repeats a path already claimed
    /// by a known probe.
    private static func largeFolderItems(claimed: [String]) -> [Item] {
        var excluded = SystemDataProbeRegistry.excludedRoots.map { realPath(SystemDataProbeRegistry.home.appendingPathComponent($0)) }
        if !hasFullDiskAccess { excluded += ["Library/Containers", "Library/Group Containers"].map { realPath(SystemDataProbeRegistry.home.appendingPathComponent($0)) } }
        let skip = Set(claimed.map { realPath(URL(fileURLWithPath: $0)) } + excluded)
        var result: [Item] = []
        for root in SystemDataProbeRegistry.genericRoots where onBootVolume(root) {
            guard scanCache?.cancellation?.isCancelled != true else { return [] }
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            for child in children where !SystemDataFileSupport.isSymbolicLink(child) && onBootVolume(child) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !skip.contains(realPath(child)) else { continue }
                let sizes = folderSizes(child, skipping: skip)
                func visit(_ url: URL, depth: Int) {
                    let path = url.standardizedFileURL.path
                    guard !skip.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                          let size = sizes[path], size >= SystemDataProbeRegistry.genericThreshold else { return }
                    if claimed.contains(where: { $0.hasPrefix(path + "/") }) || ["Library", "Application Support"].contains(url.lastPathComponent) {
                        guard depth < 4 else { return }
                        for nested in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [] {
                            guard !SystemDataFileSupport.isSymbolicLink(nested), (try? nested.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                            visit(nested, depth: depth + 1)
                        }
                    } else {
                        result.append(Item(id: "other-" + path, category: .other, name: url.lastPathComponent, path: url,
                                           detail: "未识别的大型目录，请在 Finder 中确认用途。", size: size, safety: .review,
                                           permanent: false, identity: SystemDataFileSupport.fileIdentity(at: url), selected: false))
                    }
                }
                visit(child, depth: 1)
            }
        }
        return result
    }

    static func onBootVolume(_ url: URL) -> Bool {
        guard let boot = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let volume = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return true }
        return volume.isEqual(boot)
    }

    /// One filesystem walk accumulates each candidate's bytes, excluding
    /// claimed subtrees before they can inflate their parents.
    static func folderSizes(_ root: URL, skipping: Set<String>) -> [String: Int64] {
        let rootPath = realPath(root)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .volumeIdentifierKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return [:] }
        var sizes: [String: Int64] = [:]
        for case let file as URL in walker {
            guard scanCache?.cancellation?.isCancelled != true else { return [:] }
            let path = file.path
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            if skipping.contains(path) || (values.isRegularFile != true && !onBootVolume(file)) { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? 0)
            sizes[rootPath, default: 0] += bytes
            var parent = rootPath
            let relative = path.dropFirst(rootPath.count + 1).split(separator: "/").dropLast()
            for component in relative.prefix(3) { parent += "/" + component; sizes[parent, default: 0] += bytes }
        }
        return sizes
    }

    private static func projectItems(claimed: [String]) -> [Item] {
        let fm = FileManager.default
        let roots = ["Desktop", "Documents", "Developer", "Projects", "Projeler"].map { SystemDataProbeRegistry.home.appendingPathComponent($0) }
        let claimedPaths = claimed.map { Self.realPath(URL(fileURLWithPath: $0)) }
        var results: [Item] = []
        func walk(_ url: URL, depth: Int) {
            guard scanCache?.cancellation?.isCancelled != true, depth <= 4, let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
            for child in children {
                guard !SystemDataFileSupport.isSymbolicLink(child),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if SystemDataProbeRegistry.projectTargets.contains(child.lastPathComponent) {
                    let path = Self.realPath(child)
                    guard !claimedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
                    let size = directorySize(child)
                    if size >= 30 * SystemDataProbeRegistry.mb, let identity = SystemDataFileSupport.fileIdentity(at: child) {
                        results.append(Item(id: "project-\(path)", category: .projects,
                                            name: "项目：\(child.lastPathComponent)", path: child,
                                            detail: "项目构建目录，可由项目工具重新生成。",
                                            size: size, safety: .review, permanent: false,
                                            identity: identity, selected: false))
                    }
                    continue
                }
                if !child.lastPathComponent.hasPrefix(".") && child.lastPathComponent != "Library" { walk(child, depth: depth + 1) }
            }
        }
        for root in roots where fm.fileExists(atPath: root.path) {
            if !hasFullDiskAccess && ["Desktop", "Documents"].contains(root.lastPathComponent) { continue }
            walk(root, depth: 0)
        }
        return results
    }

    /// Mirrors macos-sysdata's AppDataProbe: scan each unclaimed child of
    /// Application Support, Containers, Group Containers and Caches rather
    /// than relying on a fixed list of application names.
    private static func appDataItems(claimed: [String]) -> [Item] {
        let fm = FileManager.default
        var roots: [(URL, String, SystemDataSafety, Int64)] = [
            (SystemDataProbeRegistry.home.appendingPathComponent("Library/Application Support"), "应用数据", .review, 200 * SystemDataProbeRegistry.mb),
            (SystemDataProbeRegistry.home.appendingPathComponent("Library/Containers"), "应用容器数据", .review, 200 * SystemDataProbeRegistry.mb),
            (SystemDataProbeRegistry.home.appendingPathComponent("Library/Group Containers"), "应用共享数据", .review, 200 * SystemDataProbeRegistry.mb),
            (SystemDataProbeRegistry.home.appendingPathComponent("Library/Caches"), "应用缓存", .safe, 100 * SystemDataProbeRegistry.mb),
        ]
        roots.append((SystemDataProbeRegistry.home.appendingPathComponent("Library/Caches/Google"), "Google 缓存", .safe, 100 * SystemDataProbeRegistry.mb))
        let skipped: [String: Set<String>] = [
            "Caches": ["Homebrew", "Yarn", "pip", "CocoaPods", "org.swift.swiftpm", "go-build", "Cypress", "ms-playwright", "com.apple.dt.Xcode", "Google", "Adobe", "com.apple.QuickLook.thumbnailcache", "JetBrains"],
            "Application Support": ["MobileSync", "Claude", "Google", "Slack", "discord", "zoom.us", "Spotify", "Adobe", "Steam", "Epic", "JetBrains"],
            "Containers": ["com.microsoft.teams2", "com.apple.Safari", "com.apple.photolibraryd", "com.utmapp.UTM", "com.apple.mail", "com.docker.docker"],
            "Group Containers": ["group.net.whatsapp.WhatsApp.shared"]
        ]
        let claimedPaths = claimed.map { Self.realPath(URL(fileURLWithPath: $0)) }
        var results: [Item] = []
        for (root, label, safety, threshold) in roots {
            let container = ["Containers", "Group Containers"].contains(root.lastPathComponent)
            if container && !hasFullDiskAccess { continue }
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
            for child in children {
                guard !child.lastPathComponent.hasPrefix("."), !(skipped[root.lastPathComponent] ?? []).contains(child.lastPathComponent),
                      root.lastPathComponent != "Google" || !child.lastPathComponent.hasPrefix("AndroidStudio"),
                      !SystemDataFileSupport.isSymbolicLink(child),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let path = Self.realPath(child)
                guard !claimedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
                let size = directorySize(child)
                guard size >= threshold, let identity = SystemDataFileSupport.fileIdentity(at: child) else { continue }
                results.append(Item(id: "dynamic-\(path)", category: .apps,
                                    name: "\(label)：\(child.lastPathComponent)", path: child,
                                    detail: safety == .safe ? "应用可重新生成的缓存。" : "删除会重置或移除应用数据，请确认后处理。",
                                    size: size, safety: container && (child.lastPathComponent.hasPrefix("com.apple.") || child.lastPathComponent.hasPrefix("group.com.apple.")) ? .manual : safety, permanent: false,
                                    identity: identity, selected: false))
            }
        }
        return results
    }

    /// Mirrors TempProbe's two Darwin-confstr locations and its three-day
    /// retention rule. The scan reports old files only, while cleaning still
    /// requires explicit selection.
    private static func temporaryItems(claimed: [String]) -> [Item] {
        let paths: [(String, URL?)] = [
            ("临时缓存目录", confstrDirectory(_CS_DARWIN_USER_CACHE_DIR)),
            ("用户临时目录", confstrDirectory(_CS_DARWIN_USER_TEMP_DIR)),
        ]
        let claimedPaths = claimed.map { Self.realPath(URL(fileURLWithPath: $0)) }
        return paths.compactMap { label, root in
            guard let root else { return nil }
            guard FileManager.default.fileExists(atPath: root.path),
                  !claimedPaths.contains(where: { $0 == root.standardizedFileURL.path || $0.hasPrefix(root.standardizedFileURL.path + "/") }) else { return nil }
            let size = directorySize(root, olderThan: Date().addingTimeInterval(-3 * 86_400))
            guard size >= SystemDataProbeRegistry.mb,
                  let identity = SystemDataFileSupport.fileIdentity(at: root) else { return nil }
            return Item(id: "temp-\(root.path)", category: .temp, name: label,
                        path: root, detail: "仅统计三天以前的临时文件。", size: size,
                        safety: .safe, permanent: false, identity: identity, selected: false)
        }
    }

    private static func confstrDirectory(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }

    static func directorySize(_ url: URL, olderThan cutoff: Date? = nil) -> Int64 {
        guard !SystemDataFileSupport.isSymbolicLink(url) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: keys.union([.contentModificationDateKey])), values.isRegularFile == true {
            if let cutoff, let modified = values.contentModificationDate, modified >= cutoff { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys) + [.contentModificationDateKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard scanCache?.cancellation?.isCancelled != true else { return 0 }
            guard !SystemDataFileSupport.isSymbolicLink(file),
                  let values = try? file.resourceValues(forKeys: keys.union([.contentModificationDateKey])), values.isRegularFile == true else { continue }
            if let cutoff, let modified = values.contentModificationDate, modified > cutoff { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func systemItems() -> [Item] {
        let root = URL(fileURLWithPath: "/Library/Application Support")
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return children.compactMap { child in
            guard !["Logic", "GarageBand"].contains(child.lastPathComponent), !SystemDataFileSupport.isSymbolicLink(child),
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let size = directorySize(child)
            guard size >= 200 * SystemDataProbeRegistry.mb else { return nil }
            return Item(id: "sys-app-support-" + child.lastPathComponent, category: .system,
                        name: "系统应用数据：" + child.lastPathComponent, path: child,
                        detail: "所有用户共用的应用数据，优先通过应用自己的卸载工具处理。",
                        size: size, safety: .review, permanent: false,
                        identity: SystemDataFileSupport.fileIdentity(at: child), selected: false)
        }
    }

    static func realPath(_ url: URL) -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func withoutOverlaps(_ items: [Item]) -> [Item] {
        let prefixes = ["dynamic-", "tool-hidden-", "tool-cache-", "user-caches-"]
        return items.filter { item in
            guard prefixes.contains(where: item.id.hasPrefix) else { return true }
            let prefix = realPath(item.path) + "/"
            return !items.contains { other in other.id != item.id && other.claimedPaths.contains { realPath($0).hasPrefix(prefix) } }
        }
    }

    private static func developerItems() -> [Item] {
        let home = SystemDataProbeRegistry.home
        let covered = Set([".npm", ".cargo", ".Trash", ".android", ".gradle", ".cache", ".ollama"] + SystemDataProbeRegistry.all.map { spec in
            String(spec.url.path.dropFirst(home.path.count + 1).split(separator: "/").first ?? "")
        })
        let roots: [(URL, String, Safety, Set<String>)] = [
            (home, "tool-hidden-", .review, covered),
            (home.appendingPathComponent(".cache"), "tool-cache-", .safe, ["uv", "huggingface", "torch"])
        ]
        return roots.flatMap { root, prefix, safety, excluded -> [Item] in
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            return children.compactMap { child in
                guard !SystemDataFileSupport.isSymbolicLink(child), !excluded.contains(child.lastPathComponent),
                      prefix != "tool-hidden-" || child.lastPathComponent.hasPrefix("."),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                let size = directorySize(child)
                guard size >= 100 * SystemDataProbeRegistry.mb else { return nil }
                return Item(id: prefix + child.lastPathComponent, category: .tools, name: "开发工具数据：" + child.lastPathComponent,
                            path: child, detail: safety == .safe ? "工具可重新生成的缓存。" : "未识别的工具数据，请确认来源和用途。",
                            size: size, safety: safety, permanent: false, identity: SystemDataFileSupport.fileIdentity(at: child), selected: false)
            }
        }
    }

    static var hasFullDiskAccess: Bool {
        if let cached = scanCache?.fullDiskAccess { return cached }
        let result = (try? FileManager.default.contentsOfDirectory(atPath: SystemDataProbeRegistry.home
            .appendingPathComponent("Library/Safari").path)) != nil
        scanCache?.fullDiskAccess = result
        return result
    }
}
