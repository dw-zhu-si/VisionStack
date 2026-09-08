import AppKit
@preconcurrency import AVFoundation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct CreativePresetPicker: View {
    @EnvironmentObject private var store: AppStore
    let operation: CreativeOperation
    let onApply: (CreativePreset) -> Void
    @State private var selection: UUID?

    private var presets: [CreativePreset] {
        store.creativePresets
            .filter { $0.operation == operation && ($0.projectID == nil || $0.projectID == store.selectedProjectID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldLabel("创作预设")
                Spacer()
                Button("管理") { store.showingPresets = true }
                    .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            }
            HStack {
                Picker("创作预设", selection: $selection) {
                    Text("不使用预设").tag(Optional<UUID>.none)
                    ForEach(presets) { Text($0.name).tag(Optional(presetID($0))) }
                }
                .labelsHidden()
                Button("应用") {
                    guard let selection, let preset = presets.first(where: { $0.id == selection }) else { return }
                    onApply(preset)
                }
                .disabled(selection == nil)
            }
        }
    }

    private func presetID(_ preset: CreativePreset) -> UUID { preset.id }
}

struct CreativePresetManagerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var operation: CreativeOperation = .image
    @State private var promptPrefix = ""
    @State private var brandStyle = ""
    @State private var parametersText = ""
    @State private var projectOnly = false
    @State private var editingID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("创作预设").font(.vsTitle(24)); Spacer(); Button("关闭") { dismiss() } }
                Text("把提示词前缀、品牌风格与常用参数保存为可复用方案。预设只改变本地草稿，不会自动发起计费请求。")
                    .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                Divider()
                List(store.creativePresets.sorted { $0.updatedAt > $1.updatedAt }) { preset in
                    Button { load(preset) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).font(.vsLabel(11))
                                Text("\(preset.operation.title) · \(preset.projectID == nil ? "全局" : "当前项目")")
                                    .font(.vsBody(9)).foregroundStyle(VSColor.muted)
                            }
                            Spacer()
                            Button(role: .destructive) { store.deleteCreativePreset(preset.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }
            .padding(22)
            .frame(width: 380)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(editingID == nil ? "新建预设" : "编辑预设").font(.vsTitle(20))
                    FieldLabel("名称")
                    TextField("例如：暖金新品摄影", text: $name).textFieldStyle(.roundedBorder)
                    Picker("类型", selection: $operation) {
                        Text("图片").tag(CreativeOperation.image)
                        Text("视频").tag(CreativeOperation.video)
                    }
                    .pickerStyle(.segmented)
                    FieldLabel("提示词前缀")
                    TextEditor(text: $promptPrefix).frame(height: 90).padding(7).background(Color.white.opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 8))
                    FieldLabel("品牌风格")
                    TextEditor(text: $brandStyle).frame(height: 90).padding(7).background(Color.white.opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 8))
                    FieldLabel("参数")
                    TextEditor(text: $parametersText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 100).padding(7).background(Color.white.opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("每行一个 key=value，例如 size=1536x1024、quality=high、duration=8。")
                        .font(.vsBody(9)).foregroundStyle(VSColor.muted)
                    Toggle("只在当前项目显示", isOn: $projectOnly)
                    HStack {
                        Button("清空") { clear() }
                        Spacer()
                        Button(editingID == nil ? "保存预设" : "更新预设") { save() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(PaperBackground())
    }

    private func load(_ preset: CreativePreset) {
        editingID = preset.id
        name = preset.name
        operation = preset.operation
        promptPrefix = preset.promptPrefix
        brandStyle = preset.brandStyle
        parametersText = preset.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        projectOnly = preset.projectID != nil
    }

    private func save() {
        let parameters = Dictionary(uniqueKeysWithValues: parametersText.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (String(parts[0].prefix(80)), String(parts[1].prefix(300)))
        })
        let existing = editingID.flatMap { id in store.creativePresets.first { $0.id == id } }
        let preset = CreativePreset(
            id: existing?.id ?? UUID(),
            name: name,
            operation: operation,
            promptPrefix: promptPrefix,
            brandStyle: brandStyle,
            parameters: parameters,
            projectID: projectOnly ? store.selectedProjectID : nil,
            createdAt: existing?.createdAt ?? Date()
        )
        store.saveCreativePreset(preset)
        clear()
    }

    private func clear() {
        editingID = nil
        name = ""
        promptPrefix = ""
        brandStyle = ""
        parametersText = ""
        projectOnly = false
    }
}

