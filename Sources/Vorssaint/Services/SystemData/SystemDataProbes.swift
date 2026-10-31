// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Category and safety vocabulary follows macos-sysdata's public model.
enum SystemDataCategory: String, CaseIterable, Sendable {
    case snapshots, simulators, runtimes, xcode, packages, tools, ai, logs, temp, docker
    case vms, trash, backups, shared, android, apps, projects, system, other

    var title: String {
        switch self {
        case .snapshots: "Time Machine 快照"; case .simulators: "模拟器设备"; case .runtimes: "模拟器运行时"
        case .xcode: "Xcode"; case .packages: "包管理器"; case .tools: "开发工具数据"; case .ai: "AI 模型与工具"
        case .logs: "日志与诊断"; case .temp: "临时文件"; case .docker: "Docker"; case .vms: "虚拟机"
        case .trash: "废纸篓"; case .backups: "iOS 设备备份"; case .shared: "共享与其他用户"
        case .android: "Android"; case .apps: "应用数据与缓存"; case .projects: "项目构建目录"
        case .system: "系统"; case .other: "其他大型文件夹"
        }
    }
}

enum SystemDataSafety: String, Sendable { case safe, review, manual }

struct SystemDataProbeSpec: Sendable {
    let id: String
    let category: SystemDataCategory
    let name: String
    let detail: String
    let url: URL
    let safety: SystemDataSafety
    let minimumBytes: Int64
    let permanent: Bool
}

enum SystemDataProbeRegistry {
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    static let mb: Int64 = 1_048_576

