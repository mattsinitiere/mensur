import Foundation

// Ceiling features from the LiDAR points ARKit labels ceiling: a whole sloped ceiling, a barrel vault, and
// soffits and beams that hang below the main ceiling. Heights are above `floorY`. Everything found is
// marked `detected` for the user to review.
enum CeilingAnalysis {
    struct Result { var main: Double; var features: [CeilingFeature] }
    static let cell = 0.2

    static func analyse(_ points: [Vector3], floorY: Double) -> Result? {
        guard points.count >= 200 else { return nil }
        // Median height per 20 cm cell.
        var buckets: [Int: [Int: [Double]]] = [:]
        for p in points where p.isFinite {
            buckets[Int((p.x / cell).rounded(.down)), default: [:]][Int((p.z / cell).rounded(.down)), default: []].append(p.y - floorY)
        }
        var cells: [(i: Int, j: Int, h: Double)] = []
        for (i, row) in buckets { for (j, hs) in row where hs.count >= 3 { cells.append((i, j, hs.sorted()[hs.count / 2])) } }
        guard cells.count >= 12 else { return nil }
        func centre(_ c: (i: Int, j: Int, h: Double)) -> PlanPoint { .init(x: (Double(c.i) + 0.5) * cell, z: (Double(c.j) + 0.5) * cell) }

        // The main ceiling: the most common height (2 cm bins).
        var histogram: [Int: Int] = [:]
        for c in cells { histogram[Int((c.h / 0.02).rounded()), default: 0] += 1 }
        let main = Double(histogram.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }!.key) * 0.02

        if let slope = slope(cells.map { (centre($0), $0.h) }) { return Result(main: slope.low, features: [slope]) }
        if let vault = vault(cells.map { (centre($0), $0.h) }) { return Result(main: vault.low, features: [vault]) }

