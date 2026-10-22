import Foundation

// Window panes: where the dividers (mullions, transoms and grille bars) are, found in straightened greyscale
// close-ups of a window taken during the scan. A divider is a thin bar, lighter or darker than the glass on
// both sides of it, running across most of the window. Single edges (the glass meeting its frame, the sash
// meeting the jamb) are not bars, and trees, people or furniture seen through the glass make short or broken
// lines, so neither counts. Many evenly spaced lines are blinds, which hide the panes, so no dividers are
// reported then.
enum WindowPanes {
    // One close-up, row 0 at the top, `pixelsPerMeter` across. RoomPlan's estimate of a window changes during
    // a scan, so each close-up says where its own left and bottom edges fall, in meters from the left edge and
    // bottom of the window as finally measured.
    struct View {
        var width: Int; var height: Int; var pixels: [UInt8]
        var pixelsPerMeter = 120.0
        var left = 0.0; var bottom = 0.0
    }
    struct Result: Equatable { var vertical: [Double]; var horizontal: [Double] }   // meters from the left / bottom edge
    static let maxDividers = 6
    static let edgeMargin = 0.12          // no pane is narrower than this, so nothing closer to a close-up's edge is a bar

    // views: close-ups of one window; size: the window's width and height in meters.
    static func find(_ views: [View], size: (width: Double, height: Double)) -> Result? {
        typealias Found = (lines: [Double], covers: ClosedRange<Double>)
        var vertical: [Found] = [], horizontal: [Found] = [], blindsV = 0, blindsH = 0
        for v in views where v.width >= 16 && v.height >= 16 && v.pixels.count == v.width * v.height && v.pixelsPerMeter > 0 {
            let w = Double(v.width) / v.pixelsPerMeter, h = Double(v.height) / v.pixelsPerMeter
            let mw = max(w * 0.06, edgeMargin), mh = max(h * 0.06, edgeMargin)
            if let lines = lines(v, across: true) {
                if w > 2 * mw { vertical.append((lines.map { $0 + v.left }, (v.left + mw)...(v.left + w - mw))) }
            } else { blindsV += 1 }
            if let lines = lines(v, across: false) {
                if h > 2 * mh { horizontal.append((lines.map { $0 + v.bottom }, (v.bottom + mh)...(v.bottom + h - mh))) }
            } else { blindsH += 1 }
        }
        guard !vertical.isEmpty || !horizontal.isEmpty || blindsV + blindsH > 0 else { return nil }
        // A divider counts when at least half the close-ups that cover its place show it, within 5 cm, and it is
        // at least 10 cm inside the window (a close-up taken while RoomPlan had the window larger can show the
        // glass edge as a line that the others don't cover).
        func vote(_ found: [Found], blinds: Int, extent: Double) -> [Double] {
            guard !found.isEmpty, blinds <= found.count else { return [] }
            var clusters: [[Double]] = []
            for x in found.flatMap({ $0.lines }).sorted() {
                if let last = clusters.last?.last, x - last <= 0.05 { clusters[clusters.count - 1].append(x) } else { clusters.append([x]) }
            }
            return clusters.compactMap { c -> Double? in
                let x = c.reduce(0, +) / Double(c.count)
                let covering = found.filter { $0.covers.contains(x) }.count
                let agree = found.filter { f in f.lines.contains { c.contains($0) } }.count
                guard agree >= max(1, (covering + 1) / 2), x > 0.1, x < extent - 0.1 else { return nil }
                return x
            }
        }
        let v = vote(vertical, blinds: blindsV, extent: size.width), h = vote(horizontal, blinds: blindsH, extent: size.height)
        return Result(vertical: v.count <= maxDividers ? v : [], horizontal: h.count <= maxDividers ? h : [])
    }

