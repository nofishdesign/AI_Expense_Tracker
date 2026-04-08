import SwiftData
import SwiftUI

struct CategoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.order) private var categories: [Category]

    @State private var newCategoryName = ""
    @State private var newCategoryKeywords = ""

    var body: some View {
        NavigationStack {
            List {
                Section("已有分类") {
                    ForEach(categories) { category in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(category.name, systemImage: category.symbol)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { category.isEnabled },
                                    set: {
                                        category.isEnabled = $0
                                        try? modelContext.save()
                                    }
                                ))
                                .labelsHidden()
                            }
                            Text("关键词：\(category.keywordsCSV)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("新增分类") {
                    TextField("分类名", text: $newCategoryName)
                    TextField("关键词（逗号分隔）", text: $newCategoryKeywords)
                    Button("添加") {
                        addCategory()
                    }
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("分类管理")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func addCategory() {
        let keywords = newCategoryKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let category = Category(
            name: newCategoryName,
            symbol: "tag",
            isSystem: false,
            isEnabled: true,
            order: categories.count + 1,
            keywords: keywords
        )
        modelContext.insert(category)
        try? modelContext.save()
        newCategoryName = ""
        newCategoryKeywords = ""
    }
}
