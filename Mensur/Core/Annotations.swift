import Foundation

// Everything a room carries beyond its walls and openings: construction types, door styles, finishes, markers,
// photos, ceiling features, stairs, the building and floor it belongs to, job details and the scan report.
// All of it is optional on the project, so rooms saved before it existed decode unchanged (schemaVersion 1).

// A wall's line is its inside face (what RoomPlan measures); thickness extends outward from the room.
enum WallType: String, Codable, CaseIterable, Identifiable {
    case stud, block, brick, concrete, glass, partition
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stud: return "Stud"
        case .block: return "Concrete block"
        case .brick: return "Brick"
        case .concrete: return "Poured concrete"
        case .glass: return "Glass"
        case .partition: return "Partition"
        }
    }
    // Typical overall thickness including finishes, used until one is measured or typed.
    var defaultThickness: Double {
        switch self {
        case .stud: return 0.12
        case .block: return 0.20
        case .brick: return 0.23
        case .concrete: return 0.25
        case .glass: return 0.05
        case .partition: return 0.10
        }
    }
}

// Where a wall's thickness came from: typed in, measured at a door or window reveal, or the type's default.
enum ThicknessSource: String, Codable { case typed, reveal, typeDefault }

enum DoorStyle: String, Codable, CaseIterable, Identifiable {
    case swing, double, sliding, pocket, bifold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .swing: return "Swing"
        case .double: return "Double swing"
        case .sliding: return "Sliding"
        case .pocket: return "Pocket"
        case .bifold: return "Bifold"
        }
    }
}

// Who and what the room is for. Rooms with the same client and project group together in the library.
struct JobInfo: Codable, Hashable {
    var client = ""
    var project = ""
    var number = ""
    var tags: [String] = []
    var isEmpty: Bool { client.isEmpty && project.isEmpty && number.isEmpty && tags.isEmpty }
    var groupName: String? {
        let parts = [client, project].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// The building and floor a room belongs to. Rooms with the same building name form one building.
// frame: rooms scanned in one continuous session share the scan's coordinates and line up exactly; others
// are placed with offset and rotation (moved by hand or by matching a stair on the floor below).
struct FloorLevel: Codable, Hashable {
    var building: String
    var floor: Int = 0                   // 0 ground, 1 the floor above, -1 a basement
    var name: String? = nil
    var elevation: Double? = nil         // finished floor above the ground floor's, meters
    var frame: UUID? = nil
    var offset: PlanPoint = .zero
    var rotation: Double = 0
    var displayName: String {
        if let name, !name.isEmpty { return name }
        switch floor {
        case 0: return "Ground floor"
        case ..<0: return floor == -1 ? "Basement" : "Basement \(-floor)"
        default: return "Floor \(floor + 1)"
        }
    }
    // Where a point of this room sits in the building's plan.
    func place(_ p: PlanPoint) -> PlanPoint { Geometry.rotate(p, by: rotation) + offset }
}

enum MarkerCategory: String { case electrical, plumbing, hvac, other }

enum MarkerKind: String, Codable, CaseIterable, Identifiable {
    case outlet, gfciOutlet, switchSingle, light, data, thermostat, panel, smokeDetector
    case sink, toilet, shower, tub, floorDrain, waterHeater, hoseBibb, gas
    case supplyVent, returnVent, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .outlet: return "Outlet"
        case .gfciOutlet: return "GFCI outlet"
        case .switchSingle: return "Switch"
        case .light: return "Light"
        case .data: return "Data / TV"
        case .thermostat: return "Thermostat"
        case .panel: return "Electrical panel"
        case .smokeDetector: return "Smoke detector"
        case .sink: return "Sink"
        case .toilet: return "Toilet"
        case .shower: return "Shower"
        case .tub: return "Tub"
        case .floorDrain: return "Floor drain"
        case .waterHeater: return "Water heater"
        case .hoseBibb: return "Hose bibb"
        case .gas: return "Gas line"
        case .supplyVent: return "Supply vent"
        case .returnVent: return "Return vent"
        case .other: return "Other"
        }
    }
    // The short plan symbol, as on an electrical or plumbing drawing.
    var code: String {
        switch self {
        case .outlet: return "R"
        case .gfciOutlet: return "GF"
        case .switchSingle: return "S"
        case .light: return "L"
        case .data: return "D"
        case .thermostat: return "T"
        case .panel: return "P"
        case .smokeDetector: return "SD"
        case .sink: return "SK"
        case .toilet: return "WC"
        case .shower: return "SH"
        case .tub: return "TB"
        case .floorDrain: return "FD"
        case .waterHeater: return "WH"
        case .hoseBibb: return "HB"
        case .gas: return "G"
        case .supplyVent: return "SV"
        case .returnVent: return "RV"
        case .other: return "•"
        }
    }
    var category: MarkerCategory {
        switch self {
        case .outlet, .gfciOutlet, .switchSingle, .light, .data, .thermostat, .panel, .smokeDetector: return .electrical
        case .sink, .toilet, .shower, .tub, .floorDrain, .waterHeater, .hoseBibb, .gas: return .plumbing
        case .supplyVent, .returnVent: return .hvac
        case .other: return .other
        }
    }
    var symbol: String {
        switch category {
        case .electrical: return self == .light ? "lightbulb" : "bolt"
        case .plumbing: return "drop"
        case .hvac: return "wind"
        case .other: return "mappin"
        }
    }
    // Typical mounting height above the floor, filled in when a marker is placed on the plan.
    var typicalHeight: Double? {
        switch self {
        case .outlet, .gfciOutlet, .data: return 0.4
        case .switchSingle, .thermostat: return 1.2
        case .light, .smokeDetector, .supplyVent: return nil
        case .panel: return 1.5
        default: return nil
        }
    }
}

