import Foundation

// Tidy wall joins after a scan. RoomPlan estimates each wall on its own, so corners come out a degree or two off
// square, wall ends stop a few centimetres short of each other, and one straight wall is sometimes split into
// pieces. In order:
//   1. square: walls within 3° of the room's main axes are turned exactly onto them (about their middle);
//      corners that were joined are rejoined where the new lines cross.
//   2. close: a wall end that touches nothing is joined to a nearby free end (an L corner) or run onto a
//      nearby wall (a T junction), when the move is short.
//   3. merge: two pieces joined end to end, in line (within 2° and 3 cm) and with nothing else at the joint,
//      become one wall; the second piece's openings move onto it.
// Every change keeps RoomPlan's version in autoCleanup, so Review → Restore puts it back.
enum WallJoins {
    struct Report: Equatable { var squared = 0, joined = 0, merged = 0 }
    static let squareWithin = 3 * Double.pi / 180, joint = 0.08

    @discardableResult
    static func apply(_ project: inout RoomProject) -> Report {
        var report = Report()
        report.squared = square(&project)
        report.joined = close(&project)
        report.merged = merge(&project)
        return report
    }

    static func record(_ project: inout RoomProject, _ i: Int, _ reason: AutoCleanup.Reason = .tidied) {
        let s = project.surfaces[i]
        if s.autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: reason, originalA: s.a, originalB: s.b) }
        project.surfaces[i].evidence = .edited; project.surfaces[i].reviewed = false; project.surfaces[i].lidarCheck = nil
    }

    // Openings keep their distance from their wall's start when the wall moves.
    static func reattach(_ project: inout RoomProject, before: [UUID: PlanSurface]) {
        for i in project.surfaces.indices where project.surfaces[i].kind != .wall {
            guard let parent = project.surfaces[i].parentID, let old = before[parent],
                  let wall = project.surfaces.first(where: { $0.id == parent }), old.a != wall.a || old.b != wall.b else { continue }
            let s = project.surfaces[i]
            let ta = (s.a - old.a).dot(old.direction), tb = (s.b - old.a).dot(old.direction)
            record(&project, i)
            project.surfaces[i].a = wall.a + wall.direction * ta; project.surfaces[i].b = wall.a + wall.direction * tb
        }
    }

    // Ends of active walls that meet (within `joint`), as groups of (wall index, is end a).
    static func joints(_ project: RoomProject) -> [[(Int, Bool)]] {
        let ends = project.surfaces.indices.filter { project.surfaces[$0].kind == .wall && !project.surfaces[$0].excluded }
            .flatMap { [($0, true), ($0, false)] }
        func point(_ e: (Int, Bool)) -> PlanPoint { e.1 ? project.surfaces[e.0].a : project.surfaces[e.0].b }
        var groups: [[(Int, Bool)]] = [], used = Set<Int>()
        for (k, e) in ends.enumerated() where !used.contains(k) {
            var group = [e]; used.insert(k)
            for (m, f) in ends.enumerated() where !used.contains(m) && f.0 != e.0 && point(f).distance(to: point(e)) <= joint {
                group.append(f); used.insert(m)
            }
            if group.count > 1 { groups.append(group) }
        }
        return groups
    }

    // MARK: 1. Square

    static func square(_ project: inout RoomProject) -> Int {
        let walls = project.walls.filter { $0.length >= 0.3 }
        guard walls.count >= 3 else { return 0 }
        // The room's axis from the walls that agree with it (within 1°), so one leaning wall can't tilt it.
        let rough = Geometry.dominantAngle(walls)
        let agreeing = walls.filter { abs(remainder(atan2($0.direction.z, $0.direction.x) - rough, .pi / 2)) <= .pi / 180 }
        let axis = agreeing.isEmpty ? rough : Geometry.dominantAngle(agreeing), groups = joints(project)
        let before = Dictionary(uniqueKeysWithValues: project.surfaces.map { ($0.id, $0) })
        var lines: [Int: (PlanPoint, PlanPoint)] = [:]          // wall index → (point on line, direction)
        var turned = Set<Int>()
        for i in project.surfaces.indices where project.surfaces[i].kind == .wall && !project.surfaces[i].excluded {
            let w = project.surfaces[i]
            lines[i] = (w.midpoint, w.direction)
            guard w.length >= 0.3 else { continue }
            let angle = atan2(w.direction.z, w.direction.x)
            let off = remainder(angle - axis, .pi / 2)
            guard abs(off) > 0.1 * .pi / 180, abs(off) <= squareWithin else { continue }
            lines[i] = (w.midpoint, Geometry.rotate(w.direction, by: -off)); turned.insert(i)
        }
        guard !turned.isEmpty else { return 0 }
        func onLine(_ i: Int, _ p: PlanPoint) -> PlanPoint { let l = lines[i]!; return l.0 + l.1 * (p - l.0).dot(l.1) }
        var ends: [Int: (a: PlanPoint, b: PlanPoint)] = [:]
        for i in turned { let w = project.surfaces[i]; ends[i] = (onLine(i, w.a), onLine(i, w.b)) }
        // Rejoin each joint touching a turned wall where the lines cross (average over pairs).
        for group in groups where group.contains(where: { turned.contains($0.0) }) {
            var crossings: [PlanPoint] = []
            for (k, e) in group.enumerated() { for f in group[(k + 1)...] {
                let le = lines[e.0]!, lf = lines[f.0]!
                if abs(le.1.dot(lf.1)) < 0.94, let x = Geometry.lineIntersection(le.0, le.1, lf.0, lf.1) { crossings.append(x) }
            } }
            guard !crossings.isEmpty else { continue }
            let corner = crossings.reduce(PlanPoint(x: 0, z: 0), +) * (1 / Double(crossings.count))
            let original = group.map { $0.1 ? project.surfaces[$0.0].a : project.surfaces[$0.0].b }
            guard original.allSatisfy({ $0.distance(to: corner) <= 0.25 }) else { continue }
            for (i, atA) in group {
                var e = ends[i] ?? (project.surfaces[i].a, project.surfaces[i].b)
                if atA { e.a = corner } else { e.b = corner }
                ends[i] = e
            }
        }
        var changed = 0
        for (i, e) in ends where e.a.distance(to: e.b) >= 0.1 {
            record(&project, i); project.surfaces[i].a = e.a; project.surfaces[i].b = e.b
            if turned.contains(i) { changed += 1 }
        }
        reattach(&project, before: before)
        return changed
    }

    // MARK: 2. Close gaps

    static func close(_ project: inout RoomProject) -> Int {
        let before = Dictionary(uniqueKeysWithValues: project.surfaces.map { ($0.id, $0) })
        var joined = 0, moved = Set<String>()
        func free(_ i: Int, _ atA: Bool) -> Bool {
            let w = project.surfaces[i], p = atA ? w.a : w.b
            return !project.surfaces.indices.contains { j in
                j != i && project.surfaces[j].kind == .wall && !project.surfaces[j].excluded &&
                (project.surfaces[j].a.distance(to: p) <= joint || project.surfaces[j].b.distance(to: p) <= joint ||
                 Geometry.distance(p, to: project.surfaces[j].a, project.surfaces[j].b) <= 0.03)
            }
        }
        // A moved end must stay on its own side of the wall's other end, and the wall at least 30 cm long.
        func keeps(_ w: PlanSurface, atA: Bool, to p: PlanPoint) -> Bool {
            let fixed = atA ? w.b : w.a, end = atA ? w.a : w.b
            return (p - fixed).dot(end - fixed) > 0 && p.distance(to: fixed) >= 0.3
        }
        let walls = project.surfaces.indices.filter { project.surfaces[$0].kind == .wall && !project.surfaces[$0].excluded && project.surfaces[$0].length >= 0.3 }
        for i in walls { for atA in [true, false] where !moved.contains("\(i)\(atA)") && free(i, atA) {
            let w = project.surfaces[i], e = atA ? w.a : w.b
            var best: (cost: Double, x: PlanPoint, other: (Int, Bool)?)?      // other: the free end it joins, for an L
            for j in walls where j != i {
                let v = project.surfaces[j]
                guard abs(w.direction.dot(v.direction)) < 0.87,
                      let x = Geometry.lineIntersection(w.a, w.direction, v.a, v.direction), x.distance(to: e) <= 0.4, keeps(w, atA: atA, to: x) else { continue }
                // L corner with one of v's free ends.
                for vAtA in [true, false] where !moved.contains("\(j)\(vAtA)") && free(j, vAtA) {
                    let f = vAtA ? v.a : v.b
                    guard f.distance(to: e) <= 0.35, x.distance(to: f) <= 0.4, keeps(v, atA: vAtA, to: x) else { continue }
                    let cost = x.distance(to: e) + x.distance(to: f)
                    if cost < (best?.cost ?? .infinity) { best = (cost, x, (j, vAtA)) }
                }
                // T junction: the end runs onto v's face.
                let s = (x - v.a).dot(v.direction)
                if Geometry.distance(e, to: v.a, v.b) <= 0.25, s >= 0.05, s <= v.length - 0.05 {
                    let cost = x.distance(to: e) + 0.05
                    if cost < (best?.cost ?? .infinity) { best = (cost, x, nil) }
                }
            }
            if let best, best.cost > 0.004 {
                if atA { project.surfaces[i].a = best.x } else { project.surfaces[i].b = best.x }
                record(&project, i); moved.insert("\(i)\(atA)")
                if let (j, vAtA) = best.other {
                    if vAtA { project.surfaces[j].a = best.x } else { project.surfaces[j].b = best.x }
                    record(&project, j); moved.insert("\(j)\(vAtA)")
                }
                joined += 1
            }
        } }
        reattach(&project, before: before)
        return joined
    }

    // MARK: 3. Merge pieces

    static func merge(_ project: inout RoomProject) -> Int {
        var merged = 0
        while true {
            var done = false
            for group in joints(project) where group.count == 2 {
                let (i, iAtA) = group[0], (j, jAtA) = group[1]
                let w = project.surfaces[i], v = project.surfaces[j]
                guard abs(w.direction.dot(v.direction)) >= cos(2 * Double.pi / 180), abs(w.height - v.height) <= 0.05, abs(w.bottom - v.bottom) <= 0.05 else { continue }
                let farV = jAtA ? v.b : v.a
                let n = PlanPoint(x: -w.direction.z, z: w.direction.x)
                guard abs((farV - w.a).dot(n)) <= 0.03, abs(((jAtA ? v.a : v.b) - w.a).dot(n)) <= 0.03 else { continue }
                // One wall from w's far end to v's far end, keeping w's orientation.
                record(&project, i)
                if iAtA { project.surfaces[i].a = farV } else { project.surfaces[i].b = farV }
                let wall = project.surfaces[i]
                for k in project.surfaces.indices where project.surfaces[k].parentID == v.id {
                    let s = project.surfaces[k]
                    if project.surfaces[k].autoCleanup == nil { project.surfaces[k].autoCleanup = .init(reason: .tidied, originalA: s.a, originalB: s.b) }
                    if project.surfaces[k].autoCleanup?.originalParent == nil { project.surfaces[k].autoCleanup?.originalParent = v.id }
                    let ta = (s.a - wall.a).dot(wall.direction), tb = (s.b - wall.a).dot(wall.direction)
                    project.surfaces[k].parentID = wall.id
                    project.surfaces[k].a = wall.a + wall.direction * ta; project.surfaces[k].b = wall.a + wall.direction * tb
                }
                if project.surfaces[j].autoCleanup == nil { project.surfaces[j].autoCleanup = .init(reason: .merged, originalA: v.a, originalB: v.b) }
                else { project.surfaces[j].autoCleanup?.reason = .merged }
                project.surfaces[j].excluded = true
                // w's start may have moved; its own openings keep their places in the room.
                reattachKeepingPosition(&project, wallID: w.id)
                merged += 1; done = true; break
            }
            if !done { return merged }
        }
    }
    // After a wall grows at its start, its own openings keep their positions in the room.
    private static func reattachKeepingPosition(_ project: inout RoomProject, wallID: UUID) {
        guard let wall = project.surfaces.first(where: { $0.id == wallID }) else { return }
        for k in project.surfaces.indices where project.surfaces[k].parentID == wallID && project.surfaces[k].autoCleanup?.originalParent == nil {
            let s = project.surfaces[k]
            let ta = (s.a - wall.a).dot(wall.direction), tb = (s.b - wall.a).dot(wall.direction)
            project.surfaces[k].a = wall.a + wall.direction * ta; project.surfaces[k].b = wall.a + wall.direction * tb
        }
    }
}

