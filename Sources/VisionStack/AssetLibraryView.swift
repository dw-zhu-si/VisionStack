import AppKit
import SwiftUI

struct AssetLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kindFilter = "全部"
    @State private var favoritesOnly = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var previewJob: GenerationJob?
    @State private var editingJob: GenerationJob?
    @State private var confirmingBatchDelete = false
    @State private var confirmingRepair = false
    @State private var showingComparison = false

    private var jobs: [GenerationJob] {
        guard kindFilter != "参考图" else { return [] }
        return store.assetJobs.filter { job in
            guard job.projectID == store.selectedProjectID else { return false }
            let matchesKind = kindFilter == "全部" || (kindFilter == "图片" && job.kind == .image) || (kindFilter == "视频" && job.kind == .video)
            let matchesFavorite = !favoritesOnly || job.favorite == true
            let haystack = ([job.prompt, job.model, job.collection ?? ""] + (job.tags ?? [])).joined(separator: " ")
            let matchesQuery = query.isEmpty || haystack.localizedCaseInsensitiveContains(query)
            return matchesKind && matchesFavorite && matchesQuery
        }
    }

    private var filteredReferences: [ReferenceAsset] {
        let projectAssets = store.referenceAssets.filter { $0.projectID == store.selectedProjectID }
        return query.isEmpty ? projectAssets : projectAssets.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("素材库").font(.vsTitle(25))
                    Text("搜索、分组、收藏、版本与批量交付").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                if let report = store.mediaHealthReport {
                    StatusPill(title: report.isHealthy ? "媒体健康" : "\(report.issueCount) 项问题", color: report.isHealthy ? VSColor.moss : VSColor.vermilion)
                }
                Button { Task { await store.runMediaHealthCheck() } } label: { Label("健康检查", systemImage: "stethoscope") }
                Text("\(kindFilter == "参考图" ? filteredReferences.count : jobs.count) 项").font(.vsLabel(11)).foregroundStyle(VSColor.muted)
                Button("关闭") { dismiss() }
            }.padding(22)
            Divider()

            HStack(spacing: 12) {
                TextField("搜索提示词、模型、标签或分组", text: $query).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $kindFilter) { ForEach(["全部", "图片", "视频", "参考图"], id: \.self) { Text($0).tag($0) } }
                    .frame(width: 110)
                if kindFilter != "参考图" { Toggle("仅收藏", isOn: $favoritesOnly).toggleStyle(.checkbox) }
                Spacer()
                if kindFilter == "参考图" {
                    Button { Task { await store.importReferenceImages() } } label: { Label("导入参考图", systemImage: "photo.badge.plus") }
                } else {
                    Button("全选") { selectedIDs = Set(jobs.map(\.id)) }.disabled(jobs.isEmpty)
                    Button("版本对比") { showingComparison = true }.disabled(selectedIDs.count < 2)
                    Button("导出所选") { exportSelected() }.disabled(selectedIDs.isEmpty)
                    Button("删除所选", role: .destructive) { confirmingBatchDelete = true }.disabled(selectedIDs.isEmpty)
                }
            }.padding(16)

            if kindFilter == "参考图" {
                if filteredReferences.isEmpty {
                    EmptyStudioState(symbol: "photo.on.rectangle.angled", title: "还没有参考图", detail: "导入图片或把已生成的图片加入参考图库。")
                } else {
                    List(filteredReferences) { asset in ReferenceAssetRow(asset: asset) }
                        .scrollContentBackground(.hidden)
                }
            } else if jobs.isEmpty {
                EmptyStudioState(symbol: "square.grid.2x2", title: "没有符合条件的素材", detail: "生成结果成功归档后会自动进入素材库。")
            } else {
                List(jobs) { job in
                    AssetRow(
                        job: job,
                        selected: selectedIDs.contains(job.id),
                        onSelection: { enabled in if enabled { selectedIDs.insert(job.id) } else { selectedIDs.remove(job.id) } },
                        onPreview: { previewJob = job },
                        onEdit: { editingJob = job },
                        onFavorite: { store.updateJobMetadata(job, favorite: !(job.favorite ?? false), tags: job.tags ?? [], collection: job.collection ?? "") }
                    )
                }
                .scrollContentBackground(.hidden)
            }

            HStack {
                Image(systemName: "arrow.up.doc")
                Text(kindFilter == "参考图" ? "参考图保存在映栈受控目录；被任务、分镜引用或属于已归档项目时会阻止永久删除。" : "批量导出会为每个任务创建目录，并写入提示词、模型、参数、标签、分镜和版本关系。")
                Spacer()
                if let report = store.mediaHealthReport, !report.isHealthy {
                    Button("确认修复") { confirmingRepair = true }.foregroundStyle(VSColor.vermilion)
                }
            }.font(.vsBody(11)).foregroundStyle(VSColor.muted).padding(14)
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(PaperBackground())
        .sheet(item: $previewJob) { job in MediaViewerSheet(jobID: job.id, kind: job.kind).environmentObject(store) }
        .sheet(item: $editingJob) { job in AssetMetadataEditor(job: job).environmentObject(store) }
        .sheet(isPresented: $showingComparison) {
            VersionComparisonView(jobs: store.assetJobs.filter { selectedIDs.contains($0.id) }).environmentObject(store)
        }
        .confirmationDialog("删除所选素材？", isPresented: $confirmingBatchDelete, titleVisibility: .visible) {
            Button("删除任务和本地文件", role: .destructive) {
                let ids = selectedIDs
                selectedIDs.removeAll()
                Task { await store.deleteJobs(ids) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("将删除 \(selectedIDs.count) 项任务及其全部本地归档，此操作无法撤销。") }
        .confirmationDialog("修复媒体库？", isPresented: $confirmingRepair, titleVisibility: .visible) {
            Button("清理孤立文件并修正缺失引用", role: .destructive) { Task { await store.repairMediaLibrary() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只处理映栈受控媒体目录：删除未被任何任务引用的文件；缺失归档会转为可恢复状态，缺失参考图会解除本地记录。")
        }
    }

    private func exportSelected() {
        do { try MediaFileActions.exportJobs(store.allJobs.filter { selectedIDs.contains($0.id) }) }
        catch { store.notice = "批量导出失败：\(error.localizedDescription)" }
    }
}

private struct VersionComparisonView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let jobs: [GenerationJob]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) { Text("版本评审").font(.vsTitle(24)); Text("并排核对模型、参数、结果、评分、成本与最终版").font(.vsBody(11)).foregroundStyle(VSColor.muted) }
                Spacer(); Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(jobs) { job in
                        StudioCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(job.versionIndex.map { "版本 \($0)" } ?? String(job.id.uuidString.prefix(8))).font(.vsTitle(18))
                                StatusPill(title: job.state.rawValue, color: job.state == .succeeded ? VSColor.moss : VSColor.orange)
                                media(job)
                                FieldLabel("提示词"); Text(job.prompt).font(.vsBody(11)).lineLimit(8).textSelection(.enabled)
                                FieldLabel("模型"); Text(job.model).font(.vsBody(10)).textSelection(.enabled)
                                FieldLabel("参数"); Text(job.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                FieldLabel("成本"); Text(job.cost.flatMap { $0.actualAmount ?? $0.estimatedAmount }.map { "¥\(NSDecimalNumber(decimal: $0).stringValue)" } ?? "金额未知").font(.vsBody(11))
                                FieldLabel("评分与评语")
                                Picker("评分", selection: Binding(
                                    get: { store.versionReview(for: job.id)?.score ?? 3 },
                                    set: { store.updateVersionReview(jobID: job.id, score: $0, notes: store.versionReview(for: job.id)?.notes ?? "") }
                                )) {
                                    ForEach(1...5, id: \.self) { Text("\($0) 星").tag($0) }
                                }
                                .labelsHidden()
                                TextField("记录选择理由", text: Binding(
                                    get: { store.versionReview(for: job.id)?.notes ?? "" },
                                    set: { store.updateVersionReview(jobID: job.id, score: store.versionReview(for: job.id)?.score ?? 3, notes: $0) }
                                ), axis: .vertical)
                                .lineLimit(2...4)
                                Button {
                                    store.markFinalVersion(jobID: job.id)
                                } label: {
                                    Label(
                                        store.versionReview(for: job.id)?.isFinal == true ? "当前最终版" : "设为最终版",
                                        systemImage: store.versionReview(for: job.id)?.isFinal == true ? "checkmark.seal.fill" : "checkmark.seal"
                                    )
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(store.versionReview(for: job.id)?.isFinal == true ? VSColor.moss : VSColor.vermilion)
                                Text("重试组 \(job.effectiveRetryGroupID.uuidString.prefix(8))").font(.vsBody(9)).foregroundStyle(VSColor.muted)
                            }.frame(width: 300, alignment: .leading)
                        }
                    }
                }.padding(22)
            }
        }.frame(minWidth: 760, minHeight: 650).background(PaperBackground())
    }

    @ViewBuilder private func media(_ job: GenerationJob) -> some View {
        if job.kind == .image, let url = MediaFileActions.previewURLs(for: job).first {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(width: 300, height: 190).background(VSColor.canvas).clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            RoundedRectangle(cornerRadius: 9).fill(VSColor.ink).frame(width: 300, height: 140).overlay(Image(systemName: "film").foregroundStyle(VSColor.orange))
        }
    }
}