struct PlanMarker: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: MarkerKind
    var position: PlanPoint
    var height: Double? = nil            // above the floor; nil for floor or ceiling fixtures
    var label: String = ""
    var note: String = ""
}

// A reference photo pinned to a place on the plan. The image lives in the room's Photos folder as
// <id>.jpg; it is never used to build geometry.
struct PinnedPhoto: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var position: PlanPoint
    var heading: Double? = nil           // radians in plan coordinates, when taken during a scan
    var caption: String = ""
    var takenAt: Date = Date()
    var file: String { "Photos/\(id.uuidString).jpg" }
}

enum CeilingKind: String, Codable, CaseIterable, Identifiable {
    case soffit, beam, slope, vault
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// A ceiling feature over the rectangle centred on a→b, `width` wide. Heights are above the floor:
// soffit and beam: underside at `low`; slope: `low` along the a end rising to `high` at the b end;
// vault: `low` at the two long edges rising to `high` along the a→b axis (an elliptical barrel).
struct CeilingFeature: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: CeilingKind
    var a: PlanPoint
    var b: PlanPoint
    var width: Double
    var low: Double
    var high: Double? = nil
    var label: String = ""
    var detected = false                 // found in the LiDAR ceiling points rather than drawn by hand
    var length: Double { a.distance(to: b) }
    var direction: PlanPoint { length > 1e-8 ? (b - a) * (1 / length) : .init(x: 1, z: 0) }
    var corners: [PlanPoint] {
        let n = PlanPoint(x: -direction.z, z: direction.x) * (width / 2)
        return [a - n, b - n, b + n, a + n]
    }
    var footprintArea: Double { length * width }
    // Ceiling height at a point inside the footprint.
    func height(at p: PlanPoint) -> Double {
        let top = high ?? low
        switch kind {
        case .soffit, .beam: return low
        case .slope:
            let t = max(0, min(1, (p - a).dot(direction) / max(length, 1e-6)))
            return low + (top - low) * t
        case .vault:
            let n = PlanPoint(x: -direction.z, z: direction.x)
            let d = min(1, abs((p - a).dot(n)) / max(width / 2, 1e-6))
            return low + (top - low) * (1 - d * d).squareRoot()
        }
    }
    // Mean height over the footprint.
    var averageHeight: Double {
        let top = high ?? low
        switch kind {
        case .soffit, .beam: return low
        case .slope: return (low + top) / 2
        case .vault: return low + (top - low) * Double.pi / 4
        }
    }
    // Ceiling surface area over the footprint (the sloped or curved surface, not its plan area). Soffits and
    // beams add their vertical sides down from `roomCeiling`.
    func surfaceArea(roomCeiling: Double) -> Double {
        let top = high ?? low
        switch kind {
        case .soffit:
            return footprintArea + 2 * (length + width) * max(0, roomCeiling - low)
        case .beam:
            return footprintArea + 2 * length * max(0, roomCeiling - low)
        case .slope:
            let rise = top - low
            return width * (length * length + rise * rise).squareRoot()
        case .vault:
            // Half the perimeter of an ellipse with semi-axes width/2 and the rise (Ramanujan).
            let a = width / 2, b = max(0, top - low)
            let h = pow(a - b, 2) / max(pow(a + b, 2), 1e-12)
            let half = Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot())) / 2
            return half * length
        }
    }
}

