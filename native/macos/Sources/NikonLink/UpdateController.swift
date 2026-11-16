import AppKit
import CryptoKit
import Foundation


private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}


private struct SelfHostedUpdate: Decodable {
    let schemaVersion: Int
    let product: String
    let version: String
    let url: URL?
    let sha256: String?
    let releaseURL: URL?
    let updateType: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case product
        case version
        case url
        case sha256
        case releaseURL = "release_url"
        case updateType = "update_type"
    }
}

struct AvailableUpdate {
    let version: String
    let releasePage: URL
    let downloadURL: URL?
    let sha256: String?
}

@MainActor
final class UpdateController: ObservableObject {
    static let repositoryURL = URL(string: "https://github.com/feammer/ZENCHE")!
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/feammer/ZENCHE/releases/latest"
    )!
    private static let defaultSelfHostedUpdateEndpoint = URL(
        string: "https://zenche.top/api/update"
    )!
    private static var architectureSuffix: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    private static let releasesURL = URL(
        string: "https://github.com/feammer/ZENCHE/releases"
    )!
    private static let automaticUpdateKey = "NikonLink.automaticallyChecksForUpdates"
    private static let installIdKey = "NikonLink.anonymousInstallId"

    /// E1: 匿名安装 ID——首次生成 UUID 存 UserDefaults，与激活码/设备码无关，
    /// 仅用于服务器匿名用量统计（服务端只存 sha256 前 12 位指纹）。可随时在
    /// 设置中关闭更新检查后停止上报。
    private static func anonymousInstallId() -> String {
        if let existing = UserDefaults.standard.string(forKey: Self.installIdKey),
           !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.installIdKey)
        return id
    }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(
                automaticallyChecksForUpdates,
                forKey: Self.automaticUpdateKey
            )
        }
    }
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var statusText = "尚未检查更新"
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var downloadedInstaller: URL?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "2.0.1"
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.automaticUpdateKey) == nil {
            automaticallyChecksForUpdates = true
        } else {
            automaticallyChecksForUpdates = UserDefaults.standard.bool(
                forKey: Self.automaticUpdateKey
            )
        }
    }

    func checkAutomaticallyIfNeeded() {
        guard automaticallyChecksForUpdates else { return }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        if !silent {
            statusText = "正在检查更新…"
        }

        Task {
            defer { isChecking = false }
            do {
                let update = try await fetchSelfHostedUpdate()
                applySelfHostedUpdate(update)
            } catch {
                DiagnosticLogger.shared.warning(
                    "update",
                    "自托管更新检查失败，准备回退 GitHub：\(error.localizedDescription)"
                )
                do {
                    let release = try await fetchGitHubRelease()
                    applyGitHubRelease(release)
                } catch {
                    if !silent {
                        statusText = "检查失败，请确认网络后重试"
                    }
                    DiagnosticLogger.shared.error(
                        "update",
                        "检查更新失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func downloadUpdate() {
        guard let update = availableUpdate, !isDownloading else { return }
        guard let downloadURL = update.downloadURL else {
            NSWorkspace.shared.open(update.releasePage)
            return
        }

        isDownloading = true
        statusText = "正在下载 \(update.version)…"
        Task {
            defer { isDownloading = false }
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(
                    from: downloadURL
                )
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                if let expected = update.sha256?.lowercased(),
                   !expected.isEmpty {
                    let data = try Data(
                        contentsOf: temporaryURL,
                        options: .mappedIfSafe
                    )
                    let actual = SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                    guard actual == expected else {
                        throw UpdateIntegrityError()
                    }
                }

                let downloads = FileManager.default.urls(
                    for: .downloadsDirectory,
                    in: .userDomainMask
                ).first!
                let suggestedFilename = response.suggestedFilename
                    ?? Self.defaultInstallerFilename(version: update.version)
                let filename = suggestedFilename.lowercased().hasSuffix(".dmg")
                    ? suggestedFilename
                    : Self.defaultInstallerFilename(version: update.version)
                let destination = Self.availableDestination(
                    in: downloads,
                    filename: filename
                )
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: destination
                )
                downloadedInstaller = destination
                statusText = "更新已下载，打开安装包即可完成更新"
                NSWorkspace.shared.open(destination)
            } catch is UpdateIntegrityError {
                statusText = "更新包校验失败，已停止安装"
            } catch {
                statusText = "下载失败，请稍后重试"
            }
        }
    }

    func openDownloadedInstaller() {
        guard let downloadedInstaller else { return }
        NSWorkspace.shared.open(downloadedInstaller)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(
            availableUpdate?.releasePage ?? Self.repositoryURL
        )
    }


    private func fetchSelfHostedUpdate() async throws -> SelfHostedUpdate {
        let endpoint = ProcessInfo.processInfo.environment[
            "ZENCHE_UPDATE_ENDPOINT"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: endpoint ?? "") ?? Self.defaultSelfHostedUpdateEndpoint
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "arch", value: Self.architectureSuffix),
            URLQueryItem(name: "current_version", value: currentVersion),
            URLQueryItem(name: "channel", value: "stable"),
            URLQueryItem(name: "installId", value: Self.anonymousInstallId())
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ZENCHE-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let update = try JSONDecoder().decode(SelfHostedUpdate.self, from: data)
        guard update.schemaVersion == 1,
              update.product.caseInsensitiveCompare("ZENCHE") == .orderedSame else {
            throw URLError(.cannotParseResponse)
        }
        return update
    }

    private func applySelfHostedUpdate(_ update: SelfHostedUpdate) {
        let version = Self.normalizedVersion(update.version)
        guard Self.isNewer(version, than: currentVersion) else {
            availableUpdate = nil
            downloadedInstaller = nil
            statusText = "已是最新版本"
            return
        }
        availableUpdate = AvailableUpdate(
            version: version,
            releasePage: update.releaseURL ?? Self.releasesURL,
            downloadURL: update.updateType?.lowercased() == "incremental"
                ? nil
                : update.url,
            sha256: update.sha256
        )
        downloadedInstaller = nil
        statusText = "发现新版本 \(version)"
    }


    private func fetchGitHubRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.timeoutInterval = 20
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "ZENCHE-macOS/\(currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }


    private func applyGitHubRelease(
        _ release: GitHubRelease,
        fallbackStatus: String? = nil
    ) {
        let version = Self.normalizedVersion(release.tagName)
        guard Self.isNewer(version, than: currentVersion) else {
            availableUpdate = nil
            downloadedInstaller = nil
            statusText = ["已是最新版本", fallbackStatus]
                .compactMap { $0 }
                .joined(separator: " · ")
            return
        }

        let downloadURL = release.assets.first {
            $0.name.hasSuffix(Self.installerSuffix)
        }?.browserDownloadURL
        availableUpdate = AvailableUpdate(
            version: version,
            releasePage: release.htmlURL,
            downloadURL: downloadURL,
            sha256: nil
        )
        downloadedInstaller = nil
        statusText = ["发现新版本 \(version)", fallbackStatus]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static var installerSuffix: String {
        #if arch(arm64)
        return "-macOS-arm64.dmg"
        #elseif arch(x86_64)
        return "-macOS-x86_64.dmg"
        #else
        return ".dmg"
        #endif
    }



    private static func defaultInstallerFilename(version: String) -> String {
        "ZENCHE-\(version)\(installerSuffix)"
    }



    private static func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private static func availableDestination(in directory: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        let candidate = directory.appendingPathComponent(filename)
        guard !fileManager.fileExists(atPath: candidate.path) else {
            let base = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            var index = 2
            while true {
                let numberedName = ext.isEmpty
                    ? "\(base) \(index)"
                    : "\(base) \(index).\(ext)"
                let numberedURL = directory.appendingPathComponent(
                    numberedName
                )
                if !fileManager.fileExists(atPath: numberedURL.path) {
                    return numberedURL
                }
                index += 1
            }
        }
        return candidate
    }
}

private struct UpdateIntegrityError: Error {}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