        // Soffits and beams: connected cells at least 8 cm below the main ceiling.
        let low = Dictionary(uniqueKeysWithValues: cells.filter { $0.h < main - 0.08 }.map { ("\($0.i),\($0.j)", $0) })
        var seen = Set<String>(), features: [CeilingFeature] = []
        for (key, start) in low where !seen.contains(key) {
            var component: [(i: Int, j: Int, h: Double)] = [], stack = [start]
            seen.insert(key)
            while let c = stack.popLast() {
                component.append(c)
                for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let k = "\(c.i + di),\(c.j + dj)"
                    if let n = low[k], !seen.contains(k) { seen.insert(k); stack.append(n) }
                }
            }
            guard component.count >= 4 else { continue }
            let pts = component.map(centre)
            let box = orientedBox(pts)
            let length = box.length + cell, width = box.width + cell
            let height = component.map(\.h).sorted()[component.count / 2]
            let isBeam = width <= 0.6 && length >= 1.2
            guard isBeam || length * width >= 0.5 else { continue }
            let half = box.direction * (length / 2)
            features.append(.init(kind: isBeam ? .beam : .soffit, a: box.centre - half, b: box.centre + half,
                                  width: width, low: height, high: nil, label: isBeam ? "Beam" : "Soffit", detected: true))
        }
        return Result(main: main, features: features.sorted { $0.footprintArea > $1.footprintArea })
    }

    // A single plane over the whole ceiling, tilted more than 3° and fitting within 4 cm.
    static func slope(_ samples: [(PlanPoint, Double)]) -> CeilingFeature? {
        // Least squares for h = gx·x + gz·z + c, in coordinates centred on the samples.
        let n = Double(samples.count)
        let mx = samples.reduce(0) { $0 + $1.0.x } / n, mz = samples.reduce(0) { $0 + $1.0.z } / n, mh = samples.reduce(0) { $0 + $1.1 } / n
        var sxx = 0.0, sxz = 0.0, szz = 0.0, sxh = 0.0, szh = 0.0
        for (p, h) in samples {
            let x = p.x - mx, z = p.z - mz, y = h - mh
            sxx += x * x; sxz += x * z; szz += z * z; sxh += x * y; szh += z * y
        }
        let det = sxx * szz - sxz * sxz
        guard abs(det) > 1e-9 else { return nil }
        let gx = (sxh * szz - szh * sxz) / det, gz = (szh * sxx - sxh * sxz) / det
        let tilt = (gx * gx + gz * gz).squareRoot()
        guard tilt > tan(3 * Double.pi / 180) else { return nil }
        let rms = (samples.reduce(0) { s, e in let r = e.1 - (mh + gx * (e.0.x - mx) + gz * (e.0.z - mz)); return s + r * r } / n).squareRoot()
        guard rms < 0.04 else { return nil }
        let d = PlanPoint(x: gx / tilt, z: gz / tilt), side = PlanPoint(x: -d.z, z: d.x)
        let along = samples.map { ($0.0 - PlanPoint(x: mx, z: mz)).dot(d) }, across = samples.map { ($0.0 - PlanPoint(x: mx, z: mz)).dot(side) }
        guard let a0 = along.min(), let a1 = along.max(), let c0 = across.min(), let c1 = across.max() else { return nil }
        let centre = PlanPoint(x: mx, z: mz) + side * ((c0 + c1) / 2)
        return .init(kind: .slope, a: centre + d * a0, b: centre + d * a1, width: c1 - c0 + cell,
                     low: mh + tilt * a0, high: mh + tilt * a1, label: "Sloped ceiling", detected: true)
    }

    // A barrel vault: heights across one principal direction fit a downward parabola rising at least 20 cm,
    // while staying level along the other.
    static func vault(_ samples: [(PlanPoint, Double)]) -> CeilingFeature? {
        let pts = samples.map(\.0), box = orientedBox(pts)
        let axis = box.direction, across = PlanPoint(x: -axis.z, z: axis.x)
        for (dir, perp) in [(axis, across), (across, axis)] {
            let u = samples.map { ($0.0 - box.centre).dot(perp) }, h = samples.map(\.1)
            // Least squares for h = p·u² + q·u + r.
            var s = [Double](repeating: 0, count: 7)          // Σu⁰…Σu⁴, Σh, Σuh — then Σu²h below
            var su2h = 0.0
            for (x, y) in zip(u, h) { s[0] += 1; s[1] += x; s[2] += x * x; s[3] += x * x * x; s[4] += x * x * x * x; s[5] += y; s[6] += x * y; su2h += x * x * y }
            let m = [[s[4], s[3], s[2]], [s[3], s[2], s[1]], [s[2], s[1], s[0]]], rhs = [su2h, s[6], s[5]]
            guard let sol = solve3(m, rhs) else { continue }
            let (p, q, r) = (sol[0], sol[1], sol[2])
            guard p < -0.05 else { continue }
            let residual = (zip(u, h).reduce(0) { a, e in let f = p * e.0 * e.0 + q * e.0 + r; return a + (e.1 - f) * (e.1 - f) } / Double(u.count)).squareRoot()
            guard residual < 0.04, let lo = u.min(), let hi = u.max() else { continue }
            let vertex = -q / (2 * p), crown = r - q * q / (4 * p)
            let spring = min(p * lo * lo + q * lo + r, p * hi * hi + q * hi + r)
            guard crown - spring >= 0.2, vertex > lo, vertex < hi else { continue }
            let along = samples.map { ($0.0 - box.centre).dot(dir) }
            guard let a0 = along.min(), let a1 = along.max() else { continue }
            let centre = box.centre + perp * ((lo + hi) / 2)
            return .init(kind: .vault, a: centre + dir * a0, b: centre + dir * a1, width: hi - lo + cell,
                         low: spring, high: crown, label: "Vaulted ceiling", detected: true)
        }
        return nil
    }

    // Principal direction of a point cloud, with the extents along and across it.
    static func orientedBox(_ pts: [PlanPoint]) -> (centre: PlanPoint, direction: PlanPoint, length: Double, width: Double) {
        let n = Double(max(1, pts.count)), mean = pts.reduce(PlanPoint.zero, +) * (1 / n)
        var xx = 0.0, xz = 0.0, zz = 0.0
        for p in pts { let d = p - mean; xx += d.x * d.x; xz += d.x * d.z; zz += d.z * d.z }
        let angle = 0.5 * atan2(2 * xz, xx - zz)
        let dir = PlanPoint(x: cos(angle), z: sin(angle)), perp = PlanPoint(x: -dir.z, z: dir.x)
        let along = pts.map { ($0 - mean).dot(dir) }, across = pts.map { ($0 - mean).dot(perp) }
        let a0 = along.min() ?? 0, a1 = along.max() ?? 0, c0 = across.min() ?? 0, c1 = across.max() ?? 0
        return (mean + dir * ((a0 + a1) / 2) + perp * ((c0 + c1) / 2), dir, a1 - a0, c1 - c0)
    }

    static func solve3(_ m: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { col in
            var a = m
            for row in 0..<3 { a[row][col] = b[row] }
            return det(a) / d
        }
    }
}
