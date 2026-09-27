import Foundation
import XCTest
@testable import VisionStack

final class WorkspacePresentationTests: XCTestCase {
    func testCostsRemainSeparatedByCurrencyAndActualReplacesEstimate() {
        let costs: [JobCostRecord?] = [
            JobCostRecord(currency: "USD", estimatedAmount: 9, actualAmount: 2),
            JobCostRecord(currency: "CNY", estimatedAmount: 7),
            JobCostRecord(currency: "usd", estimatedAmount: 3),
            nil, JobCostRecord(currency: "CNY")
        ]
        let totals = CostPresentation.totals(costs)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].currency, "CNY")
        XCTAssertEqual(totals[0].actualCount, 0)
        XCTAssertEqual(totals[0].estimated, 7)
        XCTAssertEqual(totals[1].currency, "USD")
        XCTAssertEqual(totals[1].actual, 2)
        XCTAssertEqual(totals[1].estimated, 3)
        XCTAssertEqual(totals[1].actualCount, 1)
        XCTAssertEqual(totals[1].estimatedCount, 1)
        XCTAssertEqual(CostPresentation.label(costs[0]), "实际 USD 2")
        XCTAssertEqual(CostPresentation.label(costs[1]), "预计 CNY 7")
        XCTAssertEqual(CostPresentation.label(nil), "费用金额未知")
    }

    func testFilteringCannotActOnHiddenSelectedAssets() {
        let shown = UUID(), hidden = UUID(), unrelated = UUID()
        let selection = AssetSelectionPolicy.visibleSelection([shown, hidden], visibleIDs: [shown, unrelated])
        XCTAssertEqual(selection, [shown])
        XCTAssertTrue(AssetSelectionPolicy.visibleSelection(selection, visibleIDs: []).isEmpty)
    }

    @MainActor
    func testTaskToAssetNavigationCarriesExactIdentity() {
        let navigation = WorkspaceNavigation()
        let id = UUID()
        navigation.showAsset(id)
        XCTAssertEqual(navigation.focusedAssetID, id)
        if case .assets = navigation.destination {} else { XCTFail("应定位素材主区") }
    }
    func testPagingTenThousandItemsHasNoDuplicatesOrOmissions() {
        let items = Array(0..<10_000)
        let pages = (0...WorkspacePagination.lastPage(count: items.count)).flatMap {
            WorkspacePagination.page(items, number: $0)
        }
        XCTAssertEqual(pages, items)
        XCTAssertEqual(WorkspacePagination.page(items, number: 199).count, 50)
        XCTAssertTrue(WorkspacePagination.page(items, number: 200).isEmpty)
        XCTAssertTrue(WorkspacePagination.page(items, number: -1).isEmpty)
        XCTAssertTrue(WorkspacePagination.page(items, number: Int.max).isEmpty)
    }

    func testTenThousandItemPresentationBenchmark() {
        let costs = (0..<10_000).map { index -> JobCostRecord? in
            JobCostRecord(currency: index.isMultiple(of: 2) ? "CNY" : "USD", estimatedAmount: Decimal(index % 10))
        }
        let ids = (0..<10_000).map { _ in UUID() }
        let selected = Set(ids)
        measure {
            let totals = CostPresentation.totals(costs)
            let page = WorkspacePagination.page(ids, number: 100)
            let filtered = AssetSelectionPolicy.visibleSelection(selected, visibleIDs: page)
            XCTAssertEqual(totals.count, 2)
            XCTAssertEqual(filtered.count, 50)
        }
    }

    func testLegacyLedgerNeverCombinesDifferentCurrencies() {
        let jobs = ["CNY", "USD"].map { code in
            GenerationJob(kind: .image, prompt: "fixture", model: "fixture", parameters: [:], state: .succeeded, cost: JobCostRecord(currency: code, actualAmount: 2))
        }
        let summary = ProjectCostLedger.summary(for: jobs)
        XCTAssertEqual(summary.currency, "多币种")
        XCTAssertNil(summary.knownTotal)
        XCTAssertEqual(summary.totalsByCurrency.count, 2)
        XCTAssertEqual(summary.knownCount, 2)
        XCTAssertNil(ProjectCostLedger.summary(for: []).knownTotal)
    }

}
