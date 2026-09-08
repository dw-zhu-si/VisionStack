import AppKit
import SwiftUI

enum ReferenceSelectionPolicy {
    static func validatedSelection(_ selection: UUID?, supported: Bool) -> UUID? {
        supported ? selection : nil
    }
}

struct ReferenceAssetPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: UUID?
    let supported: Bool
    @State private var showingLibrary = false

    private var selectedAsset: ReferenceAsset? {
        guard let selection else { return nil }
        return store.currentProjectReferenceAssets.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("参考图")
            Picker("参考图", selection: $selection) {
                Text("不使用参考图").tag(nil as UUID?)
                ForEach(store.currentProjectReferenceAssets) { asset in Text(asset.name).tag(Optional(asset.id)) }
            }
            .labelsHidden()
            .disabled(store.currentProjectReferenceAssets.isEmpty || !supported)
            HStack(spacing: 14) {
                Spacer()
                Button { Task { await store.importReferenceImages() } } label: {
                    Label("导入", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VSColor.vermilion)
                Button { showingLibrary = true } label: {
                    Label("管理参考图", systemImage: "rectangle.stack.badge.person.crop")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VSColor.vermilion)
            }
            if let selectedAsset {
                HStack(spacing: 10) {
                    ReferenceThumbnail(asset: selectedAsset, width: 62, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedAsset.name).font(.vsLabel(10)).lineLimit(1)
                        Text("已选择；提交时将要求产生明显变化 · \(store.referenceUsageCount(selectedAsset.id)) 个历史引用")
                            .font(.vsBody(9)).foregroundStyle(VSColor.moss)
                    }
                    Spacer()
                    Button("清除") { selection = nil }
                        .buttonStyle(.plain).font(.vsLabel(9)).foregroundStyle(VSColor.vermilion)
                }
                .padding(8)
                .background(VSColor.moss.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            Text(!supported ? "当前模型未声明参考图输入；可在能力档案中核对。" : (selection == nil ? "可选；文件会复制到映栈本地目录。" : "提交时请求将包含参考图，并附带可见编辑约束；供应商是否采纳以实际结果为准。"))
                .font(.vsBody(10)).foregroundStyle(VSColor.muted)
        }
        .sheet(isPresented: $showingLibrary) {
            ReferenceLibrarySheet(selection: $selection, selectionSupported: supported)
                .environmentObject(store)
        }
        .onChange(of: store.selectedProjectID) { selection = nil }
        .onChange(of: supported) {
            selection = ReferenceSelectionPolicy.validatedSelection(selection, supported: supported)
        }
        .onChange(of: store.referenceAssets) {
            if let selection,
               !store.currentProjectReferenceAssets.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }
}

struct PortraitReferenceGroupPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var identitySelection: UUID?
    @Binding var photographySelection: UUID?
    let supported: Bool
    @State private var showingLibrary = false
    @State private var activeRole: ImageReferenceRole = .identity

    private var hasDuplicateSelection: Bool {
        identitySelection != nil && identitySelection == photographySelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                FieldLabel("写真参考组")
                Spacer()
                Button { Task { await store.importReferenceImages() } } label: {
                    Label("导入", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            }
            rolePicker(
                title: "身份参考",
                detail: "只定义人物身份，不继承服装、表情与光线",
                role: .identity,
                selection: $identitySelection
            )
            rolePicker(
                title: "摄影方案参考",
                detail: "只定义妆发、服装、场景、镜头、光线与质感",
                role: .photographyPlan,
                selection: $photographySelection
            )
            if hasDuplicateSelection {
                Label("两种职责不能使用同一张图，请分别选择。", systemImage: "exclamationmark.triangle.fill")
                    .font(.vsBody(9)).foregroundStyle(VSColor.vermilion)
            } else {
                Text("提交顺序固定为身份参考 → 摄影方案参考；每轮迭代继续使用原始参考组。")
                    .font(.vsBody(9)).foregroundStyle(VSColor.moss)
            }
        }
        .padding(11)
        .background(VSColor.canvas.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingLibrary) {
            ReferenceLibrarySheet(selection: activeSelection, selectionSupported: supported)
                .environmentObject(store)
        }
        .onChange(of: store.selectedProjectID) {
            identitySelection = nil
            photographySelection = nil
        }
        .onChange(of: supported) {
            if !supported {
                identitySelection = nil
                photographySelection = nil
            }
        }
        .onChange(of: store.referenceAssets) {
            let validIDs = Set(store.currentProjectReferenceAssets.map(\.id))
            if let identitySelection, !validIDs.contains(identitySelection) { self.identitySelection = nil }
            if let photographySelection, !validIDs.contains(photographySelection) { self.photographySelection = nil }
        }
    }

    private var activeSelection: Binding<UUID?> {
        Binding(
            get: { activeRole == .identity ? identitySelection : photographySelection },
            set: { value in
                if activeRole == .identity { identitySelection = value }
                else { photographySelection = value }
            }
        )
    }

    private func rolePicker(
        title: String,
        detail: String,
        role: ImageReferenceRole,
        selection: Binding<UUID?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.vsLabel(10)).foregroundStyle(VSColor.ink)
                Spacer()
                Button("管理图库") {
                    activeRole = role
                    showingLibrary = true
                }
                .buttonStyle(.plain).font(.vsLabel(9)).foregroundStyle(VSColor.vermilion)
            }
            Picker(title, selection: selection) {
                Text("未选择").tag(nil as UUID?)
                ForEach(store.currentProjectReferenceAssets) { asset in
                    Text(asset.name).tag(Optional(asset.id))
                }
            }
            .labelsHidden()
            .disabled(store.currentProjectReferenceAssets.isEmpty || !supported)
            Text(detail).font(.vsBody(9)).foregroundStyle(VSColor.muted)
        }
    }
}

