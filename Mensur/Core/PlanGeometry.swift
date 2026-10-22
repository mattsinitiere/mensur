import Foundation

// Plan symbols in world meters, shared by the screen, the PDF, SVG and DXF so they all draw the same thing:
// walls as bands of real thickness, door leaves and swings, stairs, and dimension strings.
enum PlanGeometry {
    typealias Segment = (PlanPoint, PlanPoint)
    struct Arc: Hashable { var center: PlanPoint; var radius: Double; var start: Double; var end: Double }   // radians, plan x/z

    // MARK: Walls with thickness

    // A wall drawn with thickness: one quadrilateral per solid piece between openings (inner edge on the wall
    // line, outer edge offset by the thickness), plus the jamb lines across the thickness at each opening.
    struct WallBand {
        var wall: PlanSurface
        var thickness: Double
        var pieces: [[PlanPoint]]
        var jambs: [Segment]
    }

    // Which side of each wall faces out of the building: walls on the outline grow outward, interior
    // partitions are centred on their line (both of their faces are rooms).
    static func outlineWalls(_ room: RoomProject) -> Set<UUID> {
        let walls = room.walls
        let boundary = Geometry.boundary(walls)
        let outline = boundary.area != nil ? boundary.points : Geometry.spaces(walls).outline
        guard outline.count >= 3 else { return Set(walls.map(\.id)) }
        return Set(walls.filter { w in
            outline.indices.contains { i in
                let a = outline[i], b = outline[(i + 1) % outline.count]
                return Geometry.distance(w.midpoint, to: a, b) < 0.12 && abs((b - a).dot(w.direction)) / max(a.distance(to: b), 1e-9) > 0.98
            }
        }.map(\.id))
    }

    static func wallBands(_ room: RoomProject) -> [WallBand] {
        let walls = room.walls
        let boundary = Geometry.boundary(walls)
        let outer = outlineWalls(room)
        // Each wall's two edges as lines: (point, direction), with its inner/outer offsets.
        func edges(_ w: PlanSurface) -> (inner: PlanPoint, outer: PlanPoint, n: PlanPoint, t: Double)? {
            guard let t = w.drawnThickness, t > 0.005 else { return nil }
            let n = Geometry.inwardNormal(w, walls: walls, boundary: boundary) * -1
            return outer.contains(w.id) ? (.zero, n * t, n, t) : (n * (-t / 2), n * (t / 2), n, t)
        }
        var result: [WallBand] = []
        for w in walls {
            guard let e = edges(w) else { continue }
            let d = w.direction, length = w.length
            // Mitre each end to the neighbour that meets it, so corners close without overlaps or notches.
            func end(_ p: PlanPoint, atA: Bool) -> (inner: PlanPoint, outer: PlanPoint) {
                let plainInner = p + e.inner, plainOuter = p + e.outer
                guard let other = walls.first(where: { $0.id != w.id && ($0.a.distance(to: p) <= 0.08 || $0.b.distance(to: p) <= 0.08) }),
                      abs(other.direction.dot(d)) < 0.985 else { return (plainInner, plainOuter) }
                let o = edges(other)
                let oInner = o?.inner ?? .zero, oOuter = o?.outer ?? .zero
                func meet(_ mine: PlanPoint, _ theirs: PlanPoint) -> PlanPoint? {
                    guard let x = Geometry.lineIntersection(w.a + mine, d, other.a + theirs, other.direction),
                          x.distance(to: p) < 4 * max(e.t, o?.t ?? 0) + 0.05 else { return nil }
                    return x
                }
                // Outer edge meets the neighbour's outer edge; inner edge meets its inner edge.
                return (meet(e.inner, oInner) ?? plainInner, meet(e.outer, oOuter) ?? plainOuter)
            }
            let startEnd = end(w.a, atA: true), finishEnd = end(w.b, atA: false)
            var pieces: [[PlanPoint]] = [], jambs: [Segment] = []
            let visible = DXFExporter.visibleWallSegments(w, room: room)
            for (p0, p1) in visible {
                let u0 = (p0 - w.a).dot(d), u1 = (p1 - w.a).dot(d)
                let i0 = u0 < 0.001 ? startEnd.inner : p0 + e.inner, o0 = u0 < 0.001 ? startEnd.outer : p0 + e.outer
                let i1 = u1 > length - 0.001 ? finishEnd.inner : p1 + e.inner, o1 = u1 > length - 0.001 ? finishEnd.outer : p1 + e.outer
                pieces.append([i0, i1, o1, o0])
                if u0 >= 0.001 { jambs.append((i0, o0)) }
                if u1 <= length - 0.001 { jambs.append((i1, o1)) }
            }
            result.append(.init(wall: w, thickness: e.t, pieces: pieces, jambs: jambs))
        }
        return result
    }

