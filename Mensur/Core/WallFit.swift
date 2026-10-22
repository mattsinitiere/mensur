import Foundation

// Walls corrected from the LiDAR mesh. RoomPlan estimates each wall from the camera and depth, then tidies it;
// the scene mesh records where the wall surface actually is. Given points on wall surfaces (plan x/z, meters),
// each RoomPlan wall with enough nearby points moves onto the plane they form (small shifts and turns only),
// joined corners and the wall's openings follow, walls the LiDAR doesn't confirm are flagged, and long straight
// runs of wall points that no RoomPlan wall explains are added as walls to confirm.
// Every change is recorded in autoCleanup, so Review → Restore puts RoomPlan's version back.
enum WallFit {
    struct Report: Equatable { var aligned = 0; var unconfirmed = 0; var added = 0 }

    static let band = 0.25                 // meters either side of a wall searched for its points
    static let maxShift = 0.30
    static let maxTurn = 4.0 * .pi / 180

    @discardableResult
    // findMissing: add walls from runs of points no wall explains. Only safe when the points are labelled wall
    // surfaces; upright triangles also include cabinet and desk sides. missingFrom: the points searched for those
    // walls (default `points`). Pass only points between about 0.9 and 1.9 m above the floor: a bulkhead or soffit
    // face is labelled wall too, but has nothing below about 2.2 m, and sofa backs and counters nothing above 1 m.
    static func apply(_ project: inout RoomProject, points: [PlanPoint], findMissing: Bool = true, missingFrom: [PlanPoint]? = nil) -> Report {
        var report = Report()
        let grid = Grid(points)
        let walls = project.walls.filter { $0.length >= 0.25 }
        guard !walls.isEmpty, points.count >= 50 else { return report }

        // Corners joined before any change, so they can be rejoined afterwards.
        struct Joint { var first: UUID; var firstAtA: Bool; var second: UUID; var secondAtA: Bool }
        var joints: [Joint] = []
        for (i, w) in walls.enumerated() { for v in walls[(i + 1)...] {
            for (wa, pw) in [(true, w.a), (false, w.b)] { for (va, pv) in [(true, v.a), (false, v.b)] where pw.distance(to: pv) <= 0.1 {
                joints.append(Joint(first: w.id, firstAtA: wa, second: v.id, secondAtA: va))
            } }
        } }

        // Which side of each wall is the room, from the enclosed outline (works for L-shaped rooms).
        let outline = Geometry.spaces(walls).outline
        func inwardSign(_ w: PlanSurface) -> Double? {
            guard outline.count >= 3 else { return nil }
            let n = PlanPoint(x: -w.direction.z, z: w.direction.x), plus = Geometry.contains(outline, w.midpoint + n * 0.3), minus = Geometry.contains(outline, w.midpoint - n * 0.3)
            return plus == minus ? nil : (plus ? 1 : -1)
        }

        // 1. Fit each wall to its points.
        var fitted: [UUID: (a: PlanPoint, b: PlanPoint)] = [:], supported: [UUID: Bool] = [:]
        for w in walls {
            let near = grid.near(w.a, w.b, margin: band + 0.1)
            let d = w.direction, n = PlanPoint(x: -d.z, z: d.x)
            // Only solid wall counts: through windows the LiDAR lands on blinds and sills, through doors on
            // whatever is beyond.
            let gaps = project.activeSurfaces.filter { $0.parentID == w.id }.map { o -> ClosedRange<Double> in
                let s0 = (o.a - w.a).dot(d), s1 = (o.b - w.a).dot(d); return (min(s0, s1) - 0.05)...(max(s0, s1) + 0.05)
            }
            var offsets: [(s: Double, t: Double, p: PlanPoint)] = []
            for p in near {
                let s = (p - w.a).dot(d), t = (p - w.a).dot(n)
                // Points right at the ends belong to the joining walls as much as to this one.
                let end = min(0.15, w.length * 0.25)
                if abs(t) <= band && s >= end && s <= w.length - end && !gaps.contains(where: { $0.contains(s) }) { offsets.append((s, t, p)) }
            }
            let solid = max(0.25, w.length - gaps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })
            let bins = max(1, Int((solid / 0.25).rounded(.up)))
            var filled = Set<Int>(); for o in offsets { filled.insert(Int(o.s / 0.25)) }
            let spread = min(1, Double(filled.count) / Double(bins))
            supported[w.id] = offsets.count >= 3
            guard offsets.count >= max(15, Int(20 * solid)), spread >= 0.35 else { continue }
            // Dense 2 cm offset bands are surfaces. The wall is the strong one furthest out of the room: cabinets
            // and desks stand in front of a wall, never behind it. Without a known inside, the densest band.
            var histogram = [Int](repeating: 0, count: Int(2 * band / 0.02) + 1)
            for o in offsets { histogram[Int(((o.t + band) / 0.02).rounded())] += 1 }
            let smooth = histogram.indices.map { i in (max(0, i - 1)...min(histogram.count - 1, i + 1)).reduce(0) { $0 + histogram[$1] } }
            let strongest = smooth.max()!
            let peaks = smooth.indices.filter { i in
                smooth[i] >= max(6, strongest * 3 / 10) && (i == 0 || smooth[i] >= smooth[i - 1]) && (i == smooth.count - 1 || smooth[i] >= smooth[i + 1])
            }
            let pick: Int
            if let inward = inwardSign(w), !peaks.isEmpty { pick = inward > 0 ? peaks.min()! : peaks.max()! }
            else { pick = smooth.indices.max { smooth[$0] < smooth[$1] }! }
            let peak = Double(pick) * 0.02 - band
            let inliers = offsets.filter { abs($0.t - peak) <= 0.05 }
            guard inliers.count >= 10 else { continue }
            // Principal direction of the inliers (2×2 covariance).
            let cx = inliers.reduce(0) { $0 + $1.p.x } / Double(inliers.count), cz = inliers.reduce(0) { $0 + $1.p.z } / Double(inliers.count)
            var sxx = 0.0, sxz = 0.0, szz = 0.0
            for o in inliers { let dx = o.p.x - cx, dz = o.p.z - cz; sxx += dx * dx; sxz += dx * dz; szz += dz * dz }
            let angle = 0.5 * atan2(2 * sxz, sxx - szz)
            var e = PlanPoint(x: cos(angle), z: sin(angle)); if e.dot(d) < 0 { e = e * -1 }
            let centre = PlanPoint(x: cx, z: cz)
            let line: (PlanPoint, PlanPoint)
            if acos(min(1, abs(e.dot(d)))) <= maxTurn { line = (centre, e) }
            else { line = (w.a + n * (inliers.reduce(0) { $0 + $1.t } / Double(inliers.count)), d) }   // keep the angle, fix the offset
            func onLine(_ p: PlanPoint) -> PlanPoint { line.0 + line.1 * (p - line.0).dot(line.1) }
            let a = onLine(w.a), b = onLine(w.b)
            // Short pieces (pillar faces, returns) have few points and other surfaces close by: small moves only.
            let limit = w.length < 1 ? 0.10 : maxShift
            guard a.distance(to: w.a) <= limit, b.distance(to: w.b) <= limit, a.distance(to: w.a) + b.distance(to: w.b) > 0.004 else { continue }
            fitted[w.id] = (a, b)
        }

