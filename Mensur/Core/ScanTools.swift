import Foundation

// Pure logic behind the capture screen, kept here so it can be tested without a device: the tracking report,
// spoken coaching, reveal depths from LiDAR points, and merging a resumed scan into its room.

// MARK: Tracking report

// The phone's position a few times a second during a scan. tracking: 0 normal, 1 limited, 2 relocalizing.
struct PoseSample: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
    var z: Double
    var tracking: Int
}

enum ScanMetrics {
    // Walking speed the phone can plausibly move at; anything faster between two samples is ARKit moving its
    // estimate (correcting drift, or snapping back after relocalizing).
    static let walkingSpeed = 1.8

    static func report(_ samples: [PoseSample]) -> ScanReport {
        var r = ScanReport()
        guard let first = samples.first, let last = samples.last else { return r }
        r.duration = max(0, last.t - first.t)
        for (p, q) in zip(samples, samples.dropFirst()) {
            let dt = max(0, q.t - p.t)
            let step = ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z)).squareRoot()
            if p.tracking != 0 { r.limitedTracking += dt }
            if p.tracking == 2 && q.tracking == 0 { r.relocalizations += 1 }
            let allowed = walkingSpeed * dt + 0.05
            if step > allowed && step > 0.1 {
                r.corrections += 1
                r.largestCorrection = max(r.largestCorrection, step - walkingSpeed * dt)
            } else { r.pathLength += step }
        }
        return r
    }

    // The widest gap between wall ends that face each other within 50 cm: what RoomPlan left open.
    static func largestCornerGap(_ room: RoomProject) -> Double? {
        let walls = room.walls
        var widest: Double?
        for w in walls {
            for p in [w.a, w.b] {
                let others = walls.filter { $0.id != w.id }.flatMap { [$0.a, $0.b] }
                guard let nearest = others.map({ $0.distance(to: p) }).min(), nearest > 0.005, nearest <= 0.5 else { continue }
                widest = max(widest ?? 0, nearest)
            }
        }
        return widest
    }

    // Plain-language summary for the Review tab and the PDF notes.
    static func summary(_ r: ScanReport, units: DisplayUnits) -> [String] {
        var lines: [String] = []
        let minutes = Int(r.duration / 60), seconds = Int(r.duration) % 60
        let path = units == .metric ? String(format: "%.0f m", r.pathLength) : String(format: "%.0f ft", r.pathLength / 0.3048)
        lines.append("You walked about \(path) in \(minutes)m \(String(format: "%02d", seconds))s\(r.passes > 1 ? " over \(r.passes) scans" : "").")
        if r.limitedTracking >= 1 { lines.append("Tracking was limited for \(Int(r.limitedTracking.rounded())) s (too fast, too dark, or a blank surface).") }
        if r.relocalizations > 0 { lines.append("Tracking was lost and found again \(r.relocalizations) time\(r.relocalizations == 1 ? "" : "s").") }
        if r.corrections > 0 {
            lines.append("ARKit corrected its position \(r.corrections) time\(r.corrections == 1 ? "" : "s"), by up to \(units.length(r.largestCorrection)). Walls scanned before a correction can be off by about that much.")
        } else { lines.append("ARKit made no sudden position corrections.") }
        if let gap = r.largestCornerGap {
            lines.append(gap > 0.05 ? "The widest corner RoomPlan left open was \(units.length(gap)) before it was closed; walls near it deserve a tape check."
                                    : "Corners met within \(units.length(gap)) before tidying.")
        }
        if r.resumedFromMap { lines.append("Part of this room was added by resuming a saved scan; check walls where the two scans meet.") }
        let risk = r.pathLength > 80 || r.corrections > 2 || r.relocalizations > 0 || (r.largestCornerGap ?? 0) > 0.08
        lines.append(risk ? "Treat long dimensions as approximate: scans this long or interrupted drift more."
                          : "Nothing suggests unusual drift. Check critical dimensions with a tape anyway.")
        return lines
    }
}

// MARK: Coaching

// Which wall still needs a close look, and where it is relative to the phone.
enum Coaching {
    enum Side: String { case ahead, left, right, behind }
    struct Hint: Equatable { var wall: UUID; var side: Side; var distance: Double; var phrase: String }

    // walls: each wall with how many times each half-metre strip has been seen up close. Picks the nearest
    // strip not yet seen, on a wall at least 1 m long.
    static func next(position: PlanPoint, heading: PlanPoint, walls: [(wall: PlanSurface, seen: [Int])]) -> Hint? {
        var best: (PlanSurface, PlanPoint, Double)?
        for (wall, seen) in walls where wall.length >= 1 && !seen.isEmpty {
            for (i, count) in seen.enumerated() where count == 0 {
                let t = (Double(i) + 0.5) / Double(seen.count)
                let p = wall.a + (wall.b - wall.a) * t, d = p.distance(to: position)
                if d < (best?.2 ?? .infinity) { best = (wall, p, d) }
            }
        }
        guard let (wall, target, distance) = best else { return nil }
        let h = heading.magnitude > 1e-6 ? heading * (1 / heading.magnitude) : PlanPoint(x: 0, z: -1)
        let to = target - position
        let forward = to.dot(h), sideways = Geometry.cross(h, to)        // + is to the right in plan x/z
        let side: Side = abs(forward) >= abs(sideways) ? (forward >= 0 ? .ahead : .behind) : (sideways > 0 ? .right : .left)
        let where_: String
        switch side {
        case .ahead: where_ = "the wall ahead"
        case .behind: where_ = "the wall behind you"
        case .left: where_ = "the wall on your left"
        case .right: where_ = "the wall on your right"
        }
        let phrase = distance > 3 ? "Walk toward \(where_), about \(Int(distance.rounded())) meters away" : "Move closer to \(where_)"
        return Hint(wall: wall.id, side: side, distance: distance, phrase: phrase)
    }
}

