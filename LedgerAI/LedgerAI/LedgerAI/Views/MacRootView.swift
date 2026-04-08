import SwiftUI

struct MacRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    enum SidebarItem: String, CaseIterable, Identifiable {
        case ledger = "账单"
        case stats = "统计"
        case settings = "设置"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .ledger: return "list.bullet.rectangle"
            case .stats: return "chart.bar.doc.horizontal"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var selection: SidebarItem? = .ledger
    @State private var autoSyncTask: Task<Void, Never>?
    @State private var isBackgroundSyncRunning = false

    private let syncService = SupabaseSyncService()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("LedgerAI")
        } detail: {
            switch selection ?? .ledger {
            case .ledger:
                LedgerListView()
            case .stats:
                StatisticsView()
            case .settings:
                SettingsView()
            }
        }
        .task {
            triggerBackgroundSync("launch-mac")
            if scenePhase == .active {
                startAutoSyncTicker()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                triggerBackgroundSync("foreground-mac")
                startAutoSyncTicker()
            default:
                stopAutoSyncTicker()
            }
        }
        .onDisappear {
            stopAutoSyncTicker()
        }
    }

    private func triggerBackgroundSync(_ trigger: String) {
        Task { @MainActor in
            guard !isBackgroundSyncRunning else { return }
            isBackgroundSyncRunning = true
            defer { isBackgroundSyncRunning = false }
            do {
                _ = try await syncService.sync(in: modelContext, trigger: trigger)
            } catch SupabaseSyncError.syncDisabled {
                // Sync optional.
            } catch SupabaseSyncError.missingCredentials {
                // Credentials not ready.
            } catch {
                // Keep UI stable. Manual sync in Settings shows explicit errors.
            }
        }
    }

    private func startAutoSyncTicker() {
        guard autoSyncTask == nil else { return }
        autoSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    triggerBackgroundSync("auto-mac")
                }
            }
        }
    }

    private func stopAutoSyncTicker() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }
}
