import Foundation
import Darwin

enum TranscriptHistory {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var createdAt = Date()
        var rawText: String
        var text: String
        var speechModel: String?
        var formattingModel: String?
        var duration: Double?
        var formattingStatus: String?
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Blah/history.jsonl")
    private static let limit = 2_000

    static func load() throws -> [Entry] {
        try prepare()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 10, omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            guard !line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { return nil }
            do { return try decoder.decode(Entry.self, from: Data(line)) }
            catch { throw AppFailure("History line \(index + 1) is invalid. Fix that line in history.jsonl; the file has not been changed.") }
        }
    }

    static func append(_ entry: Entry) throws {
        // Read the current file, never a cached list that could restore deleted entries.
        let entries = try load()
        if entries.count >= limit {
            try replace(with: Array(entries.suffix(limit - 1)) + [entry])
        } else {
            let file = try openFile(at: url, flags: O_RDWR | O_APPEND)
            defer { try? file.close() }
            let size = try file.seekToEnd()
            var data = Data()
            if size > 0 {
                try file.seek(toOffset: size - 1)
                if try file.read(upToCount: 1)?.first != 10 { data.append(10) }
            }
            data.append(try encode(entry))
            try file.write(contentsOf: data)
            try file.synchronize()
        }
    }

    static func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !manager.fileExists(atPath: url.path) else { return }
        let legacy = url.deletingLastPathComponent().appendingPathComponent("Transcripts.txt")
        if manager.fileExists(atPath: legacy.path) {
            try migrate(legacy)
        } else {
            try openFile(at: url, flags: O_WRONLY | O_CREAT | O_EXCL).close()
        }
    }

    private static func encode(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(10)
        return data
    }

    private static func replace(with entries: [Entry]) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try openFile(at: temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { try? file.close() }
        for entry in entries { try file.write(contentsOf: encode(entry)) }
        try file.synchronize()
        // The complete replacement is owner-only and committed in one rename.
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func openFile(at path: URL, flags: Int32) throws -> FileHandle {
        let descriptor = path.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, flags | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func migrate(_ legacy: URL) throws {
        let contents = try String(contentsOf: legacy, encoding: .utf8)
        let header = try NSRegularExpression(pattern: "(?m)^--- (.+) ---$")
        let matches = header.matches(in: contents, range: NSRange(contents.startIndex..., in: contents))
        var entries: [Entry] = []
        for (index, match) in matches.enumerated() {
            guard let timestampRange = Range(match.range(at: 1), in: contents) else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (contents as NSString).length
            let text = (contents as NSString).substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let date = try Date.FormatStyle(date: .abbreviated, time: .standard).parseStrategy
                .parse(String(contents[timestampRange]))
            if !text.isEmpty { entries.append(Entry(createdAt: date, rawText: text, text: text)) }
        }
        guard !entries.isEmpty || contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure("Could not import Transcripts.txt. The original file has not been changed.")
        }
        try replace(with: Array(entries.suffix(limit)))
        // Move the old log out of the import path so deleting JSONL cannot restore it.
        let backup = legacy.deletingPathExtension().appendingPathExtension("\(UUID()).txt.backup")
        try FileManager.default.moveItem(at: legacy, to: backup)
    }
}