struct VideoRoughCutView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "项目草剪"
    @State private var roughCutID = UUID()
    @State private var clips: [RoughCutClip] = []
    @State private var backgroundAudioURL: String?
    @State private var isExporting = false
    @State private var isImportingAudio = false
    @State private var importedAudioURLs: Set<String> = []
    @State private var audioImportTask: Task<Void, Never>?

    private var completedJobs: [GenerationJob] {
        store.currentProjectVideoJobs.filter { $0.state == .succeeded && !MediaFileActions.localURLs(for: $0).isEmpty }
    }
    private var segments: [RoughCutTimelineSegment] { RoughCutTimeline.segments(for: clips) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("视频草剪台").font(.vsTitle(25))
                    Text("本机编排转场、字幕和音频，并导出一条时间线成片。").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                if isExporting { ProgressView().controlSize(.small); Text("正在本机导出").font(.vsBody(10)) }
                Button("关闭") { dismiss() }
            }
            .padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    FieldLabel("草剪名称")
                    TextField("草剪名称", text: $name).textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(completedJobs) { job in
                            Button(String(job.prompt.prefix(42))) { add(job) }
                        }
                    } label: { Label("加入已完成镜头", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(completedJobs.isEmpty)
                    Button { importBackgroundAudio() } label: {
                        Label(isImportingAudio ? "正在导入音频…" : backgroundAudioURL == nil ? "加入背景音频" : "更换背景音频", systemImage: "waveform")
                    }
                    .disabled(isImportingAudio || isExporting)
                    if let backgroundAudioURL, let url = URL(string: backgroundAudioURL) {
                        HStack {
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { clearBackgroundAudio() } label: { Image(systemName: "xmark.circle") }
                                .disabled(isImportingAudio || isExporting)
                        }
                        .font(.vsBody(10))
                    }
                    Divider()
                    Text("时间线").font(.vsTitle(18))
                    if clips.isEmpty {
                        Text("先加入至少一个已完成且已归档到本机的视频镜头。").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 3) {
                                ForEach(segments, id: \.clipID) { segment in
                                    VStack(spacing: 2) {
                                        Text("\(Int(segment.durationSeconds))s")
                                        Text(segment.transition.title)
                                    }
                                    .font(.vsLabel(8)).foregroundStyle(.white)
                                    .frame(width: min(max(segment.durationSeconds * 18, 72), 200), height: 42)
                                    .background(segment.transition == .none ? VSColor.moss : VSColor.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                        Text("总时长 \(RoughCutTimeline.totalDuration(for: segments), specifier: "%.1f") 秒")
                            .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                    }
                    Spacer()
                    Button("保存草剪") { save() }.buttonStyle(.bordered).disabled(isImportingAudio)
                    Button("导出本机 MP4") { export() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(clips.isEmpty || isExporting || isImportingAudio)
                }
                .padding(22)
                .frame(width: 330)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            clipEditor(index: index, clip: clip)
                        }
                    }
                    .padding(22)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(PaperBackground())
        .onAppear {
            if let saved = store.currentProjectRoughCut {
                roughCutID = saved.id
                name = saved.name
                clips = saved.clips
                backgroundAudioURL = saved.backgroundAudioURL
            }
        }
        .onDisappear {
            audioImportTask?.cancel()
            let candidates = Array(importedAudioURLs)
            Task { await store.discardUnreferencedBackgroundAudio(candidates) }
        }
    }

    private func clipEditor(index: Int, clip: RoughCutClip) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("镜头 \(index + 1)").font(.vsTitle(17))
                    Text(store.currentProjectVideoJobs.first { $0.id == clip.jobID }?.prompt ?? "视频已不可用")
                        .font(.vsBody(10)).lineLimit(1)
                    Spacer()
                    Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == clips.count - 1)
                    Button(role: .destructive) { clips.remove(at: index) } label: { Image(systemName: "trash") }
                }
                HStack {
                    Picker("转场", selection: binding(index, \.transition)) {
                        ForEach(VideoTransitionStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("转场 \(clips[index].transitionDuration, specifier: "%.1f") 秒", value: binding(index, \.transitionDuration), in: 0...2, step: 0.25)
                        .disabled(clips[index].transition == .none)
                    Stepper("镜头 \(clips[index].durationSeconds, specifier: "%.1f") 秒", value: binding(index, \.durationSeconds), in: 0.5...120, step: 0.5)
                }
                TextField("字幕（留空则不烧录）", text: binding(index, \.caption)).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<RoughCutClip, Value>) -> Binding<Value> {
        Binding(get: { clips[index][keyPath: keyPath] }, set: { clips[index][keyPath: keyPath] = $0 })
    }

    private func add(_ job: GenerationJob) {
        let duration = Double(job.parameters["duration_seconds"] ?? "") ?? 5
        clips.append(RoughCutClip(jobID: job.id, durationSeconds: duration))
    }

    private func move(_ index: Int, _ offset: Int) {
        let target = index + offset
        guard clips.indices.contains(target) else { return }
        clips.swapAt(index, target)
    }

    private func save() {
        guard let projectID = store.selectedProjectID else { return }
        store.saveRoughCut(RoughCutProject(
            id: roughCutID,
            projectID: projectID,
            name: String(name.prefix(80)),
            clips: clips,
            backgroundAudioURL: backgroundAudioURL
        ))
    }

    private func importBackgroundAudio() {
        guard let source = CreativeFilePanels.chooseAudio() else { return }
        audioImportTask?.cancel()
        isImportingAudio = true
        audioImportTask = Task { @MainActor in
            defer { isImportingAudio = false; audioImportTask = nil }
            guard let imported = await store.importBackgroundAudio(from: source) else { return }
            guard !Task.isCancelled else {
                await store.discardUnreferencedBackgroundAudio([imported])
                return
            }
            let previous = backgroundAudioURL
            importedAudioURLs.insert(imported)
            backgroundAudioURL = imported
            if let previous, importedAudioURLs.contains(previous) {
                await store.discardUnreferencedBackgroundAudio([previous])
            }
        }
    }

    private func clearBackgroundAudio() {
        let previous = backgroundAudioURL
        backgroundAudioURL = nil
        if let previous, importedAudioURLs.contains(previous) {
            Task { await store.discardUnreferencedBackgroundAudio([previous]) }
        }
    }

    private func export() {
        guard let destination = CreativeFilePanels.chooseVideoDestination(suggestedName: name) else { return }
        save()
        let cut = RoughCutProject(
            id: roughCutID,
            projectID: store.selectedProjectID ?? UUID(),
            name: name,
            clips: clips,
            backgroundAudioURL: backgroundAudioURL
        )
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await RoughCutExporter.export(cut, jobs: store.currentProjectVideoJobs, to: destination)
                store.notice = "视频草剪已导出：\(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                store.notice = "视频草剪导出失败：\(error.localizedDescription)"
            }
        }
    }
}