// A stair in plan: the run from a (foot) to b (head), `width` wide. `up` says whether it climbs from this
// floor to `toFloor` (drawn "UP") or comes down from it ("DN").
struct Stair: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var a: PlanPoint
    var b: PlanPoint
    var width: Double = 0.9
    var risers: Int = 14
    var up = true
    var toFloor: Int? = nil
    var label: String = ""
    var length: Double { a.distance(to: b) }
    var direction: PlanPoint { length > 1e-8 ? (b - a) * (1 / length) : .init(x: 1, z: 0) }
    var corners: [PlanPoint] {
        let n = PlanPoint(x: -direction.z, z: direction.x) * (width / 2)
        return [a - n, b - n, b + n, a + n]
    }
}

// How the scan went, for judging how far to trust it. Distances in meters, times in seconds.
struct ScanReport: Codable, Hashable {
    var passes = 1                       // scans merged into this room (1, or more after resuming)
    var pathLength: Double = 0           // how far the phone travelled
    var duration: Double = 0
    var limitedTracking: Double = 0      // time ARKit reported limited tracking
    var relocalizations = 0              // times tracking was lost and found again
    var corrections = 0                  // sudden position jumps: ARKit correcting accumulated drift
    var largestCorrection: Double = 0
    var resumedFromMap = false
    // The widest gap RoomPlan left between wall ends that should meet, before the app closed it. A scan
    // that drifted tends to leave its last corner open.
    var largestCornerGap: Double? = nil
}

// MARK: Finding, moving and removing plan items

extension RoomProject {
    enum ItemKind { case surface, object, marker, photo, stair, ceiling }

    func itemKind(_ id: UUID) -> ItemKind? {
        if surfaces.contains(where: { $0.id == id }) { return .surface }
        if objects.contains(where: { $0.id == id }) { return .object }
        if markers?.contains(where: { $0.id == id }) == true { return .marker }
        if photos?.contains(where: { $0.id == id }) == true { return .photo }
        if stairs?.contains(where: { $0.id == id }) == true { return .stair }
        if ceilings?.contains(where: { $0.id == id }) == true { return .ceiling }
        return nil
    }

