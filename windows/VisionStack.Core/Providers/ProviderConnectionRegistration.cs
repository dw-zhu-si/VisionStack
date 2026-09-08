using System.Text;
using System.Text.Json.Serialization;

namespace VisionStack.Core.Providers;

public sealed record ProviderConnectionInput(
    string DisplayName,
    ProviderKind Kind,
    string BaseUrl,
    [property: JsonIgnore] string Secret,
    IReadOnlyList<string> ManualModelIds);

public sealed record ProviderConnectionMetadata(
    Guid Id,
    string DisplayName,
    ProviderKind Kind,
    string BaseUrl,
    IReadOnlyList<string> ManualModelIds,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

public sealed record ProviderConnectionRegistration(
    ProviderConnectionMetadata Metadata,
    [property: JsonIgnore] string Secret)
{
    private const int MaximumDisplayNameCharacters = 80;
    private const int MaximumModelCount = 500;
    private const int MaximumModelIdBytes = 512;
    private const int MaximumSecretBytes = 16 * 1024;

    public static ProviderConnectionRegistration Create(
        ProviderConnectionInput input,
        DateTimeOffset now,
        Guid? id = null,
        DateTimeOffset? createdAt = null)
    {
        ArgumentNullException.ThrowIfNull(input);

        string displayName = (input.DisplayName ?? string.Empty).Trim();
        if (displayName.Length == 0 || displayName.Length > MaximumDisplayNameCharacters ||
            displayName.Any(char.IsControl))
        {
            throw new ArgumentException("厂商名称不能为空、不能包含控制字符，且最多 80 个字符。", nameof(input));
        }

        Uri endpoint = ProviderEndpointPolicy.Validate(input.Kind, input.BaseUrl);
        string[] models = NormalizeModelIds(input.ManualModelIds);
        string secret = input.Secret ?? string.Empty;
        if (Encoding.UTF8.GetByteCount(secret) > MaximumSecretBytes)
        {
            throw new ArgumentException("API 密钥超过允许长度。", nameof(input));
        }

        var metadata = new ProviderConnectionMetadata(
            id ?? Guid.NewGuid(),
            displayName,
            input.Kind,
            endpoint.AbsoluteUri,
            models,
            createdAt ?? now,
            now);

        return new ProviderConnectionRegistration(metadata, secret);
    }

    private static string[] NormalizeModelIds(IReadOnlyList<string>? values)
    {
        string[] normalized = (values ?? [])
            .Select(value => (value ?? string.Empty).Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        if (normalized.Length > MaximumModelCount ||
            normalized.Any(value => Encoding.UTF8.GetByteCount(value) > MaximumModelIdBytes ||
                                    value.Any(char.IsControl)))
        {
            throw new ArgumentException("模型 ID 数量或长度超过允许范围。", nameof(values));
        }

        return normalized;
    }
}
