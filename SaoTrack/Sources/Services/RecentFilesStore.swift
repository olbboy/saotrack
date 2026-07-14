import Foundation

/// Persists the "Open Recent" list as plain file paths in UserDefaults
/// (the app is not sandboxed, so paths stay readable across launches).
enum RecentFilesStore {

    private static let key = "recentFilePaths"
    static let maxCount = 8

    static func load() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func save(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }
}
