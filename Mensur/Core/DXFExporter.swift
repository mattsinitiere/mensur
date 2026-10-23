import Foundation

enum DXFExporter {
    static let layers: [(String, Int)] = [
        ("WALLS", 7), ("WALL-HATCH", 8), ("DOORS", 3), ("DOOR-SWINGS", 3), ("WINDOWS", 4), ("OPENINGS", 8), ("MIRRORS", 6),
        ("DIMENSIONS", 8), ("SPACES", 7), ("MARKERS", 30), ("STAIRS", 7), ("CEILING", 5), ("FURNITURE", 8), ("ANNOTATIONS", 7)
    ]

    // R12 DXF in meters, X = plan x, Y = −plan z, with a layer per kind of element so CAD users can switch
    // walls, dimensions, markers and furniture on and off.
    static func text(_ room: RoomProject, style: PlanGeometry.DimensionStyle = .chained) -> String {
        var out: [String] = []
        func pair(_ group: Int, _ value: String) { out += [String(group), value] }
        func number(_ v: Double) -> String { ModelMesh.number(v) }
        func point(_ p: PlanPoint) { pair(10, number(p.x)); pair(20, number(-p.z)); pair(30, "0") }
        func line(_ a: PlanPoint, _ b: PlanPoint, layer: String) {
            pair(0, "LINE"); pair(8, layer); point(a)
            pair(11, number(b.x)); pair(21, number(-b.z)); pair(31, "0")
        }
        func polygon(_ pts: [PlanPoint], layer: String) { for i in pts.indices { line(pts[i], pts[(i + 1) % pts.count], layer: layer) } }
        func label(_ text: String, at p: PlanPoint, height: Double = 0.10, layer: String = "ANNOTATIONS", angle: Double = 0) {
            pair(0, "TEXT"); pair(8, layer); point(p); pair(40, number(height))
            // AC1009 DXF text kept ASCII for predictable CAD interoperability.
            let ascii = text.replacingOccurrences(of: "′", with: "'").replacingOccurrences(of: "″", with: "\"").replacingOccurrences(of: "²", with: "2")
                .unicodeScalars.map { $0.value >= 32 && $0.value <= 126 ? String($0) : "?" }.joined()
            pair(1, ascii); pair(50, number(angle))
        }
        func circle(_ c: PlanPoint, radius: Double, layer: String) { pair(0, "CIRCLE"); pair(8, layer); point(c); pair(40, number(radius)) }
        // DXF's Y is the plan's −Z, which mirrors angles: a plan arc from s to e becomes −s to −e, and DXF
        // arcs always run counter-clockwise from 50 to 51.
        func arc(_ a: PlanGeometry.Arc, layer: String) {
            var s = -a.start * 180 / .pi, e = -a.end * 180 / .pi
            if e < s { swap(&s, &e) }
            func norm(_ d: Double) -> Double { var x = d.truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x }
            pair(0, "ARC"); pair(8, layer); point(a.center); pair(40, number(a.radius)); pair(50, number(norm(s))); pair(51, number(norm(e)))
        }
        func textAngle(_ d: PlanPoint) -> Double { Geometry.uprightTextAngle(dx: d.x, dy: -d.z) * 180 / .pi }

        pair(0, "SECTION"); pair(2, "HEADER"); pair(9, "$ACADVER"); pair(1, "AC1009")
        pair(9, "$MEASUREMENT"); pair(70, "1"); pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "TABLES"); pair(0, "TABLE"); pair(2, "LAYER"); pair(70, String(layers.count))
        for (layer, color) in layers {
            pair(0, "LAYER"); pair(2, layer); pair(70, "0"); pair(62, String(color)); pair(6, "CONTINUOUS")
        }
        pair(0, "ENDTAB"); pair(0, "ENDSEC"); pair(0, "SECTION"); pair(2, "ENTITIES")

