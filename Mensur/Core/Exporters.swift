import Foundation

private let posix = Locale(identifier: "en_US_POSIX")

// Labels and positions for dimension strings, in world meters, shared by the SVG and DXF writers (the
// screen draws the same chains in points). `offset` is how far beyond the outer face each tier sits.
enum DimensionLayout {
    struct Line { var a: PlanPoint; var b: PlanPoint; var ticks: [PlanPoint]; var labels: [(text: String, at: PlanPoint)]; var direction: PlanPoint }

    static func lines(_ room: RoomProject, style: PlanGeometry.DimensionStyle, tier0: Double = 0.45, tier1: Double = 0.85) -> [Line] {
        let units = room.units
        if style == .walls {
            let boundary = Geometry.boundary(room.walls)
            return room.walls.map { w in
                let n = Geometry.inwardNormal(w, walls: room.walls, boundary: boundary) * 0.3
                return Line(a: w.a + n, b: w.b + n, ticks: [w.a + n, w.b + n], labels: [(units.length(w.length), w.midpoint + n * 1.5)], direction: w.direction)
            }
        }
        var result: [Line] = []
        for chain in PlanGeometry.chains(room) {
            func at(_ t: Double, _ off: Double) -> PlanPoint { chain.origin + chain.direction * t + chain.normal * off }
            let first = chain.ticks.first!, last = chain.ticks.last!
            if style != .overall && chain.ticks.count > 2 {
                var labels: [(String, PlanPoint)] = []
                if style == .chained {
                    for (t0, t1) in zip(chain.ticks, chain.ticks.dropFirst()) { labels.append((units.length(t1 - t0), at((t0 + t1) / 2, tier0 + 0.12))) }
                } else {
                    for t in chain.ticks.dropFirst() { labels.append((units.length(t - first), at(t, tier0 + 0.12))) }
                }
                result.append(Line(a: at(first, tier0), b: at(last, tier0), ticks: chain.ticks.map { at($0, tier0) }, labels: labels, direction: chain.direction))
            }
            result.append(Line(a: at(first, tier1), b: at(last, tier1), ticks: [at(first, tier1), at(last, tier1)],
                               labels: [(units.length(last - first), at((first + last) / 2, tier1 + 0.12))], direction: chain.direction))
        }
        return result
    }
}

enum PlanColors {
    static let ink = "#1B2A3A", door = "#15803D", window = "#2563EB", opening = "#6B7280", mirror = "#7E22CE", ceiling = "#0E7490"
    static func marker(_ c: MarkerCategory) -> String {
        switch c { case .electrical: return "#B45309"; case .plumbing: return "#1D4ED8"; case .hvac: return "#0F766E"; case .other: return "#6B7280" }
    }
}

// MARK: SVG

