import UIKit

// Your company on drawings: name, a contact line and a logo, set in Settings → Title block and kept on this
// device. Without them the title block shows the Mensur mark.
enum Branding {
    static var company: String? { clean(UserDefaults.standard.string(forKey: Setting.companyName)) }
    static var contact: String? { clean(UserDefaults.standard.string(forKey: Setting.companyContact)) }
    static var logoURL: URL { AppPaths.support.appendingPathComponent("Branding/logo.png") }
    static var logo: UIImage? { UIImage(contentsOfFile: logoURL.path) }
    private static func clean(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    }
    // Keeps a copy at most 600 px on its long side; nil removes it.
    static func setLogo(_ image: UIImage?) throws {
        guard let image else { try? FileManager.default.removeItem(at: logoURL); return }
        let longest = max(image.size.width, image.size.height), scale = min(1, 600 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try FileManager.default.createDirectory(at: logoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: logoURL, options: .atomic)
    }
    // The logo fitted into `r`, or the Mensur mark.
    static func drawMark(in r: CGRect, context c: CGContext) {
        guard let logo, logo.size.width > 0, logo.size.height > 0 else { BrandMark.draw(in: r, context: c); return }
        let s = min(r.width / logo.size.width, r.height / logo.size.height)
        let size = CGSize(width: logo.size.width * s, height: logo.size.height * s)
        UIGraphicsPushContext(c); defer { UIGraphicsPopContext() }
        logo.draw(in: CGRect(x: r.minX, y: r.midY - size.height / 2, width: size.width, height: size.height))
    }
}

// The plan as a picture: letter landscape at 300 dpi, with the room's name and area beneath it.
enum PlanImage {
    static func png(_ room: RoomProject, style: PlanGeometry.DimensionStyle) -> Data {
        let page = CGRect(x: 0, y: 0, width: 1100, height: 850)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        return UIGraphicsImageRenderer(bounds: page, format: format).pngData { context in
            let c = context.cgContext
            UIColor.white.setFill(); c.fill(page)
            let area = CGRect(x: 30, y: 30, width: page.width - 60, height: page.height - 110)
            let projection = PlanDrawing.projection(room, in: area.insetBy(dx: 40, dy: 40))
            PlanDrawing.draw(room, context: c, projection: PlanProjection(scale: projection.scale, center: projection.center, viewport: area, rotation: projection.rotation),
                             dimensions: true, furniture: true, grid: false, areas: true, dimensionStyle: style)
            Branding.drawMark(in: CGRect(x: 30, y: page.height - 66, width: 36, height: 36), context: c)
            let summary = RoomSummary(room)
            PlanDrawing.text(room.name, at: CGPoint(x: 76, y: page.height - 68), size: 16, color: PlanDrawing.ink, weight: .semibold)
            let detail = [room.address?.replacingOccurrences(of: "\n", with: ", "), summary.totalArea.map { room.units.areaLabel($0) }, Branding.company ?? "Mensur"].compactMap { $0 }.joined(separator: " · ")
            PlanDrawing.text(detail, at: CGPoint(x: 76, y: page.height - 46), size: 10, color: .darkGray)
        }
    }
}

// The plan set: the 11 × 17 sheet, room schedule and quantities, door, window, wall and marker schedules,
// wall elevations, reference photos, then the dimension and review schedule and notes.
enum PDFSet {
    static let page = PDFPlan.landscape
    static let left: CGFloat = 42, width: CGFloat = 1140, bottom: CGFloat = 712

    static func data(_ room: RoomProject, folder: URL, style: PlanGeometry.DimensionStyle) -> Data {
        UIGraphicsPDFRenderer(bounds: page).pdfData { pdf in
            pdf.beginPage(); PDFPlan.drawSheet(room, page: page, context: pdf.cgContext, style: style)
            var n = schedules(room, pdf: pdf, from: 2)
            n = elevations(room, pdf: pdf, from: n)
            n = photos(room, folder: folder, pdf: pdf, from: n)
            _ = PDFPlan.record(room, in: pdf, startingAt: n, extraNotes: room.scanReport.map { ["Scan quality: " + ScanMetrics.summary($0, units: room.units).joined(separator: " ")] } ?? [])
        }
    }

