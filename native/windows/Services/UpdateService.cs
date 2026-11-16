using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace NikonLink.Windows.Services;

public sealed record UpdateCheckResult(
    bool IsAvailable,
    string Version,
    string DownloadUrl,
    string? Notice = null,
    string? Sha256 = null);

public sealed class UpdateService
{
    private const string FallbackVersion = "2.0.1";
    private const string LatestReleaseApi =
        "https://api.github.com/repos/feammer/ZENCHE/releases/latest";
    private const string DefaultSelfHostedUpdateEndpoint =
        "https://zenche.top/api/update";
    private const string ReleasesUrl =
        "https://github.com/feammer/ZENCHE/releases";
    private static readonly HttpClient Client = CreateClient();
    private static readonly string InstallIdPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "NikonLink",
        "anonymous-install-id.dat");

    /// E1: 匿名安装 ID——首次生成 UUID 存本地文件，与激活码/设备码无关，
    /// 仅用于服务器匿名用量统计（服务端只存 sha256 前 12 位指纹）。
    private static string AnonymousInstallId()
    {
        try
        {
            if (File.Exists(InstallIdPath))
            {
                var existing = File.ReadAllText(InstallIdPath).Trim();
                if (existing.Length > 0) return existing;
            }
            var id = Guid.NewGuid().ToString();
            Directory.CreateDirectory(Path.GetDirectoryName(InstallIdPath)!);
            File.WriteAllText(InstallIdPath, id);
            return id;
        }
        catch
        {
            // 读取/写入失败时回退到空串：不阻断更新检查。
            return "";
        }
    }

    public string CurrentVersion { get; } =
        Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? FallbackVersion;

    public async Task<UpdateCheckResult> CheckAsync(
        CancellationToken cancellationToken = default)
    {
        try
        {
            return await CheckSelfHostedAsync(cancellationToken);
        }
        catch (Exception)
        {
            // The self-hosted feed is optional; fall back to GitHub releases.
        }

        return await CheckGitHubAsync(cancellationToken);
    }

    private async Task<UpdateCheckResult> CheckSelfHostedAsync(
        CancellationToken cancellationToken)
    {
        var endpoint = Environment.GetEnvironmentVariable(
                "ZENCHE_UPDATE_ENDPOINT")?.Trim();
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            endpoint = DefaultSelfHostedUpdateEndpoint;
        }

        var builder = new UriBuilder(endpoint);
        var query = new List<string>
        {
            "platform=windows",
            $"arch={Uri.EscapeDataString(ArchitectureSuffix)}",
            $"current_version={Uri.EscapeDataString(CurrentVersion)}",
            "channel=stable",
            $"installId={Uri.EscapeDataString(AnonymousInstallId())}"
        };
        var separator = string.IsNullOrEmpty(builder.Query) ? "?" : "&";
        builder.Query = builder.Query.TrimStart('?');
        var requestUri = new Uri(
            builder.Uri + separator + string.Join("&", query));
        using var response = await Client.GetAsync(requestUri, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(
            cancellationToken);
        using var document = await JsonDocument.ParseAsync(
            stream,
            cancellationToken: cancellationToken);
        var root = document.RootElement;
        if (!root.TryGetProperty("schema_version", out var schema) ||
            schema.GetInt32() != 1 ||
            !root.TryGetProperty("product", out var product) ||
            !string.Equals(product.GetString(), "ZENCHE", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Invalid self-hosted update feed");
        }

        var version = NormalizeVersion(
            root.GetProperty("version").GetString() ?? CurrentVersion);
        var downloadUrl = root.TryGetProperty("url", out var url)
            ? url.GetString() ?? ""
            : "";
        if (string.IsNullOrWhiteSpace(downloadUrl) &&
            root.TryGetProperty("release_url", out var releaseUrl))
        {
            downloadUrl = releaseUrl.GetString() ?? ReleasesUrl;
        }

        var sha256 = root.TryGetProperty("sha256", out var shaNode)
            ? shaNode.GetString()
            : null;
        return new UpdateCheckResult(
            IsNewer(version, CurrentVersion),
            version,
            string.IsNullOrWhiteSpace(downloadUrl) ? ReleasesUrl : downloadUrl,
            null,
            sha256);
    }

    private async Task<UpdateCheckResult> CheckGitHubAsync(
        CancellationToken cancellationToken)
    {
        using var response = await Client.GetAsync(
            LatestReleaseApi,
            cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(
            cancellationToken);
        using var document = await JsonDocument.ParseAsync(
            stream,
            cancellationToken: cancellationToken);
        var root = document.RootElement;
        var version = NormalizeVersion(
            root.GetProperty("tag_name").GetString() ?? CurrentVersion);
        var releaseUrl =
            root.GetProperty("html_url").GetString() ?? ReleasesUrl;
        var downloadUrl = releaseUrl;
        var suffix =
            $"-Windows-{ArchitectureSuffix}-Setup.exe";

        if (root.TryGetProperty("assets", out var assets))
        {
            foreach (var asset in assets.EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString() ?? "";
                if (!name.EndsWith(
                        suffix,
                        StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                downloadUrl =
                    asset.GetProperty("browser_download_url").GetString()
                    ?? releaseUrl;
                break;
            }
        }

        return new UpdateCheckResult(
            IsNewer(version, CurrentVersion),
            version,
            downloadUrl);
    }

    private static string ArchitectureSuffix =>
        RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            ? "arm64"
            : "x64";

    private static HttpClient CreateClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(20)
        };
        client.DefaultRequestHeaders.Accept.ParseAdd(
            "application/json");
        var currentVersion =
            Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3)
            ?? FallbackVersion;
        client.DefaultRequestHeaders.UserAgent.ParseAdd(
            $"ZENCHE-Windows/{currentVersion}");
        return client;
    }

    private static string NormalizeVersion(string value) =>
        value.TrimStart('v', 'V').Split('-', 2)[0];

    private static bool IsNewer(string candidate, string current)
    {
        return Version.TryParse(NormalizeVersion(candidate), out var left) &&
               Version.TryParse(NormalizeVersion(current), out var right) &&
               left > right;
    }
}
