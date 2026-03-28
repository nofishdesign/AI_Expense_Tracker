import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [AppSettings]
    @Query(sort: \CloudModelConfig.updatedAt, order: .reverse) private var cloudModels: [CloudModelConfig]

    @State private var showingCategories = false
    @State private var showingNewModel = false
    @State private var editingModel: CloudModelConfig?
    @State private var bootstrapped = false
    @State private var testingModelID: UUID?
    @State private var initErrorMessage: String = ""

    private let intakeService = LedgerIntakeService()

    var body: some View {
        NavigationStack {
            List {
                if let settings = currentSettings {
                    Section("识别策略") {
                        Toggle("启用云端优先识别", isOn: Binding(
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

                    Section("云端模型") {
                        if cloudModels.isEmpty {
                            Text("暂无云端模型，请先新增并填写 Base URL + API Key。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(cloudModels) { model in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(model.displayName)
                                        .font(.headline)
                                    Spacer()
                                    if settings.selectedCloudModelID == model.id {
                                        Text("当前")
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(.blue.opacity(0.15), in: Capsule())
                                    }
                                }

                                Text("\(model.vendor.title) · \(model.modelName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                let requestURL = model.runtime.endpoint
                                Text("请求地址：\(requestURL)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 12) {
                                    Button("设为当前") {
                                        settings.selectedCloudModelID = model.id
                                        settings.updatedAt = .now
                                        try? modelContext.save()
                                    }
                                    .buttonStyle(.bordered)

                                    Button(testingModelID == model.id ? "测速中..." : "测速") {
                                        test(model: model)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(testingModelID != nil)

                                    Button("编辑") {
                                        editingModel = model
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Text("测速结果：\(model.lastTestMessage)\(model.lastLatencyMs != nil ? " · \(model.lastLatencyMs!)ms" : "")")
                                    .font(.caption)
                                    .foregroundStyle(model.lastTestOK ? .green : .secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: deleteModels)

                        Button {
                            showingNewModel = true
                        } label: {
                            Label("新增模型", systemImage: "plus")
                        }
                    }
                } else {
                    Section("云端模型") {
                        Text("云端设置尚未初始化。")
                            .foregroundStyle(.secondary)
                        Button("立即修复") {
                            initializeSettingsData()
                        }
                    }
                }

                Section("数据") {
                    Button("分类管理") { showingCategories = true }
                }

                if !initErrorMessage.isEmpty {
                    Section("诊断") {
                        Text(initErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingCategories) {
                CategoryManagementView()
            }
            .sheet(isPresented: $showingNewModel) {
                CloudModelEditorSheet(config: nil)
            }
            .sheet(item: $editingModel) { model in
                CloudModelEditorSheet(config: model)
            }
            .task {
                guard !bootstrapped else { return }
                bootstrapped = true
                initializeSettingsData()
            }
            .onDisappear {
                try? modelContext.save()
            }
        }
    }

    private var currentSettings: AppSettings? {
        settingsList.first
    }

    private func initializeSettingsData() {
        do {
            try SeedDataService.seedIfNeeded(context: modelContext)

            let settings = try ensureSettingsExists()
            let models = try modelContext.fetch(FetchDescriptor<CloudModelConfig>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))

            if settings.selectedCloudModelID == nil, let first = models.first {
                settings.selectedCloudModelID = first.id
                settings.updatedAt = .now
            }
            try modelContext.save()
            initErrorMessage = ""
        } catch {
            initErrorMessage = "初始化失败：\(error.localizedDescription)"
        }
    }

    private func ensureSettingsExists() throws -> AppSettings {
        if let existing = try modelContext.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let settings = AppSettings()
        modelContext.insert(settings)
        return settings
    }

    private func test(model: CloudModelConfig) {
        testingModelID = model.id
        Task {
            let result = await intakeService.speedTest(config: model)
            model.lastTestAt = .now
            model.lastLatencyMs = result.latencyMs
            model.lastTestOK = result.ok
            model.lastTestMessage = result.message
            model.updatedAt = .now
            try? modelContext.save()
            testingModelID = nil
        }
    }

    private func deleteModels(offsets: IndexSet) {
        guard let settings = currentSettings else { return }
        for index in offsets {
            let model = cloudModels[index]
            if settings.selectedCloudModelID == model.id {
                settings.selectedCloudModelID = nil
            }
            modelContext.delete(model)
        }
        if settings.selectedCloudModelID == nil,
           let first = cloudModels.enumerated().first(where: { !offsets.contains($0.offset) })?.element {
            settings.selectedCloudModelID = first.id
        }
        try? modelContext.save()
    }
}