// The plan as an SVG drawing at 1:50 (1 unit = 1 cm in the room), for proposals and web pages.
enum SVGExporter {
    static func text(_ room: RoomProject, style: PlanGeometry.DimensionStyle = .chained, title: String? = nil) -> String {
        let rotation = -Geometry.dominantAngle(room.walls)
        func r(_ p: PlanPoint) -> PlanPoint { Geometry.rotate(p, by: rotation) }
        func n(_ v: Double) -> String { String(format: "%.1f", locale: posix, v * 100) }
        func xy(_ p: PlanPoint) -> String { let q = r(p); return "\(n(q.x)),\(n(q.z))" }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        func poly(_ pts: [PlanPoint], _ cls: String) -> String { "<polygon class=\"\(cls)\" points=\"\(pts.map(xy).joined(separator: " "))\"/>" }
        func line(_ a: PlanPoint, _ b: PlanPoint, _ cls: String) -> String { let p = r(a), q = r(b); return "<line class=\"\(cls)\" x1=\"\(n(p.x))\" y1=\"\(n(p.z))\" x2=\"\(n(q.x))\" y2=\"\(n(q.z))\"/>" }
        // shift moves the text down the drawing (in meters), after the plan's rotation.
        func label(_ s: String, _ p: PlanPoint, size: Double, cls: String = "label", along: PlanPoint? = nil, weight: String = "400", shift: Double = 0) -> String {
            var q = r(p); q.z += shift
            var rotate = ""
            if let along { let d = Geometry.rotate(along, by: rotation); rotate = " transform=\"rotate(\(String(format: "%.2f", locale: posix, Geometry.uprightTextAngle(dx: d.x, dy: d.z) * 180 / .pi)) \(n(q.x)) \(n(q.z)))\"" }
            return "<text class=\"\(cls)\" x=\"\(n(q.x))\" y=\"\(n(q.z))\" font-size=\"\(String(format: "%.1f", locale: posix, size))\" font-weight=\"\(weight)\" text-anchor=\"middle\" dominant-baseline=\"middle\"\(rotate)>\(esc(s))</text>"
        }

        var points = room.activeSurfaces.flatMap { [$0.a, $0.b] }
        points += PlanGeometry.wallBands(room).flatMap { $0.pieces.flatMap { $0 } }
        points += (room.stairs ?? []).flatMap(\.corners) + (room.ceilings ?? []).flatMap(\.corners)
        let rotated = points.map(r), bounds = PlanBounds(rotated.isEmpty ? [.zero] : rotated)
        let margin = 1.4, minX = bounds.minX - margin, minZ = bounds.minZ - margin
        let w = bounds.width + 2 * margin, h = bounds.depth + 2 * margin + 0.8
        var out = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(minX)) \(n(minZ)) \(n(w)) \(n(h))\" width=\(quote(String(format: "%.1fcm", locale: posix, w * 2))) height=\(quote(String(format: "%.1fcm", locale: posix, h * 2)))>",
            "<title>\(esc(title ?? room.name))</title>",
            "<style>.label{font-family:Helvetica,Arial,sans-serif;fill:\(PlanColors.ink)} .dimtext{font-family:Helvetica,Arial,sans-serif;fill:#4B5563}",
            ".space{fill:#F3F6FB} .wall{fill:\(PlanColors.ink)} .wallhatch{fill:#CBD5E1;stroke:\(PlanColors.ink);stroke-width:1.2} .wallglass{fill:#DBEAFE;stroke:\(PlanColors.window);stroke-width:1}",
            ".hatch{stroke:\(PlanColors.ink);stroke-width:0.7} .thin{stroke:\(PlanColors.ink);stroke-width:4;stroke-linecap:square} .jamb{stroke:\(PlanColors.ink);stroke-width:1}",
            ".win{stroke:\(PlanColors.window);stroke-width:1.2;fill:none} .mirror{stroke:\(PlanColors.mirror);stroke-width:1.2;fill:none} .door{stroke:\(PlanColors.door);stroke-width:1.2;fill:none}",
            ".dash{stroke-dasharray:6 4} .open{stroke:\(PlanColors.opening);stroke-width:1.2;stroke-dasharray:6 4} .dim{stroke:#6B7280;stroke-width:0.6} .ceil{stroke:\(PlanColors.ceiling);stroke-width:0.9;stroke-dasharray:12 6;fill:none}",
            ".stair{stroke:\(PlanColors.ink);stroke-width:0.8;fill:none} .furn{fill:#E2E8E2;stroke:#9CA3AF;stroke-width:0.6}</style>",
            "<rect x=\"\(n(minX))\" y=\"\(n(minZ))\" width=\"\(n(w))\" height=\"\(n(h))\" fill=\"#ffffff\"/>"
        ]
        let summary = RoomSummary(room)
        for space in summary.spaces { out.append(poly(space.points, "space")) }
        for o in room.objects where !o.excluded {
            let d = PlanPoint(x: cos(o.yaw), z: sin(o.yaw)), nn = PlanPoint(x: -sin(o.yaw), z: cos(o.yaw)), c = PlanPoint(x: o.center.x, z: o.center.z)
            let dx = d * (o.size.x / 2), dz = nn * (o.size.z / 2)
            out.append(poly([c - dx - dz, c + dx - dz, c + dx + dz, c - dx + dz], "furn"))
        }
        for f in room.ceilings ?? [] {
            out.append(poly(f.corners, "ceil"))
            out.append(label("\(f.label.isEmpty ? f.kind.title : f.label) \(room.units.length(f.low))\(f.high.map { "–" + room.units.length($0) } ?? "")", (f.a + f.b) * 0.5, size: 9, cls: "dimtext"))
        }
        // Walls: bands with hatching where thickness is known, a heavy line otherwise.
        let bands = PlanGeometry.wallBands(room), banded = Set(bands.map(\.wall.id))
        for band in bands {
            let type = band.wall.wallType ?? .stud
            for piece in band.pieces {
                out.append(poly(piece, type == .glass ? "wallglass" : type == .stud || type == .partition ? "wall" : "wallhatch"))
                for (a, b) in PlanGeometry.hatch(piece, type: type, spacing: 0.06) { out.append(line(a, b, "hatch")) }
            }
            for (a, b) in band.jambs { out.append(line(a, b, "jamb")) }
        }
        for wall in room.walls where !banded.contains(wall.id) {
            for (a, b) in DXFExporter.visibleWallSegments(wall, room: room) { out.append(line(a, b, "thin")) }
        }
        for s in room.activeSurfaces where s.kind != .wall {
            switch s.kind {
            case .window, .mirror:
                let off = PlanPoint(x: -s.direction.z, z: s.direction.x) * 0.035, cls = s.kind == .window ? "win" : "mirror"
                out += [line(s.a + off, s.b + off, cls), line(s.a - off, s.b - off, cls), line(s.a, s.b, cls)]
                for d in s.dividers ?? [] { let c = s.a + s.direction * d; out.append(line(c + off, c - off, cls)) }
            case .door:
                let symbol = PlanGeometry.doorSymbol(s, room: room)
                out.append(line(s.a, s.b, "door dash"))
                for (a, b) in symbol.solid { out.append(line(a, b, "door")) }
                for (a, b) in symbol.dashed { out.append(line(a, b, "door dash")) }
                for arc in symbol.arcs { out.append(arcPath(arc, rotation: rotation, number: n, cls: "door")) }
            default: out.append(line(s.a, s.b, "open"))
            }
        }
        for stair in room.stairs ?? [] {
            let sym = PlanGeometry.stairSymbol(stair)
            out.append(poly(sym.outline, "stair"))
            for (a, b) in sym.treads + sym.arrow { out.append(line(a, b, "stair")) }
            out.append(label(sym.label, sym.labelAt, size: 10, weight: "600"))
        }
        for line_ in DimensionLayout.lines(room, style: style) {
            out.append(line(line_.a, line_.b, "dim"))
            let tick = (line_.direction + PlanPoint(x: -line_.direction.z, z: line_.direction.x)) * 0.06
            for t in line_.ticks { out.append(line(t - tick, t + tick, "dim")) }
            for l in line_.labels { out.append(label(l.text, l.at, size: 9, cls: "dimtext", along: line_.direction)) }
        }
        for (i, space) in summary.spaces.enumerated() {
            let at = Geometry.labelPoint(space.points)
            out.append(label(summary.spaceNames[i], at, size: 12, weight: "600", shift: -0.22))
            out.append(label(room.units.areaLabel(space.area), at, size: 11))
            if let finishes = room.spaceLabel(space).flatMap(finishLine) { out.append(label(finishes, at, size: 8, cls: "dimtext", shift: 0.22)) }
        }
        for m in room.markers ?? [] {
            let q = r(m.position), color = PlanColors.marker(m.kind.category)
            out.append("<circle cx=\"\(n(q.x))\" cy=\"\(n(q.z))\" r=\"11\" fill=\"#ffffff\" stroke=\"\(color)\" stroke-width=\"1\"/>")
            out.append("<text x=\"\(n(q.x))\" y=\"\(n(q.z))\" font-size=\"8\" font-weight=\"700\" fill=\"\(color)\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"Helvetica,Arial,sans-serif\">\(esc(m.kind.code))</text>")
        }
        let foot = PlanPoint(x: minX + 0.4, z: minZ + h - 0.45)
        let caption = [room.name, room.address, summary.totalArea.map { room.units.areaLabel($0) }, "1:50 at 100%", "Mensur"].compactMap { $0 }.joined(separator: " · ")
        out.append("<text class=\"label\" x=\"\(n(foot.x))\" y=\"\(n(foot.z))\" font-size=\"12\">\(esc(caption))</text>")
        out.append("</svg>")
        return out.joined(separator: "\n") + "\n"
    }
    private static func quote(_ s: String) -> String { "\"\(s)\"" }
    static func finishLine(_ label: SpaceLabel) -> String? {
        let parts = [("F", label.floorFinish), ("W", label.wallFinish), ("C", label.ceilingFinish), ("B", label.baseFinish)]
            .compactMap { k, v in (v ?? "").isEmpty ? nil : "\(k): \(v!)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private static func arcPath(_ arc: PlanGeometry.Arc, rotation: Double, number: (Double) -> String, cls: String) -> String {
        func point(_ angle: Double) -> PlanPoint { Geometry.rotate(arc.center + PlanPoint(x: cos(angle), z: sin(angle)) * arc.radius, by: rotation) }
        let p0 = point(arc.start), p1 = point(arc.end)
        let sweep = arc.end > arc.start ? 1 : 0, large = abs(arc.end - arc.start) > .pi ? 1 : 0
        return "<path class=\"\(cls)\" d=\"M \(number(p0.x)) \(number(p0.z)) A \(number(arc.radius)) \(number(arc.radius)) 0 \(large) \(sweep) \(number(p1.x)) \(number(p1.z))\"/>"
    }
}