struct ReferenceLibrarySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UUID?
    let selectionSupported: Bool
    @State private var query = ""
    @State private var pendingDelete: ReferenceAsset?

    private var assets: [ReferenceAsset] {
        store.currentProjectReferenceAssets
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("参考图库").font(.vsTitle(24))
                    Text("为当前项目选择、预览和管理参考图").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                if selection != nil {
                    Button("不使用参考图") { selection = nil }
                }
                Button { Task { await store.importReferenceImages() } } label: {
                    Label("导入参考图", systemImage: "photo.badge.plus")
                }
                Button("关闭") { dismiss() }
            }
            .padding(20)
            Divider()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(VSColor.muted)
                TextField("按文件名搜索参考图", text: $query).textFieldStyle(.roundedBorder)
                Text("\(assets.count) 张").font(.vsLabel(10)).foregroundStyle(VSColor.muted)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            if !selectionSupported {
                Label("当前模型没有声明图片输入能力；可以管理图库，但不能选作本次生成参考图。", systemImage: "exclamationmark.triangle.fill")
                    .font(.vsBody(10)).foregroundStyle(VSColor.vermilion)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }

            if assets.isEmpty {
                EmptyStudioState(
                    symbol: "photo.on.rectangle.angled",
                    title: query.isEmpty ? "还没有参考图" : "没有匹配的参考图",
                    detail: query.isEmpty ? "导入一张图片，或把作品台中的生成结果加入参考图库。" : "换一个文件名关键词试试。"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        ForEach(assets) { asset in
                            ReferenceLibraryCard(
                                asset: asset,
                                selected: selection == asset.id,
                                selectionSupported: selectionSupported,
                                onSelect: { selection = asset.id },
                                onDelete: { pendingDelete = asset }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .background(PaperBackground())
        .confirmationDialog("删除参考图？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除本地副本", role: .destructive) {
                guard let asset = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    await store.deleteReference(asset)
                    if !store.referenceAssets.contains(where: { $0.id == asset.id }), selection == asset.id {
                        selection = nil
                    }
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            if let asset = pendingDelete {
                Text(store.referenceUsageCount(asset.id) == 0
                    ? "将删除映栈受控目录中的本地副本。"
                    : "该参考图仍被 \(store.referenceUsageCount(asset.id)) 个任务或分镜引用，映栈会保留它。")
            }
        }
    }
}

private struct ReferenceLibraryCard: View {
    @EnvironmentObject private var store: AppStore
    let asset: ReferenceAsset
    let selected: Bool
    let selectionSupported: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    private var localURL: URL? {
        guard let url = URL(string: asset.localURL), url.isFileURL else { return nil }
        return url
    }

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                ReferenceThumbnail(asset: asset, width: nil, height: 132)
                HStack(alignment: .firstTextBaseline) {
                    Text(asset.name).font(.vsLabel(11)).lineLimit(1)
                    Spacer()
                    if selected { StatusPill(title: "正在使用", color: VSColor.moss) }
                }
                Text(asset.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.vsBody(9)).foregroundStyle(VSColor.muted)
                Label("\(store.referenceUsageCount(asset.id)) 个任务或分镜引用", systemImage: "link")
                    .font(.vsBody(9)).foregroundStyle(VSColor.muted)
                HStack(spacing: 10) {
                    Button(selected ? "已选择" : "用于生成", action: onSelect)
                        .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                        .disabled(selected || !selectionSupported)
                    if let localURL {
                        Button("查看") { MediaFileActions.open(localURL) }.buttonStyle(.plain)
                        Button("Finder") { MediaFileActions.reveal(localURL) }.buttonStyle(.plain)
                    }
                    Spacer()
                    Button("删除", role: .destructive, action: onDelete).buttonStyle(.plain)
                }
                .font(.vsLabel(9))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? VSColor.moss : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
    }
}

private struct ReferenceThumbnail: View {
    let asset: ReferenceAsset
    let width: CGFloat?
    let height: CGFloat

    var body: some View {
        Group {
            if let url = URL(string: asset.localURL), url.isFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    VSColor.canvas
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(VSColor.vermilion)
                }
            }
        }
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("参考图 \(asset.name)")
    }
}

