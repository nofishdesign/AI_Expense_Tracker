import Foundation

protocol RecognitionProvider {
    func extract(from input: RecognitionInput) async throws -> ParseDraft
}

protocol CloudProvider {
    func extract(from text: String, config: CloudModelRuntimeConfig) async throws -> ParseDraft?
    func testConnection(config: CloudModelRuntimeConfig) async throws -> Int
}

protocol SyncAdapter {
    func sync() async throws
}

struct NoopSyncAdapter: SyncAdapter {
    func sync() async throws {}
}