private struct AssetRow: View {
    let job: GenerationJob
    let selected: Bool
    let onSelection: (Bool) -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onFavorite: () -> Void

    private var firstLocalURL: URL? { MediaFileActions.localURLs(for: job).first }

    @ViewBuilder var body: some View {
        if let firstLocalURL {
            rowContent.draggable(firstLocalURL)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            Toggle("选择", isOn: Binding(get: { selected }, set: { value in onSelection(value) })).labelsHidden().toggleStyle(.checkbox)
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(job.kind == .image ? VSColor.canvas : VSColor.ink)
                Image(systemName: job.kind == .image ? "photo" : "play.rectangle.fill")
                    .font(.system(size: 23)).foregroundStyle(job.kind == .image ? VSColor.vermilion : VSColor.orange)
            }
            .frame(width: 76, height: 56)
            .onTapGesture(perform: onPreview)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.prompt).font(.vsLabel(12)).lineLimit(1)
                    StatusPill(title: job.state.rawValue, color: job.state == .succeeded ? VSColor.moss : VSColor.orange)
                }
                HStack(spacing: 10) {
                    Text(job.model).lineLimit(1)
                    if let collection = job.collection, !collection.isEmpty { Label(collection, systemImage: "folder") }
                    if let parent = job.parentJobID { Label("版本自 \(parent.uuidString.prefix(6))", systemImage: "arrow.triangle.branch") }
                    if let index = job.versionIndex { Label("批次 v\(index)", systemImage: "square.stack.3d.up") }
                    if job.storyboardShotID != nil { Label("分镜", systemImage: "rectangle.split.3x1") }
                }.font(.vsBody(11)).foregroundStyle(VSColor.muted)
                if !(job.tags ?? []).isEmpty {
                    Text((job.tags ?? []).map { "#\($0)" }.joined(separator: "  ")).font(.vsBody(11)).foregroundStyle(VSColor.vermilion)
                }
            }
            Spacer()
            Text("\(MediaFileActions.previewURLs(for: job).count) 个结果").font(.vsBody(11)).foregroundStyle(VSColor.muted)
            Button(action: onFavorite) { Image(systemName: job.favorite == true ? "star.fill" : "star") }.buttonStyle(.plain).foregroundStyle(VSColor.orange)
            Button("编辑", action: onEdit).buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            Button("查看", action: onPreview).buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
        }
        .padding(.vertical, 7)
    }
}

