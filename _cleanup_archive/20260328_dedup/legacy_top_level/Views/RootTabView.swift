import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            LedgerListView()
                .tabItem {
                    Label("账本", systemImage: "list.bullet.rectangle")
                }

            CaptureView()
                .tabItem {
                    Label("录入", systemImage: "plus.circle")
                }

            StatisticsView()
                .tabItem {
                    Label("统计", systemImage: "chart.pie")
                }

            ReviewQueueView()
                .tabItem {
                    Label("待确认", systemImage: "checklist")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .task {
            try? SeedDataService.seedIfNeeded(context: modelContext)
        }
    }
}
