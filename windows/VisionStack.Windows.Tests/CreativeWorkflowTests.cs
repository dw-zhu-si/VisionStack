using System.Net;
using System.Text;
using VisionStack.Core.Providers;

namespace VisionStack.Windows.Tests;
public sealed class CreativeWorkflowTests
{
    [Fact] public async Task FailedMetadataRestoresOldCredential()
    {
        string value = "original";
        await Assert.ThrowsAsync<IOException>(() => CredentialTransaction.CommitAsync(CredentialEdit.Replace, "replacement", () => Task.FromResult(value), next => { value = next; return Task.CompletedTask; }, () => throw new IOException()));
        Assert.Equal("original", value);
    }
    [Fact] public async Task PreserveNeverReadsOrChangesSecret()
    {
        bool committed = false;
        await CredentialTransaction.CommitAsync(CredentialEdit.Preserve, "", () => throw new Exception(), _ => throw new Exception(), () => { committed = true; return Task.CompletedTask; });
        Assert.True(committed);
    }
    [Fact] public async Task ClearFailureAlsoRestoresCredential()
    {
        string value = "original";
        await Assert.ThrowsAsync<IOException>(() => CredentialTransaction.CommitAsync(CredentialEdit.Clear, "", () => Task.FromResult(value), next => { value = next; return Task.CompletedTask; }, () => throw new IOException()));
        Assert.Equal("original", value);
    }
    [Fact] public async Task CompatibleModelsChatAndImageUseBoundConnection()
    {
        var handler = new FakeHandler();
        var provider = ProviderConnectionRegistration.Create(new("Test", ProviderKind.OpenAiCompatible, "https://api.example.com/v1", "test-only", []), DateTimeOffset.UtcNow).Metadata;
        using var client = new ProviderClient(provider, "test-only", handler);
        Assert.Equal(new[] { "model" }, await client.ModelsAsync(default));
        Assert.Equal("hello", await client.ChatAsync("model", [new("user", "hi")], default));
        Assert.Equal(new byte[] { 1, 2, 3 }, await client.ImageAsync("model", "image", default));
        Assert.Equal(3, handler.Paths.Count);
        Assert.All(handler.Paths, path => Assert.StartsWith("https://api.example.com/v1/", path));
    }
    [Fact] public async Task CancelledRequestDoesNotComplete()
    {
        var provider = ProviderCatalog.CreateDefault().Connections[0];
        using var client = new ProviderClient(provider, "", new FakeHandler());
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.ModelsAsync(cancellation.Token));
    }
    [Fact] public async Task RedirectIsNotAcceptedAsSuccess()
    {
        using var client = NewClient(new HttpResponseMessage(HttpStatusCode.Redirect));
        await Assert.ThrowsAsync<IOException>(() => client.ModelsAsync(default));
    }
    [Fact] public async Task OversizedResponseRejectedBeforeReading()
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([]) };
        response.Content.Headers.ContentLength = 33L * 1024 * 1024;
        using var client = NewClient(response);
        await Assert.ThrowsAsync<IOException>(() => client.ModelsAsync(default));
    }
    [Fact] public async Task CompensationFailureRemainsVisible()
    {
        int writes = 0;
        await Assert.ThrowsAsync<AggregateException>(() => CredentialTransaction.CommitAsync(CredentialEdit.Replace, "new", () => Task.FromResult("old"), _ => ++writes == 1 ? Task.CompletedTask : throw new IOException(), () => throw new IOException()));
    }
    [Theory]
    [InlineData("{\"choices\":[]}", false)]
    [InlineData("{\"data\":[]}", true)]
    public async Task EmptyGenerationResultsProduceControlledFailure(string body, bool image)
    {
        using var client = NewClient(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) });
        if (image) await Assert.ThrowsAsync<InvalidDataException>(() => client.ImageAsync("model", "image", default));
        else await Assert.ThrowsAsync<InvalidDataException>(() => client.ChatAsync("model", [new("user", "hi")], default));
    }
    [Fact] public async Task BodyDeadlineContinuesAfterHeadersArrive()
    {
        var metadata = ProviderConnectionRegistration.Create(new("Test", ProviderKind.OpenAiCompatible, "https://api.example.com/v1", "", []), DateTimeOffset.UtcNow).Metadata;
        using var client = new ProviderClient(metadata, "", new ResponseHandler(new(HttpStatusCode.OK) { Content = new DelayedContent() }), TimeSpan.FromMilliseconds(30));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.ModelsAsync(default).WaitAsync(TimeSpan.FromSeconds(2)));
    }
    private sealed class DelayedContent : HttpContent
    {
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
        protected override Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context) => throw new NotSupportedException();
        protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new DelayedStream());
        protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken token) => Task.FromResult<Stream>(new DelayedStream());
    }
    private sealed class DelayedStream : Stream
    {
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => 0; set => throw new NotSupportedException(); }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) { await Task.Delay(Timeout.Infinite, token); return 0; }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
    private static ProviderClient NewClient(HttpResponseMessage response)
    {
        var metadata = ProviderConnectionRegistration.Create(new("Test", ProviderKind.OpenAiCompatible, "https://api.example.com/v1", "", []), DateTimeOffset.UtcNow).Metadata;
        return new ProviderClient(metadata, "", new ResponseHandler(response));
    }
    private sealed class ResponseHandler(HttpResponseMessage response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => Task.FromResult(response);
    }
    private sealed class FakeHandler : HttpMessageHandler
    {
        public List<string> Paths { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Paths.Add(request.RequestUri!.AbsoluteUri);
            Assert.Equal("test-only", request.Headers.Authorization?.Parameter);
            string body = request.RequestUri.AbsolutePath.EndsWith("models") ? "{\"data\":[{\"id\":\"model\"}]}" : request.RequestUri.AbsolutePath.EndsWith("generations") ? "{\"data\":[{\"b64_json\":\"AQID\"}]}" : "{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }
}
