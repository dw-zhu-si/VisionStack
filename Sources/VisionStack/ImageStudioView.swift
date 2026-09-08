import AppKit
import SwiftUI

struct ImageStudioView: View {
    @EnvironmentObject private var store: AppStore
    @State private var size = "1024x1024"
    @State private var quality = "auto"
    @State private var customWidth = 1024
    @State private var customHeight = 1024
    @State private var batchCount = 1
    @State private var referenceAssetID: UUID?
    @State private var identityReferenceAssetID: UUID?
    @State private var photographyReferenceAssetID: UUID?
    @State private var confirming = false

    private var profile: CapabilityProfile? { store.profile(for: store.preferredImageModel) }
    private var sizes: [String] { profile?.imageSizes.isEmpty == false ? profile!.imageSizes : ["1024x1024", "1536x1024", "1024x1536"] }
    private var qualities: [String] { profile?.qualities.isEmpty == false ? profile!.qualities : ["auto", "medium", "high"] }
    private let customSizeLabel = "自定义尺寸…"
    private var sizeOptions: [String] { sizes + [customSizeLabel] }
    private var usesCustomSize: Bool { size == customSizeLabel }
    private var customDimensionValidation: ImageDimensionValidation {
        ImageDimensionPolicy.validation(width: customWidth, height: customHeight, profile: profile)
    }
    private var effectiveSize: String {
        usesCustomSize ? ImageDimensionPolicy.requestValue(width: customWidth, height: customHeight) : size
    }
    private var isDimensionValid: Bool { !usesCustomSize || customDimensionValidation.isValid }
    private var selectedImageAgentStableID: String? {
        store.imageAgents.first { $0.id == store.selectedImageAgentID }?.stableID
    }
    private var usesPortraitReferenceGroup: Bool {
        selectedImageAgentStableID == LocalMediaAgentCatalog.portraitReshootAgentStableID
    }
    private var imageReferences: [ImageReferenceBinding] {
        if usesPortraitReferenceGroup {
            return [
                identityReferenceAssetID.map { ImageReferenceBinding(assetID: $0, role: .identity) },
                photographyReferenceAssetID.map { ImageReferenceBinding(assetID: $0, role: .photographyPlan) }
            ].compactMap { $0 }
        }
        return referenceAssetID.map { [ImageReferenceBinding(assetID: $0, role: .general)] } ?? []
    }
    private var hasDuplicatePortraitReferences: Bool {
        identityReferenceAssetID != nil && identityReferenceAssetID == photographyReferenceAssetID
    }
    private var isReferenceSelectionValid: Bool {
        guard !imageReferences.isEmpty else { return true }
        guard profile?.supportsReferenceImage == true, !hasDuplicatePortraitReferences else { return false }
        return imageReferences.count == 1 || store.preferredImageModel.lowercased().contains("qwen-image")
    }
    private var referenceSummary: String {
        if imageReferences.isEmpty { return "无" }
        if usesPortraitReferenceGroup { return "\(imageReferences.count) 张（身份/摄影职责分离）" }
        return "1 张（要求明显编辑）"
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("IMAGE COMPOSER").font(.vsLabel(9)).tracking(2).foregroundStyle(VSColor.vermilion)
                    Text("先定画面，\n+再让模型落笔。")
                        .font(.vsTitle(30)).foregroundStyle(VSColor.ink)
                    StudioCard {
                        VStack(alignment: .leading, spacing: 14) {
                            FieldLabel("画面描述")
                            TextEditor(text: $store.imagePromptDraft).font(.vsBody(13)).scrollContentBackground(.hidden).frame(height: 150).padding(8).background(VSColor.paper.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 10))
                            if store.availableModels.isEmpty {
                                ModelUnavailableCard(operation: .image)
                            } else {
                                FieldLabel("图片模型")
                                ModelSelectionControl(operation: .image, selection: $store.preferredImageModel)
                                CapabilityNote(profile: profile)
                                HStack(spacing: 12) {
                                    parameterPicker("尺寸", selection: $size, values: sizeOptions)
                                    parameterPicker("质量", selection: $quality, values: qualities)
                                }.disabled(!store.canUseModelService)
                                CreativePresetPicker(operation: .image) { preset in
                                    let applied = CreativePresetResolver.apply(
                                        preset,
                                        to: store.imagePromptDraft,
                                        parameters: ["size": effectiveSize, "quality": quality]
                                    )
                                    store.imagePromptDraft = applied.prompt
                                    if let presetSize = applied.parameters["size"] {
                                        if sizeOptions.contains(presetSize) {
                                            size = presetSize
                                        } else if let dimensions = ImageDimensionPolicy.parse(presetSize) {
                                            size = customSizeLabel
                                            customWidth = dimensions.width
                                            customHeight = dimensions.height
                                        }
                                    }
                                    if let presetQuality = applied.parameters["quality"], qualities.contains(presetQuality) {
                                        quality = presetQuality
                                    }
                                }
                                if usesCustomSize {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(spacing: 10) {
                                            dimensionField("宽度", value: $customWidth)
                                            Text("×").font(.vsLabel(12)).foregroundStyle(VSColor.muted)
                                            dimensionField("高度", value: $customHeight)
                                            Text("px").font(.vsBody(10)).foregroundStyle(VSColor.muted)
                                        }
                                        if let message = customDimensionValidation.message {
                                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                                .font(.vsBody(10)).foregroundStyle(VSColor.vermilion)
                                        } else {
                                            Text("已通过当前模型像素范围校验；提交值：\(effectiveSize)")
                                                .font(.vsBody(10)).foregroundStyle(VSColor.moss)
                                        }
                                    }
                                }
                                MediaAgentSkillPicker(operation: .image)
                                if usesPortraitReferenceGroup {
                                    PortraitReferenceGroupPicker(
                                        identitySelection: $identityReferenceAssetID,
                                        photographySelection: $photographyReferenceAssetID,
                                        supported: profile?.supportsReferenceImage == true
                                    )
                                    if imageReferences.count > 1 && !store.preferredImageModel.lowercased().contains("qwen-image") {
                                        Label("当前模型只接受 1 张参考图；双角色参考请切换到已声明 Qwen 图片能力的模型。", systemImage: "exclamationmark.triangle.fill")
                                            .font(.vsBody(9)).foregroundStyle(VSColor.vermilion)
                                    }
                                } else {
                                    ReferenceAssetPicker(selection: $referenceAssetID, supported: profile?.supportsReferenceImage == true)
                                    Text("可从“管理参考图”预览、复用或删除当前项目的参考图片。")
                                        .font(.vsBody(9)).foregroundStyle(VSColor.muted)
                                }
                                HStack {
                                    FieldLabel("批量版本")
                                    Spacer()
                                    Stepper("\(batchCount) 个", value: $batchCount, in: 1...4).frame(width: 120)
                                }
                            }
                            Button { confirming = true } label: { HStack { Image(systemName: "sparkles.rectangle.stack"); Text(batchCount == 1 ? "生成图片" : "生成 \(batchCount) 个版本"); Spacer(); Text("可能计费").opacity(0.62) } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(store.imagePromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canStartGeneration || !store.canUseModelService || store.preferredImageModel.isEmpty || !isDimensionValid || !isReferenceSelectionValid)
                        }
                    }
                    Text("映栈会把参数交给当前直连厂商或 ModelHub；直连密钥只保存在 Keychain。候选档案参数必须在确认框中再次核对。")
                        .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                }
                .padding(26)
            }
            .frame(width: 390)

            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("作品台").font(.vsTitle(22)); Spacer(); Text("\(store.currentProjectImageJobs.count) 个任务").font(.vsBody(10)).foregroundStyle(VSColor.muted) }
                if store.currentProjectImageJobs.isEmpty { EmptyStudioState(symbol: "photo.badge.plus", title: "第一张画面会出现在这里", detail: "生成结果和失败回执都会保存在当前项目历史中。") }
                else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                            ForEach(store.currentProjectImageJobs) { job in GenerationCard(job: job) }
                        }
                    }
                }
            }.padding(24)
        }
        .confirmationDialog("确认创建可能计费的图片任务", isPresented: $confirming, titleVisibility: .visible) {
            Button("使用 \(store.preferredImageModel) 生成 \(batchCount) 个版本") {
                Task {
                    await store.generateImageBatch(
                        prompt: store.imagePromptDraft,
                        size: effectiveSize,
                        quality: quality,
                        count: batchCount,
                        referenceAssetID: imageReferences.first?.assetID,
                        imageReferences: imageReferences
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("尺寸：\(effectiveSize)；质量：\(quality)；参考图：\(referenceSummary)；\(store.mediaRoutingSummary(for: .image))。ModelHub 将使用现有供应商余额。") }
        .onChange(of: store.preferredImageModel) {
            size = ParameterSelectionPolicy.preserving(size, allowed: sizeOptions, fallback: "1024x1024")
            quality = ParameterSelectionPolicy.preserving(quality, allowed: qualities, fallback: "auto")
            referenceAssetID = ReferenceSelectionPolicy.validatedSelection(
                referenceAssetID,
                supported: profile?.supportsReferenceImage == true
            )
        }
    }

    private func parameterPicker(_ label: String, selection: Binding<String>, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) { FieldLabel(label); Picker(label, selection: selection) { ForEach(values, id: \.self) { Text($0).tag($0) } }.labelsHidden() }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dimensionField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 105)
                .accessibilityLabel("自定义图片\(label)，单位像素")
        }
    }
}