    // Bars running across at least 75% of a close-up, in meters from its left edge (across: vertical bars) or
    // from its bottom edge (horizontal bars). Nil when the pattern looks like blinds.
    static func lines(_ v: View, across: Bool) -> [Double]? {
        let along = across ? v.width : v.height, span = across ? v.height : v.width
        guard along >= 16, span >= 16 else { return [] }
        func px(_ a: Int, _ s: Int) -> Float { Float(across ? v.pixels[s * v.width + a] : v.pixels[a * v.width + s]) }
        // Along each line of pixels: how strongly each point stands out from both sides at once (a ridge or a
        // valley 2–7 px from it, about 1.5–12 cm wide). A step from glass to frame differs on one side only.
        var hits = [Int](repeating: 0, count: along), counted = 0
        var row = [Float](repeating: 0, count: along), response = [Float](repeating: 0, count: along)
        for s in stride(from: span / 10, to: span - span / 10, by: 1) {
            for a in 0..<along { row[a] = (px(max(0, a - 1), s) + 2 * px(a, s) + px(min(along - 1, a + 1), s)) / 4 }
            for a in 0..<along {
                var best: Float = 0
                for k in 2...7 where a - k >= 0 && a + k < along {
                    let l = row[a] - row[a - k], r = row[a] - row[a + k]
                    if l * r > 0 { best = max(best, min(abs(l), abs(r))) }
                }
                response[a] = best
            }
            let threshold = max(12, response.sorted()[along / 2] * 3)
            for a in 1..<(along - 1) where response[a] > threshold && response[a] >= response[a - 1] && response[a] >= response[a + 1] {
                for d in -1...1 { hits[a + d] += 1 }
            }
            counted += 1
        }
        guard counted > 0 else { return [] }
        let share = hits.map { Double($0) / Double(counted) }
        let perMeter = v.pixelsPerMeter, extent = Double(along) / perMeter
        let margin = max(Int(Double(along) * 0.06), Int(edgeMargin * perMeter))
        guard along - margin > margin else { return [] }
        // Strongest first; a weaker line within 6 cm of a stronger one is the same bar.
        let peaks = (max(1, margin)..<min(along - 1, along - margin)).filter { a in
            share[a] >= 0.75 && share[a] >= share[a - 1] && share[a] >= share[a + 1]
        }.sorted { share[$0] > share[$1] }
        var kept: [Int] = []
        for a in peaks where !kept.contains(where: { Double(abs($0 - a)) / perMeter < 0.06 }) { kept.append(a) }
        guard kept.count <= maxDividers else { return nil }
        return kept.map { (Double($0) + 0.5) / perMeter }
            .map { across ? $0 : extent - $0 }                        // rows count down from the top
            .sorted()
    }
}

// Openings RoomPlan missed, from LiDAR mesh triangles ARKit labelled window or door. Points within 15 cm of a
// wall are gathered on a 10 cm grid over the wall face; a filled patch of the right size that doesn't overlap an
// existing opening becomes a window or door, marked for review (Review → Restore hides it again).
enum LidarOpenings {
    struct Point { var plan: PlanPoint; var height: Double }       // height above the floor
    struct Report: Equatable { var windows = 0; var doors = 0 }