        // Walls: the scanned inside face, plus the outer face, ends and hatching where a thickness is set.
        let bands = PlanGeometry.wallBands(room), banded = Set(bands.map(\.wall.id))
        for band in bands {
            for piece in band.pieces {
                polygon(piece, layer: "WALLS")
                for (a, b) in PlanGeometry.hatch(piece, type: band.wall.wallType ?? .stud, spacing: 0.06) { line(a, b, layer: "WALL-HATCH") }
            }
        }
        for s in room.activeSurfaces {
            switch s.kind {
            case .wall:
                if !banded.contains(s.id) { for (a, b) in visibleWallSegments(s, room: room) { line(a, b, layer: "WALLS") } }
            case .door:
                line(s.a, s.b, layer: "DOORS")
                let symbol = PlanGeometry.doorSymbol(s, room: room)
                for (a, b) in symbol.solid + symbol.dashed { line(a, b, layer: "DOOR-SWINGS") }
                for a in symbol.arcs { arc(a, layer: "DOOR-SWINGS") }
            case .window, .mirror:
                let layer = s.kind == .window ? "WINDOWS" : "MIRRORS"
                line(s.a, s.b, layer: layer)
                let n = PlanPoint(x: -s.direction.z, z: s.direction.x) * 0.035
                line(s.a + n, s.b + n, layer: layer); line(s.a - n, s.b - n, layer: layer)
                // Pane dividers: a bar across the window's double line at each one.
                for d in s.dividers ?? [] { let c = s.a + s.direction * d; line(c + n, c - n, layer: layer) }
            case .opening: line(s.a, s.b, layer: "OPENINGS")
            }
            let annotation = "\(s.label): \(ModelMesh.number(s.length)) m [\(s.evidence.rawValue)]" + (s.drawnThickness.map { " t=\(ModelMesh.number($0))" } ?? "")
            label(annotation, at: s.midpoint + PlanPoint(x: 0.05, z: -0.12), height: 0.06)
        }
        for d in DimensionLayout.lines(room, style: style) {
            line(d.a, d.b, layer: "DIMENSIONS")
            let tick = (d.direction + PlanPoint(x: -d.direction.z, z: d.direction.x)) * 0.06
            for t in d.ticks { line(t - tick, t + tick, layer: "DIMENSIONS") }
            for l in d.labels { label(l.text, at: l.at, height: 0.09, layer: "DIMENSIONS", angle: textAngle(d.direction)) }
        }
        let summary = RoomSummary(room)
        for (i, space) in summary.spaces.enumerated() {
            let at = Geometry.labelPoint(space.points)
            label(summary.spaceNames[i], at: at + PlanPoint(x: 0, z: -0.2), height: 0.14, layer: "SPACES")
            label(room.units.areaLabel(space.area), at: at, height: 0.11, layer: "SPACES")
            if let finishes = room.spaceLabel(space).flatMap(SVGExporter.finishLine) { label(finishes, at: at + PlanPoint(x: 0, z: 0.2), height: 0.07, layer: "SPACES") }
        }
        for m in room.markers ?? [] {
            circle(m.position, radius: 0.1, layer: "MARKERS")
            label(m.kind.code + (m.label.isEmpty ? "" : " " + m.label), at: m.position + PlanPoint(x: 0.13, z: 0.03), height: 0.08, layer: "MARKERS")
        }
        for stair in room.stairs ?? [] {
            let sym = PlanGeometry.stairSymbol(stair)
            polygon(sym.outline, layer: "STAIRS")
            for (a, b) in sym.treads + sym.arrow { line(a, b, layer: "STAIRS") }
            label(sym.label, at: sym.labelAt, height: 0.12, layer: "STAIRS")
        }
        for f in room.ceilings ?? [] {
            polygon(f.corners, layer: "CEILING")
            label("\(f.label.isEmpty ? f.kind.title : f.label) \(room.units.length(f.low))\(f.high.map { "-" + room.units.length($0) } ?? "")", at: (f.a + f.b) * 0.5, height: 0.08, layer: "CEILING")
        }
        for o in room.objects where !o.excluded {
            let dir = PlanPoint(x: cos(o.yaw), z: sin(o.yaw)), n = PlanPoint(x: -sin(o.yaw), z: cos(o.yaw))
            let c = PlanPoint(x: o.center.x, z: o.center.z)
            let dx = dir * (o.size.x / 2), dz = n * (o.size.z / 2)
            polygon([c - dx - dz, c + dx - dz, c + dx + dz, c - dx + dz], layer: "FURNITURE")
        }
        let bounds = PlanBounds(room.activeSurfaces.flatMap { [$0.a, $0.b] })
        label("MENSUR | METERS | X=AR X, Y=-AR Z | Measurement review required", at: .init(x: bounds.minX, z: bounds.maxZ + 1.4))
        label("Wall faces are scanned; thickness is typed, measured at reveals, or a wall-type default. Door swings are drawn as set in the app.", at: .init(x: bounds.minX, z: bounds.maxZ + 1.6))
        pair(0, "ENDSEC"); pair(0, "EOF")
        return out.joined(separator: "\n") + "\n"
    }

    static func visibleWallSegments(_ wall: PlanSurface, room: RoomProject) -> [(PlanPoint, PlanPoint)] {
        var intervals: [(Double, Double)] = []
        for s in room.activeSurfaces where s.parentID == wall.id && s.kind.isCutout && Geometry.openingIssue(s, in: room) == nil {
            let a = (s.a - wall.a).dot(wall.direction), b = (s.b - wall.a).dot(wall.direction)
            intervals.append((max(0, min(a, b)), min(wall.length, max(a, b))))
        }
        intervals.sort { $0.0 < $1.0 }
        var cursor = 0.0, result: [(PlanPoint, PlanPoint)] = []
        for (a, b) in intervals {
            if a > cursor { result.append((wall.a + wall.direction * cursor, wall.a + wall.direction * a)) }
            cursor = max(cursor, b)
        }
        if cursor < wall.length { result.append((wall.a + wall.direction * cursor, wall.b)) }
        return result
    }
}
