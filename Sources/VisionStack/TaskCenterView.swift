import SwiftUI

struct TaskCenterView: View {
    var embedded = false
    var onShowAsset: ((UUID) -> Void)? = nil
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var navigation: WorkspaceNavigation
    private var query: String { navigation.taskQuery }
    private var kind: String { navigation.taskKind }
    private var state: String { navigation.taskState }
    private var page: Int {
        get { navigation.taskPage }
        nonmutating set { navigation.taskPage = newValue }
    }

    private var jobs: [GenerationJob] {
        store.currentProjectJobs.filter { job in
            let matchesKind = kind == "全部" || (kind == "图片" && job.kind == .image) || (kind == "视频" && job.kind == .video)
            let matchesState: Bool = switch state {
            case "活动": job.state.isActivelyExecuting
            case "待处理": job.state.requiresReconciliation || job.state == .needsArchive
            case "失败": [.failed, .timedOut, .cancelled].contains(job.state)
            case "完成": job.state == .succeeded
            default: true
            }
            let haystack = [job.prompt, job.model, job.taskID ?? "", job.clientRequestID?.uuidString ?? "", job.errorMessage ?? ""].joined(separator: " ")
            return matchesKind && matchesState && (query.isEmpty || haystack.localizedCaseInsensitiveContains(query))
        }
    }
    private var costTotals: [CurrencyCostTotal] { CostPresentation.totals(store.currentProjectJobs.map(\.cost)) }
    private var unknownCostCount: Int { store.currentProjectJobs.filter { $0.cost?.actualAmount == nil && $0.cost?.estimatedAmount == nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("任务中心").font(.vsTitle(25))
                    Text("提交、供应商执行、本机归档与恢复对账").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                StatusPill(title: "\(store.currentProjectActiveGenerationCount) 个活动", color: store.currentProjectActiveGenerationCount == 0 ? VSColor.moss : VSColor.orange)
                Text("\(jobs.count) / \(store.currentProjectJobs.count)").font(.vsLabel(11)).foregroundStyle(VSColor.muted)
                if !embedded { Button("关闭") { dismiss() } }
            }.padding(22)
            Divider()
            HStack(spacing: 12) {
                TextField("搜索提示词、模型、任务号或错误", text: $navigation.taskQuery).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $navigation.taskKind) { ForEach(["全部", "图片", "视频"], id: \.self) { Text($0).tag($0) } }.frame(width: 100)
                Picker("状态", selection: $navigation.taskState) { ForEach(["全部", "活动", "待处理", "失败", "完成"], id: \.self) { Text($0).tag($0) } }.frame(width: 110)
            }.padding(16)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(costTotals) { total in
                        ledgerMetric(total.currency, "实际 \(CostPresentation.amount(total.actual))", "\(total.actualCount) 项实际 · 预计 \(CostPresentation.amount(total.estimated))（\(total.estimatedCount) 项）")
                    }
                    ledgerMetric("金额未知", "\(unknownCostCount) 项", "未知不计为零；各币种独立汇总")
                }.padding(.horizontal, 16)
            }.padding(.bottom, 12)
            if jobs.isEmpty {
                EmptyStudioState(symbol: "checkmark.circle", title: "没有符合条件的任务", detail: "任务记录与成功素材分开管理；这里保留失败、对账和诊断信息。")
            } else {
                List(WorkspacePagination.page(jobs, number: page)) { job in TaskCenterRow(job: job, onShowAsset: onShowAsset) }.scrollContentBackground(.hidden)
            }
            WorkspacePageControls(page: $navigation.taskPage, count: jobs.count)
            HStack {
                Image(systemName: "shield.checkered")
                Text("未知提交、查询中断和取消待确认不会直接计费重试；请先使用“对账”。")
                Spacer()
            }.font(.vsBody(11)).foregroundStyle(VSColor.muted).padding(14)
        }
        .frame(minWidth: embedded ? 0 : 1020, minHeight: embedded ? 0 : 700)
        .onChange(of: query) { page = 0 }
        .onChange(of: kind) { page = 0 }
        .onChange(of: state) { page = 0 }
        .onChange(of: jobs.count) { page = min(page, WorkspacePagination.lastPage(count: jobs.count)) }
        .background(PaperBackground())
    }

    private func ledgerMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.vsBody(9)).foregroundStyle(VSColor.muted)
            Text(value).font(.vsTitle(17))
            Text(detail).font(.vsBody(9)).foregroundStyle(VSColor.muted).lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(VSColor.ink.opacity(0.08)))
    }
}

private struct TaskCenterRow: View {
    @EnvironmentObject private var store: AppStore
    let job: GenerationJob
    var onShowAsset: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: job.kind == .image ? "photo" : "film").foregroundStyle(VSColor.vermilion).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.prompt).font(.vsLabel(12)).lineLimit(1)
                        StatusPill(title: job.state.rawValue, color: statusColor)
                    }
                    Text("\(job.model) · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                if job.state == .succeeded, let onShowAsset {
                    Button("查看素材") { onShowAsset(job.id) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("查看素材：\(job.prompt)")
                }
                if job.archiveState == .downloading {
                    Button("停止下载") { Task { await store.cancelArchiveJob(job.id) } }
                        .buttonStyle(.borderless)
                        .help("仅停止本机下载，保留供应商已完成结果")
                        .accessibilityLabel("停止下载：\(job.prompt)")
                }
                MediaResultActions(
                    job: job,
                    onRetry: { Task { if job.kind == .image { await store.retryImageJob(job, confirmBillable: true) } else { await store.retryVideoJob(job, confirmBillable: true) } } },
                    onCancel: job.state.isActivelyExecuting ? { Task { if job.kind == .image { await store.cancelImageJob(job.id) } else { await store.cancelVideoJob(job.id) } } } : nil,
                    onDelete: { Task { if job.kind == .image { await store.deleteImageJob(job) } else { await store.deleteVideoJob(job) } } }
                ).frame(minWidth: 300)
            }
            if job.connectionID == nil {
                HStack {
                    Menu("确认任务原厂商") {
                        ForEach(store.providerConnections) { provider in
                            Button(provider.displayName) { _ = store.bindLegacyJob(job.id, to: provider.id) }
                        }
                    }
                    Text("请按原任务来源选择；仅绑定来源，不重发或计费。").font(.vsBody(10)).foregroundStyle(VSColor.muted)
                }
            }
            HStack(spacing: 12) {
                stage("提交", job.submissionState?.displayTitle ?? "历史记录")
                stage("供应商", job.providerState?.displayTitle ?? "历史记录")
                stage("归档", job.archiveState?.displayTitle ?? "历史记录")
                if let taskID = job.taskID { Text("任务号 \(taskID)").textSelection(.enabled) }
                if let requestID = job.clientRequestID { Text("请求号 \(requestID.uuidString.prefix(8))").textSelection(.enabled) }
                Text(CostPresentation.label(job.cost))
            }.font(.vsBody(9)).foregroundStyle(VSColor.muted)
            if let error = job.errorMessage, !error.isEmpty {
                Text(error).font(.vsBody(10)).foregroundStyle(VSColor.vermilion).textSelection(.enabled)
            }
        }.padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }

    private func stage(_ title: String, _ value: String) -> some View { Text("\(title)：\(value)") }
    private var statusColor: Color {
        switch job.state {
        case .succeeded: VSColor.moss
        case .failed, .timedOut, .cancelled: VSColor.vermilion
        default: VSColor.orange
        }
    }
}
