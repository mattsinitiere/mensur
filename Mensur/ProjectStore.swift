import Foundation
import Combine
import CryptoKit
import RoomPlan
import simd

enum AppPaths {
    // Mac Catalyst runs unsandboxed, where Documents is the user's own folder, so the Mac app keeps its
    // files in Documents/Mensur. On iPhone and iPad Documents is the app's own (Files → Mensur).
    #if DEBUG
    // Developer aid: MENSUR_TEST_DATA=/some/folder keeps every file (rooms, sync state, pairing) there,
    // so end-to-end tests never touch a real library, Keychain or preferences.
    static var testRoot: URL? { ProcessInfo.processInfo.environment["MENSUR_TEST_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    #else
    static let testRoot: URL? = nil
    #endif
    static var documents: URL {
        if let test = testRoot { return test.appendingPathComponent("Documents", isDirectory: true) }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
        return base.appendingPathComponent("Mensur", isDirectory: true)
        #else
        return base
        #endif
    }
    // Sync bookkeeping that users don't need to see.
    static var support: URL {
        if let test = testRoot { return test.appendingPathComponent("Support", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mensur", isDirectory: true)
    }
}

// One room on the wire: its project and any native RoomPlan files the receiver lacks.
struct RoomTransfer: Codable {
    var id: UUID
    var project: Data?
    var originals: [String: Data] = [:]
}

@MainActor final class ProjectStore: ObservableObject {
    @Published var projects: [RoomProject] = []
    @Published var errorMessage: String?
    @Published var busy = false
    @Published private(set) var localRevision = 0          // bumps on every local change, which triggers a sync
    let received = PassthroughSubject<UUID, Never>()        // rooms replaced by a synced version
    private(set) var tombstones: [UUID: Date] = [:]         // local deletions, so synced copies don't return
    let root: URL
    private var tombstoneFile: URL { AppPaths.support.appendingPathComponent("deletions.json") }
    init() {
        root = AppPaths.documents.appendingPathComponent("Rooms", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try reload() }
        catch { errorMessage = error.localizedDescription }
        if let data = try? Data(contentsOf: tombstoneFile), let saved = try? Self.decoder().decode([UUID: Date].self, from: data) {
            tombstones = saved.filter { $0.value > Date().addingTimeInterval(-180 * 86_400) }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MENSUR_TEST_ADD_SAMPLE"] != nil { addDemo() }
        // Exercises the Mac's save-to-Downloads path (redirected into the test folder).
        if AppPaths.testRoot != nil, ProcessInfo.processInfo.environment["MENSUR_TEST_EXPORT"] != nil, let room = projects.first {
            for _ in 0..<2 { _ = try? ExportService.saveToDownloads([try! ExportService.sheet(room, portrait: false)], folderName: room.name) }
            _ = try? ExportService.saveToDownloads(try! ExportService.export(room, originals: directory(room.id)), folderName: room.name)
        }
        #endif
        #if DEBUG
        // Developer aid for reviewing sheet layouts in the Simulator: launch with
        // SIMCTL_CHILD_MENSUR_RENDER_SHEETS=1 to write each project's sheets to tmp/SheetPreviews.
        if ProcessInfo.processInfo.environment["MENSUR_RENDER_SHEETS"] != nil {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("SheetPreviews", isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (i, room) in projects.enumerated() {
                for portrait in [false, true] {
                    try? PDFPlan.sheet(room, portrait: portrait).write(to: out.appendingPathComponent("\(i)-\(portrait ? "portrait" : "landscape").pdf"))
                }
                try? PDFPlan.data(room).write(to: out.appendingPathComponent("\(i)-full.pdf"))
            }
        }
        #endif
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    func reload() throws {
        var loaded: [RoomProject] = [], failures = 0
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let file = folder.appendingPathComponent("Project.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do { loaded.append(try Self.decoder().decode(RoomProject.self, from: Data(contentsOf: file)).validated().movingReviewNotes()) }
            catch { failures += 1 }
        }
        projects = loaded.sorted { $0.updatedAt > $1.updatedAt }
        #if targetEnvironment(macCatalyst)
        let folder = "Documents → Mensur → Rooms"
        #else
        let folder = "Files → Mensur → Rooms"
        #endif
        if failures > 0 { errorMessage = "\(failures) project(s) could not be opened. Their files were preserved in \(folder)." }
    }
    func save(_ room: RoomProject) throws {
        // Whole seconds match what Project.json stores; always moving forward keeps two quick edits distinct for sync.
        var checked = try room.validated()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let previous = projects.first { $0.id == checked.id }?.updatedAt ?? .distantPast
        checked.updatedAt = max(now, previous.addingTimeInterval(1))
        try write(checked)
        localRevision += 1
    }
    private func write(_ checked: RoomProject) throws {
        let folder = directory(checked.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder().encode(checked).write(to: folder.appendingPathComponent("Project.json"), options: .atomic)
        if let i = projects.firstIndex(where: { $0.id == checked.id }) { projects[i] = checked } else { projects.insert(checked, at: 0) }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }
    func addCaptured(_ room: CapturedRoom, reflective: Bool, measurements: URL? = nil) async {
        busy = true
        defer { busy = false }
        do {
            var project = Self.build(room, reflective: reflective, measurements: measurements)
            let folder = directory(project.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Preserve the native result before conversion. Corrections never overwrite it.
            try Self.encoder().encode(room).write(to: folder.appendingPathComponent("Original-RoomPlan.json"), options: .atomic)
            // The LiDAR measurements (a few megabytes, no photos) stay with the room for troubleshooting.
            if let measurements { try? FileManager.default.moveItem(at: measurements, to: folder.appendingPathComponent("Measurements", isDirectory: true)) }
            try save(project)
            adoptScanPhotos(project)
            // Yield once so the saving overlay can render. USD export is local and synchronous.
            await Task.yield()
            do { try room.export(to: folder.appendingPathComponent("Original-RoomPlan.usdz"), exportOptions: .mesh) }
            catch {
                project.captureWarnings.append("Original USDZ export failed: \(error.localizedDescription). Native JSON was preserved.")
                try save(project)
            }
            // The address arrives after the room is safely saved, and never replaces one typed meanwhile.
            let id = project.id
            Task { @MainActor in
                guard let address = await LocationAddress.shared.addressForNewScan(),
                      var latest = self.projects.first(where: { $0.id == id }), latest.address == nil else { return }
                latest.address = address
                try? self.save(latest); self.received.send(id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    // Whether a room still has the original scan to rebuild from.
    func canRebuild(_ room: RoomProject) -> Bool {
        FileManager.default.fileExists(atPath: directory(room.id).appendingPathComponent("Original-RoomPlan.json").path)
    }
    // The room's walls, openings and objects built again from its original RoomPlan scan and LiDAR measurements
    // with the current corrections. Name, address, notes, units and space names are kept; edits to the geometry
    // are replaced (the caller keeps the previous version for Undo).
    func rebuilt(_ room: RoomProject) throws -> RoomProject {
        let folder = directory(room.id)
        let captured = try Self.decoder().decode(CapturedRoom.self, from: Data(contentsOf: folder.appendingPathComponent("Original-RoomPlan.json")))
        let measurements = folder.appendingPathComponent("Measurements", isDirectory: true)
        let reflective = room.captureWarnings.contains { $0.hasPrefix("Mirrors or large glass surfaces were reported") }
        var fresh = Self.build(captured, reflective: reflective,
                               measurements: FileManager.default.fileExists(atPath: measurements.path) ? measurements : nil)
        fresh.id = room.id; fresh.name = room.name; fresh.createdAt = room.createdAt; fresh.units = room.units
        fresh.notes = room.notes; fresh.address = room.address; fresh.spaceLabels = room.spaceLabels
        // Scans resumed later are merged back in, in the order they were taken.
        var n = 2
        while let data = try? Data(contentsOf: folder.appendingPathComponent("Original-RoomPlan-\(n).json")),
              let pass = try? Self.decoder().decode(CapturedRoom.self, from: data) {
            let m = folder.appendingPathComponent("Measurements-\(n)", isDirectory: true)
            fresh = ScanMerge.merge(Self.build(pass, reflective: reflective, measurements: FileManager.default.fileExists(atPath: m.path) ? m : nil), into: fresh).room
            n += 1
        }
        // Everything the user added or set beyond the scanned geometry stays as it is.
        fresh.job = room.job; fresh.level = room.level; fresh.markers = room.markers; fresh.photos = room.photos
        fresh.stairs = room.stairs; fresh.ceilings = room.ceilings ?? fresh.ceilings; fresh.scanReport = room.scanReport ?? fresh.scanReport
        return fresh
    }

    // A RoomPlan result made into a project, with every correction from the LiDAR measurements recorded during
    // the scan (ScanRecorder): heights from the measured floor and ceiling, walls onto their measured surfaces,
    // openings RoomPlan missed, window panes, window and door edges, then squared corners and tidied openings.
    static func build(_ room: CapturedRoom, reflective: Bool, measurements: URL?) -> RoomProject {
        var project = RoomAdapter.project(from: room, reflective: reflective)
        project.dropInvalidGeometry()
        let cornerGap = ScanMetrics.largestCornerGap(project)       // what RoomPlan left open, before tidying
        project.units = Setting.defaultUnits
        // Heights in the project are measured from RoomPlan's floor until the LiDAR floor replaces it.
        let roomFloor = Double(room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0)
        var floorY = roomFloor
        if let measurements, let levels = levels(measurements) {
            let changed = LidarLevels.apply(&project, floor: levels.floor, ceiling: levels.ceiling, roomFloor: roomFloor)
            if abs(levels.floor - roomFloor) <= 0.15 { floorY = levels.floor }
            if changed > 0 {
                project.captureWarnings.append("Ceiling measured by the LiDAR at \(project.units.length(levels.ceiling - levels.floor)); \(changed) wall height(s) corrected to match. Review → Restore original corners and stubs undoes this.")
            }
            if abs(levels.floor - roomFloor) > 0.005 && abs(levels.floor - roomFloor) <= 0.15 {
                project.captureWarnings.append("Window, door and opening heights measured from the floor the LiDAR found (\(Int((abs(levels.floor - roomFloor) * 100).rounded())) cm \(levels.floor > roomFloor ? "above" : "below") RoomPlan's).")
            }
        }
        let labelled = measurements?.appendingPathComponent("wallpoints.bin"), upright = measurements?.appendingPathComponent("wallpoints-upright.bin")
        let isLabelled = labelled.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let wallFile = isLabelled ? labelled : upright
        let lidarWalls = wallFile.flatMap { wallPoints($0, room: room, from: 0.3, to: -0.15) }
        if let points = lidarWalls {
            let mid = wallFile.flatMap { wallPoints($0, room: room, from: 0.9, to: 1.9) }
            let fit = WallFit.apply(&project, points: points, findMissing: isLabelled, missingFrom: mid)
            var parts: [String] = []
            if fit.aligned > 0 { parts.append("\(fit.aligned) wall(s) moved onto the surface the LiDAR measured") }
            if fit.unconfirmed > 0 { parts.append("\(fit.unconfirmed) wall(s) not confirmed by the LiDAR (short ones hidden, others marked for review)") }
            if fit.added > 0 { parts.append("\(fit.added) wall(s) RoomPlan missed added from the LiDAR, marked for review") }
            if !parts.isEmpty { project.captureWarnings.append(parts.joined(separator: "; ") + ". Review → Restore original corners and stubs undoes this; the original RoomPlan files are unchanged.") }
        }
        if let measurements { improveOpenings(&project, room: room, from: measurements, floorY: floorY, wallFile: wallFile) }
        // Joins: nearly-square walls squared, corner gaps closed, split walls merged; openings tidied.
        let joins = WallJoins.apply(&project), tidied = OpeningJoins.apply(&project)
        var tidy: [String] = []
        if joins.squared > 0 { tidy.append("\(joins.squared) wall(s) turned up to 3° to square") }
        if joins.joined > 0 { tidy.append("\(joins.joined) corner gap(s) closed") }
        if joins.merged > 0 { tidy.append("\(joins.merged) split wall(s) joined into one") }
        if tidied > 0 { tidy.append("\(tidied) window/door edge(s) lined up") }
        if !tidy.isEmpty { project.captureWarnings.append(tidy.joined(separator: "; ") + ". Review → Restore original corners and stubs undoes this.") }
        let squared = Setting.bool(Setting.squareCorners, default: true) ? Geometry.squareCorners(&project) : 0
        if Setting.bool(Setting.hideStubs, default: false) { Geometry.hideStubs(&project) }
        // How well the LiDAR confirms each finished wall (shown in Review and on the PDF).
        if let points = lidarWalls { WallFit.check(&project, points: points) }
        if squared > 0 {
            project.captureWarnings.append("\(squared) corner(s) were squared automatically: short corner pieces are hidden and the two walls extended to meet. Review → Restore original corners and stubs undoes this. The original RoomPlan files are unchanged.")
        }
        if let measurements { applyExtras(&project, from: measurements, floorY: floorY, cornerGap: cornerGap) }
        else if let cornerGap { project.scanReport = ScanReport(largestCornerGap: cornerGap) }
        return project
    }
    // The floor and ceiling (world y) the LiDAR measured.
    private static func levels(_ folder: URL) -> (floor: Double, ceiling: Double)? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("levels.json")),
              let levels = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let floor = (levels["floor"] as? NSNumber)?.doubleValue, let ceiling = (levels["ceiling"] as? NSNumber)?.doubleValue else { return nil }
        return (floor, ceiling)
    }
    // Windows and doors RoomPlan missed (from LiDAR window/door labels), the panes of each window (from the
    // close-ups recorded during the scan), then window and door edges from the gaps in the wall's surface.
    // floorY: the floor (world y) the project's heights are measured from.
    private static func improveOpenings(_ project: inout RoomProject, room: CapturedRoom, from folder: URL, floorY: Double, wallFile: URL?) {
        func points(_ url: URL?) -> [LidarOpenings.Point] {
            (url.flatMap { points3D($0) } ?? []).map { .init(plan: PlanPoint(x: Double($0.x), z: Double($0.z)), height: Double($0.y) - floorY) }
        }
        let found = LidarOpenings.add(&project, windows: points(folder.appendingPathComponent("windowpoints.bin")), doors: points(folder.appendingPathComponent("doorpoints.bin")))
        if found.windows + found.doors > 0 {
            project.captureWarnings.append("\(found.windows) window(s) and \(found.doors) door(s) RoomPlan missed were found by the LiDAR and added for review. Check their size and position.")
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("windows.json")),
           let records = try? JSONDecoder().decode([ScanRecorder.WindowRecord].self, from: data) {
            var divided = 0
            for record in records {
                guard let i = project.surfaces.firstIndex(where: { $0.id == record.id && $0.kind == .window }),
                      let window = room.windows.first(where: { $0.identifier == record.id }) else { continue }
                let size = (width: Double(window.dimensions.x), height: Double(window.dimensions.y))
                let views = record.views.compactMap { paneView($0, window: window) }
                guard let panes = WindowPanes.find(views, size: size) else { continue }
                // Close-ups run from the window's own left edge; the plan surface may run the other way.
                let s = project.surfaces[i], left = window.transform * SIMD4<Float>(-window.dimensions.x / 2, 0, 0, 1)
                let fromA = s.a.distance(to: PlanPoint(x: Double(left.x), z: Double(left.z))) < s.b.distance(to: PlanPoint(x: Double(left.x), z: Double(left.z)))
                let dividers = panes.vertical.map { fromA ? $0 : s.length - $0 }.filter { $0 > 0.05 && $0 < s.length - 0.05 }.sorted()
                let rails = panes.horizontal.filter { $0 > 0.05 && $0 < s.height - 0.05 }
                project.surfaces[i].dividers = dividers.isEmpty ? nil : dividers; project.surfaces[i].rails = rails.isEmpty ? nil : rails
                if !dividers.isEmpty || !rails.isEmpty { divided += 1 }
            }
            if divided > 0 { project.captureWarnings.append("Window panes found for \(divided) window(s) from the camera. Check them in each window's details.") }
        }
        let edges = LidarOpeningEdges.apply(&project, wallPoints: points(wallFile))
        if edges > 0 { project.captureWarnings.append("\(edges) window/door edge(s) set from the gap the LiDAR measured in the wall. Review → Restore original corners and stubs undoes this.") }
    }
    // One recorded close-up placed on the window as RoomPlan finally measured it. Close-ups record where RoomPlan
    // had the window at that moment; older ones don't, so they are used only when their size is within 15 cm of
    // the final one, assumed centred on it.
    private static func paneView(_ v: ScanRecorder.WindowView, window: CapturedRoom.Surface) -> WindowPanes.View? {
        let ppm = Double(ScanRecorder.pixelsPerMeter)
        let w = Double(v.width) / ppm, h = Double(v.height) / ppm
        let finalW = Double(window.dimensions.x), finalH = Double(window.dimensions.y)
        var pixels = [UInt8](v.pixels)
        guard let c = v.centre, let x = v.axis, let size = v.size, c.count == 3, x.count == 3, size.count == 2 else {
            guard abs(w - finalW) <= 0.15, abs(h - finalH) <= 0.15 else { return nil }
            return .init(width: v.width, height: v.height, pixels: pixels, pixelsPerMeter: ppm, left: (finalW - w) / 2, bottom: (finalH - h) / 2)
        }
        let finalAxis = simd_normalize(SIMD3(window.transform.columns.0.x, window.transform.columns.0.y, window.transform.columns.0.z))
        let finalCentre = SIMD3(window.transform.columns.3.x, window.transform.columns.3.y, window.transform.columns.3.z)
        var axis = simd_normalize(SIMD3(x[0], x[1], x[2]))
        guard abs(simd_dot(axis, finalAxis)) > 0.9 else { return nil }          // a different face of the window
        if simd_dot(axis, finalAxis) < 0 {                                         // seen from the other side: mirror it
            for row in 0..<v.height { pixels[(row * v.width)..<((row + 1) * v.width)].reverse() }
            axis = -axis
        }
        let viewLeft = SIMD3(c[0], c[1], c[2]) - axis * (size[0] / 2), finalLeft = finalCentre - finalAxis * (window.dimensions.x / 2)
        return .init(width: v.width, height: v.height, pixels: pixels, pixelsPerMeter: ppm,
                     left: Double(simd_dot(viewLeft - finalLeft, finalAxis)),
                     bottom: Double((c[1] - size[1] / 2) - (finalCentre.y - window.dimensions.y / 2)))
    }
    static func points3D(_ url: URL) -> [SIMD3<Float>]? {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else { return nil }
        let count = data.count / 12, step = max(1, count / 200_000)
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: count, by: step).map { i in
                SIMD3(raw.loadUnaligned(fromByteOffset: i * 12, as: Float.self), raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self),
                      raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self))
            }
        }
    }
    // Wall-surface points saved by the recorder (Float32 x, y, z triples, world frame) as plan points, at most
    // ~200k, evenly thinned. from, to: heights in meters above RoomPlan's floor; a negative `to` counts down from
    // the top of the walls.
    private static func wallPoints(_ url: URL, room: CapturedRoom, from: Double, to: Double) -> [PlanPoint]? {
        guard let data = try? Data(contentsOf: url), data.count >= 12, !room.walls.isEmpty else { return nil }
        let floorY = Double(room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min()!)
        let topY = Double(room.walls.map { $0.transform.columns.3.y + $0.dimensions.y / 2 }.max()!)
        let low = floorY + from, high = to < 0 ? topY + to : floorY + to
        let count = data.count / 12, step = max(1, count / 200_000)
        return data.withUnsafeBytes { raw -> [PlanPoint] in
            var out: [PlanPoint] = []; out.reserveCapacity(count / step + 1)
            for i in stride(from: 0, to: count, by: step) {
                let x = raw.loadUnaligned(fromByteOffset: i * 12, as: Float.self), y = Double(raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self))
                let z = raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self)
                if y > low && y < high { out.append(PlanPoint(x: Double(x), z: Double(z))) }
            }
            return out
        }
    }
    func addDemo() { var demo = RoomProject.demo(); demo.units = Setting.defaultUnits; do { try save(demo) } catch { errorMessage = error.localizedDescription } }
    func remove(_ room: RoomProject) throws {
        try FileManager.default.removeItem(at: directory(room.id)); projects.removeAll { $0.id == room.id }
        tombstones[room.id] = Date(); persistTombstones(); localRevision += 1
    }
    // Settings → Clear all rooms. Each room moves to Documents/Recently Deleted rather than being erased, and its
    // deletion syncs, so a paired device moves its copies there too.
    func removeAll() throws {
        defer { persistTombstones(); localRevision += 1 }
        for room in projects {
            try moveToRecentlyDeleted(room.id)
            tombstones[room.id] = Date()
        }
    }
    // Deletions learned from a paired device, recorded with that device's date so they reach this device's
    // other paired devices too (an iPhone paired with several Macs passes one Mac's deletions to the others).
    func adoptDeletions(_ deletions: [UUID: Date]) {
        guard !deletions.isEmpty else { return }
        for (id, date) in deletions { tombstones[id] = max(tombstones[id] ?? date, date) }
        persistTombstones()
    }
    private func persistTombstones() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? Self.encoder().encode(tombstones).write(to: tombstoneFile, options: .atomic)
    }

    // MARK: Sync

    func manifest(device: UUID) -> SyncManifest {
        let entries = projects.compactMap { room -> SyncEntry? in
            guard let data = try? Self.encoder().encode(room) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let originals = syncedFiles(room).filter { FileManager.default.fileExists(atPath: directory(room.id).appendingPathComponent($0).path) }
            return .init(id: room.id, updatedAt: Date(timeIntervalSince1970: floor(room.updatedAt.timeIntervalSince1970)), digest: digest, originals: originals)
        }
        return .init(device: device, entries: entries, tombstones: tombstones)
    }
    func transfer(_ id: UUID, project: Bool, originals: [String]) -> RoomTransfer? {
        var t = RoomTransfer(id: id)
        if project { guard let room = projects.first(where: { $0.id == id }), let data = try? Self.encoder().encode(room) else { return nil }; t.project = data }
        for name in originals where SyncPlan.isSyncedFile(name) {
            t.originals[name] = try? Data(contentsOf: directory(id).appendingPathComponent(name))
        }
        return t
    }
    // The room's native scans and photos, whether or not each is on disk yet.
    func syncedFiles(_ room: RoomProject) -> [String] {
        let passes = (2...50).map { "Original-RoomPlan-\($0).json" }.prefix { FileManager.default.fileExists(atPath: directory(room.id).appendingPathComponent($0).path) }
        return SyncPlan.originalFiles + passes + (room.photos ?? []).map(\.file)
    }
    // Writes a peer's room exactly as sent (keeping its timestamp), after the same validation as an import.
    // Native files are only added, never replaced, so originals stay untouched.
    func receive(_ t: RoomTransfer) throws {
        let folder = directory(t.id)
        if let data = t.project {
            guard data.count < 20_000_000 else { throw ProjectError.invalid("A synced room was too large.") }
            let room = try Self.decoder().decode(RoomProject.self, from: data).validated()
            guard room.id == t.id else { throw ProjectError.invalid("A synced room didn't match its identifier.") }
            try write(room)
            tombstones[t.id] = nil; persistTombstones()
        }
        for (name, data) in t.originals where SyncPlan.isSyncedFile(name) && data.count < 60_000_000 {
            let url = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: folder.path) else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        received.send(t.id)
    }
    // Before a newer version from the peer replaces this room, keep ours as its own room.
    func keepConflictCopy(_ id: UUID) throws {
        guard var copy = projects.first(where: { $0.id == id }) else { return }
        let source = directory(id)
        copy.id = UUID(); copy.name = String((copy.name + " (conflicted copy)").prefix(120))
        let folder = directory(copy.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in syncedFiles(copy) where FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path) {
            let target = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
        }
        try write(copy)
    }
    // A room deleted on the other device moves to Documents/Recently Deleted rather than being erased.
    func moveToRecentlyDeleted(_ id: UUID) throws {
        let bin = AppPaths.documents.appendingPathComponent("Recently Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let name = projects.first { $0.id == id }?.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-") ?? "Room"
        var target = bin.appendingPathComponent("\(name) – \(id.uuidString.prefix(8))", isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { target = bin.appendingPathComponent("\(name) – \(id.uuidString)", isDirectory: true) }
        try FileManager.default.moveItem(at: directory(id), to: target)
        projects.removeAll { $0.id == id }
        received.send(id)
    }
    func importProject(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        guard bytes.count < 20_000_000 else { throw ProjectError.invalid("Project JSON must be smaller than 20 MB.") }
        var room = try Self.decoder().decode(RoomProject.self, from: bytes).validated()
        room.id = UUID(); room.name = String((room.name + " · imported").prefix(120))
        room.captureWarnings.append("Imported corrected project. Original RoomPlan files are not included in this JSON.")
        try save(room)
    }
}
