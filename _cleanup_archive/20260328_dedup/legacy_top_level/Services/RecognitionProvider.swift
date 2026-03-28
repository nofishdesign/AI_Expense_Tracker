import Foundation

protocol RecognitionProvider {
    func extract(from input: RecognitionInput) async throws -> ParseDraft
}

protocol CloudProvider {
    func extract(from text: String) async throws -> ParseDraft?
}

protocol SyncAdapter {
    func sync() async throws
}

struct NoopSyncAdapter: SyncAdapter {
    func sync() async throws {}
}