    // Markers and photo pins within `pin` meters of p (nearest first), else a stair, piece of furniture or
    // ceiling feature whose footprint contains p, smallest first so one inside another can still be picked.
    func annotation(at p: PlanPoint, pin: Double) -> UUID? {
        let pins = (markers ?? []).map { ($0.id, $0.position.distance(to: p)) } + (photos ?? []).map { ($0.id, $0.position.distance(to: p)) }
        if let nearest = pins.filter({ $0.1 <= pin }).min(by: { $0.1 < $1.1 }) { return nearest.0 }
        var areas: [(UUID, Double)] = []
        for s in stairs ?? [] where Geometry.contains(s.corners, p) { areas.append((s.id, s.length * s.width)) }
        for o in objects where !o.excluded && Geometry.contains(o.corners, p) { areas.append((o.id, o.size.x * o.size.z)) }
        for c in ceilings ?? [] where Geometry.contains(c.corners, p) { areas.append((c.id, c.footprintArea + 1000)) }   // ceilings last
        return areas.min { $0.1 < $1.1 }?.0
    }

    mutating func move(_ id: UUID, by d: PlanPoint) {
        if let i = objects.firstIndex(where: { $0.id == id }) { objects[i].center.x += d.x; objects[i].center.z += d.z }
        if let i = markers?.firstIndex(where: { $0.id == id }) { markers![i].position = markers![i].position + d }
        if let i = photos?.firstIndex(where: { $0.id == id }) { photos![i].position = photos![i].position + d }
        if let i = stairs?.firstIndex(where: { $0.id == id }) { stairs![i].a = stairs![i].a + d; stairs![i].b = stairs![i].b + d }
        if let i = ceilings?.firstIndex(where: { $0.id == id }) { ceilings![i].a = ceilings![i].a + d; ceilings![i].b = ceilings![i].b + d }
    }

    // Turns furniture, a stair or a ceiling feature about its centre.
    mutating func rotate(_ id: UUID, by angle: Double) {
        func turn(_ p: PlanPoint, about c: PlanPoint) -> PlanPoint { c + Geometry.rotate(p - c, by: angle) }
        if let i = objects.firstIndex(where: { $0.id == id }) { objects[i].yaw += angle }
        if let i = stairs?.firstIndex(where: { $0.id == id }) {
            let c = (stairs![i].a + stairs![i].b) * 0.5; stairs![i].a = turn(stairs![i].a, about: c); stairs![i].b = turn(stairs![i].b, about: c)
        }
        if let i = ceilings?.firstIndex(where: { $0.id == id }) {
            let c = (ceilings![i].a + ceilings![i].b) * 0.5; ceilings![i].a = turn(ceilings![i].a, about: c); ceilings![i].b = turn(ceilings![i].b, about: c)
        }
    }

    mutating func removeItem(_ id: UUID) {
        objects.removeAll { $0.id == id }
        markers?.removeAll { $0.id == id }; if markers?.isEmpty == true { markers = nil }
        photos?.removeAll { $0.id == id }; if photos?.isEmpty == true { photos = nil }
        stairs?.removeAll { $0.id == id }; if stairs?.isEmpty == true { stairs = nil }
        ceilings?.removeAll { $0.id == id }; if ceilings?.isEmpty == true { ceilings = nil }
    }
}

extension PlanObject {
    var corners: [PlanPoint] {
        let d = PlanPoint(x: cos(yaw), z: sin(yaw)) * (size.x / 2), n = PlanPoint(x: -sin(yaw), z: cos(yaw)) * (size.z / 2)
        let c = PlanPoint(x: center.x, z: center.z)
        return [c - d - n, c + d - n, c + d + n, c - d + n]
    }
}

// MARK: Showcase