struct GenerationCard: View {
    @EnvironmentObject private var store: AppStore
    let job: GenerationJob
    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                mediaPreview
                HStack { StatusPill(title: job.state.rawValue, color: statusColor); Spacer(); Text(job.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.vsBody(8)).foregroundStyle(VSColor.muted) }
                Text(job.prompt).font(.vsBody(11)).lineLimit(3).foregroundStyle(VSColor.ink)
                Text(job.model).font(.vsBody(9)).lineLimit(1).foregroundStyle(VSColor.muted)
                if let routing = store.mediaRoutingDescription(for: job) {
                    Label(routing, systemImage: "person.crop.square.filled.and.at.rectangle")
                        .font(.vsBody(9)).foregroundStyle(VSColor.moss).lineLimit(1)
                }
                if !job.effectiveImageReferences.isEmpty {
                    Label(
                        job.effectiveImageReferences.count > 1
                            ? "参考组：身份 + 摄影方案 · 请求已包含"
                            : (job.parameters["reference_mode"] == "visible-edit"
                                ? "参考图：请求已包含 · 可见编辑约束"
                                : "参考图：请求已包含"),
                        systemImage: "photo.badge.checkmark"
                    )
                    .font(.vsBody(9)).foregroundStyle(VSColor.moss).lineLimit(1)
                }
                if let error = job.errorMessage { Text(error).font(.vsBody(9)).foregroundStyle(VSColor.vermilion).lineLimit(3) }
                if let first = job.resultURLs.first, let url = URL(string: first), ["http", "https", "file"].contains(url.scheme ?? "") {
                    Link("打开结果", destination: url).font(.vsLabel(10)).foregroundStyle(VSColor.vermilion)
                }
                MediaResultActions(
                    job: job,
                    onRetry: { Task { await store.retryImageJob(job, confirmBillable: true) } },
                    onCancel: { Task { await store.cancelImageJob(job.id) } },
                    onDelete: { Task { await store.deleteImageJob(job) } }
                )
                if job.state == .succeeded, !MediaFileActions.localURLs(for: job).isEmpty {
                    Button { Task { await store.addReference(from: job) } } label: { Label("加入参考图库", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.plain).font(.vsLabel(10)).foregroundStyle(VSColor.vermilion)
                }
            }
        }
    }

    @ViewBuilder private var mediaPreview: some View {
        if job.kind == .image, let first = job.resultURLs.first, let url = URL(string: first) {
            if url.isFileURL, let image = NSImage(contentsOf: url) {
                Button { MediaFileActions.open(url) } label: {
                    Image(nsImage: image).resizable().scaledToFill().frame(height: 150).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("点按查看图片")
            } else {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
                    .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else { placeholder.frame(height: 128) }
    }
    private var placeholder: some View { ZStack { VSColor.canvas.opacity(0.55); Image(systemName: job.kind == .image ? "photo" : "film").font(.system(size: 28)).foregroundStyle(VSColor.muted) }.clipShape(RoundedRectangle(cornerRadius: 10)) }
    private var statusColor: Color { switch job.state { case .succeeded: VSColor.moss; case .failed, .timedOut, .cancelled: VSColor.vermilion; default: VSColor.orange } }
}

struct EmptyStudioState: View {
    let symbol: String, title: String, detail: String
    var body: some View { VStack(spacing: 13) { Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(VSColor.vermilion); Text(title).font(.vsTitle(20)); Text(detail).font(.vsBody(11)).foregroundStyle(VSColor.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}
