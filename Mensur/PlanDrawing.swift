import SwiftUI
import UIKit
import os

struct PlanProjection {
    let scale: Double
    let center: PlanPoint
    let viewport: CGRect
    var zoom: Double = 1
    var offset: CGSize = .zero
    var rotation: Double = 0     // radians, turns the plan about `center` so walls can sit square to the screen
    func screen(_ p: PlanPoint) -> CGPoint {
        let d = Geometry.rotate(p - center, by: rotation)
        return CGPoint(x: Double(viewport.midX) + d.x * scale * zoom + Double(offset.width),
                       y: Double(viewport.midY) + d.z * scale * zoom + Double(offset.height))
    }
    func world(_ p: CGPoint) -> PlanPoint {
        let d = PlanPoint(x: Double(p.x - viewport.midX - offset.width) / (scale * zoom), z: Double(p.y - viewport.midY - offset.height) / (scale * zoom))
        return center + Geometry.rotate(d, by: -rotation)
    }
    // A plan-space direction on screen (rotation only).
    func direction(_ v: PlanPoint) -> CGPoint { let d = Geometry.rotate(v, by: rotation); return CGPoint(x: d.x, y: d.z) }
}

// The Mensur mark: an isometric room built from three planes of even white dots (left wall solid, right wall
// 60%, floor 30%) on Mensur blue. Drawn from a 100-unit design; scripts/make_icons.swift renders the app
// icon from the same geometry, so change both together.
enum BrandMark {
    static let blue = UIColor(red: 0x29 / 255, green: 0x61 / 255, blue: 0xCC / 255, alpha: 1)
    static let dotsPerEdge = 14
    // Each plane: a corner, its two edge vectors, and its dot opacity.
    static let planes: [(origin: CGPoint, a: CGVector, b: CGVector, opacity: CGFloat)] = [
        (CGPoint(x: 20, y: 64), CGVector(dx: 30, dy: -18), CGVector(dx: 0, dy: -30), 1),
        (CGPoint(x: 50, y: 46), CGVector(dx: 30, dy: 18), CGVector(dx: 0, dy: -30), 0.6),
        (CGPoint(x: 50, y: 46), CGVector(dx: -30, dy: 18), CGVector(dx: 30, dy: 18), 0.3)
    ]
    static func draw(in r: CGRect, context c: CGContext) {
        let k = r.width / 100, n = CGFloat(dotsPerEdge), radius = 35 / n * 0.3 * k
        c.saveGState(); defer { c.restoreGState() }
        c.addPath(UIBezierPath(roundedRect: r, cornerRadius: 22.5 * k).cgPath); c.setFillColor(blue.cgColor); c.fillPath()
        for p in planes {
            for i in 0..<dotsPerEdge {
                for j in 0..<dotsPerEdge {
                    let u = (CGFloat(i) + 0.5) / n, v = (CGFloat(j) + 0.5) / n
                    let x = r.minX + (p.origin.x + u * p.a.dx + v * p.b.dx) * k, y = r.minY + (p.origin.y + u * p.a.dy + v * p.b.dy) * k
                    c.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
            c.setFillColor(UIColor.white.withAlphaComponent(p.opacity).cgColor); c.fillPath()
        }
    }
}

enum PlanDrawing {
    // RoomPlan's world axes are arbitrary, so the plan is turned to put its dominant wall direction square
    // to the screen, choosing whichever of the two square-on orientations fills `rect` best.
    static func projection(_ room: RoomProject, in rect: CGRect, fixedScale: Double? = nil) -> PlanProjection {
        let points = room.activeSurfaces.flatMap { [$0.a, $0.b] }
        let base = -Geometry.dominantAngle(room.walls)
        let quarter = base > 0 ? base - .pi / 2 : base + .pi / 2
        let fits = [base, quarter].map { r -> (rotation: Double, scale: Double, bounds: PlanBounds) in
            let b = PlanBounds(points.map { Geometry.rotate($0, by: r) })
            return (r, min(Double(rect.width - 80) / (b.width + 0.2), Double(rect.height - 80) / (b.depth + 0.2)), b)
        }
        let best = fits[1].scale > fits[0].scale * 1.02 ? fits[1] : fits[0]
        return PlanProjection(scale: max(1, fixedScale ?? best.scale), center: Geometry.rotate(best.bounds.center, by: -best.rotation), viewport: rect, rotation: best.rotation)
    }
    static func color(_ kind: SurfaceKind) -> UIColor {
        if Setting.monochromePlans {
            switch kind { case .wall: return ink; case .window, .mirror: return UIColor(white: 0.25, alpha: 1); case .door, .opening: return UIColor(white: 0.35, alpha: 1) }
        }
        switch kind { case .wall: return UIColor(red: 0.14, green: 0.20, blue: 0.26, alpha: 1)
        case .door: return .systemGreen; case .window: return .systemBlue
        case .opening: return .systemGray; case .mirror: return .systemPurple }
    }
    static let ink = UIColor(red: 0.106, green: 0.165, blue: 0.227, alpha: 1)        // #1B2A3A walls and labels
    static let floor = UIColor(red: 0.953, green: 0.965, blue: 0.984, alpha: 1)      // #F3F6FB enclosed space fill
    static func textSize(_ string: String, size: CGFloat, weight: UIFont.Weight = .medium) -> CGSize {
        (string as NSString).size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)])
    }
    static func text(_ string: String, at point: CGPoint, size: CGFloat, color: UIColor = .darkGray, centered: Bool = false, weight: UIFont.Weight = .medium) {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let ns = string as NSString; let s = ns.size(withAttributes: attributes)
        ns.draw(at: CGPoint(x: point.x - (centered ? s.width / 2 : 0), y: point.y - (centered ? s.height / 2 : 0)), withAttributes: attributes)
    }
    // `areas` writes each enclosed space's area inside it; `tags` labels surfaces (wall numbers outside
    // their wall, opening tags such as W1 inside the room) for the PDF schedules.
    static func draw(_ room: RoomProject, context c: CGContext, projection p: PlanProjection,
                     selected: UUID? = nil, dimensions: Bool = true, furniture: Bool = true, grid: Bool = true,
                     areas: Bool = false, tags: [UUID: String] = [:]) {
        c.saveGState(); defer { c.restoreGState() }
        c.clip(to: p.viewport)
        if grid {
            c.setFillColor(UIColor(white: 0.89, alpha: 1).cgColor)
            let spacing: CGFloat = 20
            for x in stride(from: p.viewport.minX + 10, through: p.viewport.maxX, by: spacing) {
                for y in stride(from: p.viewport.minY + 10, through: p.viewport.maxY, by: spacing) { c.fillEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4)) }
            }
        }
        func line(_ a: CGPoint, _ b: CGPoint, color: UIColor, width: CGFloat, dash: [CGFloat] = []) {
            c.setStrokeColor(color.cgColor); c.setLineWidth(width); c.setLineDash(phase: 0, lengths: dash)
            c.move(to: a); c.addLine(to: b); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
        }
        let boundary = Geometry.boundary(room.walls)
        let summary = RoomSummary(room), spaces = summary.spaces
        for space in spaces {
            guard let first = space.points.first else { continue }
            c.move(to: p.screen(first)); for point in space.points.dropFirst() { c.addLine(to: p.screen(point)) }; c.closePath()
            c.setFillColor(floor.cgColor); c.fillPath()
        }
        if furniture {
            for o in room.objects where !o.excluded {
                let dir = PlanPoint(x: cos(o.yaw), z: sin(o.yaw)), n = PlanPoint(x: -sin(o.yaw), z: cos(o.yaw))
                let center = PlanPoint(x: o.center.x, z: o.center.z), dx = dir * (o.size.x / 2), dz = n * (o.size.z / 2)
                let corners = [center - dx - dz, center + dx - dz, center + dx + dz, center - dx + dz]
                c.move(to: p.screen(corners[0])); corners.dropFirst().forEach { c.addLine(to: p.screen($0)) }; c.closePath()
                c.setFillColor(UIColor(red: 0.83, green: 0.87, blue: 0.83, alpha: 0.8).cgColor); c.setStrokeColor(UIColor.systemGray.cgColor); c.setLineWidth(1); c.drawPath(using: .fillStroke)
            }
        }
        // Walls first; semantic openings overlay the cutouts.
        let surfaces = room.activeSurfaces.sorted { ($0.kind == .wall ? 0 : 1) < ($1.kind == .wall ? 0 : 1) }
        for s in surfaces {
            let a = p.screen(s.a), b = p.screen(s.b)
            let isSelected = selected == s.id
            let ink = isSelected ? UIColor.systemOrange : color(s.kind)
            if isSelected { line(a, b, color: ink.withAlphaComponent(0.25), width: 14) }
            if s.kind == .wall {
                for (start, end) in DXFExporter.visibleWallSegments(s, room: room) { line(p.screen(start), p.screen(end), color: ink, width: 4) }
            } else if s.kind == .window || s.kind == .mirror {
                let delta = CGPoint(x: b.x - a.x, y: b.y - a.y), length = max(1, hypot(delta.x, delta.y))
                let n = CGPoint(x: -delta.y / length * 2.5, y: delta.x / length * 2.5)
                line(CGPoint(x: a.x + n.x, y: a.y + n.y), CGPoint(x: b.x + n.x, y: b.y + n.y), color: ink, width: 1.5)
                line(CGPoint(x: a.x - n.x, y: a.y - n.y), CGPoint(x: b.x - n.x, y: b.y - n.y), color: ink, width: 1.5)
                line(a, b, color: ink.withAlphaComponent(0.4), width: 1)
                // Pane dividers: a short bar across the window's double line at each one.
                for d in s.dividers ?? [] where s.length > 0 {
                    let t = CGFloat(d / s.length), m = CGPoint(x: a.x + delta.x * t, y: a.y + delta.y * t)
                    line(CGPoint(x: m.x + n.x * 1.8, y: m.y + n.y * 1.8), CGPoint(x: m.x - n.x * 1.8, y: m.y - n.y * 1.8), color: ink, width: 1.5)
                }
            } else { line(a, b, color: ink, width: 1.5, dash: [4, 3]) }
            if dimensions && s.kind == .wall {
                let v = CGPoint(x: b.x - a.x, y: b.y - a.y), len = max(1, hypot(v.x, v.y)), dir = CGPoint(x: v.x / len, y: v.y / len)
                let inward = Geometry.inwardNormal(s, walls: room.walls, boundary: boundary)
                let u = p.direction(inward), n = CGPoint(x: u.x * 22, y: u.y * 22)
                let aa = CGPoint(x: a.x + n.x, y: a.y + n.y), bb = CGPoint(x: b.x + n.x, y: b.y + n.y)
                line(aa, bb, color: .gray, width: 0.5)
                let tick = CGPoint(x: (dir.x - dir.y) * 3, y: (dir.y + dir.x) * 3) // 45° to the dimension line
                for end in [aa, bb] { line(CGPoint(x: end.x - tick.x, y: end.y - tick.y), CGPoint(x: end.x + tick.x, y: end.y + tick.y), color: .gray, width: 0.7) }
                // Label sits between the wall (and any window/mirror outline on it) and its dimension line,
                // aligned with the wall and kept upright. A label longer than its wall (a short jog) would cross
                // the neighbouring walls, so it points straight out from the wall's outer face instead, where it
                // needs only its text height of wall length.
                let label = room.units.length(s.length) + (s.hasCurrentLengthCheck ? " *" : "")
                let width = textSize(label, size: 9).width, fits = width + 6 <= len
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), offset = fits ? 12 : -(4 + width / 2)
                let angle = fits ? Geometry.uprightTextAngle(dx: Double(v.x), dy: Double(v.y)) : Geometry.uprightTextAngle(dx: Double(-u.x), dy: Double(-u.y))
                c.saveGState()
                c.translateBy(x: mid.x + u.x * offset, y: mid.y + u.y * offset); c.rotate(by: CGFloat(angle))
                text(label, at: .zero, size: 9, centered: true)
                c.restoreGState()
            }
            if isSelected {
                // Drag handles: white dots ringed in the selection colour.
                for point in [a, b] {
                    let r = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                    c.setFillColor(UIColor.white.cgColor); c.fillEllipse(in: r)
                    c.setStrokeColor(ink.cgColor); c.setLineWidth(2.5); c.strokeEllipse(in: r.insetBy(dx: 1.25, dy: 1.25))
                }
            }
            if let tag = tags[s.id] {
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let host = s.kind == .wall ? s : room.walls.first { $0.id == s.parentID }
                let inward = host.map { Geometry.inwardNormal($0, walls: room.walls, boundary: boundary) } ?? .init(x: 0, z: 1)
                // Wall numbers sit just outside the wall; opening tags sit inside, past the dimension line.
                let offset: CGFloat = s.kind == .wall ? -13 : 34
                let at = CGPoint(x: mid.x + p.direction(inward).x * offset, y: mid.y + p.direction(inward).y * offset)
                let tint = s.kind == .wall ? UIColor.gray : color(s.kind)
                let size = textSize(tag, size: 8, weight: .semibold)
                let pill = CGRect(x: at.x - size.width / 2 - 3, y: at.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
                c.setFillColor(UIColor.white.cgColor); c.addPath(UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).cgPath); c.fillPath()
                c.setStrokeColor(tint.cgColor); c.setLineWidth(0.6); c.addPath(UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).cgPath); c.strokePath()
                text(tag, at: at, size: 8, color: tint, centered: true, weight: .semibold)
            }
        }
        if areas {
            for (i, space) in spaces.enumerated() {
                let at = p.screen(Geometry.labelPoint(space.points))
                let value = room.units.areaLabel(space.area)
                // A light backing keeps the label readable over furniture. A lone unnamed space shows only
                // its area; otherwise the name sits above it.
                let named = spaces.count > 1 || room.spaceLabels != nil
                let width = max(textSize(value, size: 11, weight: .semibold).width, named ? textSize(String(summary.spaceNames[i].prefix(28)), size: 9).width : 0) + 12
                let backing = CGRect(x: at.x - width / 2, y: at.y - (named ? 17 : 9), width: width, height: named ? 32 : 18)
                c.setFillColor(UIColor.white.withAlphaComponent(0.82).cgColor)
                c.addPath(UIBezierPath(roundedRect: backing, cornerRadius: 6).cgPath); c.fillPath()
                if named {
                    text(String(summary.spaceNames[i].prefix(28)), at: CGPoint(x: at.x, y: at.y - 8), size: 9, color: .gray, centered: true)
                    text(value, at: CGPoint(x: at.x, y: at.y + 5), size: 11, color: ink, centered: true, weight: .semibold)
                } else { text(value, at: at, size: 11, color: ink, centered: true, weight: .semibold) }
            }
        }
    }
}

