import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [AppSettings]
    @State private var showingCategories = false

    var body: some View {
        NavigationStack {
            List {
                if let settings = settingsList.first {
                    Section("识别策略") {
                        Toggle("启用云端兜底", isOn: Binding(
                            get: { settings.cloudEnabled },
                            set: {
                                settings.cloudEnabled = $0
                                settings.updatedAt = .now
                                try? modelContext.save()
                            }
                        ))
                        HStack {
                            Text("自动入账阈值")
                            Spacer()
                            Text("\(settings.autoConfirmThreshold, specifier: "%.2f")")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.autoConfirmThreshold },
                            set: {
                                settings.autoConfirmThreshold = $0
                                settings.updatedAt = .now
                                try? modelContext.save()
                            }
                        ), in: 0.5...0.95, step: 0.05)
                    }

                    Section("云端 Provider") {
                        TextField("Provider 名称", text: Binding(
                            get: { settings.cloudProviderName },
                            set: {
                                settings.cloudProviderName = $0
                                settings.updatedAt = .now
                            }
                        ))
                        TextField("模型", text: Binding(
                            get: { settings.cloudModelName },
                            set: {
                                settings.cloudModelName = $0
                                settings.updatedAt = .now
                            }
                        ))
                        TextField("Endpoint", text: Binding(
                            get: { settings.cloudEndpoint },
                            set: {
                                settings.cloudEndpoint = $0
                                settings.updatedAt = .now
                            }
                        ))
                    }
                }

                Section("数据") {
                    Button("分类管理") { showingCategories = true }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingCategories) {
                CategoryManagementView()
            }
            .task {
                if settingsList.isEmpty {
                    modelContext.insert(AppSettings())
                    try? modelContext.save()
                }
            }
            .onDisappear {
                try? modelContext.save()
            }
        }
    }
}
