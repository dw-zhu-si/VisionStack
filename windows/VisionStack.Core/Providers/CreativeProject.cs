using System.Text.Json;

namespace VisionStack.Core.Providers;

public sealed class CreativeProject
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "新项目";
    public string Draft { get; set; } = "";
    public string Model { get; set; } = "";
    public List<ChatEntry> Messages { get; set; } = [];
    public List<CreativeTask> Tasks { get; set; } = [];
    public override string ToString() => Name;
    public CreativeProject Snapshot() => new()
    {
        Id = Id, Name = Name, Draft = Draft, Model = Model,
        Messages = Messages.ToList(), Tasks = Tasks.ToList()
    };
}
public sealed record CreativeTask(Guid Id, Guid ProviderId, string ProviderName, string Model, string Prompt, string Status, string? Asset);

public static class ProjectFiles
{
    public static List<CreativeProject> Decode(string json)
    {
        var projects = JsonSerializer.Deserialize<List<CreativeProject>>(json) ?? throw new InvalidDataException("项目文件为空。");
        if (projects.Count > 10000 || projects.Any(x => x is null || x.Messages is null || x.Tasks is null || x.Name is null || x.Draft is null || x.Model is null))
            throw new InvalidDataException("项目文件结构无效。");
        foreach (var project in projects)
        {
            if (project.Messages.Any(x => x is null || x.Text is null || x.Role is not ("user" or "assistant")) || project.Tasks.Any(x => x is null))
                throw new InvalidDataException("项目内容结构无效。");
        }
        return projects;
    }

    /// <summary>Takes a deep-enough immutable-record snapshot before the first await.</summary>
    public static async Task<string> ExportAsync(CreativeProject project, string assetRoot, string exportRoot)
    {
        var snapshot = project.Snapshot();
        string root = Path.GetFullPath(exportRoot);
        if (!Directory.Exists(root)) throw new IOException("导出目录不存在。");
        string[] assets = snapshot.Tasks.Where(x => x.Asset is not null).Select(x => x.Asset!).Distinct().ToArray();
        foreach (string asset in assets)
        {
            if (asset is "" or "." or ".." || asset.IndexOfAny(['/', '\\']) >= 0 || Path.IsPathRooted(asset) || Path.GetFileName(asset) != asset)
                throw new IOException("素材路径无效。");
            if (!File.Exists(Path.Combine(assetRoot, asset))) throw new IOException("项目素材缺失，未创建导出目录。");
        }
        string target = Path.Combine(root, "VisionStack-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(target);
        var ownedFiles = new List<string>();
        try
        {
            string manifest = Path.Combine(target, "project.json");
            ownedFiles.Add(manifest);
            await using (var output = new FileStream(manifest, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                await JsonSerializer.SerializeAsync(output, snapshot, new JsonSerializerOptions { WriteIndented = true });
            foreach (string asset in assets)
            {
                string output = Path.Combine(target, asset);
                ownedFiles.Add(output);
                File.Copy(Path.Combine(assetRoot, asset), output, overwrite: false);
            }
            return target;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            try
            {
                foreach (string path in ownedFiles) if (File.Exists(path)) File.Delete(path);
                Directory.Delete(target, recursive: false);
            }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
            { throw new IOException("导出失败，部分文件未能清理，请检查：" + target, error); }
            throw new IOException("导出失败，已清理本次部分导出文件。", error);
        }
    }
}
