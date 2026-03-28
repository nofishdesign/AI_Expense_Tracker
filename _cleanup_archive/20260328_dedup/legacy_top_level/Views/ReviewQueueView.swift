import SwiftData
import SwiftUI

struct ReviewQueueView: View {
    @Query(sort: \TransactionRecord.createdAt, order: .reverse) private var allRecords: [TransactionRecord]
    @State private var selectedRecord: TransactionRecord?

    private var drafts: [TransactionRecord] {
        allRecords.filter { $0.status == .draft }
    }

    var body: some View {
        NavigationStack {
            List(drafts) { record in
                Button {
                    selectedRecord = record
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.merchant)
                            .font(.headline)
                        Text("¥\(record.amountCNY, specifier: "%.2f") · 置信度 \(Int(record.confidence * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("待确认")
            .sheet(isPresented: Binding(
                get: { selectedRecord != nil },
                set: { show in
                    if !show { selectedRecord = nil }
                }
            )) {
                if let record = selectedRecord {
                    TransactionEditorView(record: record)
                }
            }
        }
    }
}
