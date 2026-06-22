import Foundation

struct LocalMediaStore {
    func relativePath(attachmentID: String, filename: String) -> String {
        let safeFilename = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(attachmentID)/\(safeFilename)"
    }

    func fileURL(relativePath: String) throws -> URL {
        try rootURL().appending(path: relativePath)
    }

    func fileExists(relativePath: String) -> Bool {
        guard let url = try? fileURL(relativePath: relativePath) else {
            return false
        }

        return FileManager.default.fileExists(atPath: url.path())
    }

    func save(data: Data, relativePath: String) throws {
        let url = try fileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func rootURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = baseURL.appending(path: "Media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
