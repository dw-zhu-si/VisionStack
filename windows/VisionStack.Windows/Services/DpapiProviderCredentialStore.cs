using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace VisionStack.Windows.Services;

[SupportedOSPlatform("windows")]
internal sealed class DpapiProviderCredentialStore : IProviderCredentialStore
{
    private const int MaximumProtectedCredentialBytes = 64 * 1024;
    private readonly string _rootDirectory;

    public DpapiProviderCredentialStore(string rootDirectory)
    {
        _rootDirectory = Path.GetFullPath(rootDirectory);
    }

    public async Task<string> ReadAsync(
        Guid providerId,
        CancellationToken cancellationToken = default)
    {
        string path = CredentialPath(providerId);
        if (!File.Exists(path))
        {
            return string.Empty;
        }

        if (new FileInfo(path).Length > MaximumProtectedCredentialBytes)
        {
            throw new InvalidDataException("加密密钥文件大小无效。");
        }

        byte[] protectedBytes = await File.ReadAllBytesAsync(path, cancellationToken);
        byte[] clearBytes = ProtectedData.Unprotect(
            protectedBytes,
            optionalEntropy: null,
            DataProtectionScope.CurrentUser);
        try
        {
            return Encoding.UTF8.GetString(clearBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }
    }

    public async Task SaveAsync(
        Guid providerId,
        string secret,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(secret))
        {
            await DeleteAsync(providerId, cancellationToken);
            return;
        }

        Directory.CreateDirectory(_rootDirectory);
        byte[] clearBytes = Encoding.UTF8.GetBytes(secret);
        byte[] protectedBytes;
        try
        {
            protectedBytes = ProtectedData.Protect(
                clearBytes,
                optionalEntropy: null,
                DataProtectionScope.CurrentUser);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }

        string destination = CredentialPath(providerId);
        string temporary = Path.Combine(_rootDirectory, $".{providerId:N}.{Guid.NewGuid():N}.tmp");
        try
        {
            await File.WriteAllBytesAsync(temporary, protectedBytes, cancellationToken);
            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(protectedBytes);
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    public Task DeleteAsync(Guid providerId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        string path = CredentialPath(providerId);
        if (File.Exists(path))
        {
            File.Delete(path);
        }

        return Task.CompletedTask;
    }

    private string CredentialPath(Guid providerId) =>
        Path.Combine(_rootDirectory, $"{providerId:N}.bin");
}
