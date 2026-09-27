using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace VisionStack.Core.Providers;

/// <summary>Each client is permanently bound to one connection and credential snapshot.</summary>
public sealed class ProviderClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly ProviderConnectionMetadata _provider;
    private readonly string _secret;
    private readonly TimeSpan _requestTimeout;
    public ProviderClient(ProviderConnectionMetadata provider, string secret, HttpMessageHandler? handler = null, TimeSpan? requestTimeout = null)
    {
        ProviderEndpointPolicy.Validate(provider.Kind, provider.BaseUrl);
        _provider = provider;
        _secret = secret;
        _requestTimeout = requestTimeout ?? TimeSpan.FromMinutes(3);
        _http = new HttpClient(handler ?? CreateTransport(provider.Kind)) { Timeout = Timeout.InfiniteTimeSpan };
    }

    private static SocketsHttpHandler CreateTransport(ProviderKind kind) => new()
    {
        AllowAutoRedirect = false, UseProxy = false,
        ConnectCallback = async (context, token) =>
        {
            IPAddress[] addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, token);
            if (addresses.Length == 0) throw new IOException("地址未解析。");
            foreach (IPAddress address in addresses)
            {
                if (kind == ProviderKind.ModelHub)
                {
                    if (!IPAddress.IsLoopback(address)) throw new IOException("网关必须解析到本机回环地址。");
                }
                else ProviderEndpointPolicy.Validate(ProviderKind.OpenAiCompatible, $"https://{(address.AddressFamily == AddressFamily.InterNetworkV6 ? "[" + address + "]" : address.ToString())}/");
            }
            Exception? lastError = null;
            foreach (IPAddress address in addresses)
            {
                token.ThrowIfCancellationRequested();
                var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                using var attempt = CancellationTokenSource.CreateLinkedTokenSource(token);
                attempt.CancelAfter(TimeSpan.FromSeconds(10));
                try
                {
                    await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), attempt.Token);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch (Exception error) when (error is SocketException or OperationCanceledException)
                { socket.Dispose(); token.ThrowIfCancellationRequested(); lastError = error; }
                catch { socket.Dispose(); throw; }
            }
            throw new IOException("无法连接任何已验证的服务地址。", lastError);
        }
    };

    private async Task<JsonDocument> Request(string path, object? body, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(_requestTimeout);
        token = deadline.Token;
        var uri = new Uri(_provider.BaseUrl.TrimEnd('/') + "/" + path);
        using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, uri);
        if (_provider.Kind == ProviderKind.Anthropic)
        { request.Headers.Add("x-api-key", _secret); request.Headers.Add("anthropic-version", "2023-06-01"); }
        else if (_provider.Kind == ProviderKind.GoogleGemini) request.Headers.Add("x-goog-api-key", _secret);
        else if (_secret.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _secret);
        if (body is not null)
        {
            string payload = JsonSerializer.Serialize(body);
            if (Encoding.UTF8.GetByteCount(payload) > 8 * 1024 * 1024) throw new IOException("请求超过 8 MiB，请新建项目或缩短对话。");
            request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
        }
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (!response.IsSuccessStatusCode) throw new IOException($"服务返回 HTTP {(int)response.StatusCode}；请检查模型、连接及账户权限。");
        return JsonDocument.Parse(await ReadBounded(response.Content, 32 * 1024 * 1024, token));
    }

    internal static async Task<byte[]> ReadBounded(HttpContent content, int limit, CancellationToken token)
    {
        if (content.Headers.ContentLength > limit) throw new IOException("响应超过大小上限。");
        await using var stream = await content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        byte[] buffer = new byte[16384];
        int count;
        while ((count = await stream.ReadAsync(buffer, token)) > 0)
        { if (output.Length + count > limit) throw new IOException("响应超过大小上限。"); await output.WriteAsync(buffer.AsMemory(0, count), token); }
        return output.ToArray();
    }

    public async Task<string[]> ModelsAsync(CancellationToken token)
    {
        using var json = await Request("models", null, token);
        string key = _provider.Kind == ProviderKind.GoogleGemini ? "models" : "data";
        return json.RootElement.GetProperty(key).EnumerateArray().Select(x => x.GetProperty(_provider.Kind == ProviderKind.GoogleGemini ? "name" : "id").GetString()!).Where(x => !string.IsNullOrWhiteSpace(x)).Take(500).ToArray();
    }

    public async Task<string> ChatAsync(string model, IReadOnlyList<ChatEntry> history, CancellationToken token)
    {
        var messages = history.Select(x => new { role = x.Role, content = x.Text }).ToArray();
        object body; string path;
        if (_provider.Kind == ProviderKind.GoogleGemini)
        { path = "models/" + Uri.EscapeDataString(model.Replace("models/", "")) + ":generateContent"; body = new { contents = history.Select(x => new { role = x.Role == "assistant" ? "model" : "user", parts = new[] { new { text = x.Text } } }) }; }
        else if (_provider.Kind == ProviderKind.Anthropic) { path = "messages"; body = new { model, max_tokens = 4096, messages }; }
        else { path = "chat/completions"; body = new { model, messages, stream = false }; }
        using var json = await Request(path, body, token);
        string reply = _provider.Kind switch
        {
            ProviderKind.Anthropic => string.Join("\n", json.RootElement.GetProperty("content").EnumerateArray().Where(x => x.TryGetProperty("text", out _)).Select(x => x.GetProperty("text").GetString())),
            ProviderKind.GoogleGemini => string.Join("\n", First(json.RootElement.GetProperty("candidates")).GetProperty("content").GetProperty("parts").EnumerateArray().Select(x => x.GetProperty("text").GetString())),
            _ => First(json.RootElement.GetProperty("choices")).GetProperty("message").GetProperty("content").GetString() ?? ""
        };
        if (string.IsNullOrWhiteSpace(reply)) throw new InvalidDataException("模型未返回可用文本。");
        return reply;
    }

    private static JsonElement First(JsonElement array)
    {
        if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() == 0) throw new InvalidDataException("服务返回空结果或不兼容的响应格式。");
        return array[0];
    }

    public async Task<byte[]> ImageAsync(string model, string prompt, CancellationToken token)
    {
        if (_provider.Kind is not (ProviderKind.ModelHub or ProviderKind.OpenAiCompatible)) throw new NotSupportedException("图片生成当前仅支持 OpenAI 兼容接口。");
        using var json = await Request("images/generations", new { model, prompt, n = 1, size = "1024x1024", response_format = "b64_json" }, token);
        var item = First(json.RootElement.GetProperty("data"));
        if (item.TryGetProperty("b64_json", out var b64)) return Convert.FromBase64String(b64.GetString()!);
        var uri = new Uri(item.GetProperty("url").GetString()!);
        // Signed download URLs may contain a query, but never receive provider credentials.
        ProviderEndpointPolicy.Validate(ProviderKind.OpenAiCompatible, uri.GetLeftPart(UriPartial.Path));
        if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment)) throw new IOException("素材地址无效。");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(_requestTimeout);
        token = deadline.Token;
        using var downloader = new HttpClient(CreateTransport(ProviderKind.OpenAiCompatible)) { Timeout = Timeout.InfiniteTimeSpan };
        using var response = await downloader.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token);
        if (!response.IsSuccessStatusCode) throw new IOException("素材下载失败。");
        return await ReadBounded(response.Content, 24 * 1024 * 1024, token);
    }
    public void Dispose() => _http.Dispose();
}
public sealed record ChatEntry(string Role, string Text);
