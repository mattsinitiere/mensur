import Foundation
import RoomPlan

// What the capture screen records beside RoomPlan's result, in the scan's Measurements folder:
//   poses.json          the phone's position four times a second (PoseSample), for the tracking report
//   ceilingpoints.bin   centres of ceiling-labelled LiDAR triangles (Float32 x, y, z), for soffits, beams, slopes
//   markers.json        outlets, switches, fixtures… dropped during the scan (world x, y, z)
//   photos.json         reference photos taken during the scan (plan x, z, heading), files in Photos/
//   reveals.json        door and window reveal depths measured in reveal mode
//   capture.json        the building, floor and session the scan belongs to
struct CaptureContext: Codable { var building: String?; var floor: Int?; var floorName: String?; var frame: UUID? }
struct CapturedMarker: Codable { var kind: MarkerKind; var x: Double; var y: Double; var z: Double }
struct CapturedPhoto: Codable { var id: UUID; var x: Double; var z: Double; var heading: Double? }
// x, z: the opening's centre, to find it if RoomPlan's final result gave it a different identifier.
struct CapturedReveal: Codable { var opening: UUID; var depth: Double; var x: Double? = nil; var z: Double? = nil }

extension ProjectStore {
    static func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // Adds the scan's extra recordings to a freshly built project. floorY: the floor (world y) heights use.
    static func applyExtras(_ project: inout RoomProject, from folder: URL, floorY: Double, cornerGap: Double?) {
        if let poses = readJSON([PoseSample].self, folder.appendingPathComponent("poses.json")), poses.count > 4 {
            var report = ScanMetrics.report(poses)
            report.largestCornerGap = cornerGap
            project.scanReport = report
        } else if let cornerGap { project.scanReport = ScanReport(largestCornerGap: cornerGap) }
        if let points = points3D(folder.appendingPathComponent("ceilingpoints.bin")),
           let result = CeilingAnalysis.analyse(points.map { Vector3(x: Double($0.x), y: Double($0.y), z: Double($0.z)) }, floorY: floorY),
           !result.features.isEmpty {
            project.ceilings = result.features
            project.captureWarnings.append("\(result.features.count) ceiling feature(s) found in the LiDAR ceiling points (\(result.features.map { $0.kind.title.lowercased() }.joined(separator: ", "))). Check their heights in Elements → Ceiling.")
        }
        if let markers = readJSON([CapturedMarker].self, folder.appendingPathComponent("markers.json")), !markers.isEmpty {
            project.markers = markers.map { m in
                let height = m.y - floorY
                return PlanMarker(kind: m.kind, position: .init(x: m.x, z: m.z), height: m.kind.typicalHeight == nil && (height < 0.15 || height > 2.2) ? nil : max(0, height))
            }
        }
        if let photos = readJSON([CapturedPhoto].self, folder.appendingPathComponent("photos.json")), !photos.isEmpty {
            project.photos = photos.map { PinnedPhoto(id: $0.id, position: .init(x: $0.x, z: $0.z), heading: $0.heading) }
        }
        if let reveals = readJSON([CapturedReveal].self, folder.appendingPathComponent("reveals.json")), !reveals.isEmpty {
            var applied = 0
            for r in reveals {
                let near = r.x.flatMap { x in r.z.map { PlanPoint(x: x, z: $0) } }.flatMap { c in
                    project.surfaces.indices.filter { project.surfaces[$0].kind.isCutout }.min { project.surfaces[$0].midpoint.distance(to: c) < project.surfaces[$1].midpoint.distance(to: c) }
                        .flatMap { project.surfaces[$0].midpoint.distance(to: c) < 0.35 ? $0 : nil }
                }
                guard let i = project.surfaces.firstIndex(where: { $0.id == r.opening }) ?? near, r.depth.isFinite, r.depth > 0.03, r.depth < 0.8 else { continue }
                project.surfaces[i].revealDepth = r.depth; applied += 1
            }
            let walls = Reveals.applyToWalls(&project)
            if applied > 0 { project.captureWarnings.append("Reveal depth measured at \(applied) door(s) or window(s); \(walls) wall thickness(es) set from them.") }
        }
        if let context = readJSON(CaptureContext.self, folder.appendingPathComponent("capture.json")), let building = context.building, !building.isEmpty {
            project.level = FloorLevel(building: String(building.prefix(120)), floor: context.floor ?? 0, name: context.floorName, frame: context.frame)
        }
    }

