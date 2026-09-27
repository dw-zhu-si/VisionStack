import SwiftUI

struct ProjectHomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var navigation: WorkspaceNavigation
    private var assets: [GenerationJob] { store.assetJobs.filter { $0.projectID == store.selectedProjectID } }
    private var tasks: [GenerationJob] { store.currentProjectJobs.filter { $0.state != .succeeded } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.selectedProject?.name ?? "项目首页").font(.vsTitle(30))
                        Text("从想法到交付，继续当前项目的创作。").foregroundStyle(VSColor.muted)
                    }
                    Spacer()
                    Button("管理项目") { store.showingProjects = true }
                }
                Text("继续创作").font(.vsTitle(20))
                ForEach(StudioMode.allCases) { mode in
                    Button {
                        store.mode = mode; navigation.destination = .studio
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbol).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title).font(.vsLabel(14))
                                Text(draft(for: mode).isEmpty ? mode.subtitle : draft(for: mode)).font(.vsBody(12)).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                        }.padding(16).background(Color.white.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
                HStack {
                    Text("待处理任务 · \(tasks.count)").font(.vsTitle(20))
                    Spacer(); Button("全部任务") { navigation.destination = .tasks }
                }
                if tasks.isEmpty { Text("没有待处理任务。新生成的进度和需要恢复的任务会显示在这里。").foregroundStyle(VSColor.muted) }
                ForEach(Array(tasks.prefix(5))) { job in
                    Button { navigation.destination = .tasks } label: {
                        HStack { Text(job.prompt).lineLimit(1); Spacer(); Text(job.state.rawValue).foregroundStyle(VSColor.muted) }
                    }.buttonStyle(.plain)
                }
                HStack {
                    Text("已归档素材 · \(assets.count)").font(.vsTitle(20))
                    Spacer(); Button("全部素材") { navigation.focusedAssetID = nil; navigation.destination = .assets }
                }
                if assets.isEmpty { Text("生成结果完成本机归档后，可以在这里查看并交付。").foregroundStyle(VSColor.muted) }
                ForEach(Array(assets.prefix(6))) { job in
                    Button { navigation.showAsset(job.id) } label: {
                        HStack { Image(systemName: job.kind == .image ? "photo" : "film"); Text(job.prompt).lineLimit(1); Spacer(); Text("查看素材") }
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button("视频草剪台") { store.showingRoughCut = true }
                    Button("备份与恢复") { store.showingProjects = true }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading)
        }
    }
    private func draft(for mode: StudioMode) -> String {
        switch mode { case .chat: store.chatDraft; case .image: store.imagePromptDraft; case .video: store.videoPromptDraft }
    }
}
