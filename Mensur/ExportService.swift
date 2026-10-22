import Foundation
import UIKit

@MainActor enum ExportService {
    // Moves exported files into ~/Downloads, never overwriting: a second export of the same name gets " 2".
    // Several files go together in one folder named after the room. Returns what was saved.
    static func saveToDownloads(_ urls: [URL], folderName: String) throws -> URL {
        let downloads = AppPaths.testRoot?.appendingPathComponent("Downloads", isDirectory: true) ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        func free(_ name: String, ext: String) -> URL {
            var n = 1
            while true {
                let candidate = downloads.appendingPathComponent(n == 1 ? name : "\(name) \(n)").appendingPathExtension(ext)
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                n += 1
            }
        }
        if urls.count == 1, let file = urls.first {
            let target = free(file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
            try FileManager.default.copyItem(at: file, to: target); return target
        }
        let safe = folderName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let folder = free("\(safe.isEmpty ? "Room" : String(safe.prefix(60))) – Mensur export", ext: "")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in urls { try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent)) }
        return folder
    }
    // The single 11 × 17 sheet on its own, named after the room.
    static func sheet(_ project: RoomProject, portrait: Bool) throws -> URL {
        let room = try project.validated()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mensur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = room.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Room" : String(safe.prefix(60))) – Floor plan 11x17 \(portrait ? "portrait" : "landscape").pdf")
        try PDFPlan.sheet(room, portrait: portrait).write(to: url, options: .atomic)
        return url
    }
    enum Kind { case pdfSet, svg, png, dxf, ifc, dae, obj }

    // One export format on its own, named after the room. `folder` is the room's folder, for its photos.
    static func files(_ project: RoomProject, _ kind: Kind, folder: URL, style: PlanGeometry.DimensionStyle) throws -> [URL] {
        let room = try project.validated()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mensur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = room.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "Room" : String(safe.prefix(60))
        func write(_ name: String, _ data: Data) throws -> URL { let url = dir.appendingPathComponent(name); try data.write(to: url, options: .atomic); return url }
        switch kind {
        case .pdfSet: return [try write("\(base) – Plan set.pdf", PDFSet.data(room, folder: folder, style: style))]
        case .svg: return [try write("\(base) – Plan.svg", Data(SVGExporter.text(room, style: style).utf8))]
        case .png: return [try write("\(base) – Plan.png", PlanImage.png(room, style: style))]
        case .dxf: return [try write("\(base) – Plan.dxf", Data(DXFExporter.text(room, style: style).utf8))]
        case .ifc: return [try write("\(base).ifc", Data(IFCExporter.text(room).utf8))]
        case .dae: return [try write("\(base).dae", Data(ColladaExporter.text(ModelMesh.parts(room), title: room.name).utf8))]
        case .obj: return [try write("Corrected-model.obj", Data(ModelMesh.obj(room).utf8)), try write("Corrected-model.mtl", Data(ModelMesh.materialLibrary.utf8))]
        }
    }
    static func export(_ project: RoomProject, originals: URL, style: PlanGeometry.DimensionStyle = .walls) throws -> [URL] {
        let room = try project.validated()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mensur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [URL] = []
        func write(_ name: String, _ data: Data) throws { let url = dir.appendingPathComponent(name); try data.write(to: url, options: .atomic); files.append(url) }
        try write("Project.json", ProjectStore.encoder().encode(room))
        try write("Floorplan.dxf", Data(DXFExporter.text(room, style: style).utf8))
        try write("Floorplan.svg", Data(SVGExporter.text(room, style: style).utf8))
        try write("Floorplan.png", PlanImage.png(room, style: style))
        try write("Corrected-model.obj", Data(ModelMesh.obj(room).utf8))
        try write("Corrected-model.mtl", Data(ModelMesh.materialLibrary.utf8))
        try write("Model.ifc", Data(IFCExporter.text(room).utf8))
        try write("Model.dae", Data(ColladaExporter.text(ModelMesh.parts(room), title: room.name).utf8))
        try write("Plan set.pdf", PDFSet.data(room, folder: originals, style: style))
        let readme = """
        MENSUR EXPORT — \(room.name)
        Updated: \(room.updatedAt.formatted())
        \(room.isDemo ? "SYNTHETIC DEMONSTRATION DATA — NOT A REAL SCAN" : "Captured and/or manually edited room geometry")

        Plan set.pdf: 11x17 landscape plan sheet, room schedule and quantities, door/window/wall/marker schedules, wall elevations, reference photos, then the dimension/review schedule and notes. Print at 100% on 11x17-inch paper to preserve the stated scale.
        Floorplan.dxf: editable R12 CAD linework in layers (WALLS, WALL-HATCH, DOORS, DOOR-SWINGS, WINDOWS, DIMENSIONS, SPACES, MARKERS, STAIRS, CEILING, FURNITURE). Set drawing units to METERS when importing. DXF X=AR X; DXF Y=-AR Z. Opens in AutoCAD; DWG is not written.
        Floorplan.svg / Floorplan.png: the plan as a drawing for proposals (SVG at 1:50; PNG at 300 dpi on letter landscape).
        Model.ifc: IFC4 model for Revit and ArchiCAD: walls, doors, windows, furniture and spaces on one storey, meters, Z up.
        Model.dae: COLLADA model for SketchUp, meters, Y up.
        Corrected-model.obj + .mtl: corrected simplified 3D model, meters, Y up. Keep both files together. Walls use the thickness set on the plan (typed, measured at reveals, or the wall type's default); others are a 0.06m visualization slab. Furniture is represented as boxes. No photographic textures.
        Project.json: editable Mensur document. Import via the app to continue editing.
        Original-RoomPlan.* (if present): unchanged native scan BEFORE your corrections. Its origin and geometry can differ from corrected exports. Do not substitute it for the corrected model.

        Measured checks validate individual lengths only, not complete room accuracy. Window/mirror review is manual; the app does not suppress LiDAR reflections at capture time. Missing geometry is not proof of empty space. Area is an approximate enclosed wall-plane area, not a certified rentable/gross area.
        """
        try write("READ-ME.txt", Data(readme.utf8))
        for name in ["Original-RoomPlan.json", "Original-RoomPlan.usdz"] {
            let source = originals.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { let target = dir.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: target); files.append(target) }
        }
        // Reference photos, numbered as in the PDF set.
        for (i, photo) in (room.photos ?? []).enumerated() {
            let source = originals.appendingPathComponent(photo.file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let caption = photo.caption.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined(separator: "-").prefix(40)
            let target = dir.appendingPathComponent("Photo \(i + 1)\(caption.isEmpty ? "" : " – " + caption).jpg")
            try FileManager.default.copyItem(at: source, to: target); files.append(target)
        }
        return files
    }
}

