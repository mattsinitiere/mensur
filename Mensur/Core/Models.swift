import Foundation

struct PlanPoint: Codable, Hashable {
    var x: Double
    var z: Double
    static let zero = PlanPoint(x: 0, z: 0)
    static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, z: a.z + b.z) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, z: a.z - b.z) }
    static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, z: a.z * b) }
    var magnitude: Double { hypot(x, z) }
    func distance(to other: Self) -> Double { (self - other).magnitude }
    func dot(_ other: Self) -> Double { x * other.x + z * other.z }
    var isFinite: Bool { x.isFinite && z.isFinite }
}

struct Vector3: Codable, Hashable {
    var x: Double
    var y: Double
    var z: Double
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

enum SurfaceKind: String, Codable, CaseIterable, Identifiable {
    case wall, door, window, opening, mirror
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isCutout: Bool { self == .door || self == .window || self == .opening }
    var symbol: String {
        switch self {
        case .wall: return "square.split.2x1"
        case .door: return "door.left.hand.open"
        case .window: return "window.vertical.open"
        case .opening: return "rectangle.dashed"
        case .mirror: return "rectangle.portrait"
        }
    }
}

enum Evidence: String, Codable { case captured, edited, manual }
enum ScanConfidence: String, Codable { case high, medium, low, unknown }
enum DisplayUnits: String, Codable, CaseIterable {
    case imperial, metric
    func length(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        if self == .metric { return String(format: "%.2f m", meters) }
        let quarters = Int((abs(meters) / 0.0254 * 4).rounded())
        let feet = quarters / 48
        let inch = Double(quarters % 48) / 4
        return String(format: "%@%d′ %.2f″", meters < 0 ? "−" : "", feet, inch)
    }
    // Rounded, grouped area for labels and summaries: "2,238 sq ft" or "207.9 m²".
    func areaLabel(_ meters: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = self == .metric ? 1 : 0; f.minimumFractionDigits = f.maximumFractionDigits
        let value = self == .metric ? meters : meters * 10.7639104167
        return (f.string(from: NSNumber(value: value)) ?? "\(value)") + (self == .metric ? " m²" : " sq ft")
    }
    func area(_ meters: Double) -> String {
        self == .metric ? String(format: "%.2f m²", meters) : String(format: "%.1f sq ft", meters * 10.7639104167)
    }
}

struct LengthCheck: Codable, Hashable {
    var measuredMeters: Double
    var referenceMeters: Double
    var date: Date = Date()
    var method: String = "Laser / tape"
    var difference: Double { measuredMeters - referenceMeters }
}

// Records an automatic cleanup so it can be reversed. Optional, so projects written before it existed
// still decode and older builds ignore the key; schemaVersion stays 1.
// coverage: share of the wall's solid length with LiDAR surface points; offset: median distance of those points
// from the wall line; spread: how far they scatter around it (RMS). All meters except coverage (0…1).
struct LidarCheck: Codable, Hashable {
    var coverage: Double, offset: Double, spread: Double
    enum Level { case confirmed, partly, unconfirmed }
    var level: Level { coverage >= 0.6 && abs(offset) <= 0.02 && spread <= 0.03 ? .confirmed : coverage >= 0.3 ? .partly : .unconfirmed }
}

struct AutoCleanup: Codable, Hashable {
    // lidarAligned: moved onto the LiDAR wall surface; unconfirmed: hidden, no LiDAR support;
    // lidarAdded: a wall RoomPlan missed, found in the LiDAR mesh (restoring hides it).
    // tidied: squared, joined or lined up by WallJoins/OpeningJoins; merged: a wall piece joined into its neighbour.
    enum Reason: String, Codable { case squaredCorner, cornerPiece, stub, lidarAligned, unconfirmed, lidarAdded, tidied, merged }
    var reason: Reason
    var originalA: PlanPoint
    var originalB: PlanPoint
    var originalHeight: Double? = nil          // when the LiDAR corrected the wall's height
    var originalBottom: Double? = nil
    var originalParent: UUID? = nil            // an opening moved onto the wall its piece was merged into
}

// A user's name for an enclosed space. Spaces are recomputed from the walls, so the name is pinned to a
// point inside the space and follows whichever space contains it.
struct SpaceLabel: Codable, Hashable {
    var name: String
    var anchor: PlanPoint
    // Finish tags for the room schedule ("LVP", "Paint · eggshell", "ACT 2×2"). Optional: older projects decode.
    var floorFinish: String? = nil
    var wallFinish: String? = nil
    var ceilingFinish: String? = nil
    var baseFinish: String? = nil
    var hasFinishes: Bool { [floorFinish, wallFinish, ceilingFinish, baseFinish].contains { !($0 ?? "").isEmpty } }
}

struct PlanSurface: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String
    var kind: SurfaceKind
    var a: PlanPoint
    var b: PlanPoint
    var bottom: Double = 0
    var height: Double = 2.5
    var parentID: UUID? = nil
    var confidence: ScanConfidence = .unknown
    var evidence: Evidence = .manual
    var originalLength: Double? = nil
    var lengthCheck: LengthCheck? = nil
    var reflectiveRisk: Bool = false
    var reviewed: Bool = false
    var excluded: Bool = false
    var notes: String = ""
    var geometryCaveat: String? = nil          // curved or non-rectangular shape: area isn't computed
    var reviewNote: String? = nil              // automatic finding to confirm (e.g. found only by the LiDAR)
    var autoCleanup: AutoCleanup? = nil
    // Windows: dividers between panes. Vertical ones in meters from `a` along the window, horizontal ones in
    // meters above its bottom. Optional, so earlier projects decode unchanged (schemaVersion stays 1).
    var dividers: [Double]? = nil
    var rails: [Double]? = nil
    // Walls: how well the LiDAR mesh confirms this wall where it now is (set after a scan, cleared by edits).
    var lidarCheck: LidarCheck? = nil
    // Walls: construction type and overall thickness (meters, outward from the scanned inside face).
    var wallType: WallType? = nil
    var thickness: Double? = nil
    var thicknessSource: ThicknessSource? = nil
    // Doors: how the leaf moves. hingeAtB puts the hinge at the b end; opensOut swings it away from the room.
    var doorStyle: DoorStyle? = nil
    var hingeAtB: Bool? = nil
    var opensOut: Bool? = nil
    // Doors and windows: the measured depth of the opening's reveal (jamb), which is the wall's thickness there.
    var revealDepth: Double? = nil
    // The thickness the plan draws: typed or measured, else the type's default; nil draws a single line.
    var drawnThickness: Double? {
        guard kind == .wall else { return nil }
        return thickness ?? wallType?.defaultThickness
    }
    var paneDescription: String? {
        guard kind == .window, (dividers?.isEmpty == false) || (rails?.isEmpty == false) else { return nil }
        return "\((dividers?.count ?? 0) + 1) × \((rails?.count ?? 0) + 1) panes"
    }
    var length: Double { a.distance(to: b) }
    var midpoint: PlanPoint { (a + b) * 0.5 }
    var direction: PlanPoint { length > 1e-8 ? (b - a) * (1 / length) : .init(x: 1, z: 0) }
    var hasCurrentLengthCheck: Bool {
        guard let check = lengthCheck else { return false }
        return abs(length - check.measuredMeters) < 0.005
    }
    var needsReview: Bool {
        !excluded && ((!reviewed && (reflectiveRisk || kind == .window || kind == .mirror || confidence == .low || reviewNote != nil)) || geometryCaveat != nil)
    }
}

