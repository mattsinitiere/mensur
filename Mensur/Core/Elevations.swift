import Foundation

// Each wall drawn flat, as seen from inside the room: its outline with the doors, windows, openings and
// mirrors on it, and any markers mounted on it. x runs left to right from the viewer's left end, y up from
// the floor, both in meters.
struct Elevation {
    // xa: where the surface's own a end falls, so a door's hinge side can be found.
    struct Item { var id: UUID; var tag: String; var kind: SurfaceKind; var x0: Double; var x1: Double; var y0: Double; var y1: Double; var xa: Double; var surface: PlanSurface }
    struct Mark { var kind: MarkerKind; var x: Double; var y: Double; var label: String }
    var wall: PlanSurface
    var number: Int
    var width: Double
    var bottom: Double
    var height: Double
    var items: [Item]
    var marks: [Mark]

    static func all(_ room: RoomProject) -> [Elevation] {
        let summary = RoomSummary(room), walls = room.walls, boundary = Geometry.boundary(walls)
        let tags = Dictionary(uniqueKeysWithValues: summary.openings.map { ($0.surface.id, $0.tag) })
        return summary.walls.enumerated().map { index, w in
            // A viewer inside faces the wall (opposite its inward normal); their right is the elevation's +x.
            let facing = Geometry.inwardNormal(w, walls: walls, boundary: boundary) * -1
            let right = PlanPoint(x: -facing.z, z: facing.x)
            let ua = (w.a - w.a).dot(right), ub = (w.b - w.a).dot(right)
            let left = min(ua, ub)
            func x(_ p: PlanPoint) -> Double { (p - w.a).dot(right) - left }
            let items = room.activeSurfaces.filter { $0.parentID == w.id && $0.kind != .wall }.map { s in
                Item(id: s.id, tag: tags[s.id] ?? "", kind: s.kind, x0: min(x(s.a), x(s.b)), x1: max(x(s.a), x(s.b)),
                     y0: s.bottom - w.bottom, y1: s.bottom + s.height - w.bottom, xa: x(s.a), surface: s)
            }
            let marks = (room.markers ?? []).compactMap { m -> Mark? in
                guard let h = m.height, Geometry.distance(m.position, to: w.a, w.b) <= 0.2 else { return nil }
                let t = x(m.position)
                guard t >= -0.05, t <= w.length + 0.05 else { return nil }
                return Mark(kind: m.kind, x: t, y: h, label: m.label)
            }
            return Elevation(wall: w, number: index + 1, width: w.length, bottom: w.bottom, height: w.height, items: items, marks: marks)
        }
    }
}
