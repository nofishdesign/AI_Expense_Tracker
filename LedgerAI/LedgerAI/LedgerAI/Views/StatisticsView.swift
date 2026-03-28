import SwiftData
import SwiftUI

struct StatisticsView: View {
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse) private var allRecords: [TransactionRecord]
    @Query(sort: \Category.order) private var categories: [Category]

    private var confirmed: [TransactionRecord] {
        allRecords.filter { $0.status == .confirmed }
    }

    private var monthlyTotal: Double {
        let now = Date()
        return confirmed
            .filter { Calendar.current.isDate($0.occurredAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amountCNY }
    }

    private var categoryTotals: [(Category, Double)] {
        let grouped = Dictionary(grouping: confirmed, by: \.categoryID)
        let mapped = categories.compactMap { category -> (Category, Double)? in
            let total = grouped[category.id]?.reduce(0) { $0 + $1.amountCNY } ?? 0
            return total > 0 ? (category, total) : nil
        }
        return mapped.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("本月支出") {
                    Text("¥\(monthlyTotal, specifier: "%.2f")")
                        .font(.largeTitle.weight(.bold))
                }

                Section("分类占比") {
                    ForEach(categoryTotals, id: \.0.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(item.0.name, systemImage: item.0.symbol)
                                Spacer()
                                Text("¥\(item.1, specifier: "%.2f")")
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: item.1, total: max(monthlyTotal, 0.01))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("近 30 天消费笔数") {
                    let count = confirmed.filter {
                        $0.occurredAt >= Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
                    }.count
                    Text("\(count) 笔")
                }
            }
            .navigationTitle("统计")
        }
    }
}
