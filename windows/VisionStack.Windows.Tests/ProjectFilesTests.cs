using System.Text.Json;
using VisionStack.Core.Providers;

namespace VisionStack.Windows.Tests;
public sealed class ProjectFilesTests
{
    [Fact] public async Task ExportSnapshotCannotMixLaterProjectMutations()
    {
        string root = Path.Combine(Path.GetTempPath(), "visionstack-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(root, "a.png"), "A");
            await File.WriteAllTextAsync(Path.Combine(root, "b.png"), "B");
            await File.WriteAllTextAsync(Path.Combine(root, "keep.txt"), "untouched");
            var project = new CreativeProject { Name = "A", Messages = [new("user", "A message")], Tasks = [new(Guid.NewGuid(), Guid.NewGuid(), "provider", "model", "prompt", "完成", "a.png")] };
            var snapshot = project.Snapshot();
            project.Name = "B"; project.Messages.Clear(); project.Tasks.Clear();
            project.Tasks.Add(new(Guid.NewGuid(), Guid.NewGuid(), "B", "model", "prompt", "完成", "b.png"));
            string target = await ProjectFiles.ExportAsync(snapshot, root, root);
            var exported = JsonSerializer.Deserialize<CreativeProject>(await File.ReadAllTextAsync(Path.Combine(target, "project.json")))!;
            Assert.Equal("A", exported.Name); Assert.Single(exported.Messages);
            Assert.True(File.Exists(Path.Combine(target, "a.png"))); Assert.False(File.Exists(Path.Combine(target, "b.png")));
            Assert.Equal("untouched", await File.ReadAllTextAsync(Path.Combine(root, "keep.txt")));
        }
        finally { Directory.Delete(root, true); }
    }
    [Fact] public async Task MissingAssetDoesNotLeavePartialExport()
    {
        string root = Path.Combine(Path.GetTempPath(), "visionstack-test-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        try
        {
            var project = new CreativeProject { Tasks = [new(Guid.NewGuid(), Guid.NewGuid(), "provider", "model", "prompt", "完成", "missing.png")] };
            await Assert.ThrowsAsync<IOException>(() => ProjectFiles.ExportAsync(project, root, root));
            Assert.Empty(Directory.GetFileSystemEntries(root));
        }
        finally { Directory.Delete(root, true); }
    }
    [Theory]
    [InlineData("../private.png")]
    [InlineData("..\\private.png")]
    public async Task ExportRejectsTraversal(string asset)
    {
        var project = new CreativeProject { Tasks = [new(Guid.NewGuid(), Guid.NewGuid(), "provider", "model", "prompt", "完成", asset)] };
        await Assert.ThrowsAsync<IOException>(() => ProjectFiles.ExportAsync(project, Path.GetTempPath(), Path.GetTempPath()));
    }
    [Theory]
    [InlineData("null")]
    [InlineData("[null]")]
    [InlineData("[{\"Messages\":null}]")]
    [InlineData("[{\"Tasks\":null}]")]
    public void MalformedWorkspaceIsRejected(string json) => Assert.Throws<InvalidDataException>(() => ProjectFiles.Decode(json));
}