    @discardableResult
    static func add(_ project: inout RoomProject, windows: [Point], doors: [Point]) -> Report {
        var report = Report()
        for (kind, points) in [(SurfaceKind.window, windows), (.door, doors)] where points.count >= 20 {
            for wall in project.walls where wall.length >= 0.5 {
                let d = wall.direction, n = PlanPoint(x: -d.z, z: d.x), cell = 0.1
                var cells = Set<[Int]>()
                for p in points {
                    let s = (p.plan - wall.a).dot(d)
                    guard abs((p.plan - wall.a).dot(n)) <= 0.15, s >= 0, s <= wall.length, p.height >= 0, p.height <= wall.height + 0.1 else { continue }
                    cells.insert([Int(s / cell), Int(p.height / cell)])
                }
                var unvisited = cells
                while let seed = unvisited.first {
                    var component: [[Int]] = [], queue = [seed]; unvisited.remove(seed)
                    while let c = queue.popLast() {
                        component.append(c)
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-2, 0), (2, 0), (0, -2), (0, 2)] {
                            let next = [c[0] + dx, c[1] + dy]
                            if unvisited.remove(next) != nil { queue.append(next) }
                        }
                    }
                    let s0 = Double(component.map { $0[0] }.min()!) * cell, s1 = Double(component.map { $0[0] }.max()! + 1) * cell
                    let h0 = Double(component.map { $0[1] }.min()!) * cell, h1 = Double(component.map { $0[1] }.max()! + 1) * cell
                    let fill = Double(component.count) / ((s1 - s0) * (h1 - h0) / (cell * cell))
                    let width = s1 - s0, height = h1 - h0
                    guard fill >= 0.35 else { continue }
                    let shape = kind == .window ? (width >= 0.4 && height >= 0.4) : (width >= 0.6 && width <= 2.4 && height >= 1.6 && h0 <= 0.25)
                    guard shape else { continue }
                    let taken = project.activeSurfaces.contains { o in
                        guard o.parentID == wall.id else { return false }
                        let o0 = min((o.a - wall.a).dot(d), (o.b - wall.a).dot(d)), o1 = max((o.a - wall.a).dot(d), (o.b - wall.a).dot(d))
                        return min(o1, s1) - max(o0, s0) > 0.3 * min(o1 - o0, width)
                    }
                    guard !taken else { continue }
                    let bottom = kind == .door ? 0 : h0, top = kind == .door ? max(h1, 2.0) : h1
                    let count = project.surfaces.filter { $0.kind == kind }.count + 1
                    var opening = PlanSurface(label: "\(kind.title) \(count)", kind: kind, a: wall.a + d * s0, b: wall.a + d * s1,
                                              bottom: bottom, height: min(top - bottom, wall.height - bottom), parentID: wall.id,
                                              confidence: .low, evidence: .captured, reflectiveRisk: kind == .window)
                    opening.reviewNote = "Found by the LiDAR scan but not by RoomPlan. Confirm its size or delete it."
                    opening.autoCleanup = .init(reason: .lidarAdded, originalA: opening.a, originalB: opening.b)
                    project.surfaces.append(opening)
                    if kind == .window { report.windows += 1 } else { report.doors += 1 }
                }
            }
        }
        return report
    }
}

// Window and door edges from the LiDAR: the gap an opening leaves in the points measured on its wall's surface.
// RoomPlan's opening boxes are often several centimetres off (on real scans: a window 6 cm narrower than its gap,
// a sill drawn 15 cm too high). Each edge moves to where the gap ends, but only where solid wall is measured just
// beyond it; edges hidden by furniture or not seen stay where RoomPlan put them. Window dividers keep their place.
// Walls should already sit on their measured surface (WallFit). Changes are recorded for Review → Restore.
enum LidarOpeningEdges {
    static let cell = 0.02                // 2 cm columns and rows
    static let band = 0.06                // points within this of the wall's face count as wall surface
    static let maxSideMove = 0.15, maxHeightMove = 0.20         // per edge

