import Foundation

actor LocalPersistence {
    static let shared = LocalPersistence()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let stateURL: URL

    init(fileManager: FileManager = .default) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        stateURL = baseURL
            .appendingPathComponent("MailBriefDesktop", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func load() throws -> PersistedSnapshot? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let data = try Data(contentsOf: stateURL)
        return try decoder.decode(PersistedSnapshot.self, from: data)
    }

    func save(_ snapshot: PersistedSnapshot) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtection])
    }
}
