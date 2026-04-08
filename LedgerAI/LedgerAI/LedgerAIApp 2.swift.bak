import SwiftUI
import SwiftData

@main
struct LedgerAIApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [
            TransactionRecord.self,
            Category.self,
            ParseCandidate.self,
            UserPreference.self,
            AppSettings.self
        ])
    }
}