enum PDFPlan {
    static let landscape = CGRect(x: 0, y: 0, width: 1224, height: 792), portrait = CGRect(x: 0, y: 0, width: 792, height: 1224)  // 72 pt/in

    static func sheet(_ room: RoomProject, portrait: Bool) -> Data {
        let page = portrait ? self.portrait : landscape
        return UIGraphicsPDFRenderer(bounds: page).pdfData { pdf in pdf.beginPage(); drawSheet(room, page: page, context: pdf.cgContext) }
    }

    // Architectural scales on 11 × 17: the largest standard scale at which the plan, its dimensions and
    // tags fit the plan area. 2834.645669 pt is one meter at full size.
    // margin: room around the plan for dimension lines and tags (dimension strings need more than wall labels).
    static func scale(_ bounds: PlanBounds, in viewport: CGRect, units: DisplayUnits, margin: Double = 120) -> (pointsPerMeter: Double, label: String) {
        let required = max(bounds.width * 2834.645669 / (Double(viewport.width) - margin), bounds.depth * 2834.645669 / (Double(viewport.height) - margin))
        let options: [(Double, String)] = units == .imperial
            ? [(24, "1/2″ = 1′-0″"), (32, "3/8″ = 1′-0″"), (48, "1/4″ = 1′-0″"), (64, "3/16″ = 1′-0″"), (96, "1/8″ = 1′-0″"), (128, "3/32″ = 1′-0″"), (192, "1/16″ = 1′-0″"), (384, "1/32″ = 1′-0″")]
            : [20, 25, 50, 75, 100, 150, 200, 250, 500, 1000].map { ($0, "1:\(Int($0))") }
        if let o = options.first(where: { $0.0 >= required }) {
            return (2834.645669 / o.0, units == .imperial ? "\(o.1)  (1:\(Int(o.0)))" : o.1)
        }
        let d = ceil(required / 100) * 100
        return (2834.645669 / d, "1:\(Int(d))")
    }