// MARK: IFC

// An IFC4 model (ISO 10303-21) for Revit, ArchiCAD and other BIM tools: one storey per floor with its walls,
// doors, windows, furniture and spaces. Walls and openings are faceted solids built from the same parts as
// the OBJ; spaces are extruded from their outlines. IFC is Z-up: IFC x = plan x, IFC y = −plan z.
enum IFCExporter {
    struct Storey { var name: String; var elevation: Double; var rooms: [(room: RoomProject, place: (PlanPoint) -> PlanPoint)] }

    static func text(_ room: RoomProject) -> String {
        let name = room.level?.displayName ?? "Ground floor"
        return text(project: room.name, building: room.level?.building ?? room.name, storeys: [Storey(name: name, elevation: 0, rooms: [(room, { $0 })])])
    }

    static func text(project: String, building: String, storeys: [Storey], date: Date = Date()) -> String {
        var lines: [String] = [], next = 1
        func add(_ entity: String) -> String { let id = "#\(next)"; next += 1; lines.append("\(id)=\(entity);"); return id }
        func s(_ text: String) -> String {
            // STEP strings: ASCII, apostrophes doubled; other characters as \X2\ hex escapes.
            var out = ""
            for u in text.unicodeScalars {
                if u == "'" { out += "''" } else if u == "\\" { out += "\\\\" }
                else if u.value >= 32 && u.value < 127 { out.append(Character(u)) }
                else if u.value <= 0xFFFF { out += "\\X2\\" + String(format: "%04X", u.value) + "\\X0\\" }
            }
            return "'\(out)'"
        }
        func f(_ v: Double) -> String { let t = String(format: "%.6f", locale: posix, v); return t.contains(".") ? t : t + "." }
        func guid() -> String { s(IFCGuid.make()) }
        func point(_ x: Double, _ y: Double, _ z: Double) -> String { add("IFCCARTESIANPOINT((\(f(x)),\(f(y)),\(f(z))))") }

        let origin = point(0, 0, 0)
        let zAxis = add("IFCDIRECTION((0.,0.,1.))"), xAxis = add("IFCDIRECTION((1.,0.,0.))")
        let placement = add("IFCAXIS2PLACEMENT3D(\(origin),\(zAxis),\(xAxis))")
        let context = add("IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,1.E-05,\(placement),$)")
        let body = add("IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Body','Model',*,*,*,*,\(context),$,.MODEL_VIEW.,$)")
        let units = [add("IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.)"), add("IFCSIUNIT(*,.AREAUNIT.,$,.SQUARE_METRE.)"),
                     add("IFCSIUNIT(*,.VOLUMEUNIT.,$,.CUBIC_METRE.)"), add("IFCSIUNIT(*,.PLANEANGLEUNIT.,$,.RADIAN.)")]
        let unitAssignment = add("IFCUNITASSIGNMENT((\(units.joined(separator: ","))))")
        let projectID = add("IFCPROJECT(\(guid()),$,\(s(project)),$,$,$,$,(\(context)),\(unitAssignment))")
        let sitePlace = add("IFCLOCALPLACEMENT($,\(placement))")
        let site = add("IFCSITE(\(guid()),$,'Site',$,$,\(sitePlace),$,$,.ELEMENT.,$,$,$,$,$)")
        let buildingPlace = add("IFCLOCALPLACEMENT(\(sitePlace),\(placement))")
        let buildingID = add("IFCBUILDING(\(guid()),$,\(s(building)),$,$,\(buildingPlace),$,$,.ELEMENT.,$,$,$)")
        _ = add("IFCRELAGGREGATES(\(guid()),$,$,$,\(projectID),(\(site)))")
        _ = add("IFCRELAGGREGATES(\(guid()),$,$,$,\(site),(\(buildingID)))")

        var storeyIDs: [String] = []
        for storey in storeys {
            let storeyOrigin = point(0, 0, storey.elevation)
            let storeyAxes = add("IFCAXIS2PLACEMENT3D(\(storeyOrigin),\(zAxis),\(xAxis))")
            let storeyPlace = add("IFCLOCALPLACEMENT(\(buildingPlace),\(storeyAxes))")
            let storeyID = add("IFCBUILDINGSTOREY(\(guid()),$,\(s(storey.name)),$,$,\(storeyPlace),$,$,.ELEMENT.,\(f(storey.elevation)))")
            storeyIDs.append(storeyID)
            let local = add("IFCLOCALPLACEMENT(\(storeyPlace),\(placement))")
            var elements: [String] = [], spaces: [String] = []
            for (room, place) in storey.rooms {
                func brep(_ part: MeshPart) -> String {
                    let pts = part.vertices.map { v -> String in let p = place(PlanPoint(x: v.x, z: v.z)); return point(p.x, -p.z, v.y) }
                    let faces = part.faces.filter { $0.count >= 3 }.map { face -> String in
                        let loop = add("IFCPOLYLOOP((\(face.map { pts[$0] }.joined(separator: ","))))")
                        let bound = add("IFCFACEOUTERBOUND(\(loop),.T.)")
                        return add("IFCFACE((\(bound)))")
                    }
                    let shell = add("IFCCLOSEDSHELL((\(faces.joined(separator: ","))))")
                    return add("IFCFACETEDBREP(\(shell))")
                }
                func shape(_ parts: [MeshPart]) -> String {
                    let rep = add("IFCSHAPEREPRESENTATION(\(body),'Body','Brep',(\(parts.map(brep).joined(separator: ","))))")
                    return add("IFCPRODUCTDEFINITIONSHAPE($,$,(\(rep)))")
                }
                let parts = ModelMesh.parts(room, closedSolids: true)
                for wall in room.walls {
                    let pieces = parts.filter { $0.name.hasPrefix("wall_\(wall.id.uuidString)") }
                    guard !pieces.isEmpty else { continue }
                    elements.append(add("IFCWALL(\(guid()),$,\(s(wall.label)),\(s(wall.wallType?.title ?? "Wall")),$,\(local),\(shape(pieces)),$,.STANDARD.)"))
                }
                for o in room.activeSurfaces where o.kind == .door || o.kind == .window {
                    let host = room.walls.first { $0.id == o.parentID }
                    let depth = o.revealDepth ?? host?.drawnThickness ?? 0.06
                    let part = ModelMesh.box(name: o.label, material: "", a: o.a, b: o.b, bottom: o.bottom, height: o.height, thickness: min(depth, 0.1))
                    if o.kind == .door {
                        let op: String
                        switch o.doorStyle ?? .swing {
                        case .double: op = ".DOUBLE_DOOR_SINGLE_SWING."; case .sliding: op = ".SLIDING_TO_LEFT."
                        case .pocket: op = ".SLIDING_TO_LEFT."; case .bifold: op = ".FOLDING_TO_LEFT."
                        case .swing: op = o.hingeAtB == true ? ".SINGLE_SWING_RIGHT." : ".SINGLE_SWING_LEFT."
                        }
                        elements.append(add("IFCDOOR(\(guid()),$,\(s(o.label)),$,$,\(local),\(shape([part])),$,\(f(o.height)),\(f(o.length)),.DOOR.,\(op),$)"))
                    } else {
                        elements.append(add("IFCWINDOW(\(guid()),$,\(s(o.label)),$,$,\(local),\(shape([part])),$,\(f(o.height)),\(f(o.length)),.WINDOW.,.NOTDEFINED.,$)"))
                    }
                }
                for o in room.objects where !o.excluded {
                    let d = PlanPoint(x: cos(o.yaw), z: sin(o.yaw)), c = PlanPoint(x: o.center.x, z: o.center.z)
                    let part = ModelMesh.box(name: o.label, material: "", a: c - d * (o.size.x / 2), b: c + d * (o.size.x / 2),
                                             bottom: o.center.y - o.size.y / 2, height: o.size.y, thickness: o.size.z)
                    elements.append(add("IFCFURNITURE(\(guid()),$,\(s(o.label)),$,$,\(local),\(shape([part])),$,.NOTDEFINED.)"))
                }
                // Spaces: each enclosed outline extruded to the ceiling, named as on the plan.
                let summary = RoomSummary(room)
                let height = summary.ceilingHeight ?? 2.5, floor = room.walls.map(\.bottom).min() ?? 0
                for (i, space) in summary.spaces.enumerated() {
                    var pts = space.points.map { p -> String in let q = place(p); return add("IFCCARTESIANPOINT((\(f(q.x)),\(f(-q.z))))") }
                    pts.append(pts[0])
                    let curve = add("IFCPOLYLINE((\(pts.joined(separator: ","))))")
                    let profile = add("IFCARBITRARYCLOSEDPROFILEDEF(.AREA.,$,\(curve))")
                    let base = add("IFCAXIS2PLACEMENT3D(\(point(0, 0, floor)),\(zAxis),\(xAxis))")
                    let solid = add("IFCEXTRUDEDAREASOLID(\(profile),\(base),\(zAxis),\(f(height)))")
                    let rep = add("IFCSHAPEREPRESENTATION(\(body),'Body','SweptSolid',(\(solid)))")
                    let product = add("IFCPRODUCTDEFINITIONSHAPE($,$,(\(rep)))")
                    spaces.append(add("IFCSPACE(\(guid()),$,\(s(summary.spaceNames[i])),\(s(room.name)),$,\(local),\(product),\(s(summary.spaceNames[i])),.ELEMENT.,.INTERNAL.,$)"))
                }
            }
            if !elements.isEmpty { _ = add("IFCRELCONTAINEDINSPATIALSTRUCTURE(\(guid()),$,$,$,(\(elements.joined(separator: ","))),\(storeyID))") }
            if !spaces.isEmpty { _ = add("IFCRELAGGREGATES(\(guid()),$,$,$,\(storeyID),(\(spaces.joined(separator: ","))))") }
        }
        if !storeyIDs.isEmpty { _ = add("IFCRELAGGREGATES(\(guid()),$,$,$,\(buildingID),(\(storeyIDs.joined(separator: ","))))") }

        let stamp = ISO8601DateFormatter().string(from: date)
        let header = [
            "ISO-10303-21;", "HEADER;",
            "FILE_DESCRIPTION(('ViewDefinition [ReferenceView_V1.2]'),'2;1');",
            "FILE_NAME(\(s(project + ".ifc")),\(s(stamp)),(''),(''),'Mensur','Mensur','');",
            "FILE_SCHEMA(('IFC4'));", "ENDSEC;", "DATA;"
        ]
        return (header + lines + ["ENDSEC;", "END-ISO-10303-21;"]).joined(separator: "\n") + "\n"
    }
}