    private static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 9, _ color: UIColor = .darkGray, weight: UIFont.Weight = .regular) {
        PlanDrawing.text(s, at: CGPoint(x: x, y: y), size: size, color: color, weight: weight)
    }

    // Tables flow down the page and onto continuation pages. Columns are fractions of the page width.
    private struct Flow {
        let room: RoomProject; let pdf: UIGraphicsPDFRendererContext; var page: Int; var y: CGFloat; let title: String
        mutating func newPage(_ heading: String) {
            pdf.beginPage(); PDFPlan.heading(room, heading, pageNumber: page, context: pdf.cgContext); page += 1; y = 122
        }
        mutating func table(_ heading: String, _ columns: [(String, CGFloat)], _ rows: [[String]], note: String? = nil) {
            guard !rows.isEmpty else { return }
            if y > bottom - 60 { newPage(title + " · CONTINUED") }
            text(heading.uppercased(), left, y, 8.5, .gray, weight: .semibold); y += 15
            func header() {
                var x = left; for (h, w) in columns { text(h, x, y, 8, .gray); x += w * width }; y += 12
                let c = pdf.cgContext; c.setStrokeColor(UIColor.lightGray.cgColor); c.setLineWidth(0.5)
                c.move(to: CGPoint(x: left, y: y - 2)); c.addLine(to: CGPoint(x: left + width, y: y - 2)); c.strokePath()
            }
            header()
            for row in rows {
                if y > bottom { newPage(title + " · CONTINUED"); text(heading.uppercased() + " (CONTINUED)", left, y, 8.5, .gray, weight: .semibold); y += 15; header() }
                var x = left
                for (cell, (_, w)) in zip(row, columns) {
                    var s = cell
                    while PlanDrawing.textSize(s, size: 9, weight: .regular).width > w * width - 6, s.count > 2 { s = String(s.dropLast(2)) + "…" }
                    text(s, x, y, 9, PlanDrawing.ink); x += w * width
                }
                y += 14
            }
            if let note { text(note, left, y + 2, 8, .gray); y += 14 }
            y += 16
        }
    }

