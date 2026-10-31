// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// Checks upstream GitHub Releases and presents release notes.
/// This customized build is updated by merging upstream sources and rebuilding.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// Release notes for the available upstream version.
    @Published private(set) var availableNotes: String?

    private let repository = "vorssaint/vorssaint-utils"
    private var refreshTimer: Timer?
    private var notifiedVersion: String?   // last release we posted a notification for

    private init() {}

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.autoCheckUpdates) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoCheckUpdates)
            configureAutomaticChecks()
        }
    }

    var includeBetaUpdates: Bool {
        get {
            if let explicit = UserDefaults.standard.object(forKey: DefaultsKey.includeBetaUpdates) as? Bool {
                return explicit
            }
            return AppInfo.isBeta
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.includeBetaUpdates)
        }
    }

    // MARK: - Scheduling

    /// Called at launch: checks shortly after start and then hourly, if enabled.
    func startAutomaticChecks() {
        if AppInfo.isBeta && UserDefaults.standard.object(forKey: DefaultsKey.includeBetaUpdates) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKey.includeBetaUpdates)
        }
        configureAutomaticChecks()
        if autoCheckEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.autoCheckEnabled else { return }
                self.check(manual: false)
            }
        }
    }

    private func configureAutomaticChecks() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard autoCheckEnabled else { return }
        // Hourly (was daily). Combined with the activate / panel-open checks, a new
        // release surfaces within the hour instead of up to a day later.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
        timer.tolerance = 60 * 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Check

    func check(manual: Bool) {
        if case .checking = state { return }
        state = .checking

        let includeBetas = includeBetaUpdates
        let endpoint = includeBetas
            ? "https://api.github.com/repos/\(repository)/releases?per_page=10"
            : "https://api.github.com/repos/\(repository)/releases/latest"

        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vorssaint/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lastChecked = Date()
                guard let data, error == nil else {
                    self.availableNotes = nil
                    self.state = .failed(error?.localizedDescription ?? "-")
                    return
                }

                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    self.availableNotes = nil
                    self.state = .failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return
                }

                let releases: [GitHubRelease]
                if includeBetas {
                    releases = (try? JSONDecoder().decode([GitHubRelease].self, from: data)) ?? []
                } else if let single = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
                    releases = [single]
                } else {
                    releases = []
                }

                guard !releases.isEmpty else {
                    self.availableNotes = nil
                    self.state = .failed(error?.localizedDescription ?? "-")
                    return
                }

                let candidates = releases.map { rel -> UpdateServiceSupport.ReleaseCandidate in
                    let asset = rel.assets.first { $0.name.hasSuffix(".dmg") }
                    return UpdateServiceSupport.ReleaseCandidate(
                        tagName: rel.tagName,
                        isPrerelease: rel.prerelease ?? false,
                        isDraft: rel.draft ?? false,
                        dmgURL: asset?.browserDownloadURL,
                        dmgExpectedBytes: asset?.size,
                        body: rel.body
                    )
                }

                if let chosen = UpdateServiceSupport.selectUpdate(
                    from: candidates,
                    currentVersion: AppInfo.version,
                    includeBetas: includeBetas
                ) {
                    let versionClean = chosen.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    self.availableNotes = ReleaseNotes.inAppUpdateNotes(from: chosen.body)
                    self.state = .available(version: versionClean)
                    // Notify once per distinct release, not on every hourly re-check.
                    if !manual, versionClean != self.notifiedVersion {
                        self.notifiedVersion = versionClean
                        let s = L10n.shared.s
                        Notifier.post(title: s.updateNotifyTitle,
                                      body: "\(s.updateAvailablePrefix) \(versionClean)")
                    }
                } else {
                    self.availableNotes = nil
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    /// Re-checks only if the last check is stale — called when the app reactivates
    /// or the panel opens, so a new release surfaces promptly without hammering the
    /// API. The hourly timer is the floor; this makes it feel immediate.
    func checkIfStale(maxAge: TimeInterval = 15 * 60) {
        guard autoCheckEnabled else { return }
        switch state {
        case .checking: return
        default: break
        }
        if let last = lastChecked, Date().timeIntervalSince(last) < maxAge { return }
        check(manual: false)
    }

    // MARK: - Version compare

    /// True when `latest` is a higher semantic version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        UpdateServiceSupport.isNewer(latest, than: current)
    }
}

/// Writes a response to a scratch file and abandons it once it passes
/// `byteLimit`, so a showcase video response cannot fill the disk.
final class BoundedUpdateDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let byteLimit: Int64
    private let progress: (Int64, Int64?) -> Void
    private let completion: (URL?, URLResponse?, Error?) -> Void
    private let fileURL: URL
    private let fileHandle: FileHandle
    private var response: URLResponse?
    private var responseExpectedBytes: Int64?
    private var receivedBytes: Int64 = 0
    private var completed = false
    private var exceededLimit = false
    private var writeError: Error?

    init(byteLimit: Int64,
         progress: @escaping (Int64, Int64?) -> Void,
         completion: @escaping (URL?, URLResponse?, Error?) -> Void) throws {
        self.byteLimit = byteLimit
        self.progress = progress
        self.completion = completion
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vorssaint-update-\(UUID().uuidString).download")
        fileURL = temporaryFileURL
        guard FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: temporaryFileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryFileURL)
            throw error
        }
    }

    deinit {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        responseExpectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard writeError == nil, !exceededLimit else { return }
        let chunkBytes = Int64(data.count)
        guard chunkBytes <= byteLimit - receivedBytes else {
            exceededLimit = true
            dataTask.cancel()
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
            receivedBytes += chunkBytes
            progress(receivedBytes, responseExpectedBytes)
        } catch {
            writeError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let closeError: Error?
        do {
            try fileHandle.close()
            closeError = nil
        } catch {
            closeError = error
        }
        if let writeError {
            complete(location: nil, response: response, error: writeError)
        } else if exceededLimit {
            complete(location: nil, response: response, error: POSIXError(.EFBIG))
        } else if let error {
            complete(location: nil, response: response, error: error)
        } else if let closeError {
            complete(location: nil, response: response, error: closeError)
        } else {
            complete(location: fileURL, response: response, error: nil)
        }
    }

    private func complete(location: URL?, response: URLResponse?, error: Error?) {
        guard !completed else { return }
        completed = true
        if location == nil {
            try? FileManager.default.removeItem(at: fileURL)
        }
        completion(location, response, error)
    }
}

// MARK: - GitHub API shapes

private struct GitHubRelease: Decodable {
    let tagName: String
    let prerelease: Bool?
    let draft: Bool?
    let assets: [Asset]
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case draft
        case assets
        case body
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}