// Tidy windows and doors on their walls: edges within 4 cm of a wall end go into the corner, neighbours that
// almost touch (or overlap a little) share one edge, windows on the same wall whose sills or heads are within
// 3 cm line up, and doors start at the floor.
enum OpeningJoins {
    @discardableResult
    static func apply(_ project: inout RoomProject) -> Int {
        var changed = Set<Int>()
        for wall in project.walls {
            let d = wall.direction
            var items = project.surfaces.indices.filter { project.surfaces[$0].parentID == wall.id && !project.surfaces[$0].excluded && project.surfaces[$0].kind != .wall }
                .map { i -> (i: Int, s0: Double, s1: Double) in
                    let s = project.surfaces[i], a = (s.a - wall.a).dot(d), b = (s.b - wall.a).dot(d)
                    return (i, min(a, b), max(a, b))
                }.sorted { $0.s0 < $1.s0 }
            guard !items.isEmpty else { continue }
            for k in items.indices {
                if items[k].s0 < 0.04 { items[k].s0 = 0 }
                if items[k].s1 > wall.length - 0.04 { items[k].s1 = wall.length }
            }
            for k in 1..<max(1, items.count) where items.count > 1 {
                let gap = items[k].s0 - items[k - 1].s1
                if gap < 0.06, gap > -0.15 {
                    let edge = (items[k].s0 + items[k - 1].s1) / 2
                    items[k - 1].s1 = edge; items[k].s0 = edge
                }
            }
            for item in items where item.s1 - item.s0 >= 0.1 {
                let s = project.surfaces[item.i], a = (s.a - wall.a).dot(d), b = (s.b - wall.a).dot(d)
                let newA = a <= b ? item.s0 : item.s1, newB = a <= b ? item.s1 : item.s0
                guard abs(newA - a) > 1e-6 || abs(newB - b) > 1e-6 else { continue }
                WallJoins.record(&project, item.i)
                project.surfaces[item.i].a = wall.a + d * newA; project.surfaces[item.i].b = wall.a + d * newB
                changed.insert(item.i)
            }
            // Sills and heads of windows on this wall.
            let windows = items.map(\.i).filter { project.surfaces[$0].kind == .window }
            func align(_ value: (PlanSurface) -> Double, _ set: (inout PlanSurface, Double) -> Void) {
                var groups: [[Int]] = []
                for i in windows.sorted(by: { value(project.surfaces[$0]) < value(project.surfaces[$1]) }) {
                    if let last = groups.last?.last, value(project.surfaces[i]) - value(project.surfaces[last]) <= 0.03 { groups[groups.count - 1].append(i) } else { groups.append([i]) }
                }
                for g in groups where g.count > 1 {
                    let target = g.map { value(project.surfaces[$0]) }.sorted()[g.count / 2]
                    for i in g where abs(value(project.surfaces[i]) - target) > 1e-6 {
                        remember(&project, i)
                        var surface = project.surfaces[i]; set(&surface, target); project.surfaces[i] = surface; changed.insert(i)
                    }
                }
            }
            align({ $0.bottom }) { s, v in let top = s.bottom + s.height; s.bottom = v; s.height = top - v }
            align({ $0.bottom + $0.height }) { s, v in s.height = v - s.bottom }
            for i in items.map(\.i) where project.surfaces[i].kind == .door && project.surfaces[i].bottom > wall.bottom + 1e-6 && project.surfaces[i].bottom <= wall.bottom + 0.05 {
                remember(&project, i)
                let top = project.surfaces[i].bottom + project.surfaces[i].height
                project.surfaces[i].bottom = wall.bottom; project.surfaces[i].height = top - wall.bottom; changed.insert(i)
            }
        }
        return changed.count
    }
    // Keeps the scanned position, bottom and height, so Restore can put them back.
    private static func remember(_ project: inout RoomProject, _ i: Int) {
        if project.surfaces[i].autoCleanup == nil { WallJoins.record(&project, i) }
        let height = project.surfaces[i].height, bottom = project.surfaces[i].bottom
        if project.surfaces[i].autoCleanup?.originalHeight == nil { project.surfaces[i].autoCleanup?.originalHeight = height }
        if project.surfaces[i].autoCleanup?.originalBottom == nil { project.surfaces[i].autoCleanup?.originalBottom = bottom }
    }
}
