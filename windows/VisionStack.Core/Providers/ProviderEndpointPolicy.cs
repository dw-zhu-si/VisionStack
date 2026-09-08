using System.Net;
using System.Text;

namespace VisionStack.Core.Providers;

public static class ProviderEndpointPolicy
{
    private const int MaximumEndpointBytes = 2_048;

    public static Uri Validate(ProviderKind kind, string baseUrl)
    {
        string value = (baseUrl ?? string.Empty).Trim();
        if (value.Length == 0 || Encoding.UTF8.GetByteCount(value) > MaximumEndpointBytes ||
            value.Any(char.IsControl) ||
            !Uri.TryCreate(value, UriKind.Absolute, out Uri? endpoint) ||
            string.IsNullOrWhiteSpace(endpoint.Host) ||
            !string.IsNullOrEmpty(endpoint.UserInfo) ||
            !string.IsNullOrEmpty(endpoint.Query) ||
            !string.IsNullOrEmpty(endpoint.Fragment))
        {
            throw Error(
                ProviderEndpointErrorCode.InvalidFormat,
                "模型服务地址格式无效；不能包含账号、查询参数或片段。");
        }

        string scheme = endpoint.Scheme.ToLowerInvariant();
        string host = NormalizeHost(endpoint.Host);

        if (kind == ProviderKind.ModelHub)
        {
            if ((scheme is not "http" and not "https") ||
                !IsLoopback(host) ||
                !IsSupportedModelHubPath(endpoint.AbsolutePath))
            {
                throw Error(
                    ProviderEndpointErrorCode.ModelHubRequiresLoopback,
                    "ModelHub 地址必须是 localhost、127.0.0.1 或 ::1，并且只能使用根路径或 /v1。");
            }

            return endpoint;
        }

        if (scheme != Uri.UriSchemeHttps)
        {
            throw Error(
                ProviderEndpointErrorCode.DirectProviderRequiresHttps,
                "厂商直连地址必须使用 HTTPS；本机模型请通过 ModelHub。");
        }

        if (IsPrivateOrReserved(host))
        {
            throw Error(
                ProviderEndpointErrorCode.DirectProviderTargetsPrivateNetwork,
                "厂商直连地址不能指向回环、局域网、链路本地或云元数据地址。");
        }

        if (ContainsParentDirectorySegment(value))
        {
            throw Error(
                ProviderEndpointErrorCode.ParentDirectorySegment,
                "模型服务地址不能包含上级目录片段。");
        }

        return endpoint;
    }

    private static ProviderEndpointException Error(ProviderEndpointErrorCode code, string message) =>
        new(code, message);

    private static string NormalizeHost(string host) =>
        host.Trim().Trim('[', ']').TrimEnd('.').ToLowerInvariant();

    private static bool IsSupportedModelHubPath(string path) =>
        path is "" or "/" or "/v1" or "/v1/";

    private static bool IsLoopback(string host) =>
        host is "127.0.0.1" or "localhost" or "::1";

    private static bool IsPrivateOrReserved(string host)
    {
        if (IsLoopback(host) ||
            host is "0.0.0.0" or "169.254.169.254" ||
            host.EndsWith(".local", StringComparison.Ordinal) ||
            host.EndsWith(".internal", StringComparison.Ordinal) ||
            host.EndsWith(".localhost", StringComparison.Ordinal))
        {
            return true;
        }

        if (!IPAddress.TryParse(host, out IPAddress? address))
        {
            return false;
        }

        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
        {
            byte[] octets = address.GetAddressBytes();
            return octets[0] switch
            {
                0 or 10 or 127 => true,
                100 when octets[1] is >= 64 and <= 127 => true,
                169 when octets[1] == 254 => true,
                172 when octets[1] is >= 16 and <= 31 => true,
                192 when octets[1] == 168 => true,
                198 when octets[1] is 18 or 19 => true,
                >= 224 => true,
                _ => false
            };
        }

        byte[] bytes = address.GetAddressBytes();
        return address.Equals(IPAddress.IPv6Any) ||
               IPAddress.IsLoopback(address) ||
               address.IsIPv6LinkLocal ||
               address.IsIPv6Multicast ||
               address.IsIPv6SiteLocal ||
               (bytes[0] & 0xFE) == 0xFC;
    }

    private static bool ContainsParentDirectorySegment(string rawUrl)
    {
        int authorityStart = rawUrl.IndexOf("://", StringComparison.Ordinal);
        if (authorityStart < 0)
        {
            return false;
        }

        int pathStart = rawUrl.IndexOf('/', authorityStart + 3);
        if (pathStart < 0)
        {
            return false;
        }

        string rawPath = rawUrl[pathStart..];
        string decodedPath;
        try
        {
            decodedPath = Uri.UnescapeDataString(rawPath);
        }
        catch (UriFormatException)
        {
            decodedPath = rawPath;
        }

        return decodedPath.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => segment == "..");
    }
}