extension RoomProject {
    // The tour's sample: a small office and store room with every kind of annotation, so a first look shows
    // what a finished plan can carry. Synthetic: no physical measurements.
    static func showcase() -> Self {
        let p = [PlanPoint(x: 0, z: 0), .init(x: 6, z: 0), .init(x: 6, z: 4.5), .init(x: 0, z: 4.5)]
        var room = RoomProject(name: "Sample · Office tour", isDemo: true)
        room.surfaces = (0..<4).map { i in
            PlanSurface(label: "Wall \(i + 1)", kind: .wall, a: p[i], b: p[(i + 1) % 4], height: 2.7, confidence: .high, evidence: .manual,
                        wallType: .block, thickness: 0.2, thicknessSource: .reveal)
        }
        let partition = PlanSurface(label: "Wall 5", kind: .wall, a: .init(x: 4.2, z: 0), b: .init(x: 4.2, z: 4.5), height: 2.7, wallType: .stud)
        room.surfaces.append(partition)
        room.surfaces += [
            PlanSurface(label: "Entry", kind: .door, a: .init(x: 0.6, z: 0), b: .init(x: 1.5, z: 0), height: 2.1, parentID: room.surfaces[0].id, revealDepth: 0.2),
            PlanSurface(label: "Store door", kind: .door, a: .init(x: 4.2, z: 3.2), b: .init(x: 4.2, z: 4.0), height: 2.1, parentID: partition.id, doorStyle: .pocket),
            PlanSurface(label: "Window", kind: .window, a: .init(x: 0, z: 1.2), b: .init(x: 0, z: 3.2), bottom: 0.9, height: 1.4, parentID: room.surfaces[3].id,
                        reflectiveRisk: true, dividers: [1.0], revealDepth: 0.2)
        ]
        room.objects = [
            PlanObject(label: "Desk", center: .init(x: 2.2, y: 0.38, z: 3.6), size: .init(x: 1.52, y: 0.76, z: 0.76), yaw: 0),
            PlanObject(label: "Office chair", center: .init(x: 2.2, y: 0.5, z: 2.9), size: .init(x: 0.66, y: 1.0, z: 0.66), yaw: 0),
            PlanObject(label: "Shelving unit", center: .init(x: 5.1, y: 0.9, z: 0.4), size: .init(x: 1.2, y: 1.8, z: 0.45), yaw: 0)
        ]
        room.markers = [
            PlanMarker(kind: .outlet, position: .init(x: 1.2, z: 4.4), height: 0.4, label: "Desk circuit"),
            PlanMarker(kind: .data, position: .init(x: 2.9, z: 4.4), height: 0.4),
            PlanMarker(kind: .switchSingle, position: .init(x: 1.7, z: 0.1), height: 1.2),
            PlanMarker(kind: .light, position: .init(x: 2.1, z: 2.2)),
            PlanMarker(kind: .panel, position: .init(x: 5.9, z: 2.2), height: 1.5, label: "Sub-panel B"),
            PlanMarker(kind: .sink, position: .init(x: 5.6, z: 4.1))
        ]
        room.ceilings = [
            CeilingFeature(kind: .soffit, a: .init(x: 4.2, z: 0.9), b: .init(x: 6, z: 0.9), width: 1.8, low: 2.4, label: "Duct soffit"),
            CeilingFeature(kind: .beam, a: .init(x: 0, z: 2.25), b: .init(x: 4.2, z: 2.25), width: 0.3, low: 2.45, label: "Beam")
        ]
        let office = Geometry.Space(points: [.init(x: 0, z: 0), .init(x: 4.2, z: 0), .init(x: 4.2, z: 4.5), .init(x: 0, z: 4.5)], area: 18.9)
        let store = Geometry.Space(points: [.init(x: 4.2, z: 0), .init(x: 6, z: 0), .init(x: 6, z: 4.5), .init(x: 4.2, z: 4.5)], area: 8.1)
        room.setSpaceLabel(SpaceLabel(name: "Office", anchor: .zero, floorFinish: "LVP", wallFinish: "Paint · eggshell", ceilingFinish: "ACT 2×2", baseFinish: "Rubber 4″"), for: office)
        room.setSpaceLabel(SpaceLabel(name: "Store", anchor: .zero, floorFinish: "Sealed concrete", wallFinish: "Paint · satin", baseFinish: "Rubber 4″"), for: store)
        room.job = JobInfo(client: "Sample client", project: "Office refit", number: "1024", tags: ["flooring", "sample"])
        room.captureWarnings = ["Synthetic sample for the tour. No physical measurements were captured."]
        return room
    }
}
