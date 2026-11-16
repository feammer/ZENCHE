import Foundation
import UIKit

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
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

@MainActor
final class UpdateController: ObservableObject {
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/feammer/ZENCHE/releases/latest"
    )!
    private static let defaultSelfHostedUpdateEndpoint = URL(
        string: "https://zenche.top/api/update"
    )!
    private static let releasesURL = URL(
        string: "https://github.com/feammer/ZENCHE/releases"
    )!
    private static let repositoryURL = URL(
        string: "https://github.com/feammer/ZENCHE"
    )!
    private static let automaticUpdateKey = "NikonLink.automaticallyChecksForUpdates"
    private static let installIdKey = "NikonLink.anonymousInstallId"

    /// E1: 匿名安装 ID——首次生成 UUID 存 UserDefaults，与激活码/设备码无关，
    /// 仅用于服务器匿名用量统计（服务端只存 sha256 前 12 位指纹）。
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
    @Published private(set) var statusText = "尚未检查更新"
    @Published private(set) var availableVersion: String?
    private var releaseURL: URL?

    var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "2.0.1"
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

    func openAvailableUpdate() {
        UIApplication.shared.open(releaseURL ?? Self.releasesURL)
    }

    func openProjectPage() {
        UIApplication.shared.open(Self.repositoryURL)
    }


    private func fetchSelfHostedUpdate() async throws -> SelfHostedUpdate {
        let endpoint = ProcessInfo.processInfo.environment[
            "ZENCHE_UPDATE_ENDPOINT"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: endpoint ?? "") ?? Self.defaultSelfHostedUpdateEndpoint
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "arch", value: "arm64"),
            URLQueryItem(name: "current_version", value: currentVersion),
            URLQueryItem(name: "channel", value: "stable"),
            URLQueryItem(name: "installId", value: Self.anonymousInstallId())
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ZENCHE-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
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
            availableVersion = nil
            releaseURL = nil
            statusText = "已是最新版本"
            return
        }
        availableVersion = version
        releaseURL = update.updateType?.lowercased() == "incremental"
            ? Self.releasesURL
            : update.url ?? update.releaseURL ?? Self.releasesURL
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
            "ZENCHE-iOS/\(currentVersion)",
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
            availableVersion = nil
            releaseURL = nil
            statusText = fallbackStatus.map { "已是最新版本 · \($0)" }
                ?? "已是最新版本"
            return
        }

        availableVersion = version
        releaseURL = release.htmlURL
        statusText = fallbackStatus.map { "发现新版本 \(version) · \($0)" }
            ?? "发现新版本 \(version)"
    }




    private static func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
