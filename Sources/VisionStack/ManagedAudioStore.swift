@preconcurrency import AVFoundation
import Foundation

enum ManagedAudioStore {
    static let directoryName = "Audio"
    static let maximumBytes = 100_000_000
    private static let allowedExtensions: Set<String> = ["wav", "wave", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]

    static func importFile(from source: URL, into directory: URL, fileManager: FileManager = .default) throws -> String {
        try validateFile(source)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw VisionStackError.mediaArchiveFailed("映栈音频目录不是安全的普通目录。")
        }

        let destination = directory.appending(path: "\(UUID().uuidString).\(source.pathExtension.lowercased())")
        try fileManager.copyItem(at: source, to: destination)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return destination.absoluteString
    }

    static func validateFile(_ source: URL) throws {
        guard source.isFileURL else {
            throw VisionStackError.mediaArchiveFailed("背景音频必须来自用户选择的本机文件。")
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw VisionStackError.mediaArchiveFailed("背景音频必须是小于 100 MB 的普通文件，不能是符号链接。")
        }
        guard allowedExtensions.contains(source.pathExtension.lowercased()) else {
            throw VisionStackError.mediaArchiveFailed("背景音频支持 WAV、MP3、M4A、AAC、AIFF、CAF 或 FLAC。")
        }
        let audio = try AVAudioFile(forReading: source)
        guard audio.length > 0, audio.processingFormat.sampleRate > 0 else {
            throw VisionStackError.mediaArchiveFailed("背景音频没有可读取的音频内容。")
        }
    }

    static func deleteFile(_ value: String, from directory: URL, fileManager: FileManager = .default) throws {
        guard let url = URL(string: value), url.isFileURL else {
            throw VisionStackError.mediaArchiveFailed("背景音频地址无效。")
        }
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/") else {
            throw VisionStackError.mediaArchiveFailed("背景音频不在映栈受控目录中，未删除文件。")
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VisionStackError.mediaArchiveFailed("背景音频不是受控目录中的普通文件，未删除文件。")
        }
        try fileManager.removeItem(at: url)
    }
}