    private static func p(_ id: String, _ category: SystemDataCategory, _ name: String,
                          _ detail: String, _ path: String, _ safety: SystemDataSafety,
                          _ minimum: Int64 = 1, permanent: Bool = false) -> SystemDataProbeSpec {
        SystemDataProbeSpec(id: id, category: category, name: name, detail: detail,
                            url: path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path),
                            safety: safety, minimumBytes: minimum, permanent: permanent)
    }

    /// Concrete probes are registered here; the inventory pass also runs a
    /// claimed-path-aware large-folder scan for locations no probe recognizes.
    static let all: [SystemDataProbeSpec] = [
        p("log-asl", .logs, "旧版 ASL 日志", "系统旧版日志，通过管理员命令清理。", "/private/var/log/asl", .safe),
        p("trash", .trash, "废纸篓", "已移入废纸篓的项目，清空后无法恢复。", ".Trash", .safe, permanent: true),
        p("user-logs", .logs, "应用日志", "应用诊断日志和崩溃报告。", "Library/Logs", .safe, 1),
        p("xcode-device-logs", .xcode, "iOS 设备日志", "从连接设备复制的崩溃日志。", "Library/Developer/Xcode/iOS Device Logs", .safe, 1 * mb),
        p("homebrew-cache", .packages, "Homebrew 下载缓存", "Homebrew 下载的安装包和元数据。", "Library/Caches/Homebrew", .safe, 1 * mb),
        p("npm-cache", .packages, "npm 缓存", "npm 包缓存，可以重新下载。", ".npm/_cacache", .safe, 1 * mb),
        p("conda-cache", .tools, "Conda 包缓存", "下载的 Conda 包，可以重新获取。", ".conda/pkgs", .safe, 10 * mb),
        p("maven-cache", .tools, "Maven 仓库", "构建时可重新下载的 jar 包。", ".m2/repository", .safe, 10 * mb),
        p("gradle-cache", .packages, "Gradle 缓存", "Gradle 分发包和构建缓存。", ".gradle/caches", .safe, 1 * mb),
        p("go-cache", .tools, "Go 模块缓存", "Go 模块可以重新下载。", "go/pkg/mod", .safe, 10 * mb),
        p("lmstudio", .ai, "LM Studio 模型", "下载的模型权重。", ".lmstudio", .review, 10 * mb),
        p("codex", .ai, "Codex 数据", "会话记录和缓存。", ".codex", .review, 10 * mb),
        p("claude", .ai, "Claude Code 数据", "会话、记忆、插件和缓存。", ".claude", .review, 10 * mb),
        p("slack-cache", .apps, "Slack 缓存", "消息和文件预览，可在使用时重新生成。", "Library/Application Support/Slack/Cache", .safe, 20 * mb),
        p("discord-cache", .apps, "Discord 缓存", "媒体预览，可重新生成。", "Library/Application Support/discord/Cache", .safe, 20 * mb),
        p("spotify-cache", .apps, "Spotify 缓存", "流媒体缓存，下载的播放列表不在此处。", "Library/Application Support/Spotify/PersistentCache", .safe, 20 * mb),
        p("quicklook-cache", .apps, "Quick Look 缩略图", "按需重新生成的预览缩略图。", "Library/Caches/com.apple.QuickLook.thumbnailcache", .safe, 20 * mb),
        p("mail-downloads", .system, "Mail 附件下载", "邮件原件仍保存在邮件中。", "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .safe, 1 * mb),
        p("swiftpm-cache", .packages, "SwiftPM 缓存", "Swift 包仓库克隆，可以重新获取。", "Library/Caches/org.swift.swiftpm", .safe, 1 * mb),
        p("cargo-cache", .packages, "Cargo 注册表", "Rust crate 源码和下载包。", ".cargo/registry", .safe, 1 * mb),
        p("pip-cache", .packages, "pip 缓存", "Python wheel 和 HTTP 缓存。", "Library/Caches/pip", .safe, 1 * mb),
        p("yarn-cache", .packages, "Yarn 缓存", "Yarn 包缓存。", "Library/Caches/Yarn", .safe, 1 * mb),
        p("uv-cache", .packages, "uv 缓存", "Python wheel 和解释器缓存。", ".cache/uv", .safe, 1 * mb),
        p("cocoapods-cache", .packages, "CocoaPods 缓存", "Pod specs 和源码。", "Library/Caches/CocoaPods", .safe, 1 * mb),
        p("playwright-cache", .packages, "Playwright 浏览器", "下载的浏览器构建，可重新安装。", "Library/Caches/ms-playwright", .safe, 1 * mb),
        p("cypress-cache", .packages, "Cypress 二进制文件", "下载的 Cypress 版本。", "Library/Caches/Cypress", .safe, 1 * mb),
        p("nvm-versions", .tools, "nvm Node.js 版本", "通过 nvm 安装的 Node.js 版本。", ".nvm/versions", .review, 10 * mb),
        p("rustup-toolchains", .tools, "Rust 工具链", "通过 rustup 安装的工具链。", ".rustup/toolchains", .review, 10 * mb),
        p("pyenv-versions", .tools, "pyenv Python 版本", "通过 pyenv 安装的 Python 版本。", ".pyenv/versions", .review, 10 * mb),
        p("vscode-extensions", .tools, "VS Code 扩展", "已安装扩展，可从 Marketplace 重新安装。", ".vscode/extensions", .review, 10 * mb),
        p("cursor-extensions", .tools, "Cursor 扩展", "已安装扩展。", ".cursor/extensions", .review, 10 * mb),
        p("unity-cache", .tools, "Unity 缓存", "Unity 可重建的导入和构建缓存。", "Library/Unity/cache", .safe, 20 * mb),
        p("zoom-data", .apps, "Zoom 数据", "更新包和日志。", "Library/Application Support/zoom.us", .review, 20 * mb),
        p("steam-games", .apps, "Steam 游戏", "已安装游戏。请从 Steam 中卸载以保留存档同步。", "Library/Application Support/Steam/steamapps", .review, 20 * mb),
        p("adobe-cache", .apps, "Adobe 媒体缓存", "Premiere 和 After Effects 可重新生成的渲染缓存。", "Library/Application Support/Adobe/Common/Media Cache Files", .safe, 20 * mb),
        p("whatsapp-data", .apps, "WhatsApp 聊天与媒体", "聊天、照片、视频和文件，删除可能丢失未备份内容。", "Library/Group Containers/group.net.whatsapp.WhatsApp.shared", .manual, 100 * mb),
        p("logic-library", .apps, "Logic Pro 音色库", "Logic Pro 与 GarageBand 共用的乐器和循环。", "/Library/Application Support/Logic", .manual, 100 * mb),
        p("garageband-library", .apps, "GarageBand 音色库", "Logic Pro 与 GarageBand 共用的乐器和循环。", "/Library/Application Support/GarageBand", .manual, 100 * mb),
        p("apple-loops", .apps, "Apple Loops", "Logic Pro 与 GarageBand 共用的循环素材。", "/Library/Audio/Apple Loops/Apple", .manual, 100 * mb),

        p("torch", .ai, "PyTorch 模型缓存", "请确认内容及用途后处理。", ".cache/torch", .review, 10 * mb),
        p("rbenv", .tools, "Ruby 版本", "请确认内容及用途后处理。", ".rbenv/versions", .review, 10 * mb),
        p("sdkman", .tools, "SDKMAN 工具链", "请确认内容及用途后处理。", ".sdkman/candidates", .review, 10 * mb),
        p("miniconda", .tools, "Miniconda 环境", "请确认内容及用途后处理。", "miniconda3", .review, 10 * mb),
        p("anaconda", .tools, "Anaconda 环境", "请确认内容及用途后处理。", "anaconda3", .review, 10 * mb),
        p("ivy", .tools, "Ivy 缓存", "可按需重新生成的缓存。", ".ivy2", .safe, 10 * mb),
        p("pod-repos", .tools, "CocoaPods specs", "可按需重新生成的缓存。", ".cocoapods/repos", .safe, 10 * mb),
        p("gradle-dists", .tools, "Gradle 分发包", "可按需重新生成的缓存。", ".gradle/wrapper/dists", .safe, 10 * mb),
        p("android-cache", .tools, "Android 下载缓存", "可按需重新生成的缓存。", ".android/cache", .safe, 10 * mb),
        p("bun", .tools, "Bun 缓存", "可按需重新生成的缓存。", ".bun/install/cache", .safe, 10 * mb),
        p("npx", .tools, "npx 缓存", "可按需重新生成的缓存。", ".npm/_npx", .safe, 10 * mb),
        p("deno", .tools, "Deno 缓存", "可按需重新生成的缓存。", ".deno", .safe, 10 * mb),
        p("docker-cli", .tools, "Docker CLI 数据", "请确认内容及用途后处理。", ".docker", .review, 10 * mb),
        p("orbstack", .tools, "OrbStack 数据", "请确认内容及用途后处理。", ".orbstack", .review, 10 * mb),
        p("lima", .tools, "Lima 虚拟机", "请确认内容及用途后处理。", ".lima", .review, 10 * mb),
        p("colima", .tools, "Colima 虚拟机", "请确认内容及用途后处理。", ".colima", .review, 10 * mb),
        p("grok", .ai, "Grok 数据", "请确认内容及用途后处理。", ".grok", .review, 10 * mb),
        p("copilot", .ai, "Copilot 数据", "请确认内容及用途后处理。", ".copilot", .review, 10 * mb),
        p("kilo", .ai, "Kilo 数据", "请确认内容及用途后处理。", ".kilo", .review, 10 * mb),
        p("gemini", .ai, "Gemini 数据", "请确认内容及用途后处理。", ".gemini", .review, 10 * mb),
        p("antigravity", .tools, "Antigravity 扩展", "请确认内容及用途后处理。", ".antigravity-ide/extensions", .review, 10 * mb),
        p("slack-sw", .apps, "Slack 离线缓存", "可按需重新生成的缓存。", "Library/Application Support/Slack/Service Worker/CacheStorage", .safe, 20 * mb),
        p("teams", .apps, "Teams 缓存", "可按需重新生成的缓存。", "Library/Containers/com.microsoft.teams2/Data/Library/Caches", .safe, 20 * mb),
        p("safari", .apps, "Safari 缓存", "可按需重新生成的缓存。", "Library/Containers/com.apple.Safari/Data/Library/Caches", .safe, 20 * mb),
        p("photos", .apps, "照片缓存", "可按需重新生成的缓存。", "Library/Containers/com.apple.photolibraryd/Data/Library/Caches", .safe, 20 * mb),
        p("adobe-downloads", .apps, "Creative Cloud 安装包", "请确认内容及用途后处理。", "Library/Application Support/Adobe/Adobe Desktop Common", .review, 20 * mb),
        p("epic", .apps, "Epic Games 数据", "请确认内容及用途后处理。", "Library/Application Support/Epic", .review, 20 * mb),
        p("go-build", .packages, "Go 构建缓存", "可按需重新生成的缓存。", "Library/Caches/go-build", .safe, 1 * mb),
        p("claude-vm", .ai, "Claude 本地虚拟机", "请确认内容及用途后处理。", "Library/Application Support/Claude/vm_bundles", .review, 200 * mb),
        p("chrome-model", .ai, "Chrome 本地模型", "请确认内容及用途后处理。", "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .review, 200 * mb),
        p("system-reports", .logs, "系统崩溃报告", "请确认内容及用途后处理。", "/Library/Logs/DiagnosticReports", .safe, 1),
        p("cryptex", .system, "系统 Cryptex 数据", "请确认内容及用途后处理。", "/private/var/run/com.apple.security.cryptexd", .manual, 100 * mb),
        p("swap", .system, "交换文件", "请确认内容及用途后处理。", "/private/var/vm", .manual, 100 * mb),
        p("icloud", .system, "iCloud 本地数据", "请确认内容及用途后处理。", "Library/Mobile Documents", .manual, 500 * mb),
        p("daemon", .system, "系统守护进程容器", "请确认内容及用途后处理。", "Library/Daemon Containers", .manual, 500 * mb),
    ]

    static let genericRoots: [URL] = [home, URL(fileURLWithPath: "/Library"), URL(fileURLWithPath: "/private/var"), URL(fileURLWithPath: "/opt"), URL(fileURLWithPath: "/usr/local"), URL(fileURLWithPath: "/Users/Shared")]
    static let excludedRoots = ["Pictures", "Music", "Movies", "Desktop", "Documents", "Downloads", "Library/Messages", "Library/Mail", "Library/Containers/com.apple.mail", "Library/Mobile Documents", "Applications", "Library/CloudStorage"]
    static let genericThreshold: Int64 = 500 * mb
    static let projectTargets = Set(["node_modules", ".build", "Pods", "DerivedData", ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".turbo", ".parcel-cache", ".expo"])

    static let snapshotCommand = "/usr/bin/tmutil"
    static let simulatorCommand = "/usr/bin/xcrun"
}
