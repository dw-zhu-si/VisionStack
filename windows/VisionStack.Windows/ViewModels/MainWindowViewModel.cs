using System.Collections.ObjectModel;
using System.Security.Cryptography;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using VisionStack.Core.Providers;
using VisionStack.Windows.Services;

namespace VisionStack.Windows.ViewModels;

public sealed record ProviderKindOption(
    ProviderKind Kind,
    string Title,
    string Summary,
    string DefaultBaseUrl);

public sealed record ProviderCard(
    Guid Id,
    string DisplayName,
    string KindTitle,
    string BaseUrl,
    string ModelsSummary,
    bool IsSelected,
    bool CanDelete,
    IAsyncRelayCommand<Guid> SelectCommand,
    IAsyncRelayCommand<Guid> DeleteCommand);

public sealed partial class MainWindowViewModel : ObservableObject
{
    private readonly ProviderCatalogStore _catalogStore;
    private readonly IProviderCredentialStore _credentialStore;
    private ProviderCatalog _catalog = ProviderCatalog.CreateDefault();

    public MainWindowViewModel(string dataRoot, IProviderCredentialStore credentialStore)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);
        _credentialStore = credentialStore ?? throw new ArgumentNullException(nameof(credentialStore));
        _catalogStore = new ProviderCatalogStore(dataRoot);
        ProviderKinds =
        [
            new(
                ProviderKind.ModelHub,
                "ModelHub（推荐）",
                "统一管理多家模型目录与路由；本机回环地址可使用 HTTP。",
                "http://127.0.0.1:11435/v1"),
            new(
                ProviderKind.OpenAiCompatible,
                "OpenAI 兼容厂商",
                "支持 OpenAI 兼容 API 的任意厂商，不设置厂商白名单。",
                "https://api.openai.com/v1"),
            new(
                ProviderKind.Anthropic,
                "Anthropic",
                "Anthropic Messages 与 Models API；当前优先用于对话模型。",
                "https://api.anthropic.com/v1"),
            new(
                ProviderKind.GoogleGemini,
                "Google Gemini",
                "Gemini Models 与 generateContent API。",
                "https://generativelanguage.googleapis.com/v1beta")
        ];
        _selectedProviderKind = ProviderKinds[0];
        _displayName = ProviderKinds[0].Title;
        _baseUrl = ProviderKinds[0].DefaultBaseUrl;
        DataRootLabel = $"配置目录：{Path.GetFullPath(dataRoot)}";
        CredentialProtectionLabel = OperatingSystem.IsWindows()
            ? "API 密钥使用 Windows DPAPI（当前用户范围）加密，绝不写入 providers.json。"
            : "当前为非 Windows 预览环境，API 密钥仅保存在内存中。";
    }

    public IReadOnlyList<ProviderKindOption> ProviderKinds { get; }
    public ObservableCollection<ProviderCard> Providers { get; } = [];
    public string DataRootLabel { get; }
    public string CredentialProtectionLabel { get; }
    public bool HasStatus => !string.IsNullOrWhiteSpace(StatusMessage);
    public bool StatusSucceeded => HasStatus && !StatusIsError;

    [ObservableProperty]
    private ProviderKindOption? _selectedProviderKind;

    [ObservableProperty]
    private string _displayName = string.Empty;

    [ObservableProperty]
    private string _baseUrl = string.Empty;

    [ObservableProperty]
    private string _secret = string.Empty;

    [ObservableProperty]
    private string _manualModelIds = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasStatus))]
    [NotifyPropertyChangedFor(nameof(StatusSucceeded))]
    private string _statusMessage = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusSucceeded))]
    private bool _statusIsError;

    [ObservableProperty]
    private bool _isBusy;

    public async Task InitializeAsync()
    {
        try
        {
            _catalog = await _catalogStore.LoadAsync();
            RefreshProviderCards();
            SetStatus("已加载本机模型厂商配置。", isError: false);
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidDataException or
                                      UnauthorizedAccessException)
        {
            _catalog = ProviderCatalog.CreateDefault();
            RefreshProviderCards();
            SetStatus($"配置文件未能安全加载：{error.Message}", isError: true);
        }
    }

    partial void OnSelectedProviderKindChanged(ProviderKindOption? value)
    {
        if (value is null)
        {
            return;
        }

        DisplayName = value.Title;
        BaseUrl = value.DefaultBaseUrl;
        SetStatus(value.Summary, isError: false);
    }

    [RelayCommand]
    private void UseModelHub()
    {
        SelectedProviderKind = ProviderKinds.First(item => item.Kind == ProviderKind.ModelHub);
    }

    [RelayCommand]
    private void Validate()
    {
        try
        {
            ProviderKind kind = SelectedProviderKind?.Kind ?? ProviderKind.ModelHub;
            Uri endpoint = ProviderEndpointPolicy.Validate(kind, BaseUrl);
            SetStatus($"本地安全校验通过：{endpoint.AbsoluteUri}。尚未发起联网或计费请求。", isError: false);
        }
        catch (Exception error) when (error is ProviderEndpointException or ArgumentException)
        {
            SetStatus(error.Message, isError: true);
        }
    }

    [RelayCommand]
    private async Task SaveAsync()
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        ProviderConnectionRegistration? registration = null;
        bool credentialWritten = false;
        try
        {
            ProviderKind kind = SelectedProviderKind?.Kind ?? ProviderKind.ModelHub;
            ProviderConnectionMetadata? existingModelHub = kind == ProviderKind.ModelHub
                ? _catalog.Connections.FirstOrDefault(item => item.Id == ProviderCatalog.DefaultModelHubId)
                : null;
            registration = ProviderConnectionRegistration.Create(
                new ProviderConnectionInput(
                    DisplayName,
                    kind,
                    BaseUrl,
                    Secret,
                    ParseModelIds(ManualModelIds)),
                DateTimeOffset.UtcNow,
                existingModelHub?.Id,
                existingModelHub?.CreatedAt);

            await _credentialStore.SaveAsync(registration.Metadata.Id, registration.Secret);
            credentialWritten = registration.Secret.Length > 0;
            ProviderCatalog next = _catalog.AddAndSelect(registration.Metadata);
            await _catalogStore.SaveAsync(next);
            _catalog = next;
            Secret = string.Empty;
            RefreshProviderCards();
            SetStatus("厂商配置已保存；密钥与普通配置已分离存储。连接测试需由用户单独触发。", isError: false);
        }
        catch (Exception error) when (error is ProviderEndpointException or ArgumentException or IOException or
                                      UnauthorizedAccessException or InvalidDataException or JsonException or
                                      CryptographicException)
        {
            if (credentialWritten && registration is not null)
            {
                try
                {
                    await _credentialStore.DeleteAsync(registration.Metadata.Id);
                }
                catch (Exception cleanupError) when (cleanupError is IOException or UnauthorizedAccessException or
                                                     CryptographicException)
                {
                    // Preserve the original error; an orphaned encrypted credential is not exposed.
                }
            }

            SetStatus(error.Message, isError: true);
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    private async Task SelectProviderAsync(Guid providerId)
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        try
        {
            ProviderCatalog next = _catalog.Select(providerId);
            await _catalogStore.SaveAsync(next);
            _catalog = next;
            RefreshProviderCards();
            SetStatus("当前模型厂商已切换；尚未发起联网请求。", isError: false);
        }
        catch (Exception error) when (error is KeyNotFoundException or IOException or
                                      UnauthorizedAccessException or InvalidDataException or JsonException)
        {
            SetStatus(error.Message, isError: true);
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    private async Task DeleteProviderAsync(Guid providerId)
    {
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        try
        {
            ProviderCatalog next = _catalog.Remove(providerId);
            await _catalogStore.SaveAsync(next);
            _catalog = next;
            RefreshProviderCards();
            await _credentialStore.DeleteAsync(providerId);
            SetStatus("厂商配置与对应的加密密钥已删除。", isError: false);
        }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException or
                                      IOException or UnauthorizedAccessException or InvalidDataException or
                                      JsonException or CryptographicException)
        {
            SetStatus(error.Message, isError: true);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void RefreshProviderCards()
    {
        Providers.Clear();
        foreach (ProviderConnectionMetadata connection in _catalog.Connections
                     .OrderByDescending(item => item.Id == _catalog.SelectedProviderId)
                     .ThenBy(item => item.DisplayName, StringComparer.CurrentCulture))
        {
            Providers.Add(new ProviderCard(
                connection.Id,
                connection.DisplayName,
                KindTitle(connection.Kind),
                connection.BaseUrl,
                connection.ManualModelIds.Count == 0
                    ? "模型目录将在连接后读取"
                    : $"{connection.ManualModelIds.Count} 个手动模型",
                connection.Id == _catalog.SelectedProviderId,
                connection.Id != ProviderCatalog.DefaultModelHubId,
                SelectProviderCommand,
                DeleteProviderCommand));
        }
    }

    private static IReadOnlyList<string> ParseModelIds(string raw) =>
        (raw ?? string.Empty)
        .Split([',', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string KindTitle(ProviderKind kind) => kind switch
    {
        ProviderKind.ModelHub => "ModelHub",
        ProviderKind.OpenAiCompatible => "OpenAI 兼容",
        ProviderKind.Anthropic => "Anthropic",
        ProviderKind.GoogleGemini => "Google Gemini",
        _ => kind.ToString()
    };

    private void SetStatus(string message, bool isError)
    {
        StatusIsError = isError;
        StatusMessage = message;
    }
}
