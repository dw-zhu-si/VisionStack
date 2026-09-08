import SwiftUI

struct VideoStudioView: View {
    @EnvironmentObject private var store: AppStore
    @State private var resolution = "720p"
    @State private var ratio = "16:9"
    @State private var duration = 5
    @State private var batchCount = 1
    @State private var referenceAssetID: UUID?
    @State private var selectedShotID: UUID?
    @State private var confirming = false

    private var profile: CapabilityProfile? { store.profile(for: store.preferredVideoModel) }
    private var resolutions: [String] { profile?.videoResolutions.isEmpty == false ? profile!.videoResolutions : ["720p", "1080p"] }
    private var ratios: [String] { profile?.aspectRatios.isEmpty == false ? profile!.aspectRatios : ["16:9", "9:16", "1:1"] }
    private var durations: [Int] { profile?.durations.isEmpty == false ? profile!.durations : [4, 5, 8, 10] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("MOTION DESK").font(.vsLabel(9)).tracking(2).foregroundStyle(VSColor.vermilion)
                        Text("让镜头沿着\n+一句话开始运动。")
                            .font(.vsTitle(30)).foregroundStyle(VSColor.ink)
                        StudioCard {
                            VStack(alignment: .leading, spacing: 13) {
                                FieldLabel("镜头描述")
                                TextEditor(text: $store.videoPromptDraft).font(.vsBody(13)).scrollContentBackground(.hidden).frame(height: 120).padding(8).background(VSColor.paper.opacity(0.70)).clipShape(RoundedRectangle(cornerRadius: 10))
                                if store.availableModels.isEmpty {
                                    ModelUnavailableCard(operation: .video)
                                } else {
                                    FieldLabel("视频模型")
                                    ModelSelectionControl(operation: .video, selection: $store.preferredVideoModel)
                                    CapabilityNote(profile: profile)
                                    MediaAgentSkillPicker(operation: .video)
                                    HStack(spacing: 10) {
                                        compactPicker("分辨率", selection: $resolution, values: resolutions)
                                        compactPicker("比例", selection: $ratio, values: ratios)
                                        VStack(alignment: .leading, spacing: 6) { FieldLabel("时长"); Picker("时长", selection: $duration) { ForEach(durations, id: \.self) { Text("\($0) 秒").tag($0) } }.labelsHidden() }.frame(maxWidth: .infinity)
                                    }.disabled(!store.canUseModelService)
                                    CreativePresetPicker(operation: .video) { preset in
                                        let applied = CreativePresetResolver.apply(
                                            preset,
                                            to: store.videoPromptDraft,
                                            parameters: ["resolution": resolution, "ratio": ratio, "duration": "\(duration)"]
                                        )
                                        store.videoPromptDraft = applied.prompt
                                        if let value = applied.parameters["resolution"], resolutions.contains(value) { resolution = value }
                                        if let value = applied.parameters["ratio"], ratios.contains(value) { ratio = value }
                                        if let value = applied.parameters["duration"], let seconds = Int(value), durations.contains(seconds) { duration = seconds }
                                    }
                                    ReferenceAssetPicker(selection: $referenceAssetID, supported: profile?.supportsReferenceImage == true)
                                    HStack {
                                        FieldLabel("批量版本")
                                        Spacer()
                                        Stepper("\(batchCount) 个", value: $batchCount, in: 1...4).frame(width: 120)
                                    }
                                }
                                Button { confirming = true } label: { HStack { Image(systemName: "play.rectangle.on.rectangle"); Text(batchCount == 1 ? "创建视频任务" : "创建 \(batchCount) 个版本"); Spacer(); Text("异步 · 可能计费").opacity(0.62) } }
                                    .buttonStyle(PrimaryButtonStyle()).disabled(store.videoPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canStartGeneration || !store.canUseModelService || store.preferredVideoModel.isEmpty)
                            }
                        }
                    }.padding(24)
                }.frame(width: 425)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button { store.showingRoughCut = true } label: { Label("打开视频草剪台", systemImage: "timeline.selection") }
                            .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                    }
                    StoryboardPanel(selectedShotID: $selectedShotID, prompt: $store.videoPromptDraft, duration: $duration, referenceAssetID: $referenceAssetID)
                    Divider()
                    HStack { Text("制作队列").font(.vsTitle(22)); Spacer(); StatusPill(title: "全局 \(store.activeGenerationCount)/\(store.maxConcurrentGenerationTasks) 并发", color: store.canStartGeneration ? VSColor.moss : VSColor.orange) }
                    if store.currentProjectVideoJobs.isEmpty { EmptyStudioState(symbol: "film.stack", title: "还没有镜头任务", detail: "任务 ID、状态和结果会在当前项目中跨应用重启保留。") }
                    else {
                        ScrollView { LazyVStack(spacing: 13) { ForEach(store.currentProjectVideoJobs) { VideoJobRow(job: $0) } } }
                    }
                }.padding(24)
            }
            StoryboardTimeline(selectedShotID: $selectedShotID)
        }
        .confirmationDialog("确认创建可能计费的视频任务", isPresented: $confirming, titleVisibility: .visible) {
            Button("使用 \(store.preferredVideoModel) 创建 \(batchCount) 个版本") {
                if let selectedShotID, let shot = store.storyboardShots.first(where: { $0.id == selectedShotID }) {
                    store.updateStoryboardShot(selectedShotID, title: shot.title, prompt: store.videoPromptDraft, duration: duration, referenceAssetID: referenceAssetID)
                }
                Task { await store.generateVideoBatch(prompt: store.videoPromptDraft, size: resolution, ratio: ratio, duration: duration, count: batchCount, referenceAssetID: referenceAssetID, storyboardShotID: selectedShotID) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("\(resolution) · \(ratio) · \(duration) 秒 · \(batchCount) 个版本；\(store.mediaRoutingSummary(for: .video))。视频通常为异步任务，映栈会保存任务号并持续查询。") }
        .onChange(of: store.preferredVideoModel) {
            resolution = ParameterSelectionPolicy.preserving(resolution, allowed: resolutions, fallback: "720p")
            ratio = ParameterSelectionPolicy.preserving(ratio, allowed: ratios, fallback: "16:9")
            duration = ParameterSelectionPolicy.preserving(duration, allowed: durations, fallback: 5)
        }
    }

    private func compactPicker(_ label: String, selection: Binding<String>, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) { FieldLabel(label); Picker(label, selection: selection) { ForEach(values, id: \.self) { Text($0).tag($0) } }.labelsHidden() }.frame(maxWidth: .infinity)
    }

}

