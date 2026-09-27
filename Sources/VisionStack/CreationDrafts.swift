import Foundation

struct ImageCreationDraft: Codable, Equatable, Sendable {
    var updatedAt: Date?
    var prompt = ""
    var size = "1024x1024"
    var quality = "auto"
    var customWidth = 1024
    var customHeight = 1024
    var batchCount = 1
    var referenceAssetID: UUID?
    var identityReferenceAssetID: UUID?
    var photographyReferenceAssetID: UUID?
}

struct VideoCreationDraft: Codable, Equatable, Sendable {
    var updatedAt: Date?
    var prompt = ""
    var resolution = "720p"
    var ratio = "16:9"
    var duration = 5
    var batchCount = 1
    var referenceAssetID: UUID?
    var selectedShotID: UUID?
}