struct StoryboardPanel: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedShotID: UUID?
    @Binding var prompt: String
    @Binding var duration: Int
    @Binding var referenceAssetID: UUID?
    @State private var title = ""
    @State private var confirmingBatch = false

    private var shots: [StoryboardShot] { store.storyboardShots.filter { $0.projectID == store.selectedProjectID }.sorted { $0.order < $1.order } }
    private var batchSize: String { store.profile(for: store.preferredVideoModel)?.videoResolutions.first ?? "720p" }
    private var batchRatio: String { store.profile(for: store.preferredVideoModel)?.aspectRatios.first ?? "16:9" }
    private var batchPreview: StoryboardBatchPreview { store.storyboardBatchPreview(size: batchSize, ratio: batchRatio) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("分镜板").font(.vsTitle(18))
                    Text("镜头描述、参考图与时长会进入真实时间线").font(.vsBody(10)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                if let queue = store.currentStoryboardBatchQueue, !queue.pendingShotIDs.isEmpty {
                    StatusPill(
                        title: "\(queue.pendingShotIDs.count) 待提交",
                        color: queue.isPaused ? VSColor.orange : VSColor.moss
                    )
                    if queue.isPaused {
                        Button("恢复批量") { Task { await store.resumeStoryboardBatch() } }
                            .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                    } else {
                        Button("暂停批量") { store.pauseStoryboardBatch() }
                            .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                    }
                }
                Button { confirmingBatch = true } label: { Label("批量生成", systemImage: "play.square.stack") }
                    .buttonStyle(.plain).foregroundStyle(VSColor.vermilion).disabled(shots.isEmpty || store.preferredVideoModel.isEmpty)
                Button { addShot() } label: { Label("加入镜头", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if shots.isEmpty {
                Text("填写左侧镜头描述后加入分镜；随后可排序、修改并批量生成版本。")
                    .font(.vsBody(11)).foregroundStyle(VSColor.muted).padding(.vertical, 12)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(shots) { shot in
                            Button { select(shot) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(shot.title.isEmpty ? "镜头 \(shot.order + 1)" : shot.title).font(.vsLabel(10)).lineLimit(1)
                                    Text("\(shot.durationSeconds)s · \(store.currentProjectVideoJobs.filter { $0.storyboardShotID == shot.id }.count) 个版本")
                                        .font(.vsBody(9)).foregroundStyle(VSColor.muted)
                                }
                                .padding(9).frame(width: 150, alignment: .leading)
                                .background(selectedShotID == shot.id ? VSColor.orange.opacity(0.18) : Color.white.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedShotID == shot.id ? VSColor.vermilion : VSColor.ink.opacity(0.1)))
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)

                if let selectedShotID {
                    HStack(spacing: 8) {
                        TextField("镜头标题", text: $title).textFieldStyle(.roundedBorder)
                        Button("保存镜头") { saveShot(selectedShotID) }
                        Button("单镜头补做") {
                            Task { await store.generateStoryboardShotVersion(selectedShotID, size: batchSize, ratio: batchRatio) }
                        }
                        .disabled(!store.canStartGeneration || store.preferredVideoModel.isEmpty)
                        Button { store.moveStoryboardShot(selectedShotID, offset: -1) } label: { Image(systemName: "arrow.left") }.help("向前移动")
                        Button { store.moveStoryboardShot(selectedShotID, offset: 1) } label: { Image(systemName: "arrow.right") }.help("向后移动")
                        Button(role: .destructive) { store.deleteStoryboardShot(selectedShotID); self.selectedShotID = nil } label: { Image(systemName: "trash") }
                    }.buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                }
            }
        }
        .onChange(of: selectedShotID) { loadSelectedShot() }
        .confirmationDialog("确认批量提交分镜？", isPresented: $confirmingBatch, titleVisibility: .visible) {
            Button("建立队列并开始生成") {
                Task { await store.generateStoryboardBatch(size: batchSize, ratio: batchRatio) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(batchConfirmationText)
        }
    }

    private func addShot() {
        if let id = store.addStoryboardShot(prompt: prompt, duration: duration, referenceAssetID: referenceAssetID) {
            selectedShotID = id
            loadSelectedShot()
        }
    }

    private func select(_ shot: StoryboardShot) {
        selectedShotID = shot.id
        title = shot.title
        prompt = shot.prompt
        duration = shot.durationSeconds
        referenceAssetID = shot.referenceAssetID
    }

    private func loadSelectedShot() {
        guard let shot = shots.first(where: { $0.id == selectedShotID }) else { return }
        select(shot)
    }

    private func saveShot(_ id: UUID) {
        store.updateStoryboardShot(id, title: title, prompt: prompt, duration: duration, referenceAssetID: referenceAssetID)
    }

    private var batchConfirmationText: String {
        let costText = batchPreview.estimatedKnownCost.map {
            "按本项目已知历史单价估算约 ¥\(NSDecimalNumber(decimal: $0).stringValue)"
        } ?? "供应商未返回足够单价，当前只能显示请求数，金额未知"
        return "当前项目共 \(batchPreview.requestCount) 个分镜；首轮可并发 \(batchPreview.acceptedShotIDs.count) 个，其余进入可暂停、可恢复队列。\(costText)。每个分镜仍是独立的可能计费请求。"
    }
}

struct StoryboardTimeline: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedShotID: UUID?

    private var shots: [StoryboardShot] { store.storyboardShots.filter { $0.projectID == store.selectedProjectID }.sorted { $0.order < $1.order } }
    private var segments: [TimelineSegment] { StoryboardTimelineLayout.segments(for: shots) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timeline.selection").foregroundStyle(VSColor.vermilion)
            VStack(alignment: .leading, spacing: 1) {
                Text("时间线").font(.vsLabel(10))
                Text("\(segments.reduce(0) { $0 + $1.durationSeconds }) 秒").font(.vsBody(9)).foregroundStyle(VSColor.muted)
            }
            if segments.isEmpty {
                Text("分镜加入后会按时长排列").font(.vsBody(10)).foregroundStyle(VSColor.muted)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(segments, id: \.shotID) { segment in
                            let shot = shots.first { $0.id == segment.shotID }
                            let jobs = store.currentProjectVideoJobs.filter { $0.storyboardShotID == segment.shotID }
                            Button { selectedShotID = segment.shotID } label: {
                                VStack(spacing: 1) {
                                    Text(shot?.title ?? "镜头").lineLimit(1)
                                    Text("\(segment.startSeconds)s–\(segment.startSeconds + segment.durationSeconds)s · v\(jobs.count)")
                                }
                                .font(.vsLabel(8)).foregroundStyle(Color.white)
                                .frame(width: min(max(CGFloat(segment.durationSeconds) * 14, 74), 220), height: 32)
                                .background(jobs.contains(where: { $0.state == .succeeded }) ? VSColor.moss : VSColor.orange)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selectedShotID == segment.shotID ? Color.white : Color.clear, lineWidth: 2))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(shot?.title ?? "镜头")，从 \(segment.startSeconds) 秒开始，时长 \(segment.durationSeconds) 秒")
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).frame(height: 58).background(VSColor.canvas.opacity(0.45))
    }
}