struct PlanObject: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String
    var center: Vector3
    var size: Vector3
    var yaw: Double
    var excluded: Bool = false
}

struct RoomProject: Codable, Identifiable {
    var schemaVersion: Int = 1
    var id: UUID = UUID()
    var name: String = "Untitled room"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var units: DisplayUnits = .imperial
    var surfaces: [PlanSurface] = []
    var objects: [PlanObject] = []
    var notes: String = ""
    var isDemo: Bool = false
    var captureWarnings: [String] = []
    // Optional so earlier projects decode unchanged; schemaVersion stays 1.
    var address: String? = nil
    var spaceLabels: [SpaceLabel]? = nil
    var job: JobInfo? = nil
    var level: FloorLevel? = nil
    var markers: [PlanMarker]? = nil
    var photos: [PinnedPhoto]? = nil
    var ceilings: [CeilingFeature]? = nil
    var stairs: [Stair]? = nil
    var scanReport: ScanReport? = nil
    var activeSurfaces: [PlanSurface] { surfaces.filter { !$0.excluded } }
    var walls: [PlanSurface] { activeSurfaces.filter { $0.kind == .wall } }
    var reviewCount: Int { activeSurfaces.filter(\.needsReview).count }
    var checkedCount: Int { activeSurfaces.filter(\.hasCurrentLengthCheck).count }

