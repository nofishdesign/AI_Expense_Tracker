import SwiftData
import SwiftUI

struct TransactionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.order) private var categories: [Category]

    let record: TransactionRecord

    @State private var amount: Double = 0
    @State private var merchant: String = ""
    @State private var occurredAt: Date = .now
    @State private var selectedCategoryID: UUID?
    @State private var selectedChannel: PaymentChannel = .unknown

    private let intakeService = LedgerIntakeService()

    var body: some View {
        NavigationStack {
            Form {
                Section("消费信息") {
                    TextField("商户", text: $merchant)
                    TextField("金额", value: $amount, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                    DatePicker("时间", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
                }

                Section("分类与渠道") {
                    Picker("分类", selection: $selectedCategoryID) {
                        Text("未分类").tag(Optional<UUID>.none)
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }

                    Picker("支付方式", selection: $selectedChannel) {
                        ForEach(PaymentChannel.allCases, id: \.self) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                }
            }
            .navigationTitle("确认记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                amount = record.amountCNY
                merchant = record.merchant
                occurredAt = record.occurredAt
                selectedCategoryID = record.categoryID
                selectedChannel = record.channel
            }
        }
    }

    private func save() {
        record.amountCNY = amount
        record.merchant = merchant
        record.occurredAt = occurredAt
        record.categoryID = selectedCategoryID
        record.channel = selectedChannel
        record.updatedAt = .now
        try? intakeService.markConfirmedAndLearn(transaction: record, in: modelContext)
    }
}