struct InteractivePlan: UIViewRepresentable {
    var room: RoomProject
    var dimensions = true
    var furniture = true
    var areas = false
    var insets = UIEdgeInsets.zero    // canvas area covered by overlays; the plan is fitted inside the rest
    var resetKey = 0
    @Binding var selected: UUID?
    var onTap: ((PlanPoint) -> Void)? = nil
    var onEdit: ((PlanSurface) -> Void)? = nil     // a finished drag; nil makes the plan read-only
    func makeUIView(context: Context) -> PlanCanvas {
        let view = PlanCanvas(); view.onSelect = { selected = $0; onTap?($1) }; return view
    }
    func updateUIView(_ view: PlanCanvas, context: Context) {
        if !view.isDragging { view.room = room }      // the canvas shows its live preview until the drag ends
        view.onEdit = onEdit; view.selected = selected; view.dimensions = dimensions; view.furniture = furniture; view.areas = areas; view.insets = insets
        view.onSelect = { selected = $0; onTap?($1) }
        if view.resetKey != resetKey { view.zoom = 1; view.pan = .zero; view.resetKey = resetKey; view.unpin() }
        view.setNeedsDisplay()
    }
}

final class PlanCanvas: UIView {
    var room = RoomProject()
    var selected: UUID?
    var onSelect: ((UUID?, PlanPoint) -> Void)?
    var onEdit: ((PlanSurface) -> Void)?
    private enum Grab { case wallEnd(atA: Bool), wall, openingEnd(atA: Bool), opening }
    private var drag: (grab: Grab, original: RoomProject, surface: PlanSurface, start: PlanPoint, latest: PlanSurface?)?
    var isDragging: Bool { drag != nil }
    // The framing at the start of a drag. It holds while dragging, so the plan doesn't refit and slide under the
    // pointer as the room's bounds change, and after the drop until the room changes some other way.
    private var pinned: (fit: PlanProjection, bounds: CGRect, surfaces: [PlanSurface]?)?
    func unpin() { pinned = nil }
    var dimensions = true, furniture = true, areas = false, resetKey = 0
    var insets = UIEdgeInsets.zero
    var zoom = 1.0
    var pan = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .white; isOpaque = true
        contentMode = .redraw      // refit on resize; the default stretches the last drawing (a Mac window resize)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panPlan(_:))))
        // Mouse wheel and trackpad scrolling (Mac, or iPad with a pointer): vertical zooms around the pointer,
        // horizontal moves the plan. Dragging still pans.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
        accessibilityLabel = "Interactive floor plan. Select a surface or use the Elements tab to edit."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var projection: PlanProjection {
        // Fit inside the uncovered area, but keep the full bounds as the viewport so panning draws under overlays.
        let fit = bounds.inset(by: insets)
        let fitted = pinned.flatMap { $0.bounds == bounds && (drag != nil || $0.surfaces == room.surfaces) ? $0.fit : nil }
            ?? PlanDrawing.projection(room, in: fit)
        return PlanProjection(scale: fitted.scale, center: fitted.center, viewport: bounds, zoom: zoom,
                              offset: CGSize(width: pan.width + fit.midX - bounds.midX, height: pan.height + fit.midY - bounds.midY), rotation: fitted.rotation)
    }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        PlanDrawing.draw(room, context: c, projection: projection, selected: selected, dimensions: dimensions, furniture: furniture, areas: areas)
    }
    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        let p = projection, point = p.world(recognizer.location(in: self))
        let threshold = 22 / (p.scale * zoom)
        onSelect?(Geometry.surface(at: point, in: room.activeSurfaces, threshold: threshold, openingBias: 6 / (p.scale * zoom)), point)
    }
    static let zoomRange = 0.5...20.0
    // Zooms so the plan point under `anchor` stays under it.
    private func zoom(by factor: Double, around anchor: CGPoint) {
        let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        let r = next / zoom
        guard r != 1 else { return }
        let fit = bounds.inset(by: insets)
        let ax = Double(anchor.x - fit.midX), ay = Double(anchor.y - fit.midY)
        pan = CGSize(width: Double(pan.width) * r + ax * (1 - r), height: Double(pan.height) * r + ay * (1 - r))
        zoom = next; setNeedsDisplay()
    }
    @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
        zoom(by: Double(recognizer.scale), around: recognizer.location(in: self)); recognizer.scale = 1
    }
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        let t = recognizer.translation(in: self); recognizer.setTranslation(.zero, in: self)
        let dy = Double(t.y) * (Setting.bool(Setting.invertScrollZoom, default: false) ? -1 : 1)
        if dy != 0 { zoom(by: exp(dy * 0.004), around: recognizer.location(in: self)) }
        if t.x != 0 { pan.width += t.x; setNeedsDisplay() }
        if recognizer.state == .ended {
            Logger(subsystem: "com.matthewsinitiere.Mensur", category: "plan").notice("plan scroll ended, zoom \(self.zoom)")
        }
    }
    // A drag that starts on the selected element (its end dots or its line) edits it; anywhere else pans.
    @objc private func panPlan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            let t = recognizer.translation(in: self), start = CGPoint(x: location.x - t.x, y: location.y - t.y)
            if onEdit != nil, let (grab, surface) = grab(at: start) {
                pinned = (PlanDrawing.projection(room, in: bounds.inset(by: insets)), bounds, nil)
                drag = (grab, room, surface, projection.world(start), nil); updateDrag(to: location); return
            }
        case .changed where drag != nil: updateDrag(to: location); return
        case .ended where drag != nil, .cancelled where drag != nil, .failed where drag != nil:
            if recognizer.state == .ended, let edited = drag?.latest { pinned?.surfaces = room.surfaces; onEdit?(edited) }
            else if let d = drag { room = d.original; pinned = nil }
            drag = nil; setNeedsDisplay(); return
        default: break
        }
        let d = recognizer.translation(in: self); pan.width += d.x; pan.height += d.y; recognizer.setTranslation(.zero, in: self); setNeedsDisplay()
    }
    private func grab(at point: CGPoint) -> (Grab, PlanSurface)? {
        guard let id = selected, let s = room.activeSurfaces.first(where: { $0.id == id }) else { return nil }
        let p = projection, a = p.screen(s.a), b = p.screen(s.b)
        let toA = hypot(point.x - a.x, point.y - a.y), toB = hypot(point.x - b.x, point.y - b.y)
        if min(toA, toB) <= 22 { return (s.kind == .wall ? .wallEnd(atA: toA <= toB) : .openingEnd(atA: toA <= toB), s) }
        let onLine = Geometry.distance(p.world(point), to: s.a, s.b) * p.scale * zoom
        return onLine <= 18 ? (s.kind == .wall ? .wall : .opening, s) : nil
    }
    private func updateDrag(to location: CGPoint) {
        guard var d = drag else { return }
        let p = projection, pointer = p.world(location), metersPerPoint = 1 / (p.scale * zoom)
        let edited: PlanSurface?
        switch d.grab {
        case .wallEnd(let atA):
            let end = (atA ? d.surface.a : d.surface.b) + (pointer - d.start)
            edited = PlanEdit.moveWallEnd(d.surface, atA: atA, to: end, in: d.original, snap: 12 * metersPerPoint, axisAngle: p.rotation)
        case .wall: edited = PlanEdit.moveWall(d.surface, by: pointer - d.start)
        case .openingEnd(let atA): edited = PlanEdit.resizeOpening(d.surface, atA: atA, in: d.original, to: pointer)
        case .opening: edited = PlanEdit.moveOpening(d.surface, in: d.original, from: d.start, to: pointer, reach: 24 * metersPerPoint)
        }
        guard var surface = edited else { return }       // invalid positions keep the last good preview
        if surface != d.surface && surface.evidence != .manual { surface.evidence = .edited }
        var preview = d.original
        Geometry.replace(surface, in: &preview, joinCorners: true)
        d.latest = surface; drag = d; room = preview; setNeedsDisplay()
    }
}
