import Foundation

struct PlanBounds {
    var minX: Double; var minZ: Double; var maxX: Double; var maxZ: Double
    var width: Double { max(0.1, maxX - minX) }
    var depth: Double { max(0.1, maxZ - minZ) }
    var center: PlanPoint { .init(x: (minX + maxX) / 2, z: (minZ + maxZ) / 2) }
    init(_ points: [PlanPoint]) {
        minX = points.map(\.x).min() ?? -1; maxX = points.map(\.x).max() ?? 1
        minZ = points.map(\.z).min() ?? -1; maxZ = points.map(\.z).max() ?? 1
    }
}

struct BoundaryResult {
    var points: [PlanPoint]
    var warning: String?
    var area: Double? { warning == nil && points.count >= 3 ? abs(Geometry.signedArea(points)) : nil }
}

enum Geometry {
    static func cross(_ a: PlanPoint, _ b: PlanPoint) -> Double { a.x * b.z - a.z * b.x }
    static func signedArea(_ p: [PlanPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        return p.indices.reduce(0) { $0 + cross(p[$1], p[($1 + 1) % p.count]) } / 2
    }
    static func distance(_ p: PlanPoint, to a: PlanPoint, _ b: PlanPoint) -> Double {
        let d = b - a
        let t = max(0, min(1, (p - a).dot(d) / max(1e-12, d.dot(d))))
        return p.distance(to: a + d * t)
    }

    // A single closed cycle only. Never use a convex hull, which fills alcoves and missed walls.
    // Endpoint clustering is used ONLY for this approximate area, never to alter scan coordinates.
    static func boundary(_ walls: [PlanSurface], tolerance: Double = 0.08) -> BoundaryResult {
        func fail(_ message: String) -> BoundaryResult { .init(points: [], warning: message) }
        guard walls.count >= 3 else { return fail("At least three walls are needed for an enclosed area.") }
        guard !walls.contains(where: { $0.geometryCaveat != nil }) else {
            return fail("Curved surfaces need review; area is unavailable.")
        }
        var nodes: [PlanPoint] = []
        func node(_ p: PlanPoint) -> Int {
            if let i = nodes.firstIndex(where: { $0.distance(to: p) <= tolerance }) { return i }
            nodes.append(p); return nodes.count - 1
        }
        var edges: [(Int, Int)] = []
        for wall in walls {
            let a = node(wall.a), b = node(wall.b)
            guard a != b else { return fail("A wall is shorter than the boundary join tolerance.") }
            guard !edges.contains(where: { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }) else {
                return fail("Duplicate walls prevent a reliable enclosed area.")
            }
            edges.append((a, b))
        }
        var adjacent = Array(repeating: [Int](), count: nodes.count)
        for (a, b) in edges { adjacent[a].append(b); adjacent[b].append(a) }
        guard adjacent.allSatisfy({ $0.count == 2 }) else {
            return fail("Wall ends do not form one closed room. Align corners or remove phantom walls.")
        }
        var order = [0], previous = -1, current = 0
        repeat {
            guard let next = adjacent[current].first(where: { $0 != previous }) else { return fail("Disconnected boundary.") }
            previous = current; current = next
            if current == 0 { break }
            guard !order.contains(current) else { return fail("Boundary contains a loop.") }
            order.append(current)
        } while order.count <= nodes.count
        guard order.count == nodes.count else { return fail("Multiple disconnected rooms; area is unavailable.") }
        let p = order.map { nodes[$0] }
        for i in p.indices {
            for j in p.indices where j > i {
                if j == i + 1 || (i == 0 && j == p.count - 1) { continue }
                if segmentsIntersect(p[i], p[(i + 1) % p.count], p[j], p[(j + 1) % p.count]) {
                    return fail("Walls intersect. Correct the plan before calculating area.")
                }
            }
        }
        guard abs(signedArea(p)) > 0.01 else { return fail("Room has no usable enclosed area.") }
        return .init(points: p, warning: nil)
    }

    // MARK: Enclosed spaces

    struct Space { var points: [PlanPoint]; var area: Double }
    struct SpaceLayout {
        var spaces: [Space]                 // every enclosed space, largest first
        var outline: [PlanPoint]            // outer boundary of the largest connected group of walls
        var total: Double? { spaces.isEmpty ? nil : spaces.reduce(0) { $0 + $1.area } }
        var perimeter: Double { outline.indices.reduce(0) { $0 + outline[$1].distance(to: outline[($1 + 1) % outline.count]) } }
    }

    // Area for spaces a single wall loop can't describe: partitions meeting walls at T-junctions, crossing
    // walls and dead-end stubs. Walls become a planar graph (ends within `tolerance` joined, walls split
    // where another wall ends on or crosses them), dead ends are pruned, and each bounded face is a space.
    // Openings left as gaps between walls stay open, so a space that never closes has no area.
    static func spaces(_ walls: [PlanSurface], tolerance: Double = 0.08) -> SpaceLayout {
        var nodes: [PlanPoint] = []
        func node(_ p: PlanPoint) -> Int {
            if let i = nodes.firstIndex(where: { $0.distance(to: p) <= tolerance }) { return i }
            nodes.append(p); return nodes.count - 1
        }
        let segments = walls.map { (node($0.a), node($0.b)) }.filter { $0.0 != $0.1 }
        // Split points along each segment: nodes lying on it, and crossings with other segments.
        var cuts = segments.map { _ in [Int]() }
        for (i, seg) in segments.enumerated() {
            let a = nodes[seg.0], b = nodes[seg.1]
            for k in nodes.indices where k != seg.0 && k != seg.1 && distance(nodes[k], to: a, b) <= tolerance { cuts[i].append(k) }
            for (j, other) in segments.enumerated() where j > i {
                let c = nodes[other.0], d = nodes[other.1]
                let c1 = cross(b - a, c - a), c2 = cross(b - a, d - a), c3 = cross(d - c, a - c), c4 = cross(d - c, b - c)
                guard c1 * c2 < 0, c3 * c4 < 0, let x = lineIntersection(a, b - a, c, d - c) else { continue }
                let k = node(x); cuts[i].append(k); cuts[j].append(k)
            }
        }
        var edges = Set<[Int]>()
        for (i, seg) in segments.enumerated() {
            let a = nodes[seg.0], d = nodes[seg.1] - a
            let chain = ([seg.0] + cuts[i].sorted { (nodes[$0] - a).dot(d) < (nodes[$1] - a).dot(d) } + [seg.1])
            for (u, v) in zip(chain, chain.dropFirst()) where u != v { edges.insert([min(u, v), max(u, v)]) }
        }
        var adjacent = [Int: Set<Int>]()
        for e in edges { adjacent[e[0], default: []].insert(e[1]); adjacent[e[1], default: []].insert(e[0]) }
        // Dead ends can't bound a space.
        while let leaf = adjacent.first(where: { $0.value.count < 2 })?.key {
            for n in adjacent[leaf] ?? [] { adjacent[n]?.remove(leaf) }
            adjacent[leaf] = nil
        }
        // Walk every directed edge, turning to the next neighbour clockwise at each node, to trace faces.
        func angle(_ from: Int, _ to: Int) -> Double { let v = nodes[to] - nodes[from]; return atan2(v.z, v.x) }
        var sorted = [Int: [Int]]()
        for (n, ns) in adjacent { sorted[n] = ns.sorted { angle(n, $0) < angle(n, $1) } }
        var visited = Set<[Int]>(), faces: [[Int]] = []
        for (u, ns) in sorted { for v in ns where !visited.contains([u, v]) {
            var face: [Int] = [], (a, b) = (u, v)
            while !visited.contains([a, b]), face.count <= edges.count * 2 {
                visited.insert([a, b]); face.append(a)
                guard let ring = sorted[b], let i = ring.firstIndex(of: a) else { break }
                (a, b) = (b, ring[(i + ring.count - 1) % ring.count])
            }
            if face.count >= 3 { faces.append(face) }
        } }
        // Per connected group the outer face has the largest |area| and the opposite winding to its spaces.
        var group = [Int: Int]()
        for start in sorted.keys where group[start] == nil {
            var stack = [start]; group[start] = start
            while let n = stack.popLast() { for m in sorted[n] ?? [] where group[m] == nil { group[m] = start; stack.append(m) } }
        }
        var spaces: [Space] = [], outline: [PlanPoint] = [], largestOuter = 0.0
        for g in Set(group.values) {
            let mine = faces.filter { group[$0[0]] == g }.map { f in (f, signedArea(f.map { nodes[$0] })) }
            guard let outer = mine.max(by: { abs($0.1) < abs($1.1) }) else { continue }
            for (f, a) in mine where a * outer.1 < 0 && abs(a) >= 0.5 { spaces.append(.init(points: f.map { nodes[$0] }, area: abs(a))) }
            if abs(outer.1) > largestOuter { largestOuter = abs(outer.1); outline = outer.0.map { nodes[$0] } }
        }
        return .init(spaces: spaces.sorted { $0.area > $1.area }, outline: outline)
    }

    // Single-loop rooms use boundary(); anything else falls back to the enclosed spaces. Curved walls are only
    // approximated, so they still suppress the area.
    static func floorArea(_ walls: [PlanSurface]) -> Double? {
        if let area = boundary(walls).area { return area }
        guard !walls.contains(where: { $0.geometryCaveat != nil }) else { return nil }
        return spaces(walls).total
    }

    static func contains(_ polygon: [PlanPoint], _ p: PlanPoint, margin: Double) -> Bool {
        contains(polygon, p) && polygon.indices.allSatisfy { distance(p, to: polygon[$0], polygon[($0 + 1) % polygon.count]) >= margin }
    }

    // A point well inside a (possibly concave) polygon for its area label: the grid sample farthest from
    // every edge, so an L-shaped space doesn't put its label in the notch.
    static func labelPoint(_ polygon: [PlanPoint]) -> PlanPoint {
        let bounds = PlanBounds(polygon)
        var best = bounds.center, bestClearance = -1.0
        for i in 0...24 { for j in 0...24 {
            let p = PlanPoint(x: bounds.minX + bounds.width * Double(i) / 24, z: bounds.minZ + bounds.depth * Double(j) / 24)
            guard contains(polygon, p) else { continue }
            let clearance = polygon.indices.map { distance(p, to: polygon[$0], polygon[($0 + 1) % polygon.count]) }.min() ?? 0
            if clearance > bestClearance { best = p; bestClearance = clearance }
        } }
        return best
    }

    static func segmentsIntersect(_ a: PlanPoint, _ b: PlanPoint, _ c: PlanPoint, _ d: PlanPoint) -> Bool {
        let c1 = cross(b - a, c - a), c2 = cross(b - a, d - a)
        let c3 = cross(d - c, a - c), c4 = cross(d - c, b - c)
        if c1 * c2 < 0 && c3 * c4 < 0 { return true }
        let eps = 1e-8
        return (abs(c1) < eps && distance(c, to: a, b) < eps)
            || (abs(c2) < eps && distance(d, to: a, b) < eps)
            || (abs(c3) < eps && distance(a, to: c, d) < eps)
            || (abs(c4) < eps && distance(b, to: c, d) < eps)
    }

    static func attach(_ element: PlanSurface, to wall: PlanSurface, offset: Double, width: Double) -> PlanSurface {
        var result = element
        result.parentID = wall.id
        result.a = wall.a + wall.direction * offset
        result.b = wall.a + wall.direction * (offset + width)
        return result
    }

    // Corner moves update connected wall ends. Child openings retain their distance from wall start.
    static func replace(_ surface: PlanSurface, in project: inout RoomProject, joinCorners: Bool) {
        guard let index = project.surfaces.firstIndex(where: { $0.id == surface.id }) else {
            project.surfaces.append(surface); return
        }
        let before = project.surfaces
        let old = before[index]
        var moved = surface
        if moved.kind == .wall && (old.a != moved.a || old.b != moved.b) { moved.lidarCheck = nil }
        var changed: [UUID: PlanSurface] = [surface.id: moved]
        if joinCorners && old.kind == .wall && surface.kind == .wall {
            // Only ends that actually moved pull their neighbours; saving an unchanged wall must not snap
            // nearby corners together.
            let movedA = old.a.distance(to: surface.a) > 1e-9, movedB = old.b.distance(to: surface.b) > 1e-9
            func follow(_ p: PlanPoint) -> PlanPoint {
                if p.distance(to: old.a) < 0.08 { return movedA ? surface.a : p }
                if p.distance(to: old.b) < 0.08 { return movedB ? surface.b : p }
                return p
            }
            for var other in before where other.kind == .wall && other.id != old.id {
                let original = other
                other.a = follow(other.a); other.b = follow(other.b)
                if other != original {
                    other.lengthCheck = nil; other.reviewed = false; other.evidence = .edited; other.lidarCheck = nil
                    changed[other.id] = other
                }
            }
        }
        for i in project.surfaces.indices {
            if let s = changed[project.surfaces[i].id] { project.surfaces[i] = s }
            else if let parent = project.surfaces[i].parentID,
                    let newWall = changed[parent],
                    let oldWall = before.first(where: { $0.id == parent }), oldWall.kind == .wall {
                let offset = min((project.surfaces[i].a - oldWall.a).dot(oldWall.direction), (project.surfaces[i].b - oldWall.a).dot(oldWall.direction))
                let width = project.surfaces[i].length
                project.surfaces[i] = attach(project.surfaces[i], to: newWall, offset: offset, width: width)
                project.surfaces[i].reviewed = false
            }
        }
        if surface.excluded && surface.kind == .wall {
            for i in project.surfaces.indices where project.surfaces[i].parentID == surface.id {
                project.surfaces[i].excluded = true
            }
        }
    }

    static func contains(_ polygon: [PlanPoint], _ p: PlanPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false, j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.z > p.z) != (b.z > p.z), p.x < (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // Captured walls take their direction from each RoomPlan wall's own axis, so a wall's left-hand
    // normal may face in or out. Probe both sides of the closed boundary; without one, face the
    // centroid of all wall endpoints.
    static func inwardNormal(_ wall: PlanSurface, walls: [PlanSurface], boundary: BoundaryResult) -> PlanPoint {
        let d = wall.direction, n = PlanPoint(x: -d.z, z: d.x), flipped = n * -1
        if boundary.area != nil {
            let probe = min(0.25, max(0.02, wall.length / 4))
            let left = contains(boundary.points, wall.midpoint + n * probe)
            let right = contains(boundary.points, wall.midpoint + flipped * probe)
            if left != right { return left ? n : flipped }
        }
        let ends = walls.flatMap { [$0.a, $0.b] }
        guard !ends.isEmpty else { return n }
        let centroid = ends.reduce(PlanPoint.zero, +) * (1 / Double(ends.count))
        return (centroid - wall.midpoint).dot(n) < 0 ? flipped : n
    }

    // Openings lie on their parent wall, so a tap on one is a near-tie; `openingBias` favours the opening.
    static func surface(at p: PlanPoint, in surfaces: [PlanSurface], threshold: Double, openingBias: Double) -> UUID? {
        surfaces.compactMap { s -> (UUID, Double)? in
            let d = distance(p, to: s.a, s.b)
            return d <= threshold ? (s.id, s.kind == .wall ? d : d - openingBias) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    // Text angle along a segment, turned to read left-to-right or bottom-to-top. Segments within 10° of
    // vertical all read bottom-to-top, so slightly off-axis scanned walls don't flip direction.
    static func uprightTextAngle(dx: Double, dy: Double) -> Double {
        let tolerance = 10 * Double.pi / 180
        var angle = atan2(dy, dx)
        if angle >= .pi / 2 - tolerance { angle -= .pi } else if angle < -.pi / 2 - tolerance { angle += .pi }
        return angle
    }

    // MARK: Automatic cleanup

    static func rotate(_ p: PlanPoint, by angle: Double) -> PlanPoint {
        .init(x: p.x * cos(angle) - p.z * sin(angle), z: p.x * sin(angle) + p.z * cos(angle))
    }

    // Length-weighted dominant wall direction modulo 90°, in (-45°, 45°]: walls at θ and θ + 90° agree.
    static func dominantAngle(_ walls: [PlanSurface]) -> Double {
        var c = 0.0, s = 0.0
        for w in walls { let a = atan2(w.b.z - w.a.z, w.b.x - w.a.x); c += w.length * cos(4 * a); s += w.length * sin(4 * a) }
        return abs(c) < 1e-12 && abs(s) < 1e-12 ? 0 : atan2(s, c) / 4
    }

    static func lineIntersection(_ a: PlanPoint, _ da: PlanPoint, _ b: PlanPoint, _ db: PlanPoint) -> PlanPoint? {
        let den = cross(da, db)
        guard abs(den) > 1e-9 else { return nil }
        return a + da * (cross(b - a, db) / den)
    }

    struct CornerFix { var first: UUID; var firstAtA: Bool; var second: UUID; var secondAtA: Bool; var corner: PlanPoint; var pieces: [UUID] }

    // RoomPlan often closes a corner with one to three short wall pieces (a boxed column or chamfer), which
    // reads as a rounded corner. A fix extends the two long walls along their own lines to meet and hides
    // the pieces. Pieces that host an opening, junctions of more than two walls, near-parallel walls, and
    // corners more than 1 m from either wall end are left alone.
    static func squarableCorners(_ project: RoomProject, shortPiece: Double = 0.6, longWall: Double = 0.9, tolerance: Double = 0.08) -> [CornerFix] {
        let walls = project.walls
        let hosts = Set(project.activeSurfaces.compactMap { $0.kind == .wall ? nil : $0.parentID })
        func end(_ w: PlanSurface, _ atA: Bool) -> PlanPoint { atA ? w.a : w.b }
        func joined(_ p: PlanPoint, except id: UUID) -> [(wall: PlanSurface, atA: Bool)] {
            walls.flatMap { w -> [(wall: PlanSurface, atA: Bool)] in
                w.id == id ? [] : [(w, true), (w, false)].filter { end($0.0, $0.1).distance(to: p) <= tolerance }
            }
        }
        var fixes: [CornerFix] = [], usedEnds = Set<String>(), usedPieces = Set<UUID>()
        for start in walls where start.length >= longWall {
            for startAtA in [true, false] where !usedEnds.contains("\(start.id)\(startAtA)") {
                var pieces: [UUID] = [], current = start, atA = startAtA, total = 0.0
                var reached: (wall: PlanSurface, atA: Bool)?
                while pieces.count <= 3 {
                    let next = joined(end(current, atA), except: current.id)
                    guard next.count == 1 else { break }
                    let hit = next[0]
                    if hit.wall.length >= longWall { if !pieces.isEmpty { reached = hit }; break }
                    guard hit.wall.length < shortPiece, !hosts.contains(hit.wall.id), !pieces.contains(hit.wall.id) else { break }
                    pieces.append(hit.wall.id); total += hit.wall.length
                    current = hit.wall; atA = !hit.atA
                }
                guard let other = reached, other.wall.id != start.id, total <= 1.2,
                      !usedEnds.contains("\(other.wall.id)\(other.atA)"), !pieces.contains(where: usedPieces.contains),
                      abs(start.direction.dot(other.wall.direction)) < 0.87,
                      let corner = lineIntersection(start.a, start.direction, other.wall.a, other.wall.direction),
                      corner.distance(to: end(start, startAtA)) <= 1.0, corner.distance(to: end(other.wall, other.atA)) <= 1.0 else { continue }
                // The moved end must stay on the same side of the fixed end, so neither wall flips or collapses.
                let keeps = [(start, startAtA), (other.wall, other.atA)].allSatisfy { w, a in
                    let fixed = end(w, !a)
                    return (corner - fixed).dot(end(w, a) - fixed) > 0 && corner.distance(to: fixed) >= 0.3
                }
                guard keeps else { continue }
                fixes.append(.init(first: start.id, firstAtA: startAtA, second: other.wall.id, secondAtA: other.atA, corner: corner, pieces: pieces))
                usedEnds.formUnion(["\(start.id)\(startAtA)", "\(other.wall.id)\(other.atA)"]); usedPieces.formUnion(pieces)
            }
        }
        return fixes
    }

    private static func hide(_ id: UUID, reason: AutoCleanup.Reason, in project: inout RoomProject) {
        guard let i = project.surfaces.firstIndex(where: { $0.id == id }) else { return }
        let s = project.surfaces[i]
        if s.autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: reason, originalA: s.a, originalB: s.b) }
        project.surfaces[i].excluded = true
    }

    @discardableResult static func squareCorners(_ project: inout RoomProject) -> Int {
        let fixes = squarableCorners(project)
        for fix in fixes {
            for (id, atA) in [(fix.first, fix.firstAtA), (fix.second, fix.secondAtA)] {
                guard let i = project.surfaces.firstIndex(where: { $0.id == id }) else { continue }
                let s = project.surfaces[i]
                if s.autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: .squaredCorner, originalA: s.a, originalB: s.b) }
                // Moving an end along the wall's own line keeps attached openings exactly where they were.
                if atA { project.surfaces[i].a = fix.corner } else { project.surfaces[i].b = fix.corner }
                project.surfaces[i].evidence = .edited; project.surfaces[i].reviewed = false
            }
            for id in fix.pieces { hide(id, reason: .cornerPiece, in: &project) }
        }
        return fixes.count
    }

