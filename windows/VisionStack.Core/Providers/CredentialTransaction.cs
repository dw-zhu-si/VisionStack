namespace VisionStack.Core.Providers;

public enum CredentialEdit { Preserve, Replace, Clear }

public static class CredentialTransaction
{
    /// <summary>Compensates an in-process metadata failure by restoring the previous secret.</summary>
    public static async Task CommitAsync(CredentialEdit edit, string replacement,
        Func<Task<string>> read, Func<string, Task> write, Func<Task> commit)
    {
        if (edit == CredentialEdit.Preserve) { await commit(); return; }
        string previous = await read();
        await write(edit == CredentialEdit.Clear ? "" : replacement);
        try { await commit(); }
        catch (Exception original)
        {
            try { await write(previous); }
            catch (Exception rollback) { throw new AggregateException("配置保存失败，原密钥恢复也失败；请重新设置此连接的密钥。", original, rollback); }
            throw;
        }
    }
}