private struct VideoJobRow: View {
    @EnvironmentObject private var store: AppStore
    let job: GenerationJob
    var body: some View {
        StudioCard {
            HStack(spacing: 16) {
                ZStack { VSColor.ink; Image(systemName: job.state == .succeeded ? "play.fill" : "film").font(.system(size: 20)).foregroundStyle(VSColor.orange) }
                    .frame(width: 96, height: 70).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 7) {
                    HStack { StatusPill(title: job.state.rawValue, color: statusColor); Text([job.parameters["size"], job.parameters["aspect_ratio"], job.parameters["duration_seconds"].map { "\($0)s" }].compactMap { $0 }.joined(separator: " · ")).font(.vsBody(9)).foregroundStyle(VSColor.muted) }
                    Text(job.prompt).font(.vsBody(11)).lineLimit(2)
                    Text(job.taskID.map { "任务号：\($0)" } ?? job.model).font(.vsBody(9)).foregroundStyle(VSColor.muted).lineLimit(1)
                    if let routing = store.mediaRoutingDescription(for: job) {
                        Label(routing, systemImage: "person.crop.square.filled.and.at.rectangle")
                            .font(.vsBody(9)).foregroundStyle(VSColor.moss).lineLimit(1)
                    }
                    if let error = job.errorMessage { Text(error).font(.vsBody(9)).foregroundStyle(VSColor.vermilion).lineLimit(2) }
                }
                Spacer()
                MediaResultActions(
                    job: job,
                    onRetry: { Task { await store.retryVideoJob(job, confirmBillable: true) } },
                    onCancel: { Task { await store.cancelVideoJob(job.id) } },
                    onDelete: { Task { await store.deleteVideoJob(job) } }
                )
                .frame(minWidth: 260)
            }
        }
    }
    private var statusColor: Color { switch job.state { case .succeeded: VSColor.moss; case .failed, .timedOut, .cancelled: VSColor.vermilion; default: VSColor.orange } }
}