// IFC's 22-character compressed GUID: the 128 bits of a UUID in base 64 with IFC's alphabet.
enum IFCGuid {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")
    static func make(_ uuid: UUID = UUID()) -> String {
        let u = uuid.uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        // 2 bits, then 126 bits as 21 six-bit digits.
        var digits: [Int] = [Int(bytes[0] >> 6)]
        var bitBuffer = UInt32(bytes[0] & 0x3F), bits = 6
        for b in bytes.dropFirst() {
            bitBuffer = (bitBuffer << 8) | UInt32(b); bits += 8
            while bits >= 6 { bits -= 6; digits.append(Int((bitBuffer >> UInt32(bits)) & 0x3F)) }
        }
        return String(digits.map { alphabet[$0] })
    }
}

// MARK: Collada

// A COLLADA 1.4.1 (.dae) model for SketchUp and other 3D tools: meters, Y up, one node per wall, window,
// mirror, frame and furniture piece, coloured like the OBJ.
enum ColladaExporter {
    static let colors: [String: (Double, Double, Double, Double)] = [
        "wall": (0.80, 0.82, 0.84, 1), "glass": (0.30, 0.70, 0.86, 0.35), "mirror": (0.50, 0.58, 0.68, 1),
        "frame": (0.93, 0.94, 0.95, 1), "furniture": (0.59, 0.66, 0.61, 1), "floor": (0.88, 0.87, 0.83, 1)
    ]
    static func text(_ parts: [MeshPart], title: String, date: Date = Date()) -> String {
        func f(_ v: Double) -> String { String(format: "%.5f", locale: posix, v) }
        let stamp = ISO8601DateFormatter().string(from: date)
        let materials = Array(Set(parts.map(\.material))).sorted()
        var out = [
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
            "<COLLADA xmlns=\"http://www.collada.org/2005/11/COLLADASchema\" version=\"1.4.1\">",
            "<asset><contributor><authoring_tool>Mensur</authoring_tool><comments>\(title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "&", with: "&amp;"))</comments></contributor>",
            "<created>\(stamp)</created><modified>\(stamp)</modified><unit name=\"meter\" meter=\"1\"/><up_axis>Y_UP</up_axis></asset>",
            "<library_effects>"
        ]
        for m in materials {
            let c = colors[m] ?? (0.8, 0.8, 0.8, 1)
            out.append("<effect id=\"\(m)-fx\"><profile_COMMON><technique sid=\"common\"><lambert><diffuse><color>\(f(c.0)) \(f(c.1)) \(f(c.2)) 1</color></diffuse><transparency><float>\(f(c.3))</float></transparency></lambert></technique></profile_COMMON></effect>")
        }
        out.append("</library_effects><library_materials>")
        for m in materials { out.append("<material id=\"\(m)-mat\" name=\"\(m)\"><instance_effect url=\"#\(m)-fx\"/></material>") }
        out.append("</library_materials><library_geometries>")
        var nodes: [String] = []
        for (i, part) in parts.enumerated() {
            let id = "g\(i)"
            let positions = part.vertices.flatMap { [f($0.x), f($0.y), f($0.z)] }
            let triangles = part.faces.filter { $0.count >= 3 }.flatMap { face in (1..<(face.count - 1)).flatMap { [face[0], face[$0], face[$0 + 1]] } }
            out.append("<geometry id=\"\(id)\" name=\"\(part.name)\"><mesh>")
            out.append("<source id=\"\(id)-pos\"><float_array id=\"\(id)-pos-array\" count=\"\(positions.count)\">\(positions.joined(separator: " "))</float_array>")
            out.append("<technique_common><accessor source=\"#\(id)-pos-array\" count=\"\(part.vertices.count)\" stride=\"3\"><param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>")
            out.append("<vertices id=\"\(id)-vtx\"><input semantic=\"POSITION\" source=\"#\(id)-pos\"/></vertices>")
            out.append("<triangles material=\"\(part.material)\" count=\"\(triangles.count / 3)\"><input semantic=\"VERTEX\" source=\"#\(id)-vtx\" offset=\"0\"/><p>\(triangles.map(String.init).joined(separator: " "))</p></triangles>")
            out.append("</mesh></geometry>")
            nodes.append("<node id=\"n\(i)\" name=\"\(part.name)\"><instance_geometry url=\"#\(id)\"><bind_material><technique_common><instance_material symbol=\"\(part.material)\" target=\"#\(part.material)-mat\"/></technique_common></bind_material></instance_geometry></node>")
        }
        out.append("</library_geometries><library_visual_scenes><visual_scene id=\"scene\" name=\"Mensur\">")
        out += nodes
        out.append("</visual_scene></library_visual_scenes><scene><instance_visual_scene url=\"#scene\"/></scene></COLLADA>")
        return out.joined(separator: "\n") + "\n"
    }
}