enum CreativeFilePanels {
    @MainActor static func chooseBackupDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出项目备份与健康包"
        panel.message = "映栈会创建一个可校验的 .visionstackproject 包，不会覆盖已有备份。"
        panel.nameFieldStringValue = "\(sanitized(suggestedName)).visionstackproject"
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func chooseBackupPackage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择映栈项目备份"
        panel.message = "恢复前会校验清单、哈希与路径；恢复内容会进入一个新项目。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func chooseAudio() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择背景音频"
        panel.message = "音频会复制到映栈的本地受控目录，支持跨启动与项目备份恢复；单个文件不超过 100 MB。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func chooseVideoDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出视频草剪"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(sanitized(suggestedName)).mp4"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func sanitized(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "映栈项目" : String(clean.prefix(80))
    }
}

enum RoughCutExporter {
    @MainActor static func export(_ cut: RoughCutProject, jobs: [GenerationJob], to destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VisionStackError.mediaArchiveFailed("导出目标已存在；映栈不会覆盖旧视频。")
        }
        let segments = RoughCutTimeline.segments(for: cut.clips)
        guard !segments.isEmpty else { throw VisionStackError.mediaArchiveFailed("草剪时间线为空。") }
        let composition = AVMutableComposition()
        guard let videoA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VisionStackError.mediaArchiveFailed("无法创建本机视频时间线。")
        }
        let compositionTracks = [videoA, videoB]
        var renderSize = CGSize(width: 1920, height: 1080)
        var transforms: [UUID: CGAffineTransform] = [:]
        var insertedSegments: [RoughCutTimelineSegment] = []

        for (index, segment) in segments.enumerated() {
            guard let job = jobs.first(where: { $0.id == segment.jobID }),
                  let url = MediaFileActions.localURLs(for: job).first else {
                throw VisionStackError.mediaArchiveFailed("草剪包含未归档到本机的镜头。")
            }
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw VisionStackError.mediaArchiveFailed("镜头 \(index + 1) 没有可读取的视频轨道。")
            }
            let assetDuration = try await asset.load(.duration)
            let requestedDuration = CMTime(seconds: segment.durationSeconds, preferredTimescale: 600)
            let duration = CMTimeMinimum(assetDuration, requestedDuration)
            guard duration.seconds > 0 else { continue }
            let start = CMTime(seconds: segment.startSeconds, preferredTimescale: 600)
            try compositionTracks[index % 2].insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: start)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try audioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: start)
            }
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let absoluteSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            if index == 0, absoluteSize.width > 0, absoluteSize.height > 0 { renderSize = absoluteSize }
            transforms[segment.clipID] = fittedTransform(preferredTransform, sourceSize: absoluteSize, renderSize: renderSize)
            var inserted = segment
            inserted.durationSeconds = duration.seconds
            insertedSegments.append(inserted)
        }
        guard !insertedSegments.isEmpty else { throw VisionStackError.mediaArchiveFailed("没有可导出的有效镜头。") }

        if let value = cut.backgroundAudioURL, let audioURL = URL(string: value), audioURL.isFileURL {
            let audioAsset = AVURLAsset(url: audioURL)
            if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
               let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioDuration = try await audioAsset.load(.duration)
                let total = CMTime(seconds: RoughCutTimeline.totalDuration(for: insertedSegments), preferredTimescale: 600)
                try targetAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(audioDuration, total)), of: sourceAudio, at: .zero)
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = makeInstructions(
            segments: insertedSegments,
            tracks: compositionTracks,
            transforms: transforms
        )
        addCaptions(insertedSegments, to: videoComposition, renderSize: renderSize)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VisionStackError.mediaArchiveFailed("系统无法创建视频导出会话。")
        }
        exporter.videoComposition = videoComposition
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        if let error = exporter.error { throw error }
        guard exporter.status == .completed else {
            throw VisionStackError.mediaArchiveFailed("系统视频导出未完成（\(exporter.status.rawValue)）。")
        }
    }

    private static func fittedTransform(_ sourceTransform: CGAffineTransform, sourceSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return sourceTransform }
        let scale = min(renderSize.width / sourceSize.width, renderSize.height / sourceSize.height)
        let translatedX = (renderSize.width - sourceSize.width * scale) / 2
        let translatedY = (renderSize.height - sourceSize.height * scale) / 2
        return sourceTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: translatedX, y: translatedY))
    }

    private static func makeInstructions(
        segments: [RoughCutTimelineSegment],
        tracks: [AVCompositionTrack],
        transforms: [UUID: CGAffineTransform]
    ) -> [AVVideoCompositionInstructionProtocol] {
        let boundaries = Set(segments.flatMap { [$0.startSeconds, $0.startSeconds + $0.durationSeconds] }).sorted()
        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let active = segments.enumerated().filter { _, segment in
                segment.startSeconds < end && segment.startSeconds + segment.durationSeconds > start
            }
            guard !active.isEmpty else { return nil }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600)
            )
            instruction.layerInstructions = active.reversed().map { index, segment in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[index % 2])
                layer.setTransform(transforms[segment.clipID] ?? .identity, at: instruction.timeRange.start)
                if active.count > 1 {
                    let range = instruction.timeRange
                    if segment.startSeconds >= start {
                        layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range)
                    } else {
                        layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
                    }
                }
                return layer
            }
            return instruction
        }
    }

    private static func addCaptions(_ segments: [RoughCutTimelineSegment], to videoComposition: AVMutableVideoComposition, renderSize: CGSize) {
        let parent = CALayer()
        let video = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        video.frame = parent.frame
        parent.addSublayer(video)
        for segment in segments where !segment.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = CATextLayer()
            text.string = segment.caption
            text.alignmentMode = .center
            text.foregroundColor = NSColor.white.cgColor
            text.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
            text.fontSize = max(24, renderSize.height * 0.035)
            text.contentsScale = 2
            text.cornerRadius = 8
            text.frame = CGRect(x: renderSize.width * 0.12, y: renderSize.height * 0.07, width: renderSize.width * 0.76, height: renderSize.height * 0.09)
            text.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 1, 1, 0]
            animation.keyTimes = [0, 0.02, 0.96, 1]
            animation.beginTime = AVCoreAnimationBeginTimeAtZero + segment.startSeconds
            animation.duration = segment.durationSeconds
            animation.isRemovedOnCompletion = false
            text.add(animation, forKey: "visibility")
            parent.addSublayer(text)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}