    static func drawSheet(_ room: RoomProject, page: CGRect, context c: CGContext, style: PlanGeometry.DimensionStyle? = nil) {
        let portrait = page.height > page.width
        let summary = RoomSummary(room), units = room.units
        let frame = page.insetBy(dx: 24, dy: 24)
        c.setStrokeColor(PlanDrawing.ink.cgColor); c.setLineWidth(1.2); c.stroke(frame)
        let planRect: CGRect, title: CGRect, columns: [CGRect]
        if portrait {
            title = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 112)
            planRect = CGRect(x: frame.minX, y: title.maxY, width: frame.width, height: 740)
            let w = frame.width / 3, top = planRect.maxY
            columns = (0..<3).map { CGRect(x: frame.minX + CGFloat($0) * w, y: top, width: w, height: frame.maxY - top) }
            c.setLineWidth(0.8)
            for y in [title.maxY, planRect.maxY] { c.move(to: CGPoint(x: frame.minX, y: y)); c.addLine(to: CGPoint(x: frame.maxX, y: y)) }
            for i in 1..<3 { c.move(to: CGPoint(x: columns[i].minX, y: top)); c.addLine(to: CGPoint(x: columns[i].minX, y: frame.maxY)) }
            c.strokePath()
        } else {
            let panel = CGRect(x: frame.maxX - 300, y: frame.minY, width: 300, height: frame.height)
            planRect = CGRect(x: frame.minX, y: frame.minY, width: panel.minX - frame.minX, height: frame.height)
            title = CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: (room.address == nil ? 112 : 124) + (room.job.map { $0.isEmpty ? 0 : 12 } ?? 0))
            columns = [CGRect(x: panel.minX, y: title.maxY, width: panel.width, height: panel.maxY - title.maxY)]
            c.setLineWidth(0.8)
            c.move(to: CGPoint(x: panel.minX, y: frame.minY)); c.addLine(to: CGPoint(x: panel.minX, y: frame.maxY))
            c.move(to: CGPoint(x: panel.minX, y: title.maxY)); c.addLine(to: CGPoint(x: panel.maxX, y: title.maxY)); c.strokePath()
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: UIColor = PlanDrawing.ink, weight: UIFont.Weight = .regular) {
            PlanDrawing.text(s, at: CGPoint(x: x, y: y), size: size, color: color, weight: weight)
        }
        func label(_ s: String, _ x: CGFloat, _ y: CGFloat) { text(s.uppercased(), x, y, 7.5, .gray, weight: .semibold) }

        // Title block: your logo and company (Settings → Title block) or the Mensur mark, the room, the job, the date.
        let pad: CGFloat = 16
        Branding.drawMark(in: CGRect(x: title.minX + pad, y: title.minY + pad, width: 34, height: 34), context: c)
        let company = Branding.company ?? "Mensur"
        text(String(company.prefix(portrait ? 40 : 26)), title.minX + pad + 44, title.minY + pad + (Branding.contact == nil ? 6 : 0), Branding.company == nil ? 17 : 14, Branding.company == nil ? BrandMark.blue : PlanDrawing.ink, weight: .semibold)
        if let contact = Branding.contact { text(String(contact.prefix(portrait ? 70 : 44)), title.minX + pad + 44, title.minY + pad + 19, 8, .darkGray) }
        text(String(room.name.prefix(portrait ? 60 : 34)), title.minX + pad, title.minY + pad + 44, 13, weight: .semibold)
        // The address wraps by measured width onto at most two lines (portrait leaves room for the total area).
        var ty = title.minY + pad + 62
        if let address = room.address {
            let maxWidth = (portrait ? title.width - 240 : title.width) - pad * 2
            var lines: [String] = [], current = ""
            for word in address.replacingOccurrences(of: "\n", with: ", ").split(separator: " ").map(String.init) {
                let candidate = current.isEmpty ? word : current + " " + word
                if PlanDrawing.textSize(candidate, size: 9, weight: .regular).width > maxWidth, !current.isEmpty { lines.append(current); current = word } else { current = candidate }
            }
            if !current.isEmpty { lines.append(current) }
            if lines.count > 2 { lines = [lines[0], lines[1...].joined(separator: " ")]; while PlanDrawing.textSize(lines[1] + "…", size: 9, weight: .regular).width > maxWidth { lines[1].removeLast() }; lines[1] += "…" }
            for line in lines { text(line, title.minX + pad, ty, 9, .darkGray); ty += 12 }
            ty += 2
        } else { ty += 1 }
        if let job = room.job, !job.isEmpty {
            let parts = [job.client, job.project, job.number.isEmpty ? "" : "Job \(job.number)"].filter { !$0.isEmpty }
            text(String(parts.joined(separator: " · ").prefix(portrait ? 90 : 52)), title.minX + pad, ty, 8.5, .darkGray); ty += 12
        }
        let floorName = room.level.map { "\($0.building) · \($0.displayName) · " } ?? ""
        text("\(floorName)Floor plan · \(room.isDemo ? "sample data · " : "")updated \(room.updatedAt.formatted(date: .abbreviated, time: .omitted))", title.minX + pad, ty, 8.5, .darkGray)
        if portrait, let total = summary.totalArea {
            label("Total area", title.maxX - 200, title.minY + pad + 2)
            text(units.areaLabel(total), title.maxX - 200, title.minY + pad + 14, 22, weight: .bold)
            text((units == .metric ? DisplayUnits.imperial : .metric).areaLabel(total), title.maxX - 200, title.minY + pad + 44, 9, .darkGray)
        }

        // Plan at a standard scale, centred in its area, with wall numbers and opening tags.
        let viewport = planRect.insetBy(dx: 10, dy: 10)
        let fitted = PlanDrawing.projection(room, in: viewport)   // square-on rotation and centre
        let bounds = PlanBounds(room.activeSurfaces.flatMap { [$0.a, $0.b] }.map { Geometry.rotate($0, by: fitted.rotation) })
        let dimensionStyle = style ?? Setting.dimensionLayout
        let (ppm, scaleLabel) = scale(bounds, in: viewport, units: units, margin: dimensionStyle == .walls ? 120 : 220)
        var tags: [UUID: String] = [:]
        for (i, w) in summary.walls.enumerated() { tags[w.id] = "\(i + 1)" }
        for o in summary.openings { tags[o.surface.id] = o.tag }
        for (i, photo) in (room.photos ?? []).enumerated() { tags[photo.id] = "P\(i + 1)" }
        let projection = PlanProjection(scale: ppm, center: fitted.center, viewport: viewport, rotation: fitted.rotation)
        PlanDrawing.draw(room, context: c, projection: projection, dimensions: true, furniture: true, grid: false, areas: true, tags: tags,
                         dimensionStyle: dimensionStyle)

        // Summary, schedules and scale. Landscape stacks them in the panel; portrait gives the summary (with
        // the scale beneath it), the door and window schedule, and the wall table a column each. The scale
        // block always sits at the foot of the first column.
        var col = 0, x = columns[0].minX + pad, y = columns[0].minY + pad
        func fits(_ height: CGFloat) -> Bool { y + height <= columns[col].maxY - (col == 0 ? 108 : pad) }
        func column(_ i: Int) { guard i < columns.count else { return }; col = i; x = columns[i].minX + pad; y = columns[i].minY + pad }
        let width = columns[0].width - pad * 2
        if !portrait {
            label("Total area", x, y); y += 12
            text(summary.totalArea.map { units.areaLabel($0) } ?? "Needs review", x, y, 24, weight: .bold); y += 32
            if let total = summary.totalArea { text((units == .metric ? DisplayUnits.imperial : .metric).areaLabel(total), x, y, 9, .darkGray); y += 18 }
        } else {
            label("Summary", x, y); y += 16
        }
        func row(_ name: String, _ value: String, size: CGFloat = 9) {
            text(name, x, y, size, .darkGray); let w = PlanDrawing.textSize(value, size: size).width
            text(value, x + width - w, y, size, weight: .semibold); y += size + 5
        }
        if summary.spaces.count > 1 || room.spaceLabels != nil {
            for (i, space) in summary.spaces.enumerated() { row(String(summary.spaceNames[i].prefix(30)), units.areaLabel(space.area)) }
        }
        if summary.totalArea == nil { row("Area", "Walls don’t enclose a space") }
        row("Perimeter", summary.perimeter.map { units.length($0) } ?? "—")
        row("Ceiling height (avg.)", summary.ceilingHeight.map { units.length($0) } ?? "—")
        let count: (SurfaceKind) -> Int = { k in summary.openings.filter { $0.surface.kind == k }.count }
        row("Walls · doors · windows", "\(summary.walls.count) · \(count(.door)) · \(count(.window))")
        let checked = summary.walls.filter { $0.lidarCheck != nil }
        if !checked.isEmpty { row("LiDAR-confirmed walls", "\(checked.filter { $0.lidarCheck?.level == .confirmed }.count) of \(checked.count)") }
        y += 10

        func table(_ heading: String, _ headers: [(String, CGFloat)], _ rows: [[String]]) {
            if portrait { column(col + 1) }
            guard fits(40) else { return }
            label(heading, x, y); y += 13
            var cx = x; for (h, w) in headers { text(h, cx, y, 7.5, .gray); cx += w * width }; y += 11
            c.setStrokeColor(UIColor.lightGray.cgColor); c.setLineWidth(0.5); c.move(to: CGPoint(x: x, y: y - 2)); c.addLine(to: CGPoint(x: x + width, y: y - 2)); c.strokePath()
            for (i, r) in rows.enumerated() {
                guard fits(12) else { text("+\(rows.count - i) more in the full export schedule", x, y, 8, .gray); y += 12; return }
                var cx = x; for (cell, (_, w)) in zip(r, headers) { text(cell, cx, y, 8.5); cx += w * width }; y += 12
            }
            y += 12
        }
        table("Doors and windows", [("Tag", 0.11), ("Type", 0.25), ("Width", 0.22), ("Height", 0.22), ("Sill", 0.20)],
              summary.openings.map { o in
                  let type = o.surface.paneDescription.map { "\(o.surface.kind.title) \($0.replacingOccurrences(of: " panes", with: ""))" } ?? o.surface.kind.title
                  return [o.tag, type, units.length(o.surface.length), units.length(o.surface.height), o.surface.kind == .window || o.surface.kind == .mirror ? units.length(o.surface.bottom) : "—"]
              })
        table("Walls", [("#", 0.12), ("Name", 0.38), ("Length", 0.27), ("Height", 0.23)],
              summary.walls.enumerated().map { ["\($0.offset + 1)", String($0.element.label.prefix(16)) + ($0.element.hasCurrentLengthCheck ? " *" : ""), units.length($0.element.length), units.length($0.element.height)] })

        // Scale, scale bar and legend at the foot of the last column.
        let foot = columns[0]
        var fy = foot.maxY - 100
        let fx = foot.minX + pad
        label("Scale", fx, fy); fy += 11
        text(scaleLabel + " on 11 × 17 at 100%", fx, fy, 8.5); fy += 15
        let steps: [Double] = units == .imperial ? [1, 2, 5, 10, 20, 50, 100] : [0.5, 1, 2, 5, 10, 20, 50]
        let unitMeters = units == .imperial ? 0.3048 : 1.0
        let span = steps.first { $0 * unitMeters * ppm >= 90 } ?? steps.last!
        let barWidth = CGFloat(span * unitMeters * ppm)
        for i in 0..<4 {
            let r = CGRect(x: fx + barWidth / 4 * CGFloat(i), y: fy, width: barWidth / 4, height: 5)
            c.setFillColor((i % 2 == 0 ? PlanDrawing.ink : .white).cgColor); c.fill(r)
            c.setStrokeColor(PlanDrawing.ink.cgColor); c.setLineWidth(0.6); c.stroke(r)
        }
        let unit = units == .imperial ? "ft" : "m", spanText = span == span.rounded() ? "\(Int(span))" : "\(span)"
        text("0", fx - 2, fy + 7, 7.5, .darkGray); text("\(spanText) \(unit)", fx + barWidth - 6, fy + 7, 7.5, .darkGray); fy += 22
        if Setting.monochromePlans {
            text("Double line: window or mirror (W, M)", fx, fy, 7.5, .darkGray); fy += 10
            text("Dashed: door or opening (D, O)", fx, fy, 7.5, .darkGray); fy += 10
        } else {
            text("Blue: window · Green: door", fx, fy, 7.5, .darkGray); fy += 10
            text("Dashed: opening · Purple: mirror", fx, fy, 7.5, .darkGray); fy += 10
        }
        text("*: length checked by tape or laser · ① wall number", fx, fy, 7.5, .darkGray); fy += 10
        text("Approximate, from a LiDAR scan · verify critical dimensions", fx, fy, 7.5, .darkGray)
    }

    static func data(_ room: RoomProject) -> Data {
        UIGraphicsPDFRenderer(bounds: landscape).pdfData { pdf in
            pdf.beginPage(); drawSheet(room, page: landscape, context: pdf.cgContext)
            _ = record(room, in: pdf, startingAt: 2)
        }
    }

    // A page heading for the pages after the sheet: mark, room name, page title, footer and page number.
    static func heading(_ room: RoomProject, _ title: String, pageNumber: Int, context: CGContext) {
        func line(_ string: String, x: CGFloat = 42, y: CGFloat, size: CGFloat = 11, color: UIColor = .darkGray) {
            PlanDrawing.text(string, at: CGPoint(x: x, y: y), size: size, color: color)
        }
        Branding.drawMark(in: CGRect(x: 42, y: 24, width: 20, height: 20), context: context)
        line((Branding.company ?? "Mensur").uppercased(), x: 70, y: 28, size: 12, color: Branding.company == nil ? BrandMark.blue : PlanDrawing.ink)
        line(String(room.name.prefix(75)), y: 52, size: 24, color: .black)
        line(title, y: 88, size: 11)
        line("\(room.isDemo ? "SAMPLE DATA · " : "")Measurement review required · \(room.updatedAt.formatted(date: .abbreviated, time: .shortened))", y: 746, size: 10)
        line("\(pageNumber)", x: 1160, y: 746, size: 11)
    }

    // The dimension and review schedule, then the notes and measurement record. Returns the next page number.
    static func record(_ room: RoomProject, in pdf: UIGraphicsPDFRendererContext, startingAt first: Int, extraNotes: [String] = []) -> Int {
            func line(_ string: String, x: CGFloat = 42, y: CGFloat, size: CGFloat = 11, color: UIColor = .darkGray) {
                PlanDrawing.text(string, at: CGPoint(x: x, y: y), size: size, color: color)
            }
            func heading(_ title: String, pageNumber: Int) { PDFPlan.heading(room, title, pageNumber: pageNumber, context: pdf.cgContext) }

            let rows = room.surfaces
            var pageNo = first
            for start in stride(from: 0, to: max(1, rows.count), by: 18) {
                pdf.beginPage(); heading("DIMENSION & REVIEW SCHEDULE · Dimensions in meters", pageNumber: pageNo); pageNo += 1
                line("Element", y: 126); line("Length", x: 300, y: 126); line("Height", x: 400, y: 126); line("Bottom", x: 500, y: 126)
                line("Evidence / recognition", x: 600, y: 126); line("Review", x: 870, y: 126)
                for (index, s) in rows.dropFirst(start).prefix(18).enumerated() {
                    let y = CGFloat(154 + index * 29)
                    line(String(s.label.prefix(32)), y: y, size: 10)
                    line(String(format: "%.3f", s.length), x: 300, y: y, size: 10)
                    line(String(format: "%.3f", s.height), x: 400, y: y, size: 10)
                    line(String(format: "%.3f", s.bottom), x: 500, y: y, size: 10)
                    line("\(s.evidence.rawValue) / \(s.confidence.rawValue)", x: 600, y: y, size: 10)
                    let status = s.excluded ? "Excluded" : (s.hasCurrentLengthCheck ? "Length checked" : "Length unchecked")
                    line(status + (s.needsReview ? " · review surface" : ""), x: 870, y: y, size: 9)
                }
                line("Recognition confidence describes classification, not measurement error. Checked length does not verify position, angle, height, or area.", y: 710, size: 10)
            }
            var notes: [String] = [
                "Accuracy and reflection review",
                "Windows and mirrors can distort LiDAR results. Verify their frames and surrounding wall planes with independent measurements.",
                "Corrected 3D walls use the thickness set on the plan: typed, measured at a door or window reveal, or the wall type's typical value. Walls without one are a 60 mm visualization slab. Only reveal measurements are measured thickness.",
                "Approximate area uses a single closed wall loop and an 80 mm endpoint join tolerance. Missing, intersecting, or disconnected boundaries suppress the area.",
                "Door swings, wall types, markers and finishes are as entered in the app, not detected. No photorealistic textures, hidden services, or automatic mirror removal are included."
            ] + room.captureWarnings + extraNotes
            if let warning = Geometry.boundary(room.walls).warning { notes.append(warning) }
            if !room.notes.isEmpty { notes.append("Room notes: " + room.notes) }
            for s in room.surfaces {
                if let issue = Geometry.openingIssue(s, in: room), !s.excluded { notes.append("\(s.label): \(issue)") }
                if let caveat = s.geometryCaveat { notes.append("\(s.label): \(caveat)") }
                if let note = s.reviewNote, !s.excluded { notes.append("\(s.label): \(note)") }
                if !s.notes.isEmpty { notes.append("\(s.label): \(s.notes)") }
                if let check = s.lengthCheck {
                    notes.append(String(format: "%@: checked %.3f m; reference %.3f m; difference %+.3f m. %@.", s.label, check.measuredMeters, check.referenceMeters, check.difference, check.method))
                }
            }
            pdf.beginPage(); heading("NOTES & MEASUREMENT RECORD", pageNumber: pageNo); pageNo += 1
            var y: CGFloat = 128
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray]
            // Wrap long notes and paginate without clipping.
            for note in notes {
                let words = note.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                var current = ""
                for word in words {
                    let candidate = current.isEmpty ? word : current + " " + word
                    if (candidate as NSString).size(withAttributes: attrs).width > 1110, !current.isEmpty {
                        if y > 700 { pdf.beginPage(); heading("NOTES · CONTINUED", pageNumber: pageNo); pageNo += 1; y = 128 }
                        (current as NSString).draw(at: CGPoint(x: 42, y: y), withAttributes: attrs); y += 17; current = word
                    } else { current = candidate }
                }
                if y > 700 { pdf.beginPage(); heading("NOTES · CONTINUED", pageNumber: pageNo); pageNo += 1; y = 128 }
                (current as NSString).draw(at: CGPoint(x: 42, y: y), withAttributes: attrs); y += 29
            }
            return pageNo
    }
}