    static func schedules(_ room: RoomProject, pdf: UIGraphicsPDFRendererContext, from: Int) -> Int {
        let u = room.units, t = Takeoff(room), summary = RoomSummary(room)
        var flow = Flow(room: room, pdf: pdf, page: from, y: 122, title: "SCHEDULES AND QUANTITIES")
        flow.newPage("SCHEDULES AND QUANTITIES")
        flow.table("Room schedule", [("Space", 0.16), ("Floor area", 0.09), ("Ceiling", 0.08), ("Ceiling area", 0.09), ("Volume", 0.09), ("Floor", 0.13), ("Walls", 0.13), ("Ceiling finish", 0.12), ("Base", 0.11)],
                   t.spaces.map { s in [s.name, u.areaLabel(s.floorArea), u.length(s.ceilingHeight), u.areaLabel(s.ceilingArea), Takeoff.volumeLabel(s.volume, units: u),
                                        s.label?.floorFinish ?? "—", s.label?.wallFinish ?? "—", s.label?.ceilingFinish ?? "—", s.label?.baseFinish ?? "—"] })
        flow.table("Quantities", [("Item", 0.3), ("Quantity", 0.2), ("Basis", 0.5)], [
            ["Floor", u.areaLabel(t.floorArea), "Enclosed spaces, inside faces of walls"],
            ["Ceiling", u.areaLabel(t.ceilingArea), "Including the faces of soffits, beams, slopes and vaults"],
            ["Volume", Takeoff.volumeLabel(t.volume, units: u), "Floor area × ceiling height, adjusted for ceiling features"],
            ["Walls, gross", u.areaLabel(t.wallGross), "One face, full height"],
            ["Doors, windows and openings", u.areaLabel(t.wallOpenings), "Cut out of the walls"],
            ["Walls, net", u.areaLabel(t.wallNet), "For paint and wall covering"],
            ["Baseboard", Takeoff.runLabel(t.baseboard, units: u), "Space perimeters less door and opening widths"]
        ], note: "Approximate quantities from the scan; add waste for ordering.")
        let doors = summary.openings.filter { $0.surface.kind == .door }
        flow.table("Door schedule", [("Tag", 0.06), ("Style", 0.14), ("Width", 0.11), ("Height", 0.11), ("Swing", 0.2), ("Reveal", 0.11), ("Wall", 0.27)],
                   doors.map { o in
                       let s = o.surface, style = s.doorStyle ?? .swing
                       let swing = style == .swing ? "Hinge at \(s.hingeAtB == true ? "end" : "start") · \(s.opensOut == true ? "opens out" : "opens in")" : style == .double ? (s.opensOut == true ? "Opens out" : "Opens in") : "—"
                       return [o.tag, style.title, u.length(s.length), u.length(s.height), swing, s.revealDepth.map(u.length) ?? "—", o.wall ?? "—"]
                   })
        let windows = summary.openings.filter { $0.surface.kind == .window }
        flow.table("Window schedule", [("Tag", 0.06), ("Width", 0.12), ("Height", 0.12), ("Sill", 0.12), ("Panes", 0.12), ("Reveal", 0.12), ("Wall", 0.34)],
                   windows.map { o in [o.tag, u.length(o.surface.length), u.length(o.surface.height), u.length(o.surface.bottom), o.surface.paneDescription ?? "1 pane", o.surface.revealDepth.map(u.length) ?? "—", o.wall ?? "—"] })
        let nets = Dictionary(uniqueKeysWithValues: t.walls.map { ($0.wall.id, $0.net) })
        flow.table("Wall schedule", [("#", 0.05), ("Name", 0.2), ("Type", 0.16), ("Thickness", 0.16), ("Length", 0.13), ("Height", 0.13), ("Net area", 0.17)],
                   summary.walls.enumerated().map { i, w in
                       let thickness = w.drawnThickness.map { u.length($0) + (w.thicknessSource == .reveal ? " (reveal)" : w.thickness == nil ? " (typical)" : "") } ?? "—"
                       return ["\(i + 1)", w.label, w.wallType?.title ?? "—", thickness, u.length(w.length), u.length(w.height), u.areaLabel(nets[w.id] ?? 0)]
                   })
        let markers = room.markers ?? []
        let groups = Dictionary(grouping: markers) { $0.kind }.sorted { $0.key.title < $1.key.title }
        flow.table("Electrical, plumbing and HVAC", [("Code", 0.07), ("Type", 0.2), ("Count", 0.08), ("Heights", 0.25), ("Labels and notes", 0.4)],
                   groups.map { kind, items in
                       let heights = Set(items.compactMap { $0.height.map(u.length) }).sorted().joined(separator: ", ")
                       let labels = items.map { [$0.label, $0.note].filter { !$0.isEmpty }.joined(separator: ": ") }.filter { !$0.isEmpty }.joined(separator: "; ")
                       return [kind.code, kind.title, "\(items.count)", heights.isEmpty ? "—" : heights, labels.isEmpty ? "—" : labels]
                   })
        flow.table("Ceiling features", [("Feature", 0.25), ("Type", 0.12), ("Size", 0.2), ("Heights", 0.23), ("Source", 0.2)],
                   (room.ceilings ?? []).map { f in [f.label.isEmpty ? f.kind.title : f.label, f.kind.title, "\(u.length(f.length)) × \(u.length(f.width))",
                                                    u.length(f.low) + (f.high.map { " to " + u.length($0) } ?? ""), f.detected ? "LiDAR, review" : "Drawn"] })
        flow.table("Stairs", [("Stair", 0.25), ("Direction", 0.15), ("Risers", 0.1), ("Run", 0.15), ("Width", 0.15), ("Connects to", 0.2)],
                   (room.stairs ?? []).map { s in [s.label.isEmpty ? "Stair" : s.label, s.up ? "Up" : "Down", "\(s.risers)", u.length(s.length), u.length(s.width),
                                                   s.toFloor.map { FloorLevel(building: "x", floor: $0).displayName } ?? "—"] })
        return flow.page
    }