    // Short dead-end pieces RoomPlan leaves on long walls: a chain of short walls (joined end to end) is a
    // stub when at most one of its outer ends touches another wall, or a bump when every touching end lies
    // on the same wall. Chains reaching two different walls are corners, handled by squareCorners. Walls
    // hosting an opening are kept.
    static func wallStubs(_ project: RoomProject, maxLength: Double = 0.5, tolerance: Double = 0.08) -> [UUID] {
        let walls = project.walls
        let hosts = Set(project.activeSurfaces.compactMap { $0.kind == .wall ? nil : $0.parentID })
        let short = walls.filter { $0.length < maxLength && !hosts.contains($0.id) }
        func joins(_ p: PlanPoint, _ w: PlanSurface) -> Bool { w.a.distance(to: p) <= tolerance || w.b.distance(to: p) <= tolerance }
        var unvisited = Set(short.map(\.id)), stubs: [UUID] = []
        while let seed = short.first(where: { unvisited.contains($0.id) }) {
            var chain: [PlanSurface] = [], queue = [seed]; unvisited.remove(seed.id)
            while let w = queue.popLast() {
                chain.append(w)
                for other in short where unvisited.contains(other.id) && (joins(w.a, other) || joins(w.b, other)) {
                    unvisited.remove(other.id); queue.append(other)
                }
            }
            let ids = Set(chain.map(\.id))
            let outerEnds = chain.flatMap { [$0.a, $0.b] }.filter { p in chain.filter { joins(p, $0) }.count == 1 }
            let touching = outerEnds.map { p in Set(walls.filter { !ids.contains($0.id) && distance(p, to: $0.a, $0.b) <= tolerance }.map(\.id)) }
            let attached = touching.filter { !$0.isEmpty }
            let oneHost = attached.count <= 1 || (attached.allSatisfy { $0.count == 1 } && Set(attached.flatMap { $0 }).count == 1)
            if oneHost && chain.reduce(0, { $0 + $1.length }) <= 1.5 { stubs += chain.map(\.id) }
        }
        return stubs
    }

