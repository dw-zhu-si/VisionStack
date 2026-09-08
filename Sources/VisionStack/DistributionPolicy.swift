import Foundation

enum AppDistributionProfile: String, Sendable {
    case personal
    case publicRelease = "public"

    static var current: AppDistributionProfile {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "VisionStackDistributionProfile") as? String else {
            return .publicRelease
        }
        return AppDistributionProfile(rawValue: value) ?? .publicRelease
    }

    var requiresThirdPartyAIConsent: Bool { self == .publicRelease }
}

enum ThirdPartyAIConsentPolicy {
    static let currentVersion = 1
    static let privacyPolicyURL = URL(string: "https://pm.jcm99.com/apple/visionstack/privacy.html")!
    static let termsURL = URL(string: "https://pm.jcm99.com/apple/visionstack/terms.html")!

    static func isAccepted(version: Int?, distributionProfile: AppDistributionProfile) -> Bool {
        !distributionProfile.requiresThirdPartyAIConsent || version == currentVersion
    }
}
