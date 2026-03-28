import SwiftData
import SwiftUI

struct LedgerListView: View {
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse) private var records: [TransactionRecord]
    @Query(sort: \Category.order) private var categories: [Category]

    var body: some View {
        NavigationStack {
            List(records) { record in
                HStack(spacing: 12) {
                    Image(systemName: icon(for: record))
                        .foregroundStyle(.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.merchant)
                            .font(.headline)
                        Text(record.occurredAt, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("¥\(record.amountCNY, specifier: "%.2f")")
                            .font(.headline)
                        Text(record.status.title)
                            .font(.caption)
                            .foregroundStyle(record.status == .confirmed ? .green : .orange)
                    }
                }
            }
            .navigationTitle("账本")
        }
    }

    private func icon(for record: TransactionRecord) -> String {
        guard let categoryID = record.categoryID,
              let category = categories.first(where: { $0.id == categoryID }) else {
            return "questionmark.circle"
        }
        return category.symbol
    }
}