    @discardableResult static func hideStubs(_ project: inout RoomProject) -> Int {
        let stubs = wallStubs(project)
        for id in stubs { hide(id, reason: .stub, in: &project) }
        return stubs.count
    }

    @discardableResult static func restoreCleanup(_ project: inout RoomProject) -> Int {
        var restored = 0
        for i in project.surfaces.indices {
            guard let record = project.surfaces[i].autoCleanup else { continue }
            project.surfaces[i].a = record.originalA; project.surfaces[i].b = record.originalB
            if let height = record.originalHeight { project.surfaces[i].height = height }
            if let bottom = record.originalBottom { project.surfaces[i].bottom = bottom }
            if let parent = record.originalParent { project.surfaces[i].parentID = parent }
            if record.reason == .lidarAdded { project.surfaces[i].excluded = true }
            else if ![.squaredCorner, .lidarAligned, .tidied].contains(record.reason) { project.surfaces[i].excluded = false }
            project.surfaces[i].lidarCheck = nil
            project.surfaces[i].autoCleanup = nil; restored += 1
        }
        return restored
    }

    // A new opening centred on the tapped point of its wall, clamped inside the wall, with typical sizes the
    // user then adjusts in the editor.
    static func placeOpening(_ kind: SurfaceKind, on wall: PlanSurface, near p: PlanPoint, label: String) -> PlanSurface {
        let (width, bottom, height): (Double, Double, Double)
        switch kind {
        case .door: (width, bottom, height) = (0.9, 0, 2.03)
        case .window: (width, bottom, height) = (1.2, 0.9, 1.2)
        case .mirror: (width, bottom, height) = (1.0, 0.5, 1.5)
        case .opening, .wall: (width, bottom, height) = (1.0, 0, 2.03)
        }
        let w = min(width, wall.length)
        let offset = min(max(0, (p - wall.a).dot(wall.direction) - w / 2), wall.length - w)
        var s = attach(PlanSurface(label: label, kind: kind, a: .zero, b: .zero), to: wall, offset: offset, width: w)
        s.bottom = wall.bottom + min(bottom, max(0, wall.height - 0.3))
        s.height = max(0.1, min(height, wall.bottom + wall.height - s.bottom))
        s.reflectiveRisk = kind == .window || kind == .mirror
        return s
    }

    static func openingIssue(_ s: PlanSurface, in project: RoomProject) -> String? {
        guard s.kind != .wall else { return nil }
        guard let parent = s.parentID, let wall = project.walls.first(where: { $0.id == parent }) else {
            return "Assign an active parent wall."
        }
        let start = (s.a - wall.a).dot(wall.direction), end = (s.b - wall.a).dot(wall.direction)
        if min(start, end) < -0.03 || max(start, end) > wall.length + 0.03 { return "Extends beyond its parent wall." }
        if distance(s.a, to: wall.a, wall.b) > 0.1 || distance(s.b, to: wall.a, wall.b) > 0.1 { return "Not aligned with its parent wall." }
        if s.bottom < wall.bottom - 0.03 || s.bottom + s.height > wall.bottom + wall.height + 0.03 { return "Height extends beyond its parent wall." }
        return nil
    }
}
