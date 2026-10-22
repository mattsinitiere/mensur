import SwiftUI

struct ShareFiles: Identifiable { let id = UUID(); let urls: [URL] }
struct ActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct RoomDetailChrome: ViewModifier {
    let detail: RoomDetail
    func body(content: Content) -> some View { detail.chrome(content) }
}

struct RoomDetail: View {
    @EnvironmentObject private var store: ProjectStore
    @State var room: RoomProject
    @State private var tab = 0
    @State private var selected: UUID?
    @State private var editing: PlanSurface?
    @AppStorage(Setting.dimensions) private var showDimensions = true
    @AppStorage(Setting.furniture) private var showObjects = true
    @AppStorage(Setting.pdfPortrait) private var pdfPortrait = false
    @State private var savedFile: URL?
    @State private var resetKey = 0
    @State private var sharing: ShareFiles?
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var undoHistory: [RoomProject] = []
    @State private var showNotes = false
    @State private var showExportReview = false
    @State private var confirmRebuild = false
    @State private var tapPoint: PlanPoint?
    @State private var naming: Int?
    @State private var spaceDraft = ""
    @State private var inspectorTab = 2          // wide layout: Elements (2) or Review (3) beside the canvas
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Mac and iPad: canvas and lists side by side. iPhone: one column with four tabs.
    private var wide: Bool { UIDevice.current.userInterfaceIdiom != .phone && sizeClass == .regular }
    private var currentSurface: PlanSurface? { room.surfaces.first { $0.id == selected } }
    var body: some View {
        layout
        .background(Color.canvas)
        .navigationTitle(room.name).navigationBarTitleDisplayMode(.inline)
        .modifier(RoomDetailChrome(detail: self))
    }
    @ViewBuilder private var layout: some View {
        if wide {
            HStack(spacing: 0) {
                VStack(spacing: 14) {
                    header
                    Picker("View", selection: $tab) { Text("Plan").tag(0); Text("3D").tag(1) }
                        .pickerStyle(.segmented).frame(maxWidth: 260).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    canvas
                }
                .padding(.top, 14)
                Divider()
                VStack(spacing: 0) {
                    Picker("Details", selection: $inspectorTab) { Text("Elements").tag(2); Text("Review").tag(3) }
                        .pickerStyle(.segmented).padding(12)
                    if inspectorTab == 2 { elements } else { review }
                }
                .frame(width: 360)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .onAppear {
                if tab > 1 { tab = 0 }
                #if DEBUG
                // Developer aid for layout snapshots: MENSUR_TAB=1 opens the 3D view.
                if let t = ProcessInfo.processInfo.environment["MENSUR_TAB"].flatMap(Int.init) { tab = t }
                #endif
            }
        } else {
            VStack(spacing: 12) {
                header
                Picker("Workspace", selection: $tab) {
                    Text("Plan").tag(0); Text("3D").tag(1); Text("Elements").tag(2); Text("Review").tag(3)
                }.pickerStyle(.segmented).padding(.horizontal)
                if tab == 0 || tab == 1 { canvas }
                else if tab == 2 { elements }
                else { review }
            }
            .padding(.top, 8)
        }
    }
    @ViewBuilder private var header: some View {
        let summary = RoomSummary(room)
        if let address = room.address {
            Label(address, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
        }
        HStack(spacing: 8) {
            stat("Area", summary.totalArea.map { room.units.areaLabel($0) } ?? "Needs review")
            stat("Perimeter", summary.perimeter.map { room.units.length($0) } ?? "—")
            stat("Ceiling", summary.ceilingHeight.map { room.units.length($0) } ?? "—")
            if wide {
                stat("Walls", "\(room.walls.count)")
                stat("Doors", "\(room.activeSurfaces.filter { $0.kind == .door }.count)")
                stat("Windows", "\(room.activeSurfaces.filter { $0.kind == .window }.count)")
            }
        }.padding(.horizontal)
    }
    private var canvas: some View {
                ZStack(alignment: .bottom) {
                    Group {
                        if tab == 0 { InteractivePlan(room: room, dimensions: showDimensions, furniture: showObjects, areas: true, insets: UIEdgeInsets(top: 30, left: 0, bottom: 66, right: 0), resetKey: resetKey, selected: $selected, onTap: { tapPoint = $0 },
                                                      onEdit: { edited in commit { Geometry.replace(edited, in: &$0, joinCorners: true) } }) }
                        else { ModelPreview(room: room, showObjects: showObjects, resetKey: resetKey) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(0.06)))
                    .overlay(alignment: .topLeading) {
                        Text(tab == 0 && currentSurface != nil ? "Drag the dots to resize · drag the line to move" : Self.canvasTip(tab))
                            .font(.caption2).foregroundStyle(.secondary).padding(12).allowsHitTesting(false)
                    }
                    VStack(spacing: 10) {
                        if let s = currentSurface, tab == 0 { selection(s) }
                        dock
                    }.padding(12)
                }
                .padding(.horizontal).padding(.bottom, wide ? 16 : 8)
    }
    // Toolbar, sheets and alerts, shared by both layouts.
    fileprivate func chrome<Content: View>(_ content: Content) -> some View {
        content
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoHistory.isEmpty).accessibilityLabel("Undo edit")
                Menu {
                    Button("Room name, address and notes", systemImage: "pencil") { showNotes = true }
                    Button(room.units == .imperial ? "Display metric" : "Display feet and inches", systemImage: "ruler") {
                        commit { $0.units = $0.units == .imperial ? .metric : .imperial }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Room options")
                Menu {
                    Section("PDF sheet, 11 × 17") { sheetButtons }
                    Button("All files: PDF, CAD, 3D, project", systemImage: "square.stack.3d.up") { showExportReview = true }
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export room")
            }
        }
        .sheet(item: $editing) { s in SurfaceEditor(surface: s, room: room) { updated, join in commit { Geometry.replace(updated, in: &$0, joinCorners: join) } } }
        .sheet(isPresented: $showNotes) { RoomNotesEditor(room: room) { updated in commit { $0.name = updated.name; $0.address = updated.address; $0.notes = updated.notes } } }
        .alert("Name this space", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Showroom, office, kitchen…", text: $spaceDraft)
            Button("Save") {
                let spaces = RoomSummary(room).spaces
                if let i = naming, spaces.indices.contains(i) { commit { $0.nameSpace(spaces[i], spaceDraft) } }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: { Text("Leave it empty to use the default name.") }
        .sheet(item: $sharing) { ActivitySheet(urls: $0.urls) }
        .alert("Saved to Downloads", isPresented: Binding(get: { savedFile != nil }, set: { if !$0 { savedFile = nil } })) {
            Button("Show in Finder") { if let url = savedFile { UIApplication.shared.open(url.deletingLastPathComponent()) }; savedFile = nil }
            Button("OK", role: .cancel) { savedFile = nil }
        } message: { Text(savedFile?.lastPathComponent ?? "") }
        // A newer version from the other device replaces what's on screen; edits are already saved.
        .onReceive(store.received) { id in
            guard id == room.id, let latest = store.projects.first(where: { $0.id == id }) else { return }
            room = latest; undoHistory = []; selected = nil
        }
        .confirmationDialog("Export corrected plans and original scan", isPresented: $showExportReview, titleVisibility: .visible) {
            Button("Export PDF, CAD, 3D model and project") { export() }
        } message: {
            Text("\(room.reviewCount) surface(s) need review. \(room.checkedCount) individual lengths checked. The original USDZ does not include edits; the corrected OBJ does.")
        }
        .confirmationDialog("Re-run scan corrections", isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild from the original scan") {
                do { let fresh = try store.rebuilt(room); commit { $0 = fresh }; selected = nil }
                catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("Walls, windows, doors and furniture are built again from the original scan and its LiDAR measurements with the latest corrections. Name, address, notes and space names stay. Changes you made to the geometry are replaced; Undo brings them back.")
        }
        .alert("Couldn’t complete action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .overlay { if exporting { ZStack { Color.black.opacity(0.12); ProgressView("Preparing exports…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } } }
    }
    static func canvasTip(_ tab: Int) -> String {
        #if targetEnvironment(macCatalyst)
        return tab == 0 ? "Click a wall to edit · scroll to zoom · drag to move" : "Drag to rotate · scroll to zoom and move"
        #else
        return tab == 0 ? "Tap a wall to edit · pinch to zoom" : "Simplified model · wall thickness assumed"
        #endif
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private func selection(_ s: PlanSurface) -> some View {
        HStack {
            VStack(alignment: .leading) { Text(s.label).font(.headline); Text("\(s.kind.title) · \(room.units.length(s.length))").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if s.kind == .wall {
                // RoomPlan misses windows it cannot see as glass, such as ones behind blinds.
                Menu { addButtons } label: { Label("Add here", systemImage: "plus") }.buttonStyle(.bordered)
            }
            Button("Edit") { editing = s }.buttonStyle(.borderedProminent)
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    // Plan tools float over the canvas: fit, layer toggles, add, and the PDF sheet.
    private var dock: some View {
        HStack(spacing: 0) {
            Button { resetKey += 1 } label: { dockIcon("arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Fit to view")
            if tab == 0 { toggle("Dimensions", "ruler", $showDimensions) }
            toggle("Furniture", "sofa", $showObjects)
            if tab == 0 { Menu { addButtons } label: { dockIcon("plus") }.menuIndicator(.hidden).frame(maxWidth: .infinity).accessibilityLabel("Add element") }
            // Exports in the default layout from Settings; hold (iPhone) or right-click (Mac) for the other.
            Button { exportSheet(portrait: pdfPortrait) } label: { dockIcon("doc.richtext") }
                .contextMenu { Section("PDF sheet, 11 × 17") { sheetButtons } }
                .accessibilityLabel("Export PDF sheet").accessibilityHint("Hold or right-click for portrait or landscape")
        }
        .buttonStyle(.borderless)            // icon-only tools on every platform, not Mac bordered buttons
        .menuStyle(.button)
        .padding(.vertical, 4)
        .frame(maxWidth: wide ? 420 : .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func dockIcon(_ symbol: String, on: Bool = true) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: 42).contentShape(Rectangle())
    }
    private func toggle(_ name: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: { dockIcon(symbol, on: value.wrappedValue) }
            .accessibilityLabel(name).accessibilityValue(value.wrappedValue ? "Shown" : "Hidden")
    }
    @ViewBuilder private var addButtons: some View {
        let wall = currentSurface.flatMap { $0.kind == .wall ? $0 : nil }
        ForEach(wall == nil ? SurfaceKind.allCases : [.window, .door, .mirror, .opening]) { kind in
            Button(wall == nil ? "Add \(kind.title.lowercased())" : "Add \(kind.title.lowercased()) here", systemImage: kind.symbol) { add(kind) }
        }
    }
    @ViewBuilder private var sheetButtons: some View {
        ForEach(pdfPortrait ? [true, false] : [false, true], id: \.self) { portrait in
            Button(portrait ? "Portrait" : "Landscape", systemImage: portrait ? "rectangle.portrait" : "rectangle") { exportSheet(portrait: portrait) }
        }
    }
    private var elements: some View {
        let summary = RoomSummary(room)
        return List {
            if !summary.spaces.isEmpty {
                Section {
                    ForEach(summary.spaces.indices, id: \.self) { i in
                        Button {
                            spaceDraft = room.spaceLabels?.first { Geometry.contains(summary.spaces[i].points, $0.anchor) }?.name ?? ""
                            naming = i
                        } label: {
                            HStack {
                                Image(systemName: "square.dashed").foregroundStyle(.tint)
                                Text(summary.spaceNames[i]).foregroundStyle(.primary)
                                Spacer()
                                Text(room.units.areaLabel(summary.spaces[i].area)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityHint("Renames this space")
                    }
                } header: { Text("Spaces") } footer: { Text("Tap a space to name it. Names appear on the plan and the PDF sheet.") }
            }
            Section("Surfaces") {
                ForEach(room.surfaces) { s in
                    Button { selected = s.id; editing = s } label: {
                        HStack {
                            Image(systemName: s.kind.symbol).foregroundStyle(Color(uiColor: PlanDrawing.color(s.kind)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.label).foregroundStyle(.primary)
                                Text("\(s.kind.title) · \(room.units.length(s.length)) · \(s.evidence.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if s.excluded { Text("Excluded").font(.caption).foregroundStyle(.secondary) }
                            else if s.needsReview { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                            else if s.hasCurrentLengthCheck { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                        }
                    }
                }
            }
            Section("Furniture · recognized boxes") {
                ForEach(room.objects) { o in
                    HStack {
                        VStack(alignment: .leading) { Text(o.label); Text("\(room.units.length(o.size.x)) × \(room.units.length(o.size.z))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(o.excluded ? "Restore" : "Exclude") { commit { p in if let i = p.objects.firstIndex(where: { $0.id == o.id }) { p.objects[i].excluded.toggle() } } }.font(.caption)
                    }
                }
            }
        }
    }
    private var review: some View {
        List {
            Section("Accuracy") {
                Label("\(room.checkedCount) individual lengths checked", systemImage: "ruler")
                Text("Checking a length does not validate the surface position, angle, height, or room area. Use independent laser or tape measurements for important dimensions.").font(.subheadline).foregroundStyle(.secondary)
                if let warning = Geometry.boundary(room.walls).warning, RoomSummary(room).totalArea == nil { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else if Geometry.boundary(room.walls).warning != nil { Text("Area is the sum of the enclosed spaces; pillars or partitions mean the walls don't form one simple outline.").font(.caption).foregroundStyle(.secondary) }
                else { Text("Area is approximate. Wall endpoints within 80 mm are joined for the area calculation only.").font(.caption).foregroundStyle(.secondary) }
            }
            lidarSection
            Section("Windows and mirrors") {
                Text("Review the solid frames and wall plane, correct missing windows, add measured mirror panels, and exclude phantom walls or furniture. No automatic reflection suppression is applied.").font(.subheadline)
                ForEach(room.activeSurfaces.filter { $0.needsReview || $0.kind == .window || $0.kind == .mirror }) { s in
                    Button { editing = s } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.label)
                            Text(s.reviewed ? "Visually reviewed · \(s.hasCurrentLengthCheck ? "length checked" : "length unchecked")" : "Needs visual and measurement review").font(.caption).foregroundStyle(s.reviewed ? Color.secondary : Color.orange)
                            if let caveat = s.geometryCaveat { Text(caveat).font(.caption).foregroundStyle(.orange) }
                            if let note = s.reviewNote { Text(note).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            Section("Geometry checks") {
                ForEach(room.activeSurfaces.filter { Geometry.openingIssue($0, in: room) != nil }) { s in
                    Button { editing = s } label: { VStack(alignment: .leading) { Text(s.label); Text(Geometry.openingIssue(s, in: room) ?? "").font(.caption).foregroundStyle(.orange) } }
                }
                Text("Openings outside their parent wall are not cut into the corrected 3D wall until fixed.").font(.caption).foregroundStyle(.secondary)
            }
            cleanup
            Section("Capture notes") { ForEach(Array(room.captureWarnings.enumerated()), id: \.offset) { _, note in Text(note).font(.subheadline) } }
        }
    }
    // Each wall's LiDAR check from the scan: where the measured wall surface is, compared with the plan.
    @ViewBuilder private var lidarSection: some View {
        let checked = room.walls.filter { $0.lidarCheck != nil }
        if !checked.isEmpty {
            let confirmed = checked.filter { $0.lidarCheck?.level == .confirmed }
            Section {
                Label("\(confirmed.count) of \(checked.count) walls confirmed by the LiDAR", systemImage: confirmed.count == checked.count ? "checkmark.seal.fill" : "checkmark.seal")
                    .foregroundStyle(confirmed.count == checked.count ? Color.green : Color.primary)
                ForEach(checked.sorted { order($0) < order($1) }) { wall in
                    Button { editing = wall } label: {
                        HStack {
                            Image(systemName: symbol(wall)).foregroundStyle(tint(wall))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(wall.label) · \(room.units.length(wall.length))")
                                Text(detail(wall)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { Text("LiDAR check") } footer: {
                Text("Confirmed: the LiDAR measured this wall's surface along most of its length, within 2 cm of the plan. Lengths follow from the corners where confirmed walls meet. Tape-check walls that aren't confirmed, and any dimension that matters.")
            }
        }
    }
    private func order(_ w: PlanSurface) -> Int { switch w.lidarCheck?.level { case .unconfirmed: 0; case .partly: 1; default: 2 } }
    private func symbol(_ w: PlanSurface) -> String { switch w.lidarCheck?.level { case .confirmed: "checkmark.circle.fill"; case .partly: "circle.lefthalf.filled"; default: "exclamationmark.circle" } }
    private func tint(_ w: PlanSurface) -> Color { switch w.lidarCheck?.level { case .confirmed: .green; case .partly: .yellow; default: .orange } }
    private func detail(_ w: PlanSurface) -> String {
        guard let c = w.lidarCheck else { return "" }
        let seen = "\(Int((c.coverage * 100).rounded()))% of its length seen"
        switch c.level {
        case .confirmed: return "Confirmed · within \(max(1, Int((abs(c.offset) * 1000).rounded()))) mm · \(seen)"
        case .partly: return "Partly confirmed · \(seen); scan it closer or tape-check it"
        case .unconfirmed: return c.coverage < 0.3 ? "Not confirmed · the LiDAR barely saw this wall" : "Not confirmed · surface \(Int((abs(c.offset) * 100).rounded())) cm from the plan"
        }
    }
    private func commit(_ edit: (inout RoomProject) -> Void) {
        let before = room; var next = room; edit(&next); next.updatedAt = Date()
        do { try store.save(next); undoHistory.append(before); if undoHistory.count > 30 { undoHistory.removeFirst() }; room = next }
        catch { errorMessage = error.localizedDescription }
    }
    private func undo() {
        guard let previous = undoHistory.last else { return }
        do { try store.save(previous); room = previous; undoHistory.removeLast() } catch { errorMessage = error.localizedDescription }
    }
    private var cleanup: some View {
        let corners = Geometry.squarableCorners(room).count, stubs = Geometry.wallStubs(room).count
        let cleaned = room.surfaces.filter { $0.autoCleanup != nil }.count
        return Section("Corners and stubs") {
            if corners > 0 { Button("Square \(corners) rounded corner\(corners == 1 ? "" : "s")") { commit { _ = Geometry.squareCorners(&$0) } } }
            if stubs > 0 { Button("Hide \(stubs) short wall stub\(stubs == 1 ? "" : "s")") { commit { _ = Geometry.hideStubs(&$0) } } }
            if cleaned > 0 { Button("Restore original corners and stubs", role: .destructive) { commit { _ = Geometry.restoreCleanup(&$0) } } }
            if store.canRebuild(room) { Button("Re-run scan corrections") { confirmRebuild = true } }
            if corners == 0 && stubs == 0 && cleaned == 0 { Text("No short corner pieces or wall stubs found.").font(.subheadline).foregroundStyle(.secondary) }
            Text("RoomPlan can close a corner with short wall pieces, or leave short stubs on long walls. Squaring extends the two walls to meet; hidden pieces stay listed in Elements as excluded. Original RoomPlan files are never changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    // New elements go straight onto the plan, selected, ready to drag into place; Edit opens the details.
    private func add(_ kind: SurfaceKind) {
        let label = "\(kind.title) \(room.surfaces.filter { $0.kind == kind }.count + 1)"
        var placed: PlanSurface?
        if kind != .wall, let wall = currentSurface, wall.kind == .wall {
            placed = Geometry.placeOpening(kind, on: wall, near: tapPoint ?? wall.midpoint, label: label)      // where the wall was tapped
        } else if kind != .wall, let wall = room.walls.max(by: { $0.length < $1.length }) {
            placed = Geometry.placeOpening(kind, on: wall, near: wall.midpoint, label: label)
        } else if kind == .wall, !room.activeSurfaces.isEmpty {
            // A 2 m wall across the middle of the plan, square to the room.
            let center = PlanBounds(room.activeSurfaces.flatMap { [$0.a, $0.b] }).center
            let along = Geometry.rotate(PlanPoint(x: 1, z: 0), by: Geometry.dominantAngle(room.walls))
            placed = PlanSurface(label: label, kind: .wall, a: center - along, b: center + along, height: room.walls.map(\.height).max() ?? 2.5)
        }
        if let placed {
            commit { $0.surfaces.append(placed) }
            selected = placed.id; tab = 0; return
        }
        var s = PlanSurface(label: label, kind: kind,
                            a: .zero, b: .init(x: 1, z: 0), height: kind == .wall ? 2.5 : 1.5,
                            reflectiveRisk: kind == .window || kind == .mirror)
        if kind != .wall, let wall = room.walls.first {
            s = Geometry.attach(s, to: wall, offset: 0, width: min(1, wall.length)); s.bottom = kind == .window ? 0.8 : wall.bottom
        }
        editing = s
    }
    // iPhone shares the file; the Mac saves it straight into Downloads.
    private func deliver(_ urls: [URL]) throws {
        #if targetEnvironment(macCatalyst)
        savedFile = try ExportService.saveToDownloads(urls, folderName: room.name)
        #else
        sharing = ShareFiles(urls: urls)
        #endif
    }
    private func exportSheet(portrait: Bool) {
        do { try deliver([try ExportService.sheet(room, portrait: portrait)]) }
        catch { errorMessage = error.localizedDescription }
    }
    private func export() {
        exporting = true
        Task { @MainActor in
            await Task.yield()
            defer { exporting = false }
            do { try store.save(room); try deliver(try ExportService.export(room, originals: store.directory(room.id))) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
