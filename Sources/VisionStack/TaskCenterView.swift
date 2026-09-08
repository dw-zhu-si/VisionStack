import SwiftUI

struct TaskCenterView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind = "全部"
    @State private var state = "全部"

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
    private var ledger: ProjectCostSummary { store.currentProjectCostSummary }

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
                Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            HStack(spacing: 12) {
                TextField("搜索提示词、模型、任务号或错误", text: $query).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $kind) { ForEach(["全部", "图片", "视频"], id: \.self) { Text($0).tag($0) } }.frame(width: 100)
                Picker("状态", selection: $state) { ForEach(["全部", "活动", "待处理", "失败", "完成"], id: \.self) { Text($0).tag($0) } }.frame(width: 110)
            }.padding(16)
            HStack(spacing: 10) {
                ledgerMetric("费用台账", "\(ledger.currency) \(NSDecimalNumber(decimal: ledger.knownTotal).stringValue)", "已知金额")
                ledgerMetric("已知记录", "\(ledger.knownCount)", "其中 \(ledger.providerReportedCount) 项供应商回报")
                ledgerMetric("金额未知", "\(ledger.unknownCount)", "不会把未知金额记作 0")
                ledgerMetric("任务总数", "\(store.currentProjectJobs.count)", "图片与视频统一核算")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            if jobs.isEmpty {
                EmptyStudioState(symbol: "checkmark.circle", title: "没有符合条件的任务", detail: "任务记录与成功素材分开管理；这里保留失败、对账和诊断信息。")
            } else {
                List(jobs) { job in TaskCenterRow(job: job) }.scrollContentBackground(.hidden)
            }
            HStack {
                Image(systemName: "shield.checkered")
                Text("未知提交、查询中断和取消待确认不会直接计费重试；请先使用“对账”。")
                Spacer()
            }.font(.vsBody(11)).foregroundStyle(VSColor.muted).padding(14)
        }
        .frame(minWidth: 1020, minHeight: 700)
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
                MediaResultActions(
                    job: job,
                    onRetry: { Task { if job.kind == .image { await store.retryImageJob(job, confirmBillable: true) } else { await store.retryVideoJob(job, confirmBillable: true) } } },
                    onCancel: job.state.isActivelyExecuting ? { Task { if job.kind == .image { await store.cancelImageJob(job.id) } else { await store.cancelVideoJob(job.id) } } } : nil,
                    onDelete: { Task { if job.kind == .image { await store.deleteImageJob(job) } else { await store.deleteVideoJob(job) } } }
                ).frame(minWidth: 300)
            }
            HStack(spacing: 12) {
                stage("提交", job.submissionState?.rawValue ?? "legacy")
                stage("供应商", job.providerState?.rawValue ?? "legacy")
                stage("归档", job.archiveState?.rawValue ?? "legacy")
                if let taskID = job.taskID { Text("任务号 \(taskID)").textSelection(.enabled) }
                if let requestID = job.clientRequestID { Text("请求号 \(requestID.uuidString.prefix(8))").textSelection(.enabled) }
                Text(job.cost.flatMap { $0.actualAmount ?? $0.estimatedAmount }.map { "费用 ¥\(NSDecimalNumber(decimal: $0).stringValue)" } ?? "费用金额未知")
            }.font(.vsBody(9)).foregroundStyle(VSColor.muted)
            if let error = job.errorMessage, !error.isEmpty {
                Text(error).font(.vsBody(10)).foregroundStyle(VSColor.vermilion).textSelection(.enabled)
            }
        }.padding(.vertical, 7)
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
