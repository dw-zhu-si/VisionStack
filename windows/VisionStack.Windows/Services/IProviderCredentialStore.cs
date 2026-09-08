namespace VisionStack.Windows.Services;

public interface IProviderCredentialStore
{
    Task<string> ReadAsync(Guid providerId, CancellationToken cancellationToken = default);
    Task SaveAsync(Guid providerId, string secret, CancellationToken cancellationToken = default);
    Task DeleteAsync(Guid providerId, CancellationToken cancellationToken = default);
}
