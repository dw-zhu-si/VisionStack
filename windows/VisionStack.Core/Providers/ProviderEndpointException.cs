namespace VisionStack.Core.Providers;

public enum ProviderEndpointErrorCode
{
    InvalidFormat,
    ModelHubRequiresLoopback,
    DirectProviderRequiresHttps,
    DirectProviderTargetsPrivateNetwork,
    ParentDirectorySegment
}

public sealed class ProviderEndpointException : ArgumentException
{
    public ProviderEndpointException(ProviderEndpointErrorCode code, string message)
        : base(message)
    {
        Code = code;
    }

    public ProviderEndpointErrorCode Code { get; }
}