    // Wall elevations seen from inside, four to a page, all at one scale so they compare.
    static func elevations(_ room: RoomProject, pdf: UIGraphicsPDFRendererContext, from: Int) -> Int {
        let all = Elevation.all(room)
        guard !all.isEmpty else { return from }
        let u = room.units
        let cellW: CGFloat = 560, cellH: CGFloat = 290
        let maxW = all.map(\.width).max() ?? 1, maxH = all.map(\.height).max() ?? 1
        let scale = min((cellW - 90) / CGFloat(maxW), (cellH - 80) / CGFloat(maxH))
        var page = from
        for (i, e) in all.enumerated() {
            if i % 4 == 0 { pdf.beginPage(); PDFPlan.heading(room, "WALL ELEVATIONS · seen from inside the room", pageNumber: page, context: pdf.cgContext); page += 1 }
            let c = pdf.cgContext, slot = i % 4
            let cell = CGRect(x: left + CGFloat(slot % 2) * (cellW + 20), y: 116 + CGFloat(slot / 2) * (cellH + 14), width: cellW, height: cellH)
            text("\(e.number)  \(e.wall.label) · \(u.length(e.width)) × \(u.length(e.height))\(e.wall.wallType.map { " · " + $0.title.lowercased() } ?? "")", cell.minX, cell.minY, 10, PlanDrawing.ink, weight: .semibold)
            let base = CGPoint(x: cell.minX + 30, y: cell.maxY - 34)
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + CGFloat(x) * scale, y: base.y - CGFloat(y) * scale) }
            let w = CGFloat(e.width) * scale, h = CGFloat(e.height) * scale
            // Floor line, wall outline.
            c.setStrokeColor(UIColor.gray.cgColor); c.setLineWidth(0.6)
            c.move(to: CGPoint(x: base.x - 10, y: base.y)); c.addLine(to: CGPoint(x: base.x + w + 10, y: base.y)); c.strokePath()
            c.setStrokeColor(PlanDrawing.ink.cgColor); c.setLineWidth(1.4); c.stroke(CGRect(x: base.x, y: base.y - h, width: w, height: h))
            for item in e.items {
                let r = CGRect(x: pt(item.x0, 0).x, y: pt(0, item.y1).y, width: CGFloat(item.x1 - item.x0) * scale, height: CGFloat(item.y1 - item.y0) * scale)
                let tint = PlanDrawing.color(item.kind)
                c.setFillColor(UIColor.white.cgColor); c.fill(r)
                c.setStrokeColor(tint.cgColor); c.setLineWidth(1)
                switch item.kind {
                case .door:
                    c.stroke(r)
                    // Elevation swing: two lines from the latch side's corners to the middle of the hinge side.
                    let aIsLeft = abs(item.xa - item.x0) < abs(item.xa - item.x1)
                    let hingeLeft = (item.surface.hingeAtB == true) != aIsLeft
                    let hx = hingeLeft ? r.minX : r.maxX, lx = hingeLeft ? r.maxX : r.minX
                    if (item.surface.doorStyle ?? .swing) == .swing {
                        c.setLineDash(phase: 0, lengths: [3, 3])
                        c.move(to: CGPoint(x: lx, y: r.minY)); c.addLine(to: CGPoint(x: hx, y: r.midY)); c.addLine(to: CGPoint(x: lx, y: r.maxY)); c.strokePath()
                        c.setLineDash(phase: 0, lengths: [])
                    }
                case .window:
                    c.stroke(r); c.stroke(r.insetBy(dx: 2.5, dy: 2.5))
                    let s = item.surface
                    for d in s.dividers ?? [] {
                        let x = r.minX + CGFloat(d / max(s.length, 1e-6)) * r.width
                        c.move(to: CGPoint(x: x, y: r.minY)); c.addLine(to: CGPoint(x: x, y: r.maxY))
                    }
                    for rail in s.rails ?? [] {
                        let y = r.maxY - CGFloat(rail / max(s.height, 1e-6)) * r.height
                        c.move(to: CGPoint(x: r.minX, y: y)); c.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                    c.strokePath()
                case .mirror:
                    c.stroke(r)
                    for line in PlanGeometry.parallelLines([PlanPoint(x: Double(r.minX), z: Double(r.minY)), PlanPoint(x: Double(r.maxX), z: Double(r.minY)), PlanPoint(x: Double(r.maxX), z: Double(r.maxY)), PlanPoint(x: Double(r.minX), z: Double(r.maxY))], angle: .pi / 4, spacing: 8) {
                        c.move(to: CGPoint(x: line.0.x, y: line.0.z)); c.addLine(to: CGPoint(x: line.1.x, y: line.1.z))
                    }
                    c.setLineWidth(0.4); c.strokePath()
                default:
                    c.setLineDash(phase: 0, lengths: [4, 3]); c.stroke(r); c.setLineDash(phase: 0, lengths: [])
                }
                if !item.tag.isEmpty { PlanDrawing.text(item.tag, at: CGPoint(x: r.midX, y: r.minY - 7), size: 7.5, color: tint, centered: true, weight: .semibold) }
            }
            for m in e.marks {
                let at = pt(m.x, m.y), tint = PlanDrawing.markerColor(m.kind.category)
                let r = CGRect(x: at.x - 6, y: at.y - 6, width: 12, height: 12)
                c.setFillColor(UIColor.white.cgColor); c.fillEllipse(in: r); c.setStrokeColor(tint.cgColor); c.setLineWidth(0.8); c.strokeEllipse(in: r)
                PlanDrawing.text(m.kind.code, at: at, size: 5.5, color: tint, centered: true, weight: .bold)
            }
            // Width beneath, height beside.
            c.setStrokeColor(UIColor.gray.cgColor); c.setLineWidth(0.5)
            c.move(to: CGPoint(x: base.x, y: base.y + 12)); c.addLine(to: CGPoint(x: base.x + w, y: base.y + 12))
            c.move(to: CGPoint(x: base.x + w + 14, y: base.y)); c.addLine(to: CGPoint(x: base.x + w + 14, y: base.y - h)); c.strokePath()
            PlanDrawing.text(u.length(e.width), at: CGPoint(x: base.x + w / 2, y: base.y + 20), size: 8, color: .darkGray, centered: true)
            c.saveGState(); c.translateBy(x: base.x + w + 24, y: base.y - h / 2); c.rotate(by: -.pi / 2)
            PlanDrawing.text(u.length(e.height), at: .zero, size: 8, color: .darkGray, centered: true); c.restoreGState()
        }
        return page
    }

    // Reference photos four to a page, numbered as on the plan sheet (P1, P2…).
    static func photos(_ room: RoomProject, folder: URL, pdf: UIGraphicsPDFRendererContext, from: Int) -> Int {
        let photos = (room.photos ?? []).enumerated().compactMap { i, p -> (Int, PinnedPhoto, UIImage)? in
            UIImage(contentsOfFile: folder.appendingPathComponent(p.file).path).map { (i + 1, p, $0) }
        }
        guard !photos.isEmpty else { return from }
        var page = from
        for (k, (number, photo, image)) in photos.enumerated() {
            if k % 4 == 0 { pdf.beginPage(); PDFPlan.heading(room, "REFERENCE PHOTOS · not used for measurement", pageNumber: page, context: pdf.cgContext); page += 1 }
            let slot = k % 4, cell = CGRect(x: left + CGFloat(slot % 2) * 580, y: 116 + CGFloat(slot / 2) * 300, width: 560, height: 280)
            let box = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.height - 24)
            let s = min(box.width / image.size.width, box.height / image.size.height)
            let size = CGSize(width: image.size.width * s, height: image.size.height * s)
            image.draw(in: CGRect(x: box.minX, y: box.minY + (box.height - size.height) / 2, width: size.width, height: size.height))
            text("P\(number)  \(photo.caption.isEmpty ? "Photo" : photo.caption) · \(photo.takenAt.formatted(date: .abbreviated, time: .shortened))", cell.minX, cell.maxY - 16, 9, PlanDrawing.ink)
        }
        return page
    }
}
