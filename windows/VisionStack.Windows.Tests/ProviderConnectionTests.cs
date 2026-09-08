using System.Text.Json;
using VisionStack.Core.Providers;

namespace VisionStack.Windows.Tests;

public sealed class ProviderConnectionTests
{
    [Theory]
    [InlineData("http://127.0.0.1:11435/v1")]
    [InlineData("http://localhost:11435/")]
    [InlineData("https://[::1]:11435/v1/")]
    public void ModelHub_accepts_only_supported_loopback_endpoints(string value)
    {
        Uri endpoint = ProviderEndpointPolicy.Validate(ProviderKind.ModelHub, value);

        Assert.True(endpoint.IsAbsoluteUri);
    }

    [Theory]
    [InlineData("https://modelhub.example/v1")]
    [InlineData("http://127.0.0.1:11435/admin")]
    [InlineData("http://127.0.0.1:11435/v1?token=secret")]
    public void ModelHub_rejects_remote_unknown_or_credential_bearing_endpoints(string value)
    {
        Assert.Throws<ProviderEndpointException>(() =>
            ProviderEndpointPolicy.Validate(ProviderKind.ModelHub, value));
    }

    [Fact]
    public void Direct_provider_accepts_public_https_endpoint()
    {
        Uri endpoint = ProviderEndpointPolicy.Validate(
            ProviderKind.OpenAiCompatible,
            "https://api.vendor.example/v1");

        Assert.Equal("https", endpoint.Scheme);
        Assert.Equal("api.vendor.example", endpoint.Host);
    }

    [Theory]
    [InlineData("http://api.vendor.example/v1")]
    [InlineData("https://127.0.0.1:9443/v1")]
    [InlineData("https://10.1.2.3/v1")]
    [InlineData("https://169.254.169.254/latest/meta-data")]
    [InlineData("https://100.100.100.200/latest/meta-data")]
    [InlineData("https://[fd00::1]/v1")]
    [InlineData("https://metadata.google.internal/v1")]
    [InlineData("https://metadata.google.internal./v1")]
    [InlineData("https://user:password@api.vendor.example/v1")]
    [InlineData("https://api.vendor.example/v1?api_key=secret")]
    [InlineData("https://api.vendor.example/v1/%2E%2E/admin")]
    public void Direct_provider_rejects_insecure_or_private_endpoints(string value)
    {
        Assert.Throws<ProviderEndpointException>(() =>
            ProviderEndpointPolicy.Validate(ProviderKind.OpenAiCompatible, value));
    }

    [Fact]
    public void Registration_serialization_never_contains_provider_secret()
    {
        var input = new ProviderConnectionInput(
            "任意厂商直连",
            ProviderKind.OpenAiCompatible,
            "https://api.vendor.example/v1",
            "fixture-provider-secret",
            [" vendor/vision-v1 ", "vendor/vision-v1"]);

        ProviderConnectionRegistration registration = ProviderConnectionRegistration.Create(
            input,
            new DateTimeOffset(2026, 8, 30, 1, 30, 0, TimeSpan.FromHours(8)));
        string json = JsonSerializer.Serialize(registration);
        string inputJson = JsonSerializer.Serialize(input);

        Assert.DoesNotContain("fixture-provider-secret", json, StringComparison.Ordinal);
        Assert.DoesNotContain("fixture-provider-secret", inputJson, StringComparison.Ordinal);
        Assert.DoesNotContain("secret", json, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("任意厂商直连", registration.Metadata.DisplayName);
        Assert.Equal(["vendor/vision-v1"], registration.Metadata.ManualModelIds);
        Assert.Equal("fixture-provider-secret", registration.Secret);
    }

    [Fact]
    public void Registration_rejects_unbounded_provider_secrets()
    {
        var input = new ProviderConnectionInput(
            "厂商",
            ProviderKind.OpenAiCompatible,
            "https://api.vendor.example/v1",
            new string('x', 20_000),
            []);

        Assert.Throws<ArgumentException>(() =>
            ProviderConnectionRegistration.Create(input, DateTimeOffset.UtcNow));
    }

    [Fact]
    public async Task Catalog_round_trip_persists_metadata_without_credentials()
    {
        string root = Path.Combine(Path.GetTempPath(), $"visionstack-windows-{Guid.NewGuid():N}");
        try
        {
            var store = new ProviderCatalogStore(root);
            ProviderConnectionRegistration registration = ProviderConnectionRegistration.Create(
                new ProviderConnectionInput(
                    "示例厂商",
                    ProviderKind.OpenAiCompatible,
                    "https://api.vendor.example/v1",
                    "must-not-reach-state-json",
                    ["vendor/chat-v1"]),
                new DateTimeOffset(2026, 8, 30, 2, 0, 0, TimeSpan.FromHours(8)));
            var catalog = ProviderCatalog.CreateDefault().AddAndSelect(registration.Metadata);

            await store.SaveAsync(catalog);
            ProviderCatalog loaded = await store.LoadAsync();
            string persisted = await File.ReadAllTextAsync(store.StateFilePath);

            Assert.Equal(2, loaded.Connections.Count);
            Assert.Equal(registration.Metadata.Id, loaded.SelectedProviderId);
            Assert.Contains(loaded.Connections, item => item.Kind == ProviderKind.ModelHub);
            Assert.DoesNotContain("must-not-reach-state-json", persisted, StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void Catalog_supports_selection_and_protects_the_built_in_ModelHub_entry()
    {
        ProviderConnectionRegistration registration = ProviderConnectionRegistration.Create(
            new ProviderConnectionInput(
                "第二厂商",
                ProviderKind.OpenAiCompatible,
                "https://api.second.example/v1",
                string.Empty,
                []),
            DateTimeOffset.UtcNow);
        ProviderCatalog catalog = ProviderCatalog.CreateDefault().AddAndSelect(registration.Metadata);

        catalog = catalog.Select(ProviderCatalog.DefaultModelHubId);
        Assert.Equal(ProviderCatalog.DefaultModelHubId, catalog.SelectedProviderId);
        Assert.Throws<InvalidOperationException>(() =>
            catalog.Remove(ProviderCatalog.DefaultModelHubId));

        catalog = catalog.Select(registration.Metadata.Id).Remove(registration.Metadata.Id);
        Assert.Equal(ProviderCatalog.DefaultModelHubId, catalog.SelectedProviderId);
        Assert.Single(catalog.Connections);
    }

    [Fact]
    public void Updating_the_built_in_ModelHub_keeps_a_single_protected_entry()
    {
        DateTimeOffset createdAt = new(2026, 8, 30, 0, 0, 0, TimeSpan.Zero);
        ProviderConnectionRegistration registration = ProviderConnectionRegistration.Create(
            new ProviderConnectionInput(
                "我的 ModelHub",
                ProviderKind.ModelHub,
                "http://localhost:11435/v1",
                string.Empty,
                []),
            createdAt.AddHours(1),
            ProviderCatalog.DefaultModelHubId,
            createdAt);

        ProviderCatalog catalog = ProviderCatalog.CreateDefault(createdAt)
            .AddAndSelect(registration.Metadata);

        Assert.Single(catalog.Connections);
        Assert.Equal("我的 ModelHub", catalog.Connections[0].DisplayName);
        Assert.Equal(createdAt, catalog.Connections[0].CreatedAt);
    }
}
