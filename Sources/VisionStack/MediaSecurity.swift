import Foundation

enum MediaArchivePolicy {
    static func maximumRemoteBytes(for kind: GenerationKind) -> Int64 {
        kind == .video ? 2_000_000_000 : 100_000_000
    }

    static func maximumInlineDecodedBytes(for kind: GenerationKind) -> Int {
        kind == .video ? 250_000_000 : 50_000_000
    }

    static func maximumInlineEncodedBytes(for kind: GenerationKind) -> Int {
        ((maximumInlineDecodedBytes(for: kind) + 2) / 3) * 4 + 16
    }

    static func allowsInlineBase64CharacterCount(_ count: Int, kind: GenerationKind) -> Bool {
        count > 0 && count <= maximumInlineEncodedBytes(for: kind)
    }

    static func allowsContentType(_ rawValue: String?, kind: GenerationKind) -> Bool {
        guard let value = rawValue?.split(separator: ";", maxSplits: 1).first?.lowercased() else { return true }
        if ["application/octet-stream", "binary/octet-stream"].contains(value) { return true }
        switch kind {
        case .image: return value.hasPrefix("image/")
        case .video: return value.hasPrefix("video/")
        }
    }
}

enum MediaURLPolicy {
    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else { return false }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        if isBlockedIPv4(host) || isBlockedIPv6(host) { return false }
        return true
    }

    private static func isBlockedIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let octets = Optional(parts.compactMap { UInt8($0) }),
              octets.count == 4 else { return false }
        let a = octets[0], b = octets[1]
        return a == 0
            || a == 10
            || a == 127
            || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || a >= 224
    }

    private static func isBlockedIPv6(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        let normalized = host.lowercased()
        if normalized == "::" || normalized == "::1" { return true }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") { return true }
        if ["fe8", "fe9", "fea", "feb"].contains(where: normalized.hasPrefix) { return true }
        if normalized.hasPrefix("::ffff:") {
            return isBlockedIPv4(String(normalized.dropFirst("::ffff:".count)))
        }
        return false
    }
}
