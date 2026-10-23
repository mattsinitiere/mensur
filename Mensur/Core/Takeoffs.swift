import Foundation

// Quantities for estimating finishes, in square and cubic meters and meters. Approximate: they follow the
// walls' inside faces, the measured or typed ceiling heights and any ceiling features drawn on the plan.
struct Takeoff {
    struct WallLine { var wall: PlanSurface; var gross: Double; var openings: Double; var net: Double }
    struct SpaceLine {
        var name: String
        var label: SpaceLabel?
        var floorArea: Double
        var perimeter: Double
        var ceilingHeight: Double
        var ceilingArea: Double
        var volume: Double
        var baseboard: Double          // perimeter less door and opening widths
    }
    var walls: [WallLine]
    var spaces: [SpaceLine]
    var floorArea: Double
    var ceilingArea: Double
    var volume: Double
    var wallGross: Double
    var wallOpenings: Double
    var wallNet: Double
    var baseboard: Double
    var ceilingHeight: Double?

    init(_ room: RoomProject) {
        let summary = RoomSummary(room)
        let height = summary.ceilingHeight ?? 0
        ceilingHeight = summary.ceilingHeight
        // Walls: inside face, less the doors, windows and openings cut into it. Mirrors hang on the wall, so
        // they stay in the wall area.
        walls = room.walls.map { w in
            let gross = w.length * w.height
            let cut = room.activeSurfaces.filter { $0.parentID == w.id && $0.kind.isCutout && Geometry.openingIssue($0, in: room) == nil }
                .reduce(0.0) { sum, o in
                    let top = min(o.bottom + o.height, w.bottom + w.height), bottom = max(o.bottom, w.bottom)
                    return sum + max(0, o.length) * max(0, top - bottom)
                }
            return WallLine(wall: w, gross: gross, openings: min(cut, gross), net: max(0, gross - cut))
        }
        wallGross = walls.reduce(0) { $0 + $1.gross }
        wallOpenings = walls.reduce(0) { $0 + $1.openings }
        wallNet = walls.reduce(0) { $0 + $1.net }

        let doorWidths: [(PlanPoint, PlanPoint)] = room.activeSurfaces.filter { $0.kind == .door || $0.kind == .opening }.map { ($0.a, $0.b) }
        let features = room.ceilings ?? []
        spaces = summary.spaces.enumerated().map { i, space in
            let perimeter = space.points.indices.reduce(0.0) { $0 + space.points[$1].distance(to: space.points[($1 + 1) % space.points.count]) }
            // Openings whose ends both sit on this space's outline come off its baseboard.
            let gaps = doorWidths.filter { a, b in
                [a, b].allSatisfy { p in space.points.indices.contains { Geometry.distance(p, to: space.points[$0], space.points[($0 + 1) % space.points.count]) < 0.12 } }
            }.reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            // Ceiling features count toward the space that contains their centre.
            let inside = features.filter { Geometry.contains(space.points, ($0.a + $0.b) * 0.5) }
            var ceilingArea = space.area, volume = space.area * height
            for f in inside {
                let footprint = min(f.footprintArea, space.area)
                ceilingArea += f.surfaceArea(roomCeiling: height) - footprint
                volume += footprint * (f.averageHeight - height)
            }
            return SpaceLine(name: summary.spaceNames[i], label: room.spaceLabel(space), floorArea: space.area, perimeter: perimeter,
                             ceilingHeight: height, ceilingArea: max(0, ceilingArea), volume: max(0, volume), baseboard: max(0, perimeter - gaps))
        }
        floorArea = summary.totalArea ?? spaces.reduce(0) { $0 + $1.floorArea }
        ceilingArea = spaces.reduce(0) { $0 + $1.ceilingArea }
        volume = spaces.reduce(0) { $0 + $1.volume }
        baseboard = spaces.reduce(0) { $0 + $1.baseboard }
    }

    // Cubic meters as cubic feet or cubic meters.
    static func volumeLabel(_ m3: Double, units: DisplayUnits) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = units == .metric ? 1 : 0; f.minimumFractionDigits = f.maximumFractionDigits
        let value = units == .metric ? m3 : m3 * 35.3146667
        return (f.string(from: NSNumber(value: value)) ?? "\(value)") + (units == .metric ? " m³" : " cu ft")
    }
    // Linear meters as feet (whole) or meters.
    static func runLabel(_ m: Double, units: DisplayUnits) -> String {
        units == .metric ? String(format: "%.1f m", m) : String(format: "%.0f ft", (m / 0.3048).rounded())
    }
}