    @discardableResult
    static func apply(_ project: inout RoomProject, wallPoints: [LidarOpenings.Point]) -> Int {
        guard wallPoints.count >= 50 else { return 0 }
        var changed = 0
        for i in project.surfaces.indices {
            let o = project.surfaces[i]
            guard o.kind.isCutout, !o.excluded, o.autoCleanup?.reason != .lidarAdded, let parent = o.parentID,
                  let wall = project.walls.first(where: { $0.id == parent }), wall.length >= 0.5 else { continue }
            let d = wall.direction, n = PlanPoint(x: -d.z, z: d.x)
            let ta = (o.a - wall.a).dot(d), tb = (o.b - wall.a).dot(d)
            var s0 = min(ta, tb), s1 = max(ta, tb), y0 = o.bottom, y1 = o.bottom + o.height
            let top = wall.bottom + wall.height
            // This wall's surface points near the opening: (along the wall, height).
            let near = wallPoints.compactMap { p -> (s: Double, h: Double)? in
                let v = p.plan - wall.a, s = v.dot(d)
                guard abs(v.dot(n)) <= band, s >= s0 - 0.5, s <= s1 + 0.5, p.height >= y0 - 0.5, p.height <= y1 + 0.5 else { return nil }
                return (s, p.height)
            }
            guard near.count >= 40 else { continue }

            // Sides: columns across the middle of the opening's height.
            let (lo, hi) = o.kind == .window ? (y0 + 0.25 * (y1 - y0), y1 - 0.25 * (y1 - y0)) : (max(y0, 0.4), min(y1 - 0.2, 1.8))
            if hi - lo >= 0.2, let edges = gap(near.filter { $0.h >= lo && $0.h <= hi }.map(\.s), from: s0 - 0.4, to: s1 + 0.4, old: (s0, s1), limit: maxSideMove) {
                let n0 = max(0, edges.0 ?? s0), n1 = min(wall.length, edges.1 ?? s1)
                if n1 - n0 >= 0.3 { s0 = n0; s1 = n1 }
            }
            // Sill (windows) and head: rows across the middle of the (new) width.
            let c0 = s0 + 0.25 * (s1 - s0), c1 = s1 - 0.25 * (s1 - s0)
            let heights = near.filter { $0.s >= c0 && $0.s <= c1 }.map(\.h)
            if let edges = gap(heights, from: max(0, y0 - 0.4), to: min(top, y1 + 0.4), old: (y0, y1), limit: maxHeightMove) {
                if o.kind == .window, let sill = edges.0, sill > 0.05 { y0 = sill }
                if let head = edges.1, head < top - 0.02 { y1 = head }
                if y1 - y0 < 0.3 { y0 = o.bottom; y1 = o.bottom + o.height }
            }
            guard abs(s0 - min(ta, tb)) > 0.005 || abs(s1 - max(ta, tb)) > 0.005 || abs(y0 - o.bottom) > 0.005 || abs(y1 - o.bottom - o.height) > 0.005 else { continue }

            if project.surfaces[i].autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: .lidarAligned, originalA: o.a, originalB: o.b) }
            if project.surfaces[i].autoCleanup?.originalBottom == nil { project.surfaces[i].autoCleanup?.originalBottom = o.bottom }
            if project.surfaces[i].autoCleanup?.originalHeight == nil { project.surfaces[i].autoCleanup?.originalHeight = o.height }
            // Keep a's end as a's end, and dividers where they were along the wall and above the floor.
            let forward = ta <= tb, newA = forward ? s0 : s1, newB = forward ? s1 : s0
            project.surfaces[i].a = wall.a + d * newA; project.surfaces[i].b = wall.a + d * newB
            project.surfaces[i].bottom = y0; project.surfaces[i].height = y1 - y0
            let length = s1 - s0
            if let dividers = o.dividers {
                project.surfaces[i].dividers = dividers.map { forward ? ta + $0 - newA : newA - (ta - $0) }.filter { $0 > 0.05 && $0 < length - 0.05 }.sorted()
            }
            if let rails = o.rails { project.surfaces[i].rails = rails.map { $0 + o.bottom - y0 }.filter { $0 > 0.05 && $0 < y1 - y0 - 0.05 } }
            project.surfaces[i].evidence = .edited; project.surfaces[i].reviewed = false
            changed += 1
        }
        return changed
    }

    // The gap around `old` in 1-D samples (positions along a line), between `from` and `to`. Each end is where
    // the wall's measured density (3-cell average) climbs back to half its usual level; it counts only when solid
    // wall fills at least 70% of the 20 cm beyond it. An end without that evidence (unseen, behind furniture,
    // the wall ending) is nil. Nil overall when the middle isn't open, or when an end moved further than `limit`:
    // evidence that disagrees that much with RoomPlan is more likely trim, a curtain or a pillar than the edge.
    static func gap(_ samples: [Double], from: Double, to: Double, old: (Double, Double), limit: Double) -> (Double?, Double?)? {
        let count = Int(((to - from) / cell).rounded(.up))
        guard count >= 10 else { return nil }
        var cells = [Int](repeating: 0, count: count)
        for x in samples where x >= from && x < to { cells[min(count - 1, Int((x - from) / cell))] += 1 }
        func index(_ x: Double) -> Int { min(count - 1, max(0, Int((x - from) / cell))) }
        let outside = cells.indices.filter { $0 < index(old.0) - 1 || $0 > index(old.1) + 1 }.map { cells[$0] }.filter { $0 > 0 }.sorted()
        guard outside.count >= 5 else { return nil }
        let usual = Double(outside[outside.count / 2])
        let smooth = cells.indices.map { i in Double((max(0, i - 1)...min(count - 1, i + 1)).reduce(0) { $0 + cells[$1] }) / 3 }
        let middle = index((old.0 + old.1) / 2)
        guard smooth[middle] < 0.25 * usual else { return nil }
        var lo = middle, hi = middle
        while lo - 1 >= 0 && smooth[lo - 1] < 0.5 * usual { lo -= 1 }
        while hi + 1 < count && smooth[hi + 1] < 0.5 * usual { hi += 1 }
        func confirmed(_ beyond: [Int]) -> Bool {
            let inside = beyond.filter { $0 >= 0 && $0 < count }
            return inside.count >= 3 && Double(inside.filter { Double(cells[$0]) >= 0.25 * usual }.count) >= 0.7 * Double(inside.count)
        }
        // A gap running on past the search range is further out than `limit` (unless a wall end cut the range).
        if (lo == 0 && old.0 - from > limit) || (hi == count - 1 && to - old.1 > limit) { return nil }
        let e0 = from + Double(lo) * cell, e1 = from + Double(hi + 1) * cell
        let start = lo >= 1 && confirmed(Array((lo - 10)..<lo)) ? e0 : nil
        let end = hi + 1 < count && confirmed(Array((hi + 1)...(hi + 10))) ? e1 : nil
        if let start, abs(start - old.0) > limit { return nil }
        if let end, abs(end - old.1) > limit { return nil }
        return (start, end)
    }
}

