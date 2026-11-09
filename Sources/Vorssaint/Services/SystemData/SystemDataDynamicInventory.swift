// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation
import Darwin

extension SystemDataService {
    // Thread-local and discarded after each inventory; never caches cleanup commands.
    final class ScanCache {
        var tools: [String: String] = [:]
        var missingTools = Set<String>()
        var json: [String: [String: Any]] = [:]
        var failedJSON = Set<String>()
        var fullDiskAccess: Bool?
        var cancellation: BoundedProcessCancellation?
    }
    static let scanCacheKey = "Vorssaint.SystemData.ScanCache"
    static var scanCache: ScanCache? { Thread.current.threadDictionary[scanCacheKey] as? ScanCache }

    static func tool(_ name: String) -> String? {
        if let cached = scanCache?.tools[name] { return cached }
        if scanCache?.missingTools.contains(name) == true { return nil }
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let result = paths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
        if let result { scanCache?.tools[name] = result }
        else { scanCache?.missingTools.insert(name) }
        return result
    }

    private static func json(_ executable: String, _ arguments: [String]) -> [String: Any]? {
        let key = ([executable] + arguments).joined(separator: "\0")
        if let cached = scanCache?.json[key] { return cached }
        if scanCache?.failedJSON.contains(key) == true { return nil }
        guard let output = runCommand(executable, arguments), let data = output.data(using: .utf8),
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            scanCache?.failedJSON.insert(key)
            return nil
        }
        scanCache?.json[key] = result
        return result
    }

    private static func children(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { !SystemDataFileSupport.isSymbolicLink($0) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func row(_ id: String, _ category: SystemDataCategory, _ name: String, _ path: URL,
                            _ safety: Safety, minimum: Int64 = 1, detail: String = "请确认内容及用途。") -> Item? {
        let size = directorySize(path)
        guard size >= minimum else { return nil }
        return Item(id: id, category: category, name: name, path: path, detail: detail, size: size,
                    safety: safety, permanent: false, identity: SystemDataFileSupport.fileIdentity(at: path), selected: false)
    }

    static func packagePolicies(_ items: [Item]) -> [Item] {
        let uvRunning = !(runCommand("/usr/bin/pgrep", ["-x", "uv"]) ?? "").isEmpty
        let commands: [String: (String, [String])] = [
            "homebrew-cache": ("brew", ["cleanup", "--prune=all", "-s"]),
            "npm-cache": ("npm", ["cache", "clean", "--force"]),
            "yarn-cache": ("yarn", ["cache", "clean"]),
            "pip-cache": ("pip3", ["cache", "purge"]),
            "uv-cache": ("uv", ["cache", "clean"]),
            "cocoapods-cache": ("pod", ["cache", "clean", "--all"]),
            "conda-cache": ("conda", ["clean", "--all", "-y"]),
            "go-cache": ("go", ["clean", "-modcache"])
        ]
        return items.map { item in
            if item.id == "uv-cache", uvRunning {
                return Item(id: item.id, category: item.category, name: item.name, path: item.path,
                            detail: "检测到运行中的 uv 进程；先退出 uv/uvx 工具，再清理此缓存。", size: item.size,
                            safety: .manual, permanent: false, identity: item.identity, selected: false)
            }
            var updated = item
            if item.id == "system-reports" { updated.cleanup = .administrator(.diagnosticReports) }
            if item.id == "log-asl" { updated.cleanup = .administrator(.legacyASL) }
            if let (name, arguments) = commands[item.id], let executable = tool(name) {
                updated.cleanup = .commands([[executable] + arguments])
            }
            return updated
        }
    }

    static func packageInventory() -> [Item] {
        var result: [Item] = []
        let home = SystemDataProbeRegistry.home
        if let pnpm = tool("pnpm") {
            if let path = runCommand(pnpm, ["store", "path"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, var item = row("pkg-pnpm", .packages, "pnpm 存储", URL(fileURLWithPath: path), .safe,
                                           minimum: SystemDataProbeRegistry.mb, detail: "显示整个 pnpm 存储占用；使用 pnpm store prune 回收未引用内容，清理后可能仍有保留数据。") {
                item.cleanup = .commands([[pnpm, "store", "prune"]])
                result.append(item)
            }
        } else if let path = ["Library/pnpm/store", ".local/share/pnpm/store", ".pnpm-store"].map({ home.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let item = row("pkg-pnpm", .packages, "pnpm 存储（未找到 pnpm）", path, .review, minimum: SystemDataProbeRegistry.mb) {
            result.append(item)
        }
        for prefix in ["/opt/homebrew", "/usr/local"] where FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: prefix).appendingPathComponent("bin").appendingPathComponent("brew").path) {
            if let item = row("pkg-homebrew-" + prefix, .packages, "Homebrew 安装内容", URL(fileURLWithPath: prefix), .manual,
                              minimum: 100 * SystemDataProbeRegistry.mb, detail: "全部 formula 和 cask。请使用 brew uninstall 或 brew autoremove 管理。") { result.append(item) }
        }
        return result
    }

    static func dockerInventory() -> [Item] {
        let root = SystemDataProbeRegistry.home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms")
        guard let docker = tool("docker"), runCommand(docker, ["info"]) != nil,
              let output = runCommand(docker, ["system", "df", "--format", "{{json .}}"] ) else {
            return row("docker-vm", .docker, "Docker 磁盘映像", root, .manual, minimum: 100 * SystemDataProbeRegistry.mb,
                       detail: "Docker 未运行；启动 Docker Desktop 后使用 Docker 的 prune 命令清理。 ").map { [$0] } ?? []
        }
        let kinds: [String: (String, Safety, [String])] = [
            "Build Cache": ("Docker 构建缓存", .safe, ["builder", "prune", "-a", "-f"]),
            "Images": ("未使用的 Docker 镜像", .review, ["image", "prune", "-a", "-f"]),
            "Containers": ("已停止的 Docker 容器", .review, ["container", "prune", "-f"]),
            "Local Volumes": ("未使用的 Docker 卷", .review, ["volume", "prune", "-a", "-f"])
        ]
        let reclaimable: [Item] = output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = entry["Type"] as? String, let kind = kinds[type], let text = entry["Reclaimable"] as? String else { return nil }
            let scanner = Scanner(string: text)
            guard let number = scanner.scanDouble() else { return nil }
            let unit = scanner.scanCharacters(from: .letters)?.uppercased() ?? "B"
            let factor: Double = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 1
            let bytes = Int64(number * factor)
            guard bytes > 0 else { return nil }
            var item = Item(id: "docker-" + type, category: .docker, name: kind.0, path: root,
                            detail: "容量来自 docker system df 的 Reclaimable；卷和容器可能包含未备份数据。", size: bytes,
                            safety: kind.1, permanent: false, identity: nil, selected: false)
            item.cleanup = .commands([[docker] + kind.2])
            return item
        }
        return reclaimable + composeInventory(docker: docker)
    }

    static func runtimeInventory() -> [Item] {
        guard let runtimes = json("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]) else { return [] }
        let matches = json("/usr/bin/xcrun", ["simctl", "runtime", "match", "list", "-j"])
        let chosen = matches.map { Set($0.values.compactMap { ($0 as? [String: Any])?["chosenRuntimeBuild"] as? String }) }
        let devices = json("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])?["devices"] as? [String: [Any]]
        return runtimes.compactMap { identifier, value in
            guard let runtime = value as? [String: Any], runtime["deletable"] as? Bool == true,
                  let version = runtime["version"] as? String, let build = runtime["build"] as? String else { return nil }
            let runtimeID = runtime["runtimeIdentifier"] as? String
            let unused = chosen.map { builds in
                guard !builds.contains(build), let runtimeID, let devices else { return false }
                return (devices[runtimeID] ?? []).isEmpty
            } ?? false
            var item = Item(id: "runtime-" + identifier, category: .runtimes,
                            name: "模拟器运行时 \(version)（\(build)）" + (unused ? " · 未使用" : ""), path: URL(fileURLWithPath: runtime["path"] as? String ?? "/"),
                            detail: "删除后使用此运行时的模拟器将无法启动，可从 Xcode 组件设置重新下载。",
                            size: (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0, safety: .review,
                            permanent: false, identity: nil, selected: false)
            item.cleanup = .commands([["/usr/bin/xcrun", "simctl", "runtime", "delete", identifier]])
            return item
        }
    }

    static func deviceInventory() -> [Item] {
        guard let groups = json("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])?["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [Item] = []
        var cachePaths: [URL] = []
        var cacheBytes: Int64 = 0
        for devices in groups.values {
            for device in devices {
                guard let id = device["udid"] as? String, let name = device["name"] as? String, let path = device["dataPath"] as? String else { continue }
                let root = URL(fileURLWithPath: path)
                let available = device["isAvailable"] as? Bool ?? false
                let bytes = (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0
                if !available {
                    var item = Item(id: "sim-unavailable-" + id, category: .simulators, name: "不可用模拟器：" + name,
                                    path: root, detail: "对应运行时已卸载，此设备无法启动。", size: bytes, safety: .safe,
                                    permanent: false, identity: nil, selected: false)
                    item.cleanup = .commands([["/usr/bin/xcrun", "simctl", "delete", id]])
                    result.append(item)
                } else {
                    let caches = [root.appendingPathComponent("Library/Caches"), root.appendingPathComponent("tmp")].filter { FileManager.default.fileExists(atPath: $0.path) }
                    let deviceCacheBytes = caches.reduce(Int64(0)) { $0 + directorySize($1) }
                    cachePaths += caches
                    cacheBytes += deviceCacheBytes
                    let eraseBytes = max(bytes - deviceCacheBytes, 0)
                    guard eraseBytes >= 100 * SystemDataProbeRegistry.mb else { continue }
                    var item = Item(id: "sim-erase-" + id, category: .simulators, name: "重置模拟器：" + name,
                                    path: root, detail: "恢复出厂状态，模拟器中的应用与数据将丢失。", size: eraseBytes,
                                    safety: .review, permanent: false, identity: nil, selected: false)
                    item.cleanup = .commands([["/usr/bin/xcrun", "simctl", "shutdown", "all"], ["/usr/bin/xcrun", "simctl", "erase", id]])
                    result.append(item)
                }
            }
        }
        let shared = SystemDataProbeRegistry.home.appendingPathComponent("Library/Developer/CoreSimulator/Caches/dyld")
        if FileManager.default.fileExists(atPath: shared.path) { cachePaths.append(shared); cacheBytes += directorySize(shared) }
        if cacheBytes > 0 {
            var item = Item(id: "sim-caches", category: .simulators, name: "模拟器设备缓存", path: SystemDataProbeRegistry.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"),
                            detail: "每台设备的 Caches 和 tmp，以及共享 dyld 缓存；清理前关闭模拟器。", size: cacheBytes,
                            safety: .safe, permanent: false, identity: nil, selected: false)
            item.cleanup = .remove(cachePaths, contentsOnly: true, shutdownSimulators: true)
            item.additionalClaims = cachePaths
            result.append(item)
        }
        if let item = row("sim-system-dyld", .simulators, "系统模拟器 dyld 缓存", URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches/dyld"), .manual,
                          minimum: 50 * SystemDataProbeRegistry.mb, detail: "受 macOS 保护，只能随所属运行时一同移除。") { result.append(item) }
        return result
    }

    static func componentInventory() -> [Item] {
        let home = SystemDataProbeRegistry.home
        let mb = SystemDataProbeRegistry.mb
        var result: [Item] = []
        for backup in children(home.appendingPathComponent("Library/Application Support/MobileSync/Backup")) {
            let info = NSDictionary(contentsOf: backup.appendingPathComponent("Info.plist"))
            if let item = row("backup-" + backup.lastPathComponent, .backups, info?["Device Name"] as? String ?? backup.lastPathComponent,
                              backup, .review, detail: "设备本地备份，可能是唯一的备份副本。") { result.append(item) }
        }
        for entry in children(URL(fileURLWithPath: "/Users/Shared")) {
            let support = entry.appendingPathComponent("Application Support")
            let candidates = entry.lastPathComponent == "Library" && FileManager.default.fileExists(atPath: support.path) ? children(support) : [entry]
            result += candidates.compactMap { row("shared-" + $0.path, .shared, $0.lastPathComponent, $0, .review, minimum: 20 * mb) }
        }
        let sources: [(String, String?, String)] = [
            ("Parallels", "pvm", "Parallels"), ("Documents/Parallels", "pvm", "Parallels"),
            ("Library/Containers/com.utmapp.UTM/Data/Documents", "utm", "UTM"),
            ("Virtual Machines.localized", "vmwarevm", "VMware"), ("Documents/Virtual Machines.localized", "vmwarevm", "VMware"),
            ("VirtualBox VMs", nil, "VirtualBox"), (".tart/vms", nil, "Tart")
        ]
        for (relative, suffix, product) in sources {
            if !hasFullDiskAccess && (relative.hasPrefix("Documents/") || relative.hasPrefix("Library/Containers/")) { continue }
            for machine in children(home.appendingPathComponent(relative)) where suffix == nil || machine.pathExtension == suffix {
                if let item = row("vm-" + machine.path, .vms, product + "：" + machine.deletingPathExtension().lastPathComponent, machine, .review,
                                  minimum: 50 * mb, detail: "完整虚拟机及其中的全部数据。") { result.append(item) }
            }
        }
        for account in children(URL(fileURLWithPath: "/Users")) where account.lastPathComponent != home.lastPathComponent && account.lastPathComponent != "Shared" {
            result.append(Item(id: "shared-user-" + account.lastPathComponent, category: .shared, name: "用户账户：" + account.lastPathComponent,
                               path: account, detail: "其他用户的主目录；通过系统设置中的用户与群组管理。", size: directorySize(account), safety: .manual,
                               permanent: false, identity: nil, selected: false))
        }
        if hasFullDiskAccess {
            for root in [home.appendingPathComponent("Movies"), home.appendingPathComponent("Documents")] {
                for library in children(root) where library.pathExtension == "fcpbundle" {
                    let renders = children(library).map { $0.appendingPathComponent("Render Files") }.filter { FileManager.default.fileExists(atPath: $0.path) }
                    let size = renders.reduce(Int64(0)) { $0 + directorySize($1) }
                    if size >= 20 * mb {
                        var item = Item(id: "fcp-renders-" + library.path, category: .apps, name: "Final Cut 渲染文件：" + library.deletingPathExtension().lastPathComponent,
                                        path: library, detail: "打开项目时可重新生成；优先在 Final Cut 中删除生成的资源库文件。", size: size,
                                        safety: .safe, permanent: false, identity: nil, selected: false)
                        item.cleanup = .remove(renders, contentsOnly: true); result.append(item)
                    }
                }
            }
        }
        let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Android/sdk")
        for folder in ["system-images", "platforms", "build-tools", "ndk", "cmake", "sources"] {
            result += children(sdk.appendingPathComponent(folder)).compactMap { row("android-" + $0.path, .android, "Android \(folder)：" + $0.lastPathComponent, $0, .review, minimum: folder == "system-images" ? 1 : 20 * mb) }
        }
        for folder in ["emulator", "cmdline-tools", "platform-tools", "extras", "skins", "licenses"] {
            let path = sdk.appendingPathComponent(folder)
            if let item = row("android-" + folder, .android, "Android SDK：" + folder, path, .review, minimum: 20 * mb) { result.append(item) }
        }
        for cache in children(home.appendingPathComponent("Library/Caches/Google")) where cache.lastPathComponent.hasPrefix("AndroidStudio") {
            if var item = row("android-studio-cache-" + cache.lastPathComponent, .android, cache.lastPathComponent + " 缓存", cache, .safe, minimum: 10 * mb) {
                item.cleanup = .remove([cache], contentsOnly: true); result.append(item)
            }
        }
        for avd in children(home.appendingPathComponent(".android/avd")) where avd.pathExtension == "avd" {
            if let item = row("android-avd-" + avd.path, .android, "Android 模拟器：" + avd.deletingPathExtension().lastPathComponent, avd, .review) { result.append(item) }
        }
        return result
    }
}

extension SystemDataService {
    static func modelInventory() -> [Item] {
        let home = SystemDataProbeRegistry.home
        let env = ProcessInfo.processInfo.environment
        let root = env["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".ollama/models")
        let threshold = 100 * SystemDataProbeRegistry.mb
        var models: [(String, [String: Int64])] = []
        let manifests = root.appendingPathComponent("manifests")
        if let walker = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walker {
                guard !SystemDataFileSupport.isSymbolicLink(file),
                      let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let components = Array(file.pathComponents.dropFirst(manifests.pathComponents.count))
                guard components.count >= 4 else { continue }
                let registry = components.dropLast(3).joined(separator: "/")
                let namespace = components[components.count - 3]
                let name = (registry == "registry.ollama.ai" ? (namespace == "library" ? "" : namespace + "/") : registry + "/" + namespace + "/") + components[components.count - 2] + ":" + components.last!
                var layers: [String: Int64] = [:]
                let entries = (object["layers"] as? [[String: Any]] ?? []) + (object["config"].map { [$0 as? [String: Any] ?? [:]] } ?? [])
                for entry in entries {
                    if let digest = entry["digest"] as? String, let size = entry["size"] as? NSNumber { layers[digest] = size.int64Value }
                }
                models.append((name, layers))
            }
        }
        var result: [Item] = []
        var users: [String: Int] = [:]
        var bytes: [String: Int64] = [:]
        for (_, layers) in models { for (digest, size) in layers { users[digest, default: 0] += 1; bytes[digest] = size } }
        let ollama = tool("ollama")
        for (name, layers) in models {
            let size = layers.filter { users[$0.key] == 1 }.values.reduce(0, +)
            guard size >= threshold else { continue }
            var item = Item(id: "ai-ollama-" + name, category: .ai, name: "Ollama：" + name, path: root,
                            detail: "仅计算此模型独占的层；使用 ollama rm 管理共享层。", size: size,
                            safety: ollama == nil ? .manual : .review, permanent: false, identity: nil, selected: false)
            if let ollama { item.cleanup = .commands([[ollama, "rm", name]]) }
            result.append(item)
        }
        let shared = users.filter { $0.value > 1 }.keys.reduce(Int64(0)) { $0 + (bytes[$1] ?? 0) }
        if shared >= threshold {
            result.append(Item(id: "ai-ollama-shared", category: .ai, name: "Ollama 共享模型层", path: root,
                               detail: "最后一个使用这些层的模型被移除后，空间才会释放。", size: shared, safety: .manual,
                               permanent: false, identity: nil, selected: false))
        }
        if !result.contains(where: { $0.id.hasPrefix("ai-ollama") }), let fallback = row("tool-ollama", .ai, "Ollama 模型", root, .review, minimum: 10 * SystemDataProbeRegistry.mb) { result.append(fallback) }
        let hub = env["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) } ?? env["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") } ?? home.appendingPathComponent(".cache/huggingface/hub")
        for folder in children(hub) where ["models--", "datasets--", "spaces--"].contains(where: folder.lastPathComponent.hasPrefix) {
            if let item = row("ai-hf-" + folder.lastPathComponent, .ai, "Hugging Face：" + folder.lastPathComponent.replacingOccurrences(of: "--", with: "/"), folder, .review, minimum: threshold) { result.append(item) }
        }
        let xet = hub.deletingLastPathComponent().appendingPathComponent("xet")
        if let item = row("ai-hf-xet", .ai, "Hugging Face 下载分块", xet, .review, minimum: threshold) { result.append(item) }
        if !result.contains(where: { $0.id.hasPrefix("ai-hf") }), let item = row("tool-huggingface", .ai, "Hugging Face 缓存", home.appendingPathComponent(".cache/huggingface"), .review, minimum: 10 * SystemDataProbeRegistry.mb) { result.append(item) }
        return result
    }

    static func ideInventory() -> [Item] {
        let home = SystemDataProbeRegistry.home
        let caches = home.appendingPathComponent("Library/Caches/JetBrains")
        let settings = home.appendingPathComponent("Library/Application Support/JetBrains")
        var versions: [String: [(String, Int)]] = [:]
        let pattern = try! NSRegularExpression(pattern: "^([A-Za-z]+)([0-9]{4})\\.([0-9]{1,2})$")
        for child in children(caches) + children(settings) {
            let name = child.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard let match = pattern.firstMatch(in: name, range: range),
                  let productRange = Range(match.range(at: 1), in: name),
                  let yearRange = Range(match.range(at: 2), in: name), let minorRange = Range(match.range(at: 3), in: name),
                  let year = Int(name[yearRange]), let minor = Int(name[minorRange]) else { continue }
            let product = String(name[productRange])
            if !(versions[product] ?? []).contains(where: { $0.0 == name }) { versions[product, default: []].append((name, year * 100 + minor)) }
        }
        var result: [Item] = []
        for entries in versions.values {
            let newest = entries.map(\.1).max()
            for (name, version) in entries {
                let cache = caches.appendingPathComponent(name)
                let config = settings.appendingPathComponent(name)
                if version == newest {
                    if let item = row("jetbrains-caches-" + name, .tools, name + " 缓存", cache, .safe, minimum: 20 * SystemDataProbeRegistry.mb) { result.append(item) }
                } else {
                    let size = directorySize(cache) + directorySize(config)
                    if size >= 20 * SystemDataProbeRegistry.mb {
                        result.append(Item(id: "jetbrains-old-" + name, category: .tools, name: name + "（旧版本）", path: cache,
                                           detail: "旧版本的缓存、设置和插件；仍使用此版本时请保留。", size: size, safety: .review,
                                           permanent: false, identity: SystemDataFileSupport.fileIdentity(at: cache), selected: false,
                                           additionalClaims: [config], cleanup: .remove([cache, config].filter { FileManager.default.fileExists(atPath: $0.path) }, contentsOnly: false)))
                    }
                }
            }
        }
        let unity = home.appendingPathComponent("Library/Unity")
        for store in children(unity) where store.lastPathComponent.hasPrefix("Asset Store") {
            if let item = row("unity-" + store.lastPathComponent, .tools, "Unity Asset Store 下载", store, .review, minimum: 20 * SystemDataProbeRegistry.mb) { result.append(item) }
        }
        for editor in children(URL(fileURLWithPath: "/Applications/Unity/Hub/Editor")) {
            if let item = row("unity-editor-" + editor.lastPathComponent, .tools, "Unity " + editor.lastPathComponent, editor, .manual, minimum: 100 * SystemDataProbeRegistry.mb, detail: "请通过 Unity Hub 的安装管理卸载编辑器。") { result.append(item) }
        }
        return result
    }
}

extension SystemDataService {
    static func xcodeInventory() -> [Item] {
        let home = SystemDataProbeRegistry.home
        let root = home.appendingPathComponent("Library/Developer/Xcode")
        let derived = root.appendingPathComponent("DerivedData")
        var result: [Item] = []
        var shared: [URL] = []
        for folder in children(derived) {
            let info = NSDictionary(contentsOf: folder.appendingPathComponent("info.plist"))
            guard let workspace = info?["WorkspacePath"] as? String, !workspace.isEmpty else { shared.append(folder); continue }
            var project = URL(fileURLWithPath: workspace)
            while ["xcodeproj", "xcworkspace"].contains(project.pathExtension) { project.deleteLastPathComponent() }
            if let item = row("xcode-deriveddata-" + folder.lastPathComponent, .xcode, "构建数据：" + project.lastPathComponent,
                              folder, .safe, minimum: SystemDataProbeRegistry.mb, detail: project.path + "。构建产物和索引，可重新生成。") { result.append(item) }
        }
        let sharedBytes = shared.reduce(Int64(0)) { $0 + directorySize($1) }
        if sharedBytes > 0 {
            var item = Item(id: "xcode-DerivedData", category: .xcode, name: "Xcode 共享模块与符号缓存", path: derived,
                            detail: "项目共用的构建缓存，可重新生成。", size: sharedBytes, safety: .safe,
                            permanent: false, identity: SystemDataFileSupport.fileIdentity(at: derived), selected: false)
            item.cleanup = .remove(shared, contentsOnly: false)
            result.append(item)
        }
        for (relative, name, safety) in [
            ("iOS DeviceSupport", "iOS 设备支持文件", Safety.safe),
            ("watchOS DeviceSupport", "watchOS 设备支持文件", .safe),
            ("tvOS DeviceSupport", "tvOS 设备支持文件", .safe),
            ("visionOS DeviceSupport", "visionOS 设备支持文件", .safe),
            ("UserData/Previews/Simulator Devices", "SwiftUI 预览模拟器", .safe),
            ("Archives", "Xcode 发布归档", .review)
        ] {
            let path = root.appendingPathComponent(relative)
            if var item = row("xcode-" + relative, .xcode, name, path, safety,
                              detail: safety == .safe ? "连接设备或构建时可重新生成。" : "包含发布归档和 dSYM；仍需分析崩溃的构建应保留。") {
                item.cleanup = .remove([path], contentsOnly: true)
                result.append(item)
            }
        }
        let cache = home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode")
        if var item = row("xcode-caches", .xcode, "Xcode 文档与下载缓存", cache, .safe, minimum: SystemDataProbeRegistry.mb) {
            item.cleanup = .remove([cache], contentsOnly: true); result.append(item)
        }
        if let active = runCommand("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines), !active.isEmpty {
            let activePath = realPath(URL(fileURLWithPath: active)) + "/"
            for app in children(URL(fileURLWithPath: "/Applications")) where app.lastPathComponent.hasPrefix("Xcode") && app.pathExtension == "app" {
                guard !activePath.hasPrefix(realPath(app) + "/") else { continue }
                if let item = row("xcode-app-" + app.lastPathComponent, .xcode, "非当前版本：" + app.lastPathComponent, app, .review, detail: "不是 xcode-select 当前选中的开发工具目录。") { result.append(item) }
            }
        }
        return result
    }

    static func systemComponentInventory() -> [Item] {
        var result: [Item] = []
        let home = SystemDataProbeRegistry.home
        for app in children(URL(fileURLWithPath: "/Applications")) where app.lastPathComponent.hasPrefix("Install macOS") && app.pathExtension == "app" {
            if let item = row("sys-installer-" + app.lastPathComponent, .system, app.deletingPathExtension().lastPathComponent, app, .review,
                              detail: "下载的 macOS 安装器，可通过软件更新重新下载。") { result.append(item) }
        }
        for folder in children(home.appendingPathComponent("Library/iTunes")) where folder.lastPathComponent.hasSuffix("Software Updates") {
            if var item = row("sys-ipsw-" + folder.lastPathComponent, .system, "设备固件：" + folder.lastPathComponent, folder, .safe) {
                item.cleanup = .remove([folder], contentsOnly: true); result.append(item)
            }
        }
        let cacheRoot = URL(fileURLWithPath: "/Library/Caches")
        let cacheEntries = ((try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []).filter { entry in
            var info = stat()
            return lstat(entry.path, &info) == 0 && info.st_flags & (UInt32(SF_RESTRICTED) | UInt32(UF_DATAVAULT)) == 0
        }
        let cacheBytes = cacheEntries.reduce(Int64(0)) { $0 + directorySize($1) }
        if !cacheEntries.isEmpty, cacheBytes >= 10 * SystemDataProbeRegistry.mb {
            var item = Item(id: "sys-library-caches", category: .system, name: "系统共享缓存", path: cacheRoot,
                            detail: "只统计未受系统保护的缓存项，可由所属系统服务重新生成。", size: cacheBytes, safety: .safe,
                            permanent: false, identity: nil, selected: false)
            item.cleanup = .administrator(.sharedCaches)
            item.additionalClaims = cacheEntries
            result.append(item)
        }
        let clt = URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        let active = runCommand("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let redundant = active.map { !$0.hasPrefix(clt.path) } == true && children(URL(fileURLWithPath: "/Applications")).contains { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
        if let item = row("sys-clt", .system, "Command Line Tools", clt, redundant ? .review : .manual,
                          detail: redundant ? "当前选中的 Xcode 已提供这些工具，可重新安装。" : "终端所需编译器和 SDK，应保留。") { result.append(item) }
        return result
    }
}

extension SystemDataService {
    /// Engine API unique image sizes avoid charging shared layers to each project.
    static func composeInventory(docker: String) -> [Item] {
        guard let host = runCommand(docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"] )?.trimmingCharacters(in: .whitespacesAndNewlines), host.hasPrefix("unix://"),
              let api = runCommand(docker, ["version", "--format", "{{.Server.APIVersion}}"] )?.trimmingCharacters(in: .whitespacesAndNewlines), !api.isEmpty, api.allSatisfy({ $0.isNumber || $0 == "." }),
              let output = runCommand("/usr/bin/curl", ["--silent", "--fail", "--max-time", "60", "--unix-socket", String(host.dropFirst(7)), "http://localhost/v" + api + "/system/df?verbose=1"], timeout: 70),
              let data = output.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        func list(_ legacy: String, _ current: [String]) -> [[String: Any]] {
            for key in current { if let rows = (json[key] as? [String: Any])?["Items"] as? [[String: Any]] { return rows } }
            return json[legacy] as? [[String: Any]] ?? []
        }
        let containers = list("Containers", ["ContainersUsage", "ContainerUsage"])
        let images = list("Images", ["ImagesUsage", "ImageUsage"])
        let volumes = list("Volumes", ["VolumesUsage", "VolumeUsage"])
        let projectKey = "com.docker.compose.project"
        let directoryKey = "com.docker.compose.project.working_dir"
        var owners: [String: Set<String>] = [:]
        var projects: [String: (URL, [String], Bool)] = [:]
        for container in containers {
            let labels = container["Labels"] as? [String: String] ?? [:]
            if let image = container["ImageID"] as? String { owners[image, default: []].insert(labels[projectKey] ?? "") }
            guard let name = labels[projectKey], let directory = labels[directoryKey], directory.hasPrefix("/"), let id = container["Id"] as? String else { continue }
            var project = projects[name] ?? (URL(fileURLWithPath: directory), [], false)
            project.1.append(id)
            project.2 = project.2 || ["running", "paused", "restarting"].contains(container["State"] as? String ?? "")
            projects[name] = project
        }
        var result: [Item] = []
        for (name, project) in projects {
            let owned = images.filter { owners[$0["Id"] as? String ?? ""] == Set([name]) }
            let bytes = owned.reduce(Int64(0)) { sum, image in
                let shared = (image["SharedSize"] as? NSNumber)?.int64Value ?? -1
                let total = (image["Size"] as? NSNumber)?.int64Value ?? 0
                return sum + (shared >= 0 ? max(total - shared, 0) : 0)
            }
            if bytes > 0 {
                var item = Item(id: "docker-project-images-" + name, category: .docker, name: "Docker 项目镜像：" + name, path: project.0,
                                detail: project.2 ? "项目容器仍在运行，镜像正在使用。" : "仅此项目使用的镜像独占层；保留数据卷。", size: bytes,
                                safety: project.2 ? .manual : .review, permanent: false, identity: nil, selected: false)
                let references = owned.flatMap { image -> [String] in
                    let tags = (image["RepoTags"] as? [String] ?? []).filter { $0 != "<none>:<none>" }
                    return tags.isEmpty ? [image["Id"] as? String ?? ""].filter { !$0.isEmpty } : tags
                }
                if !project.2 { item.cleanup = .commands([[docker, "container", "rm"] + project.1, [docker, "image", "rm"] + references]) }
                result.append(item)
            }
            let volumeBytes = volumes.reduce(Int64(0)) { sum, volume in
                guard (volume["Labels"] as? [String: String])?[projectKey] == name,
                      let usage = volume["UsageData"] as? [String: Any], (usage["RefCount"] as? NSNumber)?.int64Value ?? 0 > 0 else { return sum }
                return sum + max((usage["Size"] as? NSNumber)?.int64Value ?? 0, 0)
            }
            if volumeBytes > 0 {
                result.append(Item(id: "docker-project-volumes-" + name, category: .docker, name: "Docker 项目数据卷：" + name, path: project.0,
                                   detail: "容器使用的数据卷，可能包含数据库；请通过 docker compose 管理。", size: volumeBytes,
                                   safety: .manual, permanent: false, identity: nil, selected: false))
            }
        }
        return result
    }
}