// MARK: Reveals

enum Reveals {
    // Depth of a door or window reveal from LiDAR points in the opening's own coordinates: u across the
    // opening (0 at one jamb, `width` at the other), v up from its bottom, w out of the wall face (positive
    // away from the room). Jamb surfaces show as points near u = 0 or u = width spread over w; the spread is
    // the wall's depth there. Nil without enough points, or outside 5–70 cm.
    static func depth(_ points: [Vector3], width: Double, height: Double) -> Double? {
        let jamb = points.filter { p in
            (abs(p.x) < 0.10 || abs(p.x - width) < 0.10) && p.y > 0.1 && p.y < height - 0.05 && p.z > -0.08 && p.z < 0.9
        }.map(\.z).sorted()
        guard jamb.count >= 20 else { return nil }
        let lo = jamb[Int(Double(jamb.count) * 0.05)], hi = jamb[min(jamb.count - 1, Int(Double(jamb.count) * 0.95))]
        let depth = hi - lo
        return depth >= 0.05 && depth <= 0.7 ? depth : nil
    }

    // Walls take the thickness measured at their doors and windows (the median of them), unless typed.
    @discardableResult static func applyToWalls(_ room: inout RoomProject) -> Int {
        var changed = 0
        for i in room.surfaces.indices where room.surfaces[i].kind == .wall && room.surfaces[i].thicknessSource != .typed {
            let id = room.surfaces[i].id
            let depths = room.surfaces.filter { $0.parentID == id && !$0.excluded }.compactMap(\.revealDepth).sorted()
            guard !depths.isEmpty else { continue }
            room.surfaces[i].thickness = depths[depths.count / 2]; room.surfaces[i].thicknessSource = .reveal
            changed += 1
        }
        return changed
    }
}

// MARK: Resumed scans

enum ScanMerge {
    // Adds what a resumed scan found to the room it continues, in the same coordinates. Walls the room
    // already has (parallel, within 12 cm, overlapping by half the shorter) are skipped; so are openings and
    // furniture already there. The room's own edits, names and annotations stay.
    static func merge(_ new: RoomProject, into room: RoomProject) -> (room: RoomProject, walls: Int, openings: Int, objects: Int) {
        var result = room
        func duplicate(_ a: PlanSurface, _ b: PlanSurface) -> Bool {
            guard abs(a.direction.dot(b.direction)) > 0.995 else { return false }
            let n = PlanPoint(x: -b.direction.z, z: b.direction.x)
            guard abs((a.midpoint - b.a).dot(n)) < 0.12 else { return false }
            let t0 = (a.a - b.a).dot(b.direction), t1 = (a.b - b.a).dot(b.direction)
            let overlap = min(b.length, max(t0, t1)) - max(0, min(t0, t1))
            return overlap >= 0.5 * min(a.length, b.length)
        }
        var wallMap: [UUID: UUID] = [:]           // new wall → the wall it ends up as
        var walls = 0, openings = 0, objects = 0
        for w in new.surfaces where w.kind == .wall && !w.excluded {
            if let existing = result.walls.first(where: { duplicate(w, $0) }) { wallMap[w.id] = existing.id; continue }
            var copy = w
            copy.label = "Wall \(result.surfaces.filter { $0.kind == .wall }.count + 1)"
            if result.surfaces.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
            wallMap[w.id] = copy.id
            result.surfaces.append(copy); walls += 1
        }
        for s in new.surfaces where s.kind != .wall && !s.excluded {
            guard let parent = s.parentID.flatMap({ wallMap[$0] }) else { continue }
            if result.activeSurfaces.contains(where: { $0.kind == s.kind && $0.parentID == parent && duplicate(s, $0) }) { continue }
            var copy = s
            copy.parentID = parent
            copy.label = "\(s.kind.title) \(result.surfaces.filter { $0.kind == s.kind }.count + 1)"
            if result.surfaces.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
            result.surfaces.append(copy); openings += 1
        }
        for o in new.objects where !o.excluded {
            let near = result.objects.contains { e in
                hypot(e.center.x - o.center.x, e.center.z - o.center.z) < 0.3 && e.label.split(separator: " ").first == o.label.split(separator: " ").first
            }
            guard !near else { continue }
            var copy = o
            if result.objects.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
            result.objects.append(copy); objects += 1
        }
        if let markers = new.markers { result.markers = (result.markers ?? []) + markers }
        if let photos = new.photos { result.photos = (result.photos ?? []) + photos }
        if let ceilings = new.ceilings, result.ceilings?.isEmpty ?? true { result.ceilings = ceilings }
        var report = result.scanReport ?? ScanReport()
        if let added = new.scanReport {
            report.passes += added.passes; report.pathLength += added.pathLength; report.duration += added.duration
            report.limitedTracking += added.limitedTracking; report.relocalizations += added.relocalizations
            report.corrections += added.corrections; report.largestCorrection = max(report.largestCorrection, added.largestCorrection)
        } else { report.passes += 1 }
        report.resumedFromMap = true
        result.scanReport = report
        result.captureWarnings.append("Resumed scan added \(walls) wall(s), \(openings) opening(s) and \(objects) furniture item(s). Check walls where the two scans meet.")
        return (result, walls, openings, objects)
    }
}