    // geometryCaveat hides the area, so only a shape the plan can't draw belongs there (a curved wall drawn as a
    // straight chord). Rooms saved earlier kept LiDAR findings there, and walls with a stepped or sloping top
    // ("Nonuniform wall height"), which doesn't change the floor; those move to reviewNote.
    static let nonuniformHeight = "Nonuniform wall height represented by a rectangular envelope."
    func movingReviewNotes() -> Self {
        var room = self
        for i in room.surfaces.indices {
            guard let caveat = room.surfaces[i].geometryCaveat else { continue }
            if caveat.contains("by the LiDAR scan") {
                room.surfaces[i].reviewNote = caveat; room.surfaces[i].geometryCaveat = nil
            } else if caveat.contains(Self.nonuniformHeight) {
                let rest = caveat.replacingOccurrences(of: Self.nonuniformHeight, with: "").trimmingCharacters(in: .whitespaces)
                room.surfaces[i].geometryCaveat = rest.isEmpty ? nil : rest
                room.surfaces[i].reviewNote = [room.surfaces[i].reviewNote, Self.nonuniformHeight].compactMap { $0 }.joined(separator: " ")
            }
        }
        return room
    }
    func validated() throws -> Self {
        guard schemaVersion == 1 else { throw ProjectError.invalid("Unsupported project version.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              surfaces.count <= 1000, objects.count <= 1000 else { throw ProjectError.invalid("Invalid project size or title.") }
        guard (address?.count ?? 0) <= 300, (spaceLabels ?? []).allSatisfy({ $0.name.count <= 120 && $0.anchor.isFinite }),
              (spaceLabels ?? []).allSatisfy({ l in [l.floorFinish, l.wallFinish, l.ceilingFinish, l.baseFinish].allSatisfy { ($0?.count ?? 0) <= 120 } }),
              (spaceLabels?.count ?? 0) <= 200 else { throw ProjectError.invalid("Invalid address or space names.") }
        try validateAnnotations()
        guard Set(surfaces.map(\.id)).count == surfaces.count,
              Set(objects.map(\.id)).count == objects.count else { throw ProjectError.invalid("Duplicate element identifiers.") }
        let wallIDs = Set(surfaces.filter { $0.kind == .wall }.map(\.id))
        for s in surfaces {
            guard s.a.isFinite, s.b.isFinite, s.height.isFinite, s.bottom.isFinite,
                  s.length >= 0.01, s.length <= 100, s.height > 0, s.height <= 30,
                  abs(s.a.x) < 1000, abs(s.a.z) < 1000, abs(s.b.x) < 1000, abs(s.b.z) < 1000,
                  abs(s.bottom) < 100, s.label.count <= 120, s.notes.count < 20000,
                  s.parentID == nil || wallIDs.contains(s.parentID!) else {
                throw ProjectError.invalid("Invalid dimensions or parent wall for \(s.label).")
            }
            guard (s.dividers ?? []).count <= 20, (s.rails ?? []).count <= 20,
                  (s.dividers ?? []).allSatisfy({ $0.isFinite && $0 > 0 && $0 < s.length }),
                  (s.rails ?? []).allSatisfy({ $0.isFinite && $0 > 0 && $0 < s.height }) else {
                throw ProjectError.invalid("Invalid window panes for \(s.label).")
            }
            guard [s.thickness, s.revealDepth].allSatisfy({ $0.map { $0.isFinite && $0 > 0 && $0 <= 2 } ?? true }) else {
                throw ProjectError.invalid("Invalid thickness for \(s.label).")
            }
            if let c = s.lengthCheck {
                guard c.measuredMeters.isFinite, c.referenceMeters.isFinite,
                      c.measuredMeters > 0, c.measuredMeters <= 100 else { throw ProjectError.invalid("Invalid measurement.") }
            }
        }
        for o in objects {
            guard o.center.isFinite, o.size.isFinite, o.yaw.isFinite,
                  o.size.x > 0, o.size.y > 0, o.size.z > 0,
                  max(o.size.x, max(o.size.y, o.size.z)) <= 100,
                  abs(o.center.x) < 1000, abs(o.center.y) < 1000, abs(o.center.z) < 1000 else {
                throw ProjectError.invalid("Invalid furniture geometry.")
            }
        }
        return self
    }

    // The user's name for each space in `spaces`, or "Space A", "Space B"… where none is set.
    func spaceNames(_ spaces: [Geometry.Space]) -> [String] {
        spaces.enumerated().map { i, space in
            spaceLabel(space).flatMap { $0.name.isEmpty ? nil : $0.name } ?? "Space \(i < 26 ? String(UnicodeScalar(65 + i)!) : "\(i + 1)")"
        }
    }
    // The name and finishes pinned inside `space`, if any.
    func spaceLabel(_ space: Geometry.Space) -> SpaceLabel? { spaceLabels?.first { Geometry.contains(space.points, $0.anchor) } }
    // Names `space`, replacing any name pinned inside it; an empty name restores the default. Finishes stay.
    mutating func nameSpace(_ space: Geometry.Space, _ name: String) {
        var label = spaceLabel(space) ?? SpaceLabel(name: "", anchor: Geometry.labelPoint(space.points))
        label.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        setSpaceLabel(label, for: space)
    }
    // Replaces whatever is pinned inside `space`; a label with neither a name nor finishes is removed.
    mutating func setSpaceLabel(_ label: SpaceLabel, for space: Geometry.Space) {
        var labels = (spaceLabels ?? []).filter { !Geometry.contains(space.points, $0.anchor) }
        var pinned = label
        pinned.anchor = Geometry.labelPoint(space.points)
        for path in [\SpaceLabel.floorFinish, \.wallFinish, \.ceilingFinish, \.baseFinish] {
            let text = (pinned[keyPath: path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            pinned[keyPath: path] = text.isEmpty ? nil : String(text.prefix(120))
        }
        if !pinned.name.isEmpty || pinned.hasFinishes { labels.append(pinned) }
        spaceLabels = labels.isEmpty ? nil : labels
    }

    // Limits on everything beyond walls and openings, so an imported or synced project can't carry
    // malformed or extreme values into drawing and exports.
    func validateAnnotations() throws {
        func ok(_ p: PlanPoint) -> Bool { p.isFinite && abs(p.x) < 1000 && abs(p.z) < 1000 }
        func height(_ h: Double?) -> Bool { h.map { $0.isFinite && $0 >= -1 && $0 <= 30 } ?? true }
        if let job {
            guard job.client.count <= 120, job.project.count <= 120, job.number.count <= 60,
                  job.tags.count <= 30, job.tags.allSatisfy({ $0.count <= 40 }) else { throw ProjectError.invalid("Invalid job details.") }
        }
        if let level {
            guard !level.building.isEmpty, level.building.count <= 120, (level.name?.count ?? 0) <= 60, abs(level.floor) <= 200,
                  level.elevation.map({ $0.isFinite && abs($0) <= 300 }) ?? true, ok(level.offset), level.rotation.isFinite else { throw ProjectError.invalid("Invalid building or floor.") }
        }
        guard (markers?.count ?? 0) <= 2000, (markers ?? []).allSatisfy({ ok($0.position) && height($0.height) && $0.label.count <= 120 && $0.note.count <= 2000 }) else {
            throw ProjectError.invalid("Invalid markers.")
        }
        guard (photos?.count ?? 0) <= 500, (photos ?? []).allSatisfy({ ok($0.position) && $0.caption.count <= 500 && ($0.heading?.isFinite ?? true) }) else {
            throw ProjectError.invalid("Invalid photo pins.")
        }
        guard (ceilings?.count ?? 0) <= 200, (ceilings ?? []).allSatisfy({ c in
            ok(c.a) && ok(c.b) && c.length >= 0.05 && c.length <= 100 && c.width.isFinite && c.width > 0.02 && c.width <= 100
                && height(c.low) && height(c.high) && c.label.count <= 120
        }) else { throw ProjectError.invalid("Invalid ceiling features.") }
        guard (stairs?.count ?? 0) <= 50, (stairs ?? []).allSatisfy({ s in
            ok(s.a) && ok(s.b) && s.length >= 0.3 && s.length <= 30 && s.width.isFinite && s.width >= 0.3 && s.width <= 10
                && (1...100).contains(s.risers) && s.label.count <= 120
        }) else { throw ProjectError.invalid("Invalid stairs.") }
        if let r = scanReport {
            guard [r.pathLength, r.duration, r.limitedTracking, r.largestCorrection].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ProjectError.invalid("Invalid scan report.")
            }
        }
    }

    // Removes only what validated() would reject, so one malformed piece of a capture cannot block saving
    // the rest. Returns how many elements were dropped and records that in captureWarnings.
    @discardableResult mutating func dropInvalidGeometry() -> Int {
        func valid(_ s: PlanSurface) -> Bool {
            s.a.isFinite && s.b.isFinite && s.height.isFinite && s.bottom.isFinite
                && s.length >= 0.01 && s.length <= 100 && s.height > 0 && s.height <= 30
                && abs(s.a.x) < 1000 && abs(s.a.z) < 1000 && abs(s.b.x) < 1000 && abs(s.b.z) < 1000 && abs(s.bottom) < 100
        }
        let before = surfaces.count + objects.count
        var seen = Set<UUID>()
        surfaces = Array(surfaces.filter { valid($0) && seen.insert($0.id).inserted }.prefix(1000))
        let wallIDs = Set(surfaces.filter { $0.kind == .wall }.map(\.id))
        for i in surfaces.indices where surfaces[i].parentID.map({ !wallIDs.contains($0) }) ?? false { surfaces[i].parentID = nil }
        for i in surfaces.indices {
            surfaces[i].label = String(surfaces[i].label.prefix(120)); surfaces[i].notes = String(surfaces[i].notes.prefix(19_000))
            if surfaces[i].lengthCheck.map({ !$0.measuredMeters.isFinite || !$0.referenceMeters.isFinite || $0.measuredMeters <= 0 || $0.measuredMeters > 100 }) ?? false { surfaces[i].lengthCheck = nil }
        }
        seen = []
        objects = Array(objects.filter { o in
            o.center.isFinite && o.size.isFinite && o.yaw.isFinite && o.size.x > 0 && o.size.y > 0 && o.size.z > 0
                && max(o.size.x, max(o.size.y, o.size.z)) <= 100
                && abs(o.center.x) < 1000 && abs(o.center.y) < 1000 && abs(o.center.z) < 1000 && seen.insert(o.id).inserted
        }.prefix(1000))
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Untitled room" }
        name = String(name.prefix(120))
        let dropped = before - surfaces.count - objects.count
        if dropped > 0 { captureWarnings.append("\(dropped) captured element(s) had invalid or extreme dimensions and were left out. The original RoomPlan files still contain them.") }
        return dropped
    }

    static func demo() -> Self {
        let p = [PlanPoint(x: 0, z: 0), .init(x: 5, z: 0), .init(x: 5, z: 4), .init(x: 0, z: 4)]
        var room = RoomProject(name: "Sample · Studio", isDemo: true)
        room.surfaces = (0..<4).map { i in
            PlanSurface(label: "Wall \(i + 1)", kind: .wall, a: p[i], b: p[(i + 1) % 4], height: 2.7, confidence: .high, evidence: .manual)
        }
        room.surfaces += [
            PlanSurface(label: "Entry", kind: .door, a: .init(x: 0.5, z: 0), b: .init(x: 1.4, z: 0), height: 2.1, parentID: room.surfaces[0].id),
            PlanSurface(label: "Window", kind: .window, a: .init(x: 5, z: 1), b: .init(x: 5, z: 2.8), bottom: 0.9, height: 1.4, parentID: room.surfaces[1].id, reflectiveRisk: true, dividers: [0.9]),
            PlanSurface(label: "Mirror", kind: .mirror, a: .init(x: 2.2, z: 4), b: .init(x: 3.3, z: 4), bottom: 0.4, height: 1.9, parentID: room.surfaces[2].id, reflectiveRisk: true)
        ]
        room.objects = [PlanObject(label: "Table", center: .init(x: 2.6, y: 0.4, z: 1.8), size: .init(x: 1.6, y: 0.8, z: 0.8), yaw: 0)]
        room.captureWarnings = ["Synthetic sample. No physical measurements were captured."]
        return room
    }
}

// Figures for the summary panel and schedules, shared by the app and the PDF sheet.
struct RoomSummary {
    struct Opening { var tag: String; var surface: PlanSurface; var wall: String? }
    var spaces: [Geometry.Space]
    var spaceNames: [String]
    var totalArea: Double?
    var perimeter: Double?
    var ceilingHeight: Double?
    var walls: [PlanSurface]
    var openings: [Opening]
    init(_ room: RoomProject) {
        let walls = room.walls
        let layout = Geometry.spaces(walls)
        let caveat = walls.contains { $0.geometryCaveat != nil }
        if let loop = Geometry.boundary(walls).area {
            let points = Geometry.boundary(walls).points
            spaces = [.init(points: points, area: loop)]; totalArea = loop
            perimeter = points.indices.reduce(0) { $0 + points[$1].distance(to: points[($1 + 1) % points.count]) }
        } else {
            spaces = caveat ? [] : layout.spaces; totalArea = caveat ? nil : layout.total
            perimeter = caveat || layout.outline.isEmpty ? nil : layout.perimeter
        }
        spaceNames = room.spaceNames(spaces)
        let length = walls.reduce(0) { $0 + $1.length }
        ceilingHeight = length > 0 ? walls.reduce(0) { $0 + $1.height * $1.length } / length : nil
        self.walls = walls
        // Tags number each kind in list order: D1, W1, O1, M1.
        var counts: [SurfaceKind: Int] = [:]
        let prefix: [SurfaceKind: String] = [.door: "D", .window: "W", .opening: "O", .mirror: "M"]
        let names = Dictionary(uniqueKeysWithValues: room.surfaces.map { ($0.id, $0.label) })
        openings = room.activeSurfaces.filter { $0.kind != .wall }.map { s in
            counts[s.kind, default: 0] += 1
            return .init(tag: "\(prefix[s.kind] ?? "")\(counts[s.kind]!)", surface: s, wall: s.parentID.flatMap { names[$0] })
        }
    }
}

enum ProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): return text } }
}
