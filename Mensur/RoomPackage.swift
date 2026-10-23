import Foundation
import UniformTypeIdentifiers

// A room as one .mensur file, for AirDrop, Messages or Files: the project, its native scans, LiDAR
// measurements and photos. The format is a header line, a JSON list of files and their sizes, then the
// files' bytes in that order. Only the file names a room folder normally holds are written or accepted.
extension UTType {
    static let mensurRoom = UTType(exportedAs: "com.matthewsinitiere.mensur.room", conformingTo: .data)
}

enum RoomPackage {
    static let magic = Data("MENSUR-ROOM 1\n".utf8)
    struct Entry: Codable { var path: String; var size: Int }

    // Which relative paths travel in a package.
    static func allowed(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        if parts.count == 1 { return parts[0] == "Project.json" || SyncPlan.isSyncedFile(parts[0]) }
        guard parts.count == 2 else { return false }
        if parts[0] == "Photos" { return SyncPlan.isSyncedFile(path) }
        let measurementFolder = parts[0] == "Measurements" || (parts[0].hasPrefix("Measurements-") && Int(parts[0].dropFirst(13)) != nil)
        let name = parts[1]
        return measurementFolder && (name.hasSuffix(".json") || name.hasSuffix(".bin") || name == "WorldMap.arworldmap")
            && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    static func write(folder: URL, to file: URL) throws {
        var entries: [Entry] = [], urls: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let root = folder.resolvingSymlinksInPath().path, full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(root + "/") else { continue }
            let path = String(full.dropFirst(root.count + 1))
            guard allowed(path) else { continue }
            entries.append(.init(path: path, size: values.fileSize ?? 0)); urls.append(url)
        }
        guard entries.contains(where: { $0.path == "Project.json" }) else { throw ProjectError.invalid("This room has no saved project to send.") }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        let list = try JSONEncoder().encode(entries)
        out.write(magic); out.write(Data("\(list.count)\n".utf8)); out.write(list)
        for (entry, url) in zip(entries, urls) {
            let data = try Data(contentsOf: url)
            guard data.count == entry.size else { throw ProjectError.invalid("\(entry.path) changed while packaging.") }
            out.write(data)
        }
    }

    // The package's files, checked against the allowed names and size limits.
    static func read(_ file: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count < 500_000_000, data.starts(with: magic) else { throw ProjectError.invalid("This isn’t a Mensur room file.") }
        var cursor = magic.count
        guard let newline = data[cursor...].firstIndex(of: 10), let length = Int(String(decoding: data[cursor..<newline], as: UTF8.self)),
              length > 0, length < 1_000_000, newline + 1 + length <= data.count else { throw ProjectError.invalid("This Mensur room file is damaged.") }
        cursor = newline + 1
        let entries = try JSONDecoder().decode([Entry].self, from: data[cursor..<(cursor + length)])
        cursor += length
        var files: [String: Data] = [:]
        for e in entries {
            guard allowed(e.path), e.size >= 0, e.size < 200_000_000, cursor + e.size <= data.count, files[e.path] == nil else {
                throw ProjectError.invalid("This Mensur room file has an unexpected file (\(e.path.prefix(60))).")
            }
            files[e.path] = Data(data[cursor..<(cursor + e.size)]); cursor += e.size
        }
        guard cursor == data.count, files["Project.json"] != nil else { throw ProjectError.invalid("This Mensur room file is damaged.") }
        return files
    }
}

extension ProjectStore {
    // The room's folder as a .mensur file in a temporary folder, named after the room.
    func package(_ room: RoomProject) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mensur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = room.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let file = dir.appendingPathComponent("\(safe.isEmpty ? "Room" : String(safe.prefix(60))).mensur")
        try RoomPackage.write(folder: directory(room.id), to: file)
        return file
    }

    // Adds a received room as a new room (its own identifier, so it never collides with the sender's copy).
    @discardableResult func importPackage(_ url: URL) throws -> RoomProject {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let files = try RoomPackage.read(url)
        var room = try Self.decoder().decode(RoomProject.self, from: files["Project.json"]!).validated()
        room.id = UUID()
        room.captureWarnings.append("Received from another device on \(Date().formatted(date: .abbreviated, time: .shortened)).")
        let folder = directory(room.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, data) in files where path != "Project.json" {
            let target = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        try save(room)
        return room
    }
}