// Wall heights from the LiDAR: the floor and ceiling the mesh measured (median heights of floor- and
// ceiling-labelled triangles). Full-height walls RoomPlan made 3–40 cm too short or tall are corrected.
// roomFloor: RoomPlan's floor (world y), which heights in the project are measured from. RoomPlan can put the
// floor a few centimetres off (4.4 cm low on a real scan), which moves every sill and head height by as much;
// within 15 cm, window and mirror heights are re-measured from the LiDAR floor, and the tops of doors and
// openings (which stay on the floor) move with it.
enum LidarLevels {
    @discardableResult
    static func apply(_ project: inout RoomProject, floor: Double, ceiling: Double, roomFloor: Double? = nil) -> Int {
        let measured = ceiling - floor
        guard measured > 1.8, measured < 8 else { return 0 }
        var changed = 0
        func record(_ i: Int) {
            let s = project.surfaces[i]
            if s.autoCleanup == nil { project.surfaces[i].autoCleanup = .init(reason: .lidarAligned, originalA: s.a, originalB: s.b) }
            if project.surfaces[i].autoCleanup?.originalHeight == nil { project.surfaces[i].autoCleanup?.originalHeight = s.height }
            if project.surfaces[i].autoCleanup?.originalBottom == nil { project.surfaces[i].autoCleanup?.originalBottom = s.bottom }
            project.surfaces[i].evidence = .edited
        }
        if let roomFloor, case let shift = floor - roomFloor, abs(shift) > 0.005, abs(shift) <= 0.15 {
            for i in project.surfaces.indices where project.surfaces[i].kind != .wall || project.surfaces[i].bottom >= 0.05 {
                let s = project.surfaces[i]
                record(i)
                if s.bottom < 0.05 && s.kind != .wall { project.surfaces[i].height = max(0.1, s.height - shift) }
                else { project.surfaces[i].bottom = s.bottom - shift }
            }
        }
        for i in project.surfaces.indices where project.surfaces[i].kind == .wall && !project.surfaces[i].excluded && project.surfaces[i].bottom < 0.05 {
            let s = project.surfaces[i], off = abs(s.height - measured)
            guard off >= 0.03, off <= 0.4 else { continue }
            record(i)
            project.surfaces[i].height = measured
            changed += 1
        }
        return changed
    }
}