    // Hatching for a convex polygon in its construction type's pattern, `spacing` apart (meters in exports,
    // points on screen). Lines are clipped to the polygon.
    static func hatch(_ polygon: [PlanPoint], type: WallType, spacing: Double) -> [Segment] {
        switch type {
        case .brick: return parallelLines(polygon, angle: .pi / 4, spacing: spacing * 0.6)
        case .block: return parallelLines(polygon, angle: .pi / 4, spacing: spacing) + parallelLines(polygon, angle: -.pi / 4, spacing: spacing)
        case .concrete: return parallelLines(polygon, angle: .pi / 4, spacing: spacing * 1.6)
        case .stud, .glass, .partition: return []
        }
    }

    static func parallelLines(_ polygon: [PlanPoint], angle: Double, spacing: Double) -> [Segment] {
        guard polygon.count >= 3, spacing > 0 else { return [] }
        let d = PlanPoint(x: cos(angle), z: sin(angle)), n = PlanPoint(x: -d.z, z: d.x)
        let offsets = polygon.map { $0.dot(n) }
        guard let lo = offsets.min(), let hi = offsets.max(), (hi - lo) / spacing < 4000 else { return [] }
        var lines: [Segment] = []
        var c = (lo / spacing).rounded(.up) * spacing
        while c <= hi {
            // Where the line {p · n = c} crosses the polygon's edges.
            var hits: [Double] = []
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                let fa = a.dot(n) - c, fb = b.dot(n) - c
                if (fa < 0) != (fb < 0), abs(fa - fb) > 1e-12 {
                    let p = a + (b - a) * (fa / (fa - fb))
                    hits.append(p.dot(d))
                }
            }
            hits.sort()
            var k = 0
            while k + 1 < hits.count {
                lines.append((n * c + d * hits[k], n * c + d * hits[k + 1])); k += 2
            }
            c += spacing
        }
        return lines
    }

    // MARK: Doors

    struct DoorSymbol { var solid: [Segment] = []; var dashed: [Segment] = []; var arcs: [Arc] = [] }

    // The leaf and swing for a door, drawn open into the room (or out of it). A door without a style is a
    // single swing hinged at its a end.
    static func doorSymbol(_ door: PlanSurface, room: RoomProject) -> DoorSymbol {
        let walls = room.walls
        let host = walls.first { $0.id == door.parentID }
        var side = host.map { Geometry.inwardNormal($0, walls: walls, boundary: Geometry.boundary(walls)) } ?? PlanPoint(x: -door.direction.z, z: door.direction.x)
        if door.opensOut == true { side = side * -1 }
        let d = door.direction, w = door.length
        var symbol = DoorSymbol()
        func leaf(hinge: PlanPoint, toward free: PlanPoint, width: Double) {
            let tip = hinge + side * width
            symbol.solid.append((hinge, tip))
            let a0 = atan2((free - hinge).z, (free - hinge).x), a1 = atan2(side.z, side.x)
            var delta = a1 - a0
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            symbol.arcs.append(.init(center: hinge, radius: width, start: a0, end: a0 + delta))
        }
        switch door.doorStyle ?? .swing {
        case .swing:
            let hinge = door.hingeAtB == true ? door.b : door.a, free = door.hingeAtB == true ? door.a : door.b
            leaf(hinge: hinge, toward: free, width: w)
        case .double:
            let mid = door.midpoint
            leaf(hinge: door.a, toward: mid, width: w / 2)
            leaf(hinge: door.b, toward: mid, width: w / 2)
        case .sliding:
            let off = side * 0.03, panel = w * 0.55
            symbol.solid.append((door.a + off, door.a + off + d * panel))
            symbol.solid.append((door.b - off - d * panel, door.b - off))
        case .pocket:
            let pocketEnd = door.hingeAtB == true ? door.b : door.a, dir = door.hingeAtB == true ? d : d * -1
            symbol.dashed.append((pocketEnd, pocketEnd + dir * w))
            symbol.solid.append((pocketEnd + dir * (w * 0.4), pocketEnd - dir * (w * 0.6)))
        case .bifold:
            let q = w / 4
            for (start, dir) in [(door.a, d), (door.b, d * -1)] {
                let peak = start + dir * q + side * q * 0.8
                symbol.solid.append((start, peak)); symbol.solid.append((peak, start + dir * (2 * q)))
            }
        }
        return symbol
    }

    // MARK: Stairs

    struct StairSymbol { var outline: [PlanPoint]; var treads: [Segment]; var arrow: [Segment]; var labelAt: PlanPoint; var label: String }

    static func stairSymbol(_ s: Stair) -> StairSymbol {
        let d = s.direction, n = PlanPoint(x: -d.z, z: d.x) * (s.width / 2)
        let treads = (1..<max(1, s.risers)).map { i -> Segment in
            let c = s.a + d * (s.length * Double(i) / Double(s.risers)); return (c - n, c + n)
        }
        // Arrow up the run: line from the foot to near the head, with a head of two short strokes.
        let tip = s.b - d * min(0.15, s.length * 0.1), back = d * -0.25, wing = PlanPoint(x: -d.z, z: d.x) * 0.15
        let arrow: [Segment] = [(s.a + d * 0.1, tip), (tip, tip + back + wing), (tip, tip + back - wing)]
        return .init(outline: s.corners, treads: treads, arrow: arrow, labelAt: s.a + d * (s.length * 0.25) + n * 0.6, label: s.up ? "UP" : "DN")
    }

    // MARK: Dimension strings

    enum DimensionStyle: String, CaseIterable, Identifiable {
        case walls, chained, running, overall
        var id: String { rawValue }
        var title: String {
            switch self {
            case .walls: return "Each wall"
            case .chained: return "Chained"
            case .running: return "Running"
            case .overall: return "Overall only"
            }
        }
    }

    // One outside face of the plan: collinear outline walls, with every corner and opening edge along it.
    // `origin` lies on the face's outermost line (outside any wall thickness); ticks are distances along
    // `direction` from `origin`, sorted; `normal` points away from the room.
    struct Chain { var origin: PlanPoint; var direction: PlanPoint; var normal: PlanPoint; var ticks: [Double] }

    static func chains(_ room: RoomProject) -> [Chain] {
        let walls = room.walls, outer = outlineWalls(room), boundary = Geometry.boundary(walls)
        var groups: [[PlanSurface]] = []
        for w in walls where outer.contains(w.id) && w.length >= 0.05 {
            if let i = groups.firstIndex(where: { g in
                let r = g[0]
                return abs(r.direction.dot(w.direction)) > 0.9995
                    && abs((w.midpoint - r.a).dot(PlanPoint(x: -r.direction.z, z: r.direction.x))) < 0.06
            }) { groups[i].append(w) } else { groups.append([w]) }
        }
        return groups.compactMap { group in
            let ref = group.max { $0.length < $1.length }!
            var d = ref.direction
            let n = Geometry.inwardNormal(ref, walls: walls, boundary: boundary) * -1
            // Read left to right / bottom to top in plan coordinates.
            if d.x < -1e-9 || (abs(d.x) < 1e-9 && d.z < 0) { d = d * -1 }
            let thickness = group.compactMap(\.drawnThickness).max() ?? 0
            let origin = ref.a + n * thickness
            var ticks: [Double] = []
            for w in group {
                ticks += [(w.a - origin).dot(d), (w.b - origin).dot(d)]
                for s in room.activeSurfaces where s.parentID == w.id && s.kind.isCutout {
                    ticks += [(s.a - origin).dot(d), (s.b - origin).dot(d)]
                }
            }
            ticks.sort()
            var unique: [Double] = []
            for t in ticks where unique.last.map({ t - $0 > 0.01 }) ?? true { unique.append(t) }
            guard unique.count >= 2 else { return nil }
            return Chain(origin: origin, direction: d, normal: n, ticks: unique)
        }
    }
}