private struct ReferenceAssetRow: View {
    @EnvironmentObject private var store: AppStore
    let asset: ReferenceAsset
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 14) {
            preview
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name).font(.vsLabel(12)).lineLimit(1)
                HStack {
                    Text(asset.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if asset.sourceJobID != nil { Label("来自生成素材", systemImage: "arrow.triangle.branch") }
                }.font(.vsBody(10)).foregroundStyle(VSColor.muted)
            }
            Spacer()
            if let url = URL(string: asset.localURL), url.isFileURL {
                Button("打开") { MediaFileActions.open(url) }.buttonStyle(.plain)
                Button("Finder") { MediaFileActions.reveal(url) }.buttonStyle(.plain)
            }
            Button("删除", role: .destructive) { confirmingDelete = true }.buttonStyle(.plain)
        }
        .padding(.vertical, 7)
        .confirmationDialog("删除参考图？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除本地副本", role: .destructive) { Task { await store.deleteReference(asset) } }
            Button("取消", role: .cancel) {}
        } message: { Text(store.referenceUsageCount(asset.id) == 0 ? "将删除映栈受控目录中的本地副本。" : "该参考图仍被任务或分镜引用，映栈会阻止删除。") }
    }

    @ViewBuilder private var preview: some View {
        if let url = URL(string: asset.localURL), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 76, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            RoundedRectangle(cornerRadius: 9).fill(VSColor.canvas).frame(width: 76, height: 56)
                .overlay(Image(systemName: "photo").foregroundStyle(VSColor.vermilion))
        }
    }
}

private struct AssetMetadataEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let job: GenerationJob
    @State private var favorite: Bool
    @State private var tags: String
    @State private var collection: String

    init(job: GenerationJob) {
        self.job = job
        _favorite = State(initialValue: job.favorite ?? false)
        _tags = State(initialValue: (job.tags ?? []).joined(separator: ", "))
        _collection = State(initialValue: job.collection ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("编辑素材信息").font(.vsTitle(22)); Spacer(); Button("关闭") { dismiss() } }
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    FieldLabel("提示词"); Text(job.prompt).font(.vsBody(12)).textSelection(.enabled)
                    FieldLabel("分组 / 项目"); TextField("例如：品牌片 A / 第三镜", text: $collection).textFieldStyle(.roundedBorder)
                    FieldLabel("标签"); TextField("用逗号分隔，例如：人物, 夜景, 终稿", text: $tags).textFieldStyle(.roundedBorder)
                    Toggle("收藏", isOn: $favorite).toggleStyle(.checkbox)
                }
            }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { save() }.buttonStyle(PrimaryButtonStyle()) }
        }.padding(24).frame(width: 560).background(PaperBackground())
    }

    private func save() {
        let values = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        store.updateJobMetadata(job, favorite: favorite, tags: values, collection: collection)
        dismiss()
    }
}
