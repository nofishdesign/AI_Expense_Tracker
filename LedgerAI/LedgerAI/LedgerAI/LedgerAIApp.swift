import SwiftUI
import SwiftData

@main
struct LedgerAIApp: App {
    var body: some Scene {
        WindowGroup {
#if os(macOS)
            MacRootView()
#else
            RootTabView()
#endif
        }
        .modelContainer(for: [
            TransactionRecord.self,
            Category.self,
            ParseCandidate.self,
            UserPreference.self,
            AppSettings.self,
            CloudModelConfig.self
        ])
    }
}
