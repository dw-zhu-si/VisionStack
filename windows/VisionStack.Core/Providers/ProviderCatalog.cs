namespace VisionStack.Core.Providers;

public sealed record ProviderCatalog(
    int SchemaVersion,
    Guid SelectedProviderId,
    IReadOnlyList<ProviderConnectionMetadata> Connections)
{
    public const int CurrentSchemaVersion = 1;
    public static readonly Guid DefaultModelHubId =
        Guid.Parse("98A4E47E-9C3D-4F5B-8BC2-4EE118F9FA40");

    public static ProviderCatalog CreateDefault(DateTimeOffset? now = null)
    {
        DateTimeOffset timestamp = now ?? DateTimeOffset.UtcNow;
        var modelHub = new ProviderConnectionMetadata(
            DefaultModelHubId,
            "ModelHub（推荐）",
            ProviderKind.ModelHub,
            "http://127.0.0.1:11435/v1",
            [],
            timestamp,
            timestamp);

        return new ProviderCatalog(CurrentSchemaVersion, modelHub.Id, [modelHub]);
    }

    public ProviderCatalog AddAndSelect(ProviderConnectionMetadata connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (connection.Id == DefaultModelHubId && connection.Kind != ProviderKind.ModelHub)
        {
            throw new InvalidOperationException("内置 ModelHub 标识不能用于其他厂商类型。");
        }

        ProviderEndpointPolicy.Validate(connection.Kind, connection.BaseUrl);

        List<ProviderConnectionMetadata> next = Connections
            .Where(item => item.Id != connection.Id)
            .ToList();
        next.Add(connection);
        return this with
        {
            SelectedProviderId = connection.Id,
            Connections = next.ToArray()
        };
    }

    public ProviderCatalog Select(Guid providerId)
    {
        if (!Connections.Any(item => item.Id == providerId))
        {
            throw new KeyNotFoundException("要选择的模型厂商不存在。");
        }

        return this with { SelectedProviderId = providerId };
    }

    public ProviderCatalog Remove(Guid providerId)
    {
        if (providerId == DefaultModelHubId)
        {
            throw new InvalidOperationException("内置 ModelHub 入口不能删除。");
        }

        ProviderConnectionMetadata? existing = Connections.FirstOrDefault(item => item.Id == providerId);
        if (existing is null)
        {
            throw new KeyNotFoundException("要删除的模型厂商不存在。");
        }

        ProviderConnectionMetadata[] next = Connections
            .Where(item => item.Id != providerId)
            .ToArray();
        Guid selected = SelectedProviderId == providerId ? DefaultModelHubId : SelectedProviderId;
        return this with
        {
            SelectedProviderId = selected,
            Connections = next
        };
    }
}