        func record(_ i: Int) {
            let s = project.surfaces[i]
            if s.autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: .lidarAligned, originalA: s.a, originalB: s.b) }
            project.surfaces[i].evidence = .edited; project.surfaces[i].reviewed = false
        }
        let before = Dictionary(uniqueKeysWithValues: project.surfaces.map { ($0.id, $0) })
        for (id, ends) in fitted {
            guard let i = project.surfaces.firstIndex(where: { $0.id == id }) else { continue }
            record(i); project.surfaces[i].a = ends.a; project.surfaces[i].b = ends.b
        }
        report.aligned = fitted.count

        // 2. Rejoin corners that were joined: where the two (new) wall lines cross, or between the ends of
        // nearly parallel pieces.
        for j in joints where fitted[j.first] != nil || fitted[j.second] != nil {
            guard let i = project.surfaces.firstIndex(where: { $0.id == j.first }), let k = project.surfaces.firstIndex(where: { $0.id == j.second }) else { continue }
            let w = project.surfaces[i], v = project.surfaces[k]
            let pw = j.firstAtA ? w.a : w.b, pv = j.secondAtA ? v.a : v.b
            var corner = (pw + pv) * 0.5
            if abs(w.direction.dot(v.direction)) < 0.97, let x = Geometry.lineIntersection(w.a, w.direction, v.a, v.direction),
               x.distance(to: pw) <= 0.6, x.distance(to: pv) <= 0.6 { corner = x }
            record(i); record(k)
            if j.firstAtA { project.surfaces[i].a = corner } else { project.surfaces[i].b = corner }
            if j.secondAtA { project.surfaces[k].a = corner } else { project.surfaces[k].b = corner }
        }

        // Short walls squeezed to almost nothing by the rejoined corners are hidden.
        for i in project.surfaces.indices where project.surfaces[i].kind == .wall && !project.surfaces[i].excluded
            && project.surfaces[i].autoCleanup?.reason == .lidarAligned && project.surfaces[i].length < 0.1
            && !project.activeSurfaces.contains(where: { $0.parentID == project.surfaces[i].id }) {
            project.surfaces[i].autoCleanup?.reason = .unconfirmed; project.surfaces[i].excluded = true
        }

        // 3. Openings follow their wall onto its new line.
        for i in project.surfaces.indices where project.surfaces[i].kind != .wall {
            guard let parent = project.surfaces[i].parentID, let old = before[parent], let wall = project.surfaces.first(where: { $0.id == parent }),
                  old.a != wall.a || old.b != wall.b else { continue }
            let s = project.surfaces[i]
            // Same distance along the wall from its start as before.
            let ta = (s.a - old.a).dot(old.direction), tb = (s.b - old.a).dot(old.direction)
            record(i)
            project.surfaces[i].a = wall.a + wall.direction * ta; project.surfaces[i].b = wall.a + wall.direction * tb
        }

        // 4. Walls the LiDAR doesn't confirm, when it confirmed most of the rest.
        let total = walls.reduce(0) { $0 + $1.length }, confirmed = walls.filter { supported[$0.id] == true }.reduce(0) { $0 + $1.length }
        if total > 0, confirmed / total >= 0.5 {
            for w in walls where supported[w.id] != true {
                guard let i = project.surfaces.firstIndex(where: { $0.id == w.id }) else { continue }
                let hosts = project.activeSurfaces.contains { $0.parentID == w.id }
                if w.length < 0.6 && !hosts {
                    if project.surfaces[i].autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: .unconfirmed, originalA: w.a, originalB: w.b) }
                    project.surfaces[i].excluded = true
                } else if !(project.surfaces[i].reviewNote ?? "").contains("LiDAR") {
                    project.surfaces[i].reviewNote = [project.surfaces[i].reviewNote, "Not confirmed by the LiDAR scan. Check that this wall is real."]
                        .compactMap { $0 }.joined(separator: " ")
                }
                report.unconfirmed += 1
            }
        }

        // 5. Long straight runs of wall points that no wall explains: walls RoomPlan missed.
        let current = project.walls
        var leftover = (missingFrom ?? points).filter { p in !current.contains { Geometry.distance(p, to: $0.a, $0.b) <= 0.3 } }
        let lo = PlanPoint(x: current.flatMap { [$0.a.x, $0.b.x] }.min()!, z: current.flatMap { [$0.a.z, $0.b.z] }.min()!)
        let hi = PlanPoint(x: current.flatMap { [$0.a.x, $0.b.x] }.max()!, z: current.flatMap { [$0.a.z, $0.b.z] }.max()!)
        leftover = leftover.filter { $0.x > lo.x + 0.2 && $0.x < hi.x - 0.2 && $0.z > lo.z + 0.2 && $0.z < hi.z - 0.2 }
        let height = current.map(\.height).sorted()[current.count / 2]
        for _ in 0..<(findMissing ? 5 : 0) {
            guard leftover.count >= 60, let run = bestRun(leftover) else { break }
            var wall = PlanSurface(label: "Wall \(project.walls.count + 1)", kind: .wall, a: run.a, b: run.b, height: height,
                                   confidence: .low, evidence: .captured)
            wall.reviewNote = "Found by the LiDAR scan but not by RoomPlan. Confirm or delete it."
            wall.autoCleanup = .init(reason: .lidarAdded, originalA: run.a, originalB: run.b)
            project.surfaces.append(wall); report.added += 1
            leftover = leftover.filter { Geometry.distance($0, to: run.a, run.b) > 0.15 }
        }
        return report
    }

    // How well the LiDAR confirms each wall where it now is: wall-surface points within 10 cm of its solid parts
    // (not across its windows and doors), in 25 cm steps. Sets lidarCheck on every active wall.
    @discardableResult
    static func check(_ project: inout RoomProject, points: [PlanPoint]) -> (confirmed: Int, total: Int) {
        let grid = Grid(points)
        var confirmed = 0, total = 0
        for i in project.surfaces.indices where project.surfaces[i].kind == .wall && !project.surfaces[i].excluded && project.surfaces[i].length >= 0.25 {
            let w = project.surfaces[i], d = w.direction, n = PlanPoint(x: -d.z, z: d.x)
            let gaps = project.activeSurfaces.filter { $0.parentID == w.id }.map { o -> ClosedRange<Double> in
                let s0 = (o.a - w.a).dot(d), s1 = (o.b - w.a).dot(d); return (min(s0, s1) - 0.05)...(max(s0, s1) + 0.05)
            }
            let end = min(0.15, w.length * 0.25)
            var offsets: [Double] = [], bins = Set<Int>()
            for p in grid.near(w.a, w.b, margin: 0.2) {
                let s = (p - w.a).dot(d), t = (p - w.a).dot(n)
                guard abs(t) <= 0.10, s >= end, s <= w.length - end, !gaps.contains(where: { $0.contains(s) }) else { continue }
                offsets.append(t); bins.insert(Int(s / 0.25))
            }
            let solidLength = w.length - 2 * end - gaps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            // Mostly glass or doorway: too little solid wall to check.
            guard solidLength >= 0.4 else { project.surfaces[i].lidarCheck = nil; continue }
            let solid = max(0.25, solidLength)
            let coverage = min(1, Double(bins.count) / max(1, (solid / 0.25).rounded(.up)))
            let sorted = offsets.sorted(), median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            // Robust scatter (1.4826 × median absolute deviation): a few points from furniture near the wall
            // don't count against it.
            let deviations = sorted.map { abs($0 - median) }.sorted()
            let spread = deviations.isEmpty ? 0 : 1.4826 * deviations[deviations.count / 2]
            project.surfaces[i].lidarCheck = LidarCheck(coverage: offsets.count >= 5 ? coverage : 0, offset: median, spread: spread)
            total += 1
            if project.surfaces[i].lidarCheck?.level == .confirmed { confirmed += 1 }
        }
        return (confirmed, total)
    }

    // The longest well-filled straight run (≥ 1 m, 70% of 25 cm steps occupied, 3 cm thick) among points.
    private static func bestRun(_ points: [PlanPoint]) -> (a: PlanPoint, b: PlanPoint)? {
        var best: (a: PlanPoint, b: PlanPoint, score: Int)?
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Int { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Int(seed % UInt64(points.count)) }
        for _ in 0..<400 {
            let p = points[next()], q = points[next()], length = p.distance(to: q)
            guard length >= 0.5 else { continue }
            let d = (q - p) * (1 / length), n = PlanPoint(x: -d.z, z: d.x)
            let along = points.filter { abs(($0 - p).dot(n)) <= 0.03 }.map { ($0 - p).dot(d) }.sorted()
            guard along.count >= 40 else { continue }
            // Longest stretch without a gap over 0.4 m.
            var start = 0, bestSpan = (0, 0)
            for k in 1..<along.count where along[k] - along[k - 1] > 0.4 {
                if k - 1 - start > bestSpan.1 - bestSpan.0 { bestSpan = (start, k - 1) }; start = k
            }
            if along.count - 1 - start > bestSpan.1 - bestSpan.0 { bestSpan = (start, along.count - 1) }
            let s0 = along[bestSpan.0], s1 = along[bestSpan.1], span = s1 - s0
            guard span >= 1.0 else { continue }
            let steps = Int((span / 0.25).rounded(.up)), filled = Set(along[bestSpan.0...bestSpan.1].map { Int(($0 - s0) / 0.25) }).count
            guard Double(filled) / Double(steps) >= 0.7 else { continue }
            let count = bestSpan.1 - bestSpan.0 + 1
            if count > (best?.score ?? 0) { best = (p + d * s0, p + d * s1, count) }
        }
        return best.map { ($0.a, $0.b) }
    }

    // Points bucketed in 0.5 m cells for neighbourhood queries.
    private struct Grid {
        var cells: [Int64: [PlanPoint]] = [:]
        init(_ points: [PlanPoint]) { for p in points { cells[key(p), default: []].append(p) } }
        func key(_ p: PlanPoint) -> Int64 { Int64(floor(p.x / 0.5)) << 32 ^ (Int64(floor(p.z / 0.5)) & 0xffffffff) }
        func near(_ a: PlanPoint, _ b: PlanPoint, margin: Double) -> [PlanPoint] {
            let x0 = Int64(floor((min(a.x, b.x) - margin) / 0.5)), x1 = Int64(floor((max(a.x, b.x) + margin) / 0.5))
            let z0 = Int64(floor((min(a.z, b.z) - margin) / 0.5)), z1 = Int64(floor((max(a.z, b.z) + margin) / 0.5))
            var out: [PlanPoint] = []
            for x in x0...x1 { for z in z0...z1 { out += cells[x << 32 ^ (z & 0xffffffff)] ?? [] } }
            return out
        }
    }
}
