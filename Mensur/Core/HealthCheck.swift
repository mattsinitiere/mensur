import Foundation

// A room's plan checked for the mistakes a scan typically leaves: walls that don't close into a room, gaps
// where a wall or opening was missed, ends left hanging, corners at odd angles, walls that overlap or cross,
// slivers, and openings off their wall.
struct HealthFinding: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case problem, warning, info
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    var id: String { "\(title)|\(surfaces.map(\.uuidString).joined())" }
    var severity: Severity
    var title: String
    var detail: String
    var surfaces: [UUID] = []
    var at: PlanPoint? = nil
}

enum HealthCheck {
    static let join = 0.08

    static func run(_ room: RoomProject) -> [HealthFinding] {
        let walls = room.walls, units = room.units
        var findings: [HealthFinding] = []
        guard !walls.isEmpty else { return [.init(severity: .problem, title: "No walls", detail: "Scan the room or add walls to the plan.")] }

        // Does each end meet another wall: at its end, or anywhere along it (a T-junction)?
        struct End { var wall: PlanSurface; var point: PlanPoint; var atA: Bool }
        var open: [End] = []
        for w in walls {
            for (p, atA) in [(w.a, true), (w.b, false)] {
                let meets = walls.contains { o in o.id != w.id && Geometry.distance(p, to: o.a, o.b) <= join }
                if !meets { open.append(End(wall: w, point: p, atA: atA)) }
            }
        }
        // Gaps: two loose ends close together, most likely a missed wall or an opening RoomPlan dropped.
        var used = Set<Int>()
        let pairs = open.indices.flatMap { i in open.indices.filter { $0 > i }.map { (i, $0) } }
            .filter { open[$0.0].wall.id != open[$0.1].wall.id }
            .map { ($0.0, $0.1, open[$0.0].point.distance(to: open[$0.1].point)) }
            .filter { $0.2 <= 1.5 }.sorted { $0.2 < $1.2 }
        for (i, j, gap) in pairs where !used.contains(i) && !used.contains(j) {
            used.formUnion([i, j])
            findings.append(.init(severity: .problem, title: "Gap of \(units.length(gap))",
                                  detail: "\(open[i].wall.label) and \(open[j].wall.label) don't meet. A wall may be missing, or a doorway RoomPlan didn't find.",
                                  surfaces: [open[i].wall.id, open[j].wall.id], at: (open[i].point + open[j].point) * 0.5))
        }
        for (i, end) in open.enumerated() where !used.contains(i) {
            findings.append(.init(severity: .warning, title: "\(end.wall.label) ends in open space",
                                  detail: "This end doesn't meet another wall. Extend it, or scan the area around it again.",
                                  surfaces: [end.wall.id], at: end.point))
        }

        // Whole outline: is there at least one enclosed space?
        let summary = RoomSummary(room)
        if summary.spaces.isEmpty {
            findings.append(.init(severity: .problem, title: "Walls don't enclose a room",
                                  detail: Geometry.boundary(walls).warning ?? "Close the gaps so the walls form a loop; the area can't be computed until then."))
        }

        // Corners at angles other than square, straight on or 45°.
        var cornersSeen = Set<String>()
        for w in walls {
            for o in walls where o.id != w.id {
                guard let corner = [w.a, w.b].first(where: { p in [o.a, o.b].contains { $0.distance(to: p) <= join } }) else { continue }
                let key = [w.id.uuidString, o.id.uuidString].sorted().joined()
                guard cornersSeen.insert(key).inserted else { continue }
                // The corner's angle between the two walls, each measured from the corner along the wall.
                let v1 = (w.a.distance(to: corner) < w.b.distance(to: corner) ? w.b : w.a) - corner
                let v2 = (o.a.distance(to: corner) < o.b.distance(to: corner) ? o.b : o.a) - corner
                let angle = acos(max(-1, min(1, v1.dot(v2) / max(v1.magnitude * v2.magnitude, 1e-12)))) * 180 / .pi   // 0…180
                let nearest = [45.0, 90, 135, 180].map { abs(angle - $0) }.min() ?? 0
                if nearest > 3 && angle > 5 {
                    findings.append(.init(severity: .warning, title: "\(w.label) and \(o.label) meet at \(Int(angle.rounded()))°",
                                          detail: "Not square. If the corner is really square, use Review → Square corners or drag a wall end.",
                                          surfaces: [w.id, o.id], at: corner))
                }
            }
        }

        // Overlapping and crossing walls.
        for (i, w) in walls.enumerated() {
            for o in walls.dropFirst(i + 1) {
                let n = PlanPoint(x: -w.direction.z, z: w.direction.x)
                if abs(w.direction.dot(o.direction)) > 0.995, abs((o.a - w.a).dot(n)) < 0.03, abs((o.b - w.a).dot(n)) < 0.03 {
                    let t0 = (o.a - w.a).dot(w.direction), t1 = (o.b - w.a).dot(w.direction)
                    let overlap = min(w.length, max(t0, t1)) - max(0, min(t0, t1))
                    if overlap > 0.05 {
                        findings.append(.init(severity: .warning, title: "\(w.label) overlaps \(o.label)",
                                              detail: "They lie on the same line for \(units.length(overlap)). Exclude one, or shorten it.",
                                              surfaces: [w.id, o.id], at: w.a + w.direction * ((max(0, min(t0, t1)) + min(w.length, max(t0, t1))) / 2)))
                    }
                    continue
                }
                guard Geometry.segmentsIntersect(w.a, w.b, o.a, o.b) else { continue }
                let ends = [w.a, w.b, o.a, o.b]
                let touching = ends.contains { p in Geometry.distance(p, to: w.a, w.b) <= join && Geometry.distance(p, to: o.a, o.b) <= join }
                if !touching, let x = Geometry.lineIntersection(w.a, w.direction, o.a, o.direction) {
                    findings.append(.init(severity: .warning, title: "\(w.label) crosses \(o.label)",
                                          detail: "Walls normally meet end to end or at a T. One of them probably runs too far.",
                                          surfaces: [w.id, o.id], at: x))
                }
            }
        }

        for w in walls where w.length < 0.15 {
            findings.append(.init(severity: .info, title: "\(w.label) is only \(units.length(w.length)) long",
                                  detail: "A sliver like this is usually a scanning artefact. Review → Hide short wall stubs removes it.",
                                  surfaces: [w.id], at: w.midpoint))
        }
        for s in room.activeSurfaces where s.kind != .wall {
            if let issue = Geometry.openingIssue(s, in: room) {
                findings.append(.init(severity: .warning, title: "\(s.label): off its wall", detail: issue, surfaces: [s.id], at: s.midpoint))
            }
        }
        let heights = walls.map(\.height)
        if let lo = heights.min(), let hi = heights.max(), hi - lo > 0.15 {
            findings.append(.init(severity: .info, title: "Wall heights vary from \(units.length(lo)) to \(units.length(hi))",
                                  detail: "Expected under a sloped ceiling, a soffit or a split level. Otherwise check the lowest walls."))
        }
        return findings.sorted { $0.severity < $1.severity }
    }
}
