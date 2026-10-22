import Foundation

enum DXFExporter {
    static func text(_ room: RoomProject) -> String {
        var out: [String] = []
        func pair(_ group: Int, _ value: String) { out += [String(group), value] }
        func point(_ p: PlanPoint) { pair(10, ModelMesh.number(p.x)); pair(20, ModelMesh.number(-p.z)); pair(30, "0") }
        func line(_ a: PlanPoint, _ b: PlanPoint, layer: String) {
            pair(0, "LINE"); pair(8, layer); point(a)
            pair(11, ModelMesh.number(b.x)); pair(21, ModelMesh.number(-b.z)); pair(31, "0")
        }
        func label(_ text: String, at p: PlanPoint, height: Double = 0.10) {
            pair(0, "TEXT"); pair(8, "ANNOTATIONS"); point(p); pair(40, ModelMesh.number(height))
            // AC1009 DXF text kept ASCII for predictable CAD interoperability.
            let ascii = text.unicodeScalars.map { $0.value >= 32 && $0.value <= 126 ? String($0) : "?" }.joined()
            pair(1, ascii); pair(50, "0")
        }
        pair(0, "SECTION"); pair(2, "HEADER"); pair(9, "$ACADVER"); pair(1, "AC1009")
        pair(9, "$MEASUREMENT"); pair(70, "1"); pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "TABLES"); pair(0, "TABLE"); pair(2, "LAYER"); pair(70, "7")
        for (layer, color) in [("WALLS",7), ("DOORS",3), ("WINDOWS",4), ("OPENINGS",8), ("MIRRORS",6), ("FURNITURE",8), ("ANNOTATIONS",7)] {
            pair(0, "LAYER"); pair(2, layer); pair(70, "0"); pair(62, String(color)); pair(6, "CONTINUOUS")
        }
        pair(0, "ENDTAB"); pair(0, "ENDSEC"); pair(0, "SECTION"); pair(2, "ENTITIES")
        for s in room.activeSurfaces {
            let layer: String
            switch s.kind { case .wall: layer = "WALLS"; case .door: layer = "DOORS"; case .window: layer = "WINDOWS"; case .opening: layer = "OPENINGS"; case .mirror: layer = "MIRRORS" }
            if s.kind == .wall {
                for (a, b) in visibleWallSegments(s, room: room) { line(a, b, layer: layer) }
            } else { line(s.a, s.b, layer: layer) }
            if s.kind == .window || s.kind == .mirror {
                let n = PlanPoint(x: -s.direction.z, z: s.direction.x) * 0.035
                line(s.a + n, s.b + n, layer: layer); line(s.a - n, s.b - n, layer: layer)
                // Pane dividers: a bar across the window's double line at each one.
                for d in s.dividers ?? [] { let c = s.a + s.direction * d; line(c + n, c - n, layer: layer) }
            }
            let annotation = "\(s.label): \(ModelMesh.number(s.length)) m [\(s.evidence.rawValue)]"
            label(annotation, at: s.midpoint + PlanPoint(x: 0.05, z: -0.12))
        }
        for o in room.objects where !o.excluded {
            let dir = PlanPoint(x: cos(o.yaw), z: sin(o.yaw)), n = PlanPoint(x: -sin(o.yaw), z: cos(o.yaw))
            let c = PlanPoint(x: o.center.x, z: o.center.z)
            let dx = dir * (o.size.x / 2), dz = n * (o.size.z / 2)
            let corners = [c - dx - dz, c + dx - dz, c + dx + dz, c - dx + dz]
            for i in corners.indices { line(corners[i], corners[(i + 1) % 4], layer: "FURNITURE") }
        }
        let bounds = PlanBounds(room.activeSurfaces.flatMap { [$0.a, $0.b] })
        label("MENSUR | METERS | X=AR X, Y=-AR Z | Measurement review required", at: .init(x: bounds.minX, z: bounds.maxZ + 0.5))
        label("Wall lines represent captured planes; thickness and door swings are not surveyed.", at: .init(x: bounds.minX, z: bounds.maxZ + 0.7))
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
