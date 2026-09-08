using System.Text.Json;
using System.Text.Json.Serialization;

namespace VisionStack.Core.Providers;

public sealed class ProviderCatalogStore
{
    private const long MaximumStateBytes = 5 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public ProviderCatalogStore(string rootDirectory)
    {
        if (string.IsNullOrWhiteSpace(rootDirectory))
        {
            throw new ArgumentException("状态目录不能为空。", nameof(rootDirectory));
        }

        RootDirectory = Path.GetFullPath(rootDirectory);
        StateFilePath = Path.Combine(RootDirectory, "providers.json");
    }

    public string RootDirectory { get; }
    public string StateFilePath { get; }

    public async Task<ProviderCatalog> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(StateFilePath))
        {
            return ProviderCatalog.CreateDefault();
        }

        var info = new FileInfo(StateFilePath);
        if (info.Length <= 0 || info.Length > MaximumStateBytes)
        {
            throw new InvalidDataException("模型厂商状态文件大小无效。");
        }

        await using FileStream stream = new(
            StateFilePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 16 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        ProviderCatalog? catalog = await JsonSerializer.DeserializeAsync<ProviderCatalog>(
            stream,
            JsonOptions,
            cancellationToken);

        Validate(catalog);
        return catalog!;
    }

    public async Task SaveAsync(
        ProviderCatalog catalog,
        CancellationToken cancellationToken = default)
    {
        Validate(catalog);
        Directory.CreateDirectory(RootDirectory);
        string temporaryPath = Path.Combine(
            RootDirectory,
            $".{Path.GetFileName(StateFilePath)}.{Guid.NewGuid():N}.tmp");

        try
        {
            await using (FileStream stream = new(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 16 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, catalog, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }

            File.Move(temporaryPath, StateFilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static void Validate(ProviderCatalog? catalog)
    {
        if (catalog is null ||
            catalog.SchemaVersion != ProviderCatalog.CurrentSchemaVersion ||
            catalog.Connections is null ||
            catalog.Connections.Count == 0 ||
            catalog.Connections.Count > 1_000 ||
            !catalog.Connections.Any(item => item.Id == catalog.SelectedProviderId) ||
            !catalog.Connections.Any(item => item.Id == ProviderCatalog.DefaultModelHubId &&
                                             item.Kind == ProviderKind.ModelHub))
        {
            throw new InvalidDataException("模型厂商状态文件结构无效或版本不受支持。");
        }

        foreach (ProviderConnectionMetadata connection in catalog.Connections)
        {
            ProviderEndpointPolicy.Validate(connection.Kind, connection.BaseUrl);
        }
    }
}
