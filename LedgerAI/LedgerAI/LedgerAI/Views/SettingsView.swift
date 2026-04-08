import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppSettings.updatedAt, order: .reverse) private var settingsList: [AppSettings]
    @Query(sort: \CloudModelConfig.updatedAt, order: .reverse) private var cloudModels: [CloudModelConfig]

    @State private var showingCategories = false
    @State private var showingNewModel = false
    @State private var editingModel: CloudModelConfig?
    @State private var bootstrapped = false
    @State private var testingModelID: UUID?
    @State private var pendingDeleteModelID: UUID?
    @State private var showClearAllConfirm = false
    @State private var showSyncConfigSheet = false
    @State private var isClearingAllData = false
    @State private var isSyncing = false
    @State private var initErrorMessage: String = ""

    private let intakeService = LedgerIntakeService()
    private let syncService = SupabaseSyncService()

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 0) {
                    Text("设置")
                        .font(.system(size: 42, weight: .bold))
                        .padding(.top, 40)
                        .padding(.bottom, 8)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if let settings = currentSettings {
                    Section("基础设置") {
                        Toggle("显示手动输入入口", isOn: Binding(
                            get: { settings.manualEntryEnabled },
                            set: {
                                settings.manualEntryEnabled = $0
                                persistSettings(settings)
                            }
                        ))
                    }

                    Section("云端识别") {
                        Toggle("启用云端优先识别", isOn: Binding(
                            get: { settings.cloudEnabled },
                            set: {
                                settings.cloudEnabled = $0
                                persistSettings(settings)
                            }
                        ))

                        VStack(alignment: .leading, spacing: 8) {
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
                                    persistSettings(settings)
                                }
                            ), in: 0.5...0.95, step: 0.05)
                        }

                        if cloudModels.isEmpty {
                            Text("暂无云端模型，请先新增并填写 Base URL + API Key。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(cloudModels) { model in
                            VStack(alignment: .leading, spacing: 6) {
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

                                Text(speedStatusText(for: model))
                                    .font(.caption)
                                    .foregroundStyle(speedStatusColor(for: model))
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", role: .destructive) {
                                    pendingDeleteModelID = model.id
                                }

                                Button("编辑") {
                                    editingModel = model
                                }

                                Button(testingModelID == model.id ? "测速中" : "测速") {
                                    test(model: model)
                                }
                                .tint(.blue)
                                .disabled(testingModelID != nil)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if settings.selectedCloudModelID != model.id {
                                    Button("设为当前") {
                                        settings.selectedCloudModelID = model.id
                                        persistSettings(settings)
                                    }
                                    .tint(.indigo)
                                }
                            }
                        }

                        Button {
                            showingNewModel = true
                        } label: {
                            Label("新增模型", systemImage: "plus")
                        }
                    }

                    Section("设备同步") {
                        Toggle("启用跨设备同步", isOn: Binding(
                            get: { settings.syncEnabled },
                            set: {
                                settings.syncEnabled = $0
                                persistSettings(settings)
                            }
                        ))

                        Button {
                            showSyncConfigSheet = true
                        } label: {
                            HStack {
                                Text("同步配置")
                                Spacer()
                                Text(syncConfigSummary(for: settings))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(isSyncing ? "同步中..." : "立即同步") {
                            runManualSync()
                        }
                        .disabled(isSyncing)

                        HStack(alignment: .top) {
                            Text("同步状态")
                            Spacer()
                            Text(syncStatusText(for: settings))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .font(.footnote)
                        }

                        HStack {
                            Text("上次同步")
                            Spacer()
                            Text(lastSyncText(for: settings))
                                .foregroundStyle(.secondary)
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
                    Button("清除所有数据", role: .destructive) {
                        showClearAllConfirm = true
                    }
                    .disabled(isClearingAllData)
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
            .sheet(isPresented: $showSyncConfigSheet) {
                if let settings = currentSettings {
                    syncConfigSheet(settings: settings)
                } else {
                    Text("设置尚未初始化")
                        .foregroundStyle(.secondary)
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
            .toolbar(.hidden, for: .navigationBar)
#else
            .listStyle(.inset)
#endif
            .task {
                guard !bootstrapped else { return }
                bootstrapped = true
                initializeSettingsData()
            }
            .onDisappear {
                try? modelContext.save()
            }
            .alert("确认删除该模型？", isPresented: deleteModelAlertBinding) {
                Button("取消", role: .cancel) {
                    pendingDeleteModelID = nil
                }
                Button("删除", role: .destructive) {
                    guard let modelID = pendingDeleteModelID else { return }
                    deleteModel(by: modelID)
                    pendingDeleteModelID = nil
                }
            } message: {
                Text("删除后不可恢复。")
            }
            .alert("确认清除所有数据？", isPresented: $showClearAllConfirm) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    clearAllData()
                }
            } message: {
                Text("这会删除账单、分类、云端模型与设置，并重置为初始状态。")
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

    private func persistSettings(_ settings: AppSettings) {
        settings.updatedAt = .now
        try? modelContext.save()
    }

    private func syncConfigSummary(for settings: AppSettings) -> String {
        let hasURL = !settings.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = !settings.supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCode = !settings.syncOwnerCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let configuredCount = [hasURL, hasKey, hasCode].filter { $0 }.count

        switch configuredCount {
        case 3:
            return "已配置"
        case 0:
            return "未配置"
        default:
            return "部分配置"
        }
    }

    private func syncStatusText(for settings: AppSettings) -> String {
        let status = settings.lastSyncMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "未同步" : status
    }

    private func lastSyncText(for settings: AppSettings) -> String {
        guard let lastSyncAt = settings.lastSyncAt else { return "从未同步" }
        return lastSyncAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func syncConfigSheet(settings: AppSettings) -> some View {
        NavigationStack {
            Form {
                Section("Supabase 配置") {
                    TextField("Supabase URL", text: Binding(
                        get: { settings.supabaseURL },
                        set: {
                            settings.supabaseURL = $0
                            persistSettings(settings)
                        }
                    ))
                    .platformDisableAutoInputHelpers()
#if os(iOS)
                    .keyboardType(.URL)
#endif

                    SecureField("Supabase Anon Key", text: Binding(
                        get: { settings.supabaseAnonKey },
                        set: {
                            settings.supabaseAnonKey = $0
                            persistSettings(settings)
                        }
                    ))

                    TextField("同步码（两端保持一致）", text: Binding(
                        get: { settings.syncOwnerCode },
                        set: {
                            settings.syncOwnerCode = $0
                            persistSettings(settings)
                        }
                    ))
                    .platformDisableAutoInputHelpers()
                }

                Section {
                    Text("iPhone 和 Mac 使用同一个同步码即可共享账单。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("同步配置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showSyncConfigSheet = false
                    }
                }
            }
        }
    }

    private func ensureSettingsExists() throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let all = try modelContext.fetch(descriptor)
        if let primary = all.first {
            if all.count > 1 {
                for redundant in all.dropFirst() {
                    modelContext.delete(redundant)
                }
            }
            return primary
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

    private var deleteModelAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteModelID != nil },
            set: { visible in
                if !visible { pendingDeleteModelID = nil }
            }
        )
    }

    private func deleteModel(by modelID: UUID) {
        guard let settings = currentSettings else { return }
        guard let model = cloudModels.first(where: { $0.id == modelID }) else { return }

        if settings.selectedCloudModelID == model.id {
            settings.selectedCloudModelID = nil
        }
        modelContext.delete(model)

        if settings.selectedCloudModelID == nil,
           let first = cloudModels.first(where: { $0.id != modelID }) {
            settings.selectedCloudModelID = first.id
        }
        settings.updatedAt = .now
        try? modelContext.save()
    }

    private func speedStatusText(for model: CloudModelConfig) -> String {
        if testingModelID == model.id {
            return "状态：测速中..."
        }
        guard model.lastTestAt != nil else {
            return "状态：未测速"
        }
        if model.lastTestOK {
            if let latency = model.lastLatencyMs {
                return "状态：可用 · \(latency)ms"
            }
            return "状态：可用"
        }
        if let latency = model.lastLatencyMs {
            return "状态：不可用 · \(latency)ms"
        }
        return "状态：不可用"
    }

    private func speedStatusColor(for model: CloudModelConfig) -> Color {
        guard model.lastTestAt != nil else { return .secondary }
        return model.lastTestOK ? .green : .red
    }

    private func clearAllData() {
        guard !isClearingAllData else { return }
        isClearingAllData = true
        defer { isClearingAllData = false }

        do {
            try modelContext.delete(model: TransactionRecord.self)
            try modelContext.delete(model: ParseCandidate.self)
            try modelContext.delete(model: UserPreference.self)
            try modelContext.delete(model: Category.self)
            try modelContext.delete(model: CloudModelConfig.self)
            try modelContext.delete(model: AppSettings.self)
            try modelContext.save()

            try SeedDataService.seedIfNeeded(context: modelContext)
            initErrorMessage = ""
        } catch {
            initErrorMessage = "清除数据失败：\(error.localizedDescription)"
        }
        try? modelContext.save()
    }

    private func runManualSync() {
        guard !isSyncing else { return }
        isSyncing = true

        Task { @MainActor in
            defer { isSyncing = false }

            do {
                let summary = try await syncService.sync(in: modelContext, trigger: "manual")
                if let settings = currentSettings {
                    settings.lastSyncAt = .now
                    settings.lastSyncMessage = summary.message
                    settings.updatedAt = .now
                    try? modelContext.save()
                }
            } catch {
                if let settings = currentSettings {
                    settings.lastSyncAt = .now
                    settings.lastSyncMessage = "同步失败：\(error.localizedDescription)"
                    settings.updatedAt = .now
                    try? modelContext.save()
                }
            }
        }
    }
}
