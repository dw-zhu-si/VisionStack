import SwiftUI

struct ProjectWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var renameTarget: CreativeProject?
    @State private var renameDraft = ""
    @State private var archiveTarget: CreativeProject?

    private var projectJobs: [GenerationJob] { store.allJobs.filter { $0.projectID == store.selectedProjectID } }
    private var knownCosts: [Decimal] { projectJobs.compactMap { $0.cost?.actualAmount ?? $0.cost?.estimatedAmount } }
    private var totalKnownCost: Decimal { knownCosts.reduce(Decimal.zero, +) }
    private var unknownCostCount: Int { projectJobs.filter { $0.cost?.actualAmount == nil && $0.cost?.estimatedAmount == nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("项目工作区").font(.vsTitle(25))
                    Text("对话、任务、素材、分镜和成本按项目归档").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("项目").font(.vsTitle(18)); Spacer(); Text("\(store.projects.filter { $0.archivedAt == nil }.count) 个活动").font(.vsBody(10)).foregroundStyle(VSColor.muted) }
                    List(store.projects.sorted { ($0.archivedAt == nil ? 0 : 1, $0.updatedAt) < ($1.archivedAt == nil ? 0 : 1, $1.updatedAt) }) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name).font(.vsLabel(11))
                                Text(project.archivedAt == nil ? project.summary : "已归档").font(.vsBody(9)).foregroundStyle(VSColor.muted).lineLimit(1)
                            }
                            Spacer()
                            if project.id == store.selectedProjectID { Image(systemName: "checkmark.circle.fill").foregroundStyle(VSColor.moss) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if project.archivedAt == nil { store.selectProject(project.id) } }
                        .contextMenu {
                            Button("重命名") { renameTarget = project; renameDraft = project.name }
                            if project.archivedAt == nil { Button("归档", role: .destructive) { archiveTarget = project } }
                            else { Button("恢复并切换") { store.restoreProject(project.id) } }
                        }
                    }.scrollContentBackground(.hidden)
                    StudioCard {
                        VStack(alignment: .leading, spacing: 9) {
                            FieldLabel("新项目")
                            TextField("项目名称", text: $name).textFieldStyle(.roundedBorder)
                            TextField("一句话说明（可选）", text: $summary).textFieldStyle(.roundedBorder)
                            Button("创建并切换") { store.createProject(name: name, summary: summary); name = ""; summary = "" }
                                .buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }.padding(20).frame(width: 380)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(store.selectedProject?.name ?? "未选择项目").font(.vsTitle(24))
                        HStack(spacing: 12) {
                            metric("对话", store.conversations.filter { $0.projectID == store.selectedProjectID }.count)
                            metric("任务", projectJobs.count)
                            metric("素材", store.currentProjectAssetCount)
                            metric("分镜", store.storyboardShots.filter { $0.projectID == store.selectedProjectID }.count)
                        }
                        Text("成本台账").font(.vsTitle(19))
                        StudioCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text("已知成本"); Spacer(); Text("¥\(NSDecimalNumber(decimal: totalKnownCost).stringValue)").font(.vsLabel(13)) }
                                HStack { Text("供应商返回或本地估算"); Spacer(); Text("\(knownCosts.count) 项") }
                                HStack { Text("金额未知"); Spacer(); Text("\(unknownCostCount) 项").foregroundStyle(unknownCostCount == 0 ? VSColor.moss : VSColor.orange) }
                                Text("未知金额不会按 0 元计入总额；只有供应商明确返回或用户配置估算时才汇总。")
                                    .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                            }.font(.vsBody(12))
                        }
                        Text("项目备份、恢复与健康检查").font(.vsTitle(19))
                        StudioCard {
                            VStack(alignment: .leading, spacing: 11) {
                                Text("备份与健康包会复制当前项目的对话、任务、素材、参考图、分镜、预设、版本评审和草剪，并生成 SHA-256 清单。恢复始终创建新项目，不覆盖现有项目。")
                                    .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                                HStack {
                                    Button("导出备份与健康包") {
                                        guard let project = store.selectedProject,
                                              let destination = CreativeFilePanels.chooseBackupDestination(suggestedName: project.name) else { return }
                                        Task { await store.exportCurrentProjectBackup(to: destination) }
                                    }
                                    Button("检查备份") {
                                        guard let package = CreativeFilePanels.chooseBackupPackage() else { return }
                                        Task { await store.inspectProjectBackup(at: package) }
                                    }
                                    Button("恢复为新项目") {
                                        guard let package = CreativeFilePanels.chooseBackupPackage() else { return }
                                        Task { await store.restoreProjectBackup(from: package) }
                                    }
                                }
                            }
                        }
                        Text("最近任务").font(.vsTitle(19))
                        ForEach(projectJobs.prefix(12)) { job in
                            HStack {
                                Image(systemName: job.kind == .image ? "photo" : "film").foregroundStyle(VSColor.vermilion)
                                Text(job.prompt).lineLimit(1)
                                Spacer()
                                Text(job.cost.flatMap { $0.actualAmount ?? $0.estimatedAmount }.map { "¥\(NSDecimalNumber(decimal: $0).stringValue)" } ?? "金额未知")
                                StatusPill(title: job.state.rawValue, color: job.state == .succeeded ? VSColor.moss : VSColor.orange)
                            }.font(.vsBody(11)).padding(.vertical, 5)
                        }
                    }.padding(24)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(PaperBackground())
        .alert("重命名项目", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("项目名称", text: $renameDraft)
            Button("保存") { if let id = renameTarget?.id { store.renameProject(id, name: renameDraft) }; renameTarget = nil }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("归档项目？", isPresented: Binding(get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } }), titleVisibility: .visible) {
            Button("归档项目", role: .destructive) { if let id = archiveTarget?.id { store.archiveProject(id) }; archiveTarget = nil }
            Button("取消", role: .cancel) { archiveTarget = nil }
        } message: { Text("项目内容会保留在本机，可继续审计；至少保留一个活动项目。") }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.vsBody(10)).foregroundStyle(VSColor.muted); Text("\(value)").font(.vsTitle(21)) }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
