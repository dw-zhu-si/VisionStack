import AppKit
import AVKit
import SwiftUI

struct SafeJobExportMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let kind: GenerationKind
    let prompt: String
    let model: String
    let parameters: [String: String]
    let state: JobState
    let favorite: Bool
    let tags: [String]
    let collection: String
    let parentJobID: UUID?
    let retryGroupID: UUID
    let batchID: UUID?
    let versionIndex: Int?
    let storyboardShotID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let cost: JobCostRecord?

    init(job: GenerationJob) {
        schemaVersion = 1
        id = job.id
        kind = job.kind
        prompt = job.prompt
        model = job.model
        parameters = job.parameters
        state = job.state
        favorite = job.favorite ?? false
        tags = job.tags ?? []
        collection = job.collection ?? ""
        parentJobID = job.parentJobID
        retryGroupID = job.effectiveRetryGroupID
        batchID = job.batchID
        versionIndex = job.versionIndex
        storyboardShotID = job.storyboardShotID
        createdAt = job.createdAt
        updatedAt = job.updatedAt
        cost = job.cost
    }
}

@MainActor
enum MediaFileActions {
    static func localURLs(for job: GenerationJob) -> [URL] {
        job.resultURLs.compactMap(URL.init(string:)).filter { url in
            guard url.isFileURL else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    static func previewURLs(for job: GenerationJob) -> [URL] {
        let local = localURLs(for: job)
        if !local.isEmpty { return local }
        return ((job.remoteResultURLs ?? []) + job.resultURLs)
            .compactMap(URL.init(string:))
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func exportJob(_ job: GenerationJob) throws {
        let urls = localURLs(for: job)
        guard !urls.isEmpty else { throw VisionStackError.mediaArchiveFailed("请先把远程结果保存到本机。") }

        if urls.count == 1 {
            let panel = NSSavePanel()
            panel.title = "下载生成结果"
            panel.nameFieldStringValue = urls[0].lastPathComponent
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try exportSingleFile(job, to: destination)
            return
        }

        guard let directory = chooseDirectory(title: "选择多结果下载目录") else { return }
        try export(job, to: directory)
    }

    static func exportSingleFile(_ job: GenerationJob, to destination: URL) throws {
        let urls = localURLs(for: job)
        guard urls.count == 1, let source = urls.first else {
            throw VisionStackError.mediaArchiveFailed("单文件下载需要一个已归档到本机的结果。")
        }
        try copyReplacing(source, to: destination)
    }

    static func exportJobs(_ jobs: [GenerationJob]) throws {
        let exportable = jobs.filter { !localURLs(for: $0).isEmpty }
        guard !exportable.isEmpty else { throw VisionStackError.mediaArchiveFailed("所选任务没有本地媒体。") }
        guard let directory = chooseDirectory(title: "选择批量导出目录") else { return }
        for job in exportable { try export(job, to: directory) }
    }

    private static func export(_ job: GenerationJob, to directory: URL) throws {
        let folderName = uniqueName("\(job.kind.rawValue)-\(job.id.uuidString.prefix(8))", in: directory)
        let folder = directory.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, source) in localURLs(for: job).enumerated() {
            let name = "\(String(format: "%02d", index + 1))-\(source.lastPathComponent)"
            try copyReplacing(source, to: folder.appending(path: name))
        }
        let metadata = folder.appending(path: "生成参数.json")
        try JSONEncoder.visionStack.encode(SafeJobExportMetadata(job: job)).write(to: metadata, options: .atomic)
    }

    private static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func copyReplacing(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func uniqueName(_ base: String, in directory: URL) -> String {
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

private struct MediaExportMenu: View {
    @EnvironmentObject private var store: AppStore
    let job: GenerationJob
    var title = "下载"

    var body: some View {
        Menu {
            Button(MediaFileActions.localURLs(for: job).count == 1 ? "下载媒体文件…" : "下载全部媒体…") {
                perform { try MediaFileActions.exportJob(job) }
            }
            Button("导出媒体与参数…") {
                perform { try MediaFileActions.exportJobs([job]) }
            }
        } label: {
            Label(title, systemImage: "arrow.down.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { store.notice = "导出副本失败：\(error.localizedDescription)" }
    }
}

struct MediaConfirmationContent: Equatable, Sendable {
    let title: String
    let primaryButtonTitle: String
    let message: String
    let isDestructive: Bool
}

enum MediaPendingConfirmation: Equatable, Sendable {
    case delete
    case terminalAction(MediaTerminalAction)

    func content(
        for kind: GenerationKind,
        hasRemoteResultURLs: Bool = false,
        hasUnconfirmedSubmission: Bool = false
    ) -> MediaConfirmationContent {
        switch self {
        case .delete:
            if hasUnconfirmedSubmission {
                MediaConfirmationContent(
                    title: "放弃对账并删除本地记录？",
                    primaryButtonTitle: "仍然删除本地记录",
                    message: "本次提交是否被供应商受理仍无法确认。删除只会移除映栈本地记录和本地文件，不会取消可能存在的供应商任务，供应商仍可能计费；此操作无法撤销。",
                    isDestructive: true
                )
            } else {
                MediaConfirmationContent(
                    title: "删除这项\(kind.rawValue)任务？",
                    primaryButtonTitle: "删除任务和全部本地文件",
                    message: "任务记录和映栈媒体目录中的所有归档文件会一起删除，此操作无法撤销。",
                    isDestructive: true
                )
            }
        case .terminalAction(.retry):
            MediaConfirmationContent(
                title: "确认重试并可能再次计费",
                primaryButtonTitle: "重试",
                message: "重试会使用原模型和参数创建新的上游请求。原请求可能已被供应商受理，因此本次操作可能再次计费。" + (hasRemoteResultURLs ? " 检测到原任务已有远程结果，可优先“存到本机”。" : ""),
                isDestructive: false
            )
        case .terminalAction(.newVersion):
            MediaConfirmationContent(
                title: "确认创建可能计费的新版本",
                primaryButtonTitle: "创建新版本",
                message: "将沿用原模型和参数向当前厂商或 ModelHub 重新提交，可能再次消耗供应商余额。",
                isDestructive: false
            )
        }
    }
}

struct MediaConfirmationState: Equatable, Sendable {
    private(set) var pending: MediaPendingConfirmation?
    var isPresented = false

    mutating func request(_ action: MediaPendingConfirmation) {
        pending = action
        isPresented = true
    }

    mutating func dismiss() {
        pending = nil
        isPresented = false
    }
}

struct MediaResultActions: View {
    @EnvironmentObject private var store: AppStore
    let job: GenerationJob
    let onRetry: () -> Void
    let onCancel: (() -> Void)?
    let onDelete: () -> Void

    @State private var showingPreview = false
    @State private var confirmation = MediaConfirmationState()

    private var localURLs: [URL] { MediaFileActions.localURLs(for: job) }
    private var previewURLs: [URL] { MediaFileActions.previewURLs(for: job) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = job.progress, progress > 0, progress < 1 {
                HStack {
                    ProgressView(value: progress).frame(maxWidth: 150)
                    Text("下载 \(Int(progress * 100))%").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
            }

            HStack(spacing: 12) {
                if !previewURLs.isEmpty {
                    Button { showingPreview = true } label: { Label("查看", systemImage: "eye") }
                }
                if !localURLs.isEmpty {
                    MediaExportMenu(job: job)
                    Button { MediaFileActions.reveal(localURLs[0]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                } else if !previewURLs.isEmpty {
                    Button { Task { await store.archiveRemoteResults(for: job) } } label: { Label("存到本机", systemImage: "square.and.arrow.down") }
                }

                Spacer()
                if [.running, .queued].contains(job.state), let onCancel {
                    Button(action: onCancel) { Label("停止", systemImage: "stop.circle") }
                } else if job.state.requiresReconciliation {
                    Button { Task { await store.reconcileJob(job) } } label: {
                        Label("对账", systemImage: "arrow.triangle.2.circlepath")
                    }
                } else if let terminalAction = MediaTerminalAction(state: job.state) {
                    Button {
                        let availability = store.retryAvailability(for: job)
                        if availability.isAvailable {
                            confirmation.request(.terminalAction(terminalAction))
                        } else {
                            store.notice = availability.reason
                        }
                    } label: {
                        Label(terminalAction.label, systemImage: terminalAction.systemImage)
                    }
                }
                Button(role: .destructive) { confirmation.request(.delete) } label: {
                    Label(job.state == .submissionUnknown ? "删除记录" : "删除", systemImage: "trash")
                }
                    .contentShape(Rectangle())
                    .disabled(!store.canDeleteJob(job))
                    .help(store.canDeleteJob(job)
                          ? (job.state == .submissionUnknown ? "放弃对账并删除本地记录；不会取消供应商任务" : "删除任务和本地归档")
                          : "请先停止任务，并完成对账或本地归档")
            }
            .buttonStyle(.plain)
            .font(.vsLabel(10))
            .foregroundStyle(VSColor.vermilion)
        }
        .sheet(isPresented: $showingPreview) {
            MediaViewerSheet(jobID: job.id, kind: job.kind).environmentObject(store)
        }
        .alert(confirmationContent.title, isPresented: $confirmation.isPresented, presenting: confirmation.pending) { pending in
            switch pending {
            case .delete:
                Button(confirmationContent.primaryButtonTitle, role: .destructive) {
                    confirmation.dismiss()
                    showingPreview = false
                    onDelete()
                }
            case .terminalAction(let action):
                Button(action == .retry ? "重试" : "创建新版本") {
                    confirmation.dismiss()
                    onRetry()
                }
            }
            Button("取消", role: .cancel) { confirmation.dismiss() }
        } message: { pending in
            Text(pending.content(
                for: job.kind,
                hasRemoteResultURLs: !(job.remoteResultURLs ?? []).isEmpty,
                hasUnconfirmedSubmission: job.submissionState == .unknown && job.providerState == .unknown
            ).message)
        }
    }

    private var confirmationContent: MediaConfirmationContent {
        confirmation.pending?.content(
            for: job.kind,
            hasRemoteResultURLs: !(job.remoteResultURLs ?? []).isEmpty,
            hasUnconfirmedSubmission: job.submissionState == .unknown && job.providerState == .unknown
        )
            ?? MediaConfirmationContent(title: "确认操作", primaryButtonTitle: "继续", message: "请核对后继续。", isDestructive: false)
    }

}

enum MediaTerminalAction: Equatable, Sendable {
    case retry
    case newVersion

    init?(state: JobState) {
        switch state {
        case .failed, .timedOut:
            self = .retry
        case .succeeded, .cancelled:
            self = .newVersion
        case .queued, .running, .submissionUnknown, .pollingDegraded, .cancelPending, .needsArchive:
            return nil
        }
    }

    var label: String {
        switch self {
        case .retry: "重试"
        case .newVersion: "新版本"
        }
    }

    var systemImage: String {
        switch self {
        case .retry: "arrow.clockwise"
        case .newVersion: "arrow.triangle.branch"
        }
    }
}

struct MediaViewerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let kind: GenerationKind

    @State private var selectedIndex = 0
    @State private var player: AVPlayer?
    @State private var zoom: CGFloat = 1

    private var job: GenerationJob? {
        kind == .image ? store.imageJobs.first(where: { $0.id == jobID }) : store.videoJobs.first(where: { $0.id == jobID })
    }
    private var urls: [URL] { job.map(MediaFileActions.previewURLs) ?? [] }
    private var selectedURL: URL? { urls.indices.contains(selectedIndex) ? urls[selectedIndex] : urls.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .image ? "图片画廊" : "视频播放器").font(.vsTitle(21))
                    Text(job?.model ?? "").font(.vsBody(11)).foregroundStyle(VSColor.muted).lineLimit(1)
                }
                Spacer()
                if urls.count > 1 { Text("\(selectedIndex + 1) / \(urls.count)").font(.vsLabel(11)) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()

            Group {
                if let url = selectedURL {
                    if kind == .image { imageViewer(url) }
                    else {
                        VideoPlayer(player: player).background(Color.black)
                            .onAppear { loadPlayer(url) }
                            .onChange(of: url) { loadPlayer(url) }
                            .onDisappear { player?.pause(); player = nil }
                    }
                } else {
                    EmptyStudioState(symbol: "exclamationmark.triangle", title: "媒体不可用", detail: "该任务没有可读取的结果地址。")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            if urls.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, _ in
                        Button { selectedIndex = index; zoom = 1 } label: {
                            Text("\(index + 1)").font(.vsLabel(11)).frame(width: 30, height: 26)
                                .background(index == selectedIndex ? VSColor.vermilion : VSColor.canvas)
                                .foregroundStyle(index == selectedIndex ? Color.white : VSColor.ink)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 10)
            }

            Divider()
            HStack(spacing: 16) {
                Text(job?.prompt ?? "").font(.vsBody(11)).lineLimit(2).foregroundStyle(VSColor.muted)
                Spacer()
                if kind == .image {
                    Button { zoom = max(0.5, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom = min(4, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    Text("\(Int(zoom * 100))%").font(.vsBody(11)).frame(width: 44)
                }
                if let url = selectedURL, url.isFileURL {
                    Button { MediaFileActions.open(url) } label: { Label("默认应用", systemImage: "arrow.up.forward.app") }
                    if let job { MediaExportMenu(job: job, title: "下载全部") }
                    Button { MediaFileActions.reveal(url) } label: { Label("Finder", systemImage: "folder") }
                } else if let job {
                    Button { Task { await store.archiveRemoteResults(for: job) } } label: { Label("存到本机", systemImage: "square.and.arrow.down") }
                }
            }.buttonStyle(.plain).foregroundStyle(VSColor.vermilion).padding(16)
        }
        .frame(minWidth: 900, minHeight: 660)
        .background(PaperBackground())
    }

    @ViewBuilder
    private func imageViewer(_ url: URL) -> some View {
        if url.isFileURL, let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().scaledToFit().scaleEffect(zoom).padding(30).draggable(url)
            }.background(VSColor.ink.opacity(0.94))
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit().padding(30)
                case .failure: EmptyStudioState(symbol: "photo.badge.exclamationmark", title: "图片无法加载", detail: url.absoluteString)
                default: ProgressView("正在载入图片…")
                }
            }.background(VSColor.ink.opacity(0.94))
        }
    }

    private func loadPlayer(_ url: URL) {
        player?.pause()
        let value = AVPlayer(url: url)
        player = value
        value.play()
    }

}
