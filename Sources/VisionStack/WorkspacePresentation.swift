import Foundation
import SwiftUI

@MainActor
final class WorkspaceNavigation: ObservableObject {
    enum Destination { case home, studio, tasks, assets }
    @Published var destination: Destination = .home
    @Published var focusedAssetID: UUID?
    @Published var taskQuery = ""
    @Published var taskKind = "全部"
    @Published var taskState = "全部"
    @Published var taskPage = 0
    private(set) var assetOrigin: Destination = .home
    func showAsset(_ id: UUID) { assetOrigin = destination; focusedAssetID = id; destination = .assets }
    func returnFromAsset() { focusedAssetID = nil; destination = assetOrigin }
}

struct CurrencyCostTotal: Equatable, Identifiable, Sendable {
    var id: String { currency }
    let currency: String
    var actual: Decimal = 0
    var estimated: Decimal = 0
    var actualCount = 0
    var estimatedCount = 0
}

enum CostPresentation {
    static func totals(_ costs: [JobCostRecord?]) -> [CurrencyCostTotal] {
        var values: [String: CurrencyCostTotal] = [:]
        for case let cost? in costs {
            let code = currency(cost)
            if let amount = cost.actualAmount {
                var value = values[code] ?? CurrencyCostTotal(currency: code)
                value.actual += amount; value.actualCount += 1; values[code] = value
            } else if let amount = cost.estimatedAmount {
                var value = values[code] ?? CurrencyCostTotal(currency: code)
                value.estimated += amount; value.estimatedCount += 1; values[code] = value
            }
        }
        return values.values.sorted { $0.currency < $1.currency }
    }
    static func currency(_ cost: JobCostRecord) -> String {
        let code = cost.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.isEmpty ? "币种未提供" : code
    }
    static func amount(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func label(_ cost: JobCostRecord?) -> String {
        guard let cost else { return "费用金额未知" }
        if let value = cost.actualAmount { return "实际 \(currency(cost)) \(amount(value))" }
        if let value = cost.estimatedAmount { return "预计 \(currency(cost)) \(amount(value))" }
        return "费用金额未知"
    }
}

enum AssetSelectionPolicy {
    static func visibleSelection(_ selected: Set<UUID>, visibleIDs: [UUID]) -> Set<UUID> {
        selected.intersection(Set(visibleIDs))
    }
}

extension SubmissionState {
    var displayTitle: String { switch self {
    case .notSubmitted: "未提交"; case .submitting: "提交中"; case .submitted: "已提交"
    case .unknown: "待确认"; case .rejected: "已拒绝"
    } }
}
extension ProviderState {
    var displayTitle: String { switch self {
    case .notStarted: "未开始"; case .queued: "排队中"; case .running: "执行中"
    case .succeeded: "已完成"; case .failed: "失败"; case .cancelPending: "取消待确认"
    case .cancelled: "已取消"; case .unknown: "待确认"
    } }
}
extension ArchiveState {
    var displayTitle: String { switch self {
    case .notRequired: "无需归档"; case .pending: "待归档"; case .downloading: "下载中"
    case .succeeded: "已归档"; case .failed: "归档失败"; case .missing: "文件缺失"
    } }
}

/// Bounds view construction while filtering still considers the full project.
enum WorkspacePagination {
    static let pageSize = 50
    static func page<T>(_ items: [T], number: Int, size: Int = pageSize) -> [T] {
        guard size > 0, number >= 0, number <= Int.max / size else { return [] }
        let start = number * size
        guard start < items.count else { return [] }
        return Array(items[start..<min(items.count, start + min(size, items.count - start))])
    }
    static func lastPage(count: Int, size: Int = pageSize) -> Int {
        guard count > 0, size > 0 else { return 0 }
        return (count - 1) / size
    }
}

struct WorkspacePageControls: View {
    @Binding var page: Int
    let count: Int
    var body: some View {
        HStack {
            Button("上一页") { page -= 1 }.disabled(page == 0)
            Text("第 \(page + 1) / \(WorkspacePagination.lastPage(count: count) + 1) 页 · 共 \(count) 项")
                .font(.vsBody(11)).foregroundStyle(VSColor.muted)
            Button("下一页") { page += 1 }.disabled(page >= WorkspacePagination.lastPage(count: count))
        }.padding(10)
    }
}