    // Moves photos taken during the scan from its Measurements folder to the room's Photos folder.
    func adoptScanPhotos(_ room: RoomProject) {
        let folder = directory(room.id), source = folder.appendingPathComponent("Measurements/Photos", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let target = folder.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for photo in room.photos ?? [] {
            let from = source.appendingPathComponent("\(photo.id.uuidString).jpg"), to = folder.appendingPathComponent(photo.file)
            if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.moveItem(at: from, to: to) }
        }
    }

    // MARK: Photos

    func photoURL(_ room: RoomProject, _ photo: PinnedPhoto) -> URL { directory(room.id).appendingPathComponent(photo.file) }

    // Saves a reference photo's JPEG beside the room. Large images are scaled to 2048 px on the long side.
    func savePhoto(_ jpeg: Data, for room: RoomProject, photo: PinnedPhoto) throws {
        let url = photoURL(room, photo)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
    }
    func deletePhotoFile(_ room: RoomProject, _ photo: PinnedPhoto) { try? FileManager.default.removeItem(at: photoURL(room, photo)) }

    // MARK: Resumed scans

    // The world map saved with the room's latest scan pass, which a new scan can relocalize against.
    func latestWorldMap(_ room: RoomProject) -> URL? {
        let folder = directory(room.id)
        var candidates = [folder.appendingPathComponent("Measurements/WorldMap.arworldmap")]
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("Measurements-\(n)").path) {
            candidates.append(folder.appendingPathComponent("Measurements-\(n)/WorldMap.arworldmap")); n += 1
        }
        return candidates.last { FileManager.default.fileExists(atPath: $0.path) }
    }
    func canResume(_ room: RoomProject) -> Bool { latestWorldMap(room) != nil }
    func resumeContext(_ room: RoomProject) -> ResumeContext? {
        latestWorldMap(room).map { ResumeContext(roomID: room.id, name: room.name, worldMap: $0, level: room.level) }
    }

    // A scan resumed from a room's saved world map lands in the same coordinates: what it adds is merged
    // into the room, and its native result is kept as Original-RoomPlan-<n>.json for rebuilding.
    func addResumed(_ captured: CapturedRoom, into id: UUID, measurements: URL?) async {
        busy = true
        defer { busy = false }
        guard let existing = projects.first(where: { $0.id == id }) else { return }
        do {
            let pass = Self.build(captured, reflective: false, measurements: measurements)
            let folder = directory(id)
            var n = 2
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent("Original-RoomPlan-\(n).json").path) { n += 1 }
            try Self.encoder().encode(captured).write(to: folder.appendingPathComponent("Original-RoomPlan-\(n).json"), options: .atomic)
            if let measurements {
                let target = folder.appendingPathComponent("Measurements-\(n)", isDirectory: true)
                try? FileManager.default.moveItem(at: measurements, to: target)
                let photos = target.appendingPathComponent("Photos", isDirectory: true)
                for photo in pass.photos ?? [] {
                    let from = photos.appendingPathComponent("\(photo.id.uuidString).jpg"), to = folder.appendingPathComponent(photo.file)
                    try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: from, to: to)
                }
            }
            var merged = ScanMerge.merge(pass, into: existing).room
            merged.updatedAt = Date()
            try save(merged)
            received.send(id)
        } catch { errorMessage = error.localizedDescription }
    }
}
