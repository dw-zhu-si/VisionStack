using System.Collections.ObjectModel;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using VisionStack.Core.Providers;

namespace VisionStack.Windows.ViewModels;

public sealed partial class MainWindowViewModel
{
    private readonly string _workspaceRoot;
    private CancellationTokenSource? _operation;
    private bool _loadingProject;
    private bool _workspaceLoaded;
    private readonly SemaphoreSlim _saveGate = new(1, 1);
    public ObservableCollection<CreativeProject> Projects { get; } = [];
    public ObservableCollection<string> Models { get; } = [];
    [ObservableProperty] private CreativeProject? _selectedProject;
    [ObservableProperty] private string _projectName = "新项目";
    [ObservableProperty] private string _prompt = "";
    [ObservableProperty] private string _modelId = "";
    [ObservableProperty] private string _workspaceSummary = "";
    [ObservableProperty] private bool _consentToProvider;
    [ObservableProperty] private bool _consentToCharge;
    [ObservableProperty] private string _exportDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    partial void OnPromptChanged(string value) { if (!_loadingProject && SelectedProject is not null) SelectedProject.Draft = value; }
    partial void OnModelIdChanged(string value) { if (!_loadingProject && SelectedProject is not null) SelectedProject.Model = value; }
    partial void OnSelectedProjectChanged(CreativeProject? value)
    {
        _loadingProject = true;
        Prompt = value?.Draft ?? ""; ModelId = value?.Model ?? "";
        _loadingProject = false; RefreshWorkspace();
    }
    private async Task LoadWorkspaceAsync()
    {
        string path = Path.Combine(_workspaceRoot, "projects.json");
        if (File.Exists(path))
        {
            if (new FileInfo(path).Length > 32 * 1024 * 1024) throw new InvalidDataException("项目文件超过上限。");
            var projects = ProjectFiles.Decode(await File.ReadAllTextAsync(path));
            foreach (var project in projects)
            {
                project.Tasks = project.Tasks.Select(t => t.Status == "运行中" ? t with { Status = "中断：重启前未确认结果，请核对厂商账单后手动重试" } : t).ToList();
                Projects.Add(project);
            }
        }
        if (Projects.Count == 0) Projects.Add(new CreativeProject());
        SelectedProject = Projects[0];
        _workspaceLoaded = true;
    }
    private async Task PersistWorkspace()
    {
        if (!_workspaceLoaded) throw new IOException("项目文件未能加载，已阻止保存以保留原文件。请先备份并修复项目文件。");
        await _saveGate.WaitAsync();
        string temp = Path.Combine(_workspaceRoot, $".{Guid.NewGuid():N}.tmp");
        try
        {
            Directory.CreateDirectory(_workspaceRoot);
            string json = JsonSerializer.Serialize(Projects.ToArray());
            if (System.Text.Encoding.UTF8.GetByteCount(json) > 32 * 1024 * 1024) throw new IOException("项目记录超过上限，请导出并整理内容。");
            await File.WriteAllTextAsync(temp, json);
            File.Move(temp, Path.Combine(_workspaceRoot, "projects.json"), true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); _saveGate.Release(); }
    }
    [RelayCommand] private async Task SaveDraftAsync() => await RunLocal(async () => { await PersistWorkspace(); SetStatus("项目与草稿已保存。", false); });
    [RelayCommand] private async Task NewProjectAsync() => await RunLocal(async () =>
    {
        var project = new CreativeProject { Name = string.IsNullOrWhiteSpace(ProjectName) ? "新项目" : ProjectName.Trim() };
        Projects.Add(project); SelectedProject = project; await PersistWorkspace();
    });
    private async Task RunLocal(Func<Task> operation)
    { try { await operation(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException) { SetStatus(e.Message, true); } }
    private void RefreshWorkspace()
    {
        WorkspaceSummary = SelectedProject is null ? "" : string.Join("\n\n", SelectedProject.Messages.Select(x => $"{(x.Role == "user" ? "你" : "模型")}：{x.Text}")) + "\n\n任务：\n" + string.Join("\n", SelectedProject.Tasks.Select(x => $"{x.ProviderName} / {x.Model}：{x.Status}"));
    }
    [RelayCommand] private void CancelOperation() => _operation?.Cancel();
    [RelayCommand] private async Task TestConnectionAsync() => await ExecuteRemote(false, async (client, provider, project, text, model, token) =>
    {
        string[] models = await client.ModelsAsync(token);
        Models.Clear(); foreach (string id in models.Concat(provider.ManualModelIds).Distinct()) Models.Add(id);
        SetStatus($"连接成功，已读取 {Models.Count} 个模型。模型目录不保证每个模型支持生图。", false);
    });
    [RelayCommand] private async Task SendChatAsync() => await ExecuteRemote(true, async (client, provider, project, text, model, token) =>
    {
        ValidateCreation(text, model);
        var history = project.Messages.Append(new ChatEntry("user", text)).ToArray();
        string reply = await client.ChatAsync(model, history, token);
        project.Messages.Add(new("user", text)); project.Messages.Add(new("assistant", reply));
        project.Draft = ""; if (SelectedProject == project) Prompt = "";
        await PersistWorkspace(); SetStatus("回复已保存。实际费用以厂商账单为准。", false);
    });
    [RelayCommand] private async Task GenerateImageAsync() => await ExecuteRemote(true, async (client, provider, project, text, model, token) =>
    {
        ValidateCreation(text, model);
        var task = new CreativeTask(Guid.NewGuid(), provider.Id, provider.DisplayName, model, text, "运行中", null);
        project.Tasks.Add(task); await PersistWorkspace(); RefreshWorkspace();
        try
        {
            byte[] bytes = await client.ImageAsync(model, text, token);
            token.ThrowIfCancellationRequested();
            string extension = bytes.Length >= 8 && bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71 ? ".png" : bytes.Length > 3 && bytes[0] == 255 && bytes[1] == 216 ? ".jpg" : throw new IOException("厂商未返回受支持的 PNG/JPEG 图片。");
            string filename = task.Id.ToString("N") + extension;
            Directory.CreateDirectory(Path.Combine(_workspaceRoot, "assets"));
            string destination = Path.Combine(_workspaceRoot, "assets", filename);
            string temporary = destination + ".tmp";
            try
            {
                await File.WriteAllBytesAsync(temporary, bytes, token);
                token.ThrowIfCancellationRequested();
                File.Move(temporary, destination);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
            project.Tasks[project.Tasks.IndexOf(task)] = task with { Status = "完成", Asset = filename };
        }
        catch (Exception)
        { project.Tasks[project.Tasks.IndexOf(task)] = task with { Status = token.IsCancellationRequested ? "已取消；远端可能仍计费" : "失败；请核对厂商账单后重试" }; throw; }
        finally { await PersistWorkspace(); RefreshWorkspace(); }
    });
    private static void ValidateCreation(string prompt, string model)
    { if (prompt.Length == 0 || model.Length == 0 || prompt.Length > 100000 || model.Length > 512) throw new InvalidOperationException("请输入模型 ID 与提示词；提示词最多 100000 字符。"); }
    private async Task ExecuteRemote(bool charge, Func<ProviderClient, ProviderConnectionMetadata, CreativeProject, string, string, CancellationToken, Task> action)
    {
        if (IsBusy) return;
        if (!_catalogLoaded || !_workspaceLoaded) { SetStatus("本地配置或项目未能安全加载，已阻止联网操作。", true); return; }
        if (!ConsentToProvider || (charge && !ConsentToCharge)) { SetStatus("请明确同意向当前厂商发送数据；生成调用还需勾选本次费用确认。", true); return; }
        var provider = _catalog.Connections.Single(x => x.Id == _catalog.SelectedProviderId);
        var project = SelectedProject;
        string text = Prompt.Trim(); string model = ModelId.Trim();
        if (project is null) return;
        IsBusy = true; _operation = new CancellationTokenSource();
        // Every request consumes consent, preventing later provider switches from inheriting it.
        ConsentToProvider = false; ConsentToCharge = false;
        try
        {
            using var client = new ProviderClient(provider, await _credentialStore.ReadAsync(provider.Id, _operation.Token));
            await action(client, provider, project, text, model, _operation.Token);
        }
        catch (OperationCanceledException) { SetStatus("请求已停止。已发出的生成请求可能仍由厂商处理或计费。", true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or IndexOutOfRangeException or HttpRequestException or JsonException or InvalidOperationException or NotSupportedException or FormatException or KeyNotFoundException or System.Security.Cryptography.CryptographicException or ArgumentException)
        { SetStatus("操作失败。请检查连接、模型能力和目录权限；不要在未核对账单前重复提交。", true); }
        finally { _operation.Dispose(); _operation = null; IsBusy = false; RefreshWorkspace(); }
    }
    [RelayCommand] private async Task ExportProjectAsync() => await RunLocal(async () =>
    {
        var snapshot = SelectedProject?.Snapshot();
        if (snapshot is null) return;
        string destination = await ProjectFiles.ExportAsync(snapshot, Path.Combine(_workspaceRoot, "assets"), ExportDirectory);
        SetStatus("项目与图片已导出至：" + destination, false);
    });
}
