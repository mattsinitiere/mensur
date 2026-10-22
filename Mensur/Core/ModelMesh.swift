import Foundation

struct MeshPart {
    var name: String
    var material: String
    var vertices: [Vector3]
    var faces: [[Int]]
}

enum ModelMesh {
    static let materialLibrary = """
    newmtl wall
    Kd 0.80 0.82 0.84
    newmtl glass
    Kd 0.30 0.70 0.86
    d 0.30
    newmtl mirror
    Kd 0.50 0.58 0.68
    newmtl frame
    Kd 0.93 0.94 0.95
    newmtl furniture
    Kd 0.59 0.66 0.61
    newmtl floor
    Kd 0.88 0.87 0.83
    """

    static func box(name: String, material: String, a: PlanPoint, b: PlanPoint,
                    bottom: Double, height: Double, thickness: Double) -> MeshPart {
        let d = b - a, l = max(d.magnitude, 0.001)
        let n = PlanPoint(x: -d.z / l, z: d.x / l) * (thickness / 2)
        let corners = [a - n, b - n, b + n, a + n]
        let vertices = corners.map { Vector3(x: $0.x, y: bottom, z: $0.z) }
            + corners.map { Vector3(x: $0.x, y: bottom + height, z: $0.z) }
        return .init(name: name, material: material, vertices: vertices,
                     faces: [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]])
    }

    static func parts(_ project: RoomProject, includeObjects: Bool = true) -> [MeshPart] {
        var result: [MeshPart] = []
        for wall in project.walls {
            let openings = project.activeSurfaces.filter {
                $0.parentID == wall.id && $0.kind.isCutout && Geometry.openingIssue($0, in: project) == nil
            }
            // Rectangular wall patches preserve holes for every valid door/window/opening.
            var xs = [0.0, wall.length], ys = [wall.bottom, wall.bottom + wall.height]
            var holes: [(Double, Double, Double, Double)] = []
            for o in openings {
                let t1 = (o.a - wall.a).dot(wall.direction), t2 = (o.b - wall.a).dot(wall.direction)
                let x0 = max(0, min(t1, t2)), x1 = min(wall.length, max(t1, t2))
                let y0 = max(wall.bottom, o.bottom), y1 = min(wall.bottom + wall.height, o.bottom + o.height)
                guard x1 > x0, y1 > y0 else { continue }
                holes.append((x0, x1, y0, y1)); xs += [x0, x1]; ys += [y0, y1]
            }
            xs = Array(Set(xs)).sorted(); ys = Array(Set(ys)).sorted()
            func solid(_ i: Int, _ j: Int) -> Bool {
                guard i >= 0, j >= 0, i < xs.count - 1, j < ys.count - 1 else { return false }
                let x = (xs[i] + xs[i + 1]) / 2, y = (ys[j] + ys[j + 1]) / 2
                return !holes.contains(where: { x > $0.0 && x < $0.1 && y > $0.2 && y < $0.3 })
            }
            for i in 0..<(xs.count - 1) {
                for j in 0..<(ys.count - 1) where solid(i, j) {
                    var patch = box(name: "wall_\(wall.id.uuidString)_\(i)_\(j)", material: "wall",
                                    a: wall.a + wall.direction * xs[i], b: wall.a + wall.direction * xs[i + 1],
                                    bottom: ys[j], height: ys[j + 1] - ys[j], thickness: 0.06)
                    // Faces shared with the next patch are inside the wall; leaving them out keeps translucent
                    // walls free of seams. box() faces: bottom, top, front, end at b, back, end at a.
                    let inside = [solid(i, j - 1), solid(i, j + 1), false, solid(i + 1, j), false, solid(i - 1, j)]
                    patch.faces = patch.faces.enumerated().filter { !inside[$0.offset] }.map(\.element)
                    result.append(patch)
                }
            }
        }
        for s in project.activeSurfaces where s.kind == .window || s.kind == .mirror {
            let offset = s.kind == .mirror ? PlanPoint(x: -s.direction.z, z: s.direction.x) * 0.04 : .zero
            result.append(box(name: "\(s.kind.rawValue)_\(s.id.uuidString)", material: s.kind == .window ? "glass" : "mirror",
                              a: s.a + offset, b: s.b + offset, bottom: s.bottom, height: s.height, thickness: 0.012))
            guard s.kind == .window else { continue }
            // A frame round the window (4 cm, standing just proud of the 6 cm wall) and bars 2.5 cm wide between
            // panes, so it reads as a window from any side. Visualization only: not measured frame sizes.
            let d = s.direction, f = min(0.04, s.length / 6, s.height / 6), bar = 0.025, top = s.bottom + s.height
            let id = s.id.uuidString
            result += [
                box(name: "frame_\(id)_left", material: "frame", a: s.a, b: s.a + d * f, bottom: s.bottom, height: s.height, thickness: 0.08),
                box(name: "frame_\(id)_right", material: "frame", a: s.b - d * f, b: s.b, bottom: s.bottom, height: s.height, thickness: 0.08),
                box(name: "frame_\(id)_sill", material: "frame", a: s.a + d * f, b: s.b - d * f, bottom: s.bottom, height: f, thickness: 0.08),
                box(name: "frame_\(id)_head", material: "frame", a: s.a + d * f, b: s.b - d * f, bottom: top - f, height: f, thickness: 0.08)
            ]
            for (i, x) in (s.dividers ?? []).enumerated() where x > f && x < s.length - f {
                let c = s.a + d * x
                result.append(box(name: "mullion_\(id)_\(i)", material: "frame", a: c - d * (bar / 2), b: c + d * (bar / 2),
                                  bottom: s.bottom + f, height: s.height - 2 * f, thickness: 0.04))
            }
            for (i, r) in (s.rails ?? []).enumerated() where r > f && r < s.height - f {
                result.append(box(name: "transom_\(id)_\(i)", material: "frame", a: s.a + d * f, b: s.b - d * f,
                                  bottom: s.bottom + r - bar / 2, height: bar, thickness: 0.04))
            }
        }
        if includeObjects {
            for o in project.objects where !o.excluded {
                let dir = PlanPoint(x: cos(o.yaw), z: sin(o.yaw))
                let c = PlanPoint(x: o.center.x, z: o.center.z)
                result.append(box(name: "object_\(o.id.uuidString)", material: "furniture", a: c - dir * (o.size.x / 2),
                                  b: c + dir * (o.size.x / 2), bottom: o.center.y - o.size.y / 2, height: o.size.y, thickness: o.size.z))
            }
        }
        let boundary = Geometry.boundary(project.walls)
        if boundary.area != nil {
            let floorY = project.walls.map(\.bottom).min() ?? 0
            result.append(.init(name: "approximate_floor", material: "floor",
                                vertices: boundary.points.map { .init(x: $0.x, y: floorY, z: $0.z) },
                                faces: triangulate(boundary.points)))
        }
        return result
    }

    // Ear clipping preserves concave room footprints. Collinear points are removed first.
    static func triangulate(_ points: [PlanPoint]) -> [[Int]] {
        guard points.count >= 3 else { return [] }
        var indices = Array(points.indices)
        if Geometry.signedArea(points) < 0 { indices.reverse() }
        var faces: [[Int]] = [], budget = points.count * points.count
        while indices.count > 3 && budget > 0 {
            budget -= 1
            var found = false
            for i in indices.indices {
                let a = indices[(i + indices.count - 1) % indices.count], b = indices[i], c = indices[(i + 1) % indices.count]
                let turn = Geometry.cross(points[b] - points[a], points[c] - points[b])
                if abs(turn) < 1e-10 { indices.remove(at: i); found = true; break }
                guard turn > 0 else { continue }
                let occupied = indices.contains { k in
                    guard k != a && k != b && k != c else { return false }
                    let p = points[k]
                    return Geometry.cross(points[b] - points[a], p - points[a]) >= -1e-10
                        && Geometry.cross(points[c] - points[b], p - points[b]) >= -1e-10
                        && Geometry.cross(points[a] - points[c], p - points[c]) >= -1e-10
                }
                if !occupied { faces.append([a, c, b]); indices.remove(at: i); found = true; break }
            }
            if !found { return [] }
        }
        if indices.count == 3 { faces.append([indices[0], indices[2], indices[1]]) }
        return faces
    }

    static func obj(_ project: RoomProject) -> String {
        var lines = ["# Mensur corrected model. Units: meters; Y up.",
                     "# Wall thickness 0.06m is visualization only, not measured construction thickness.",
                     "mtllib Corrected-model.mtl"]
        var offset = 1
        for part in parts(project) {
            lines += ["o \(part.name)", "usemtl \(part.material)"]
            lines += part.vertices.map { "v \(number($0.x)) \(number($0.y)) \(number($0.z))" }
            lines += part.faces.map { "f " + $0.map { String($0 + offset) }.joined(separator: " ") }
            offset += part.vertices.count
        }
        return lines.joined(separator: "\n") + "\n"
    }
    static func number(_ n: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), n) }
}
