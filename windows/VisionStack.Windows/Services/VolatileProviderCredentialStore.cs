using System.Collections.Concurrent;

namespace VisionStack.Windows.Services;

internal sealed class VolatileProviderCredentialStore : IProviderCredentialStore
{
    private readonly ConcurrentDictionary<Guid, string> _values = new();

    public Task<string> ReadAsync(Guid providerId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(_values.GetValueOrDefault(providerId, string.Empty));
    }

    public Task SaveAsync(Guid providerId, string secret, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrEmpty(secret))
        {
            _values.TryRemove(providerId, out _);
        }
        else
        {
            _values[providerId] = secret;
        }

        return Task.CompletedTask;
    }

    public Task DeleteAsync(Guid providerId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _values.TryRemove(providerId, out _);
        return Task.CompletedTask;
    }
}
