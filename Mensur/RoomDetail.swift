import SwiftUI
import PhotosUI

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
struct EditingItem: Identifiable { let id: UUID }
struct EditingSpace: Identifiable { let id: Int }

struct RoomDetail: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var navigation: AppNavigation
    @State var room: RoomProject
    @State private var tab = 0
    @State private var selected: UUID?
    @State private var editing: PlanSurface?
    @State private var editingItem: EditingItem?
    @State private var editingSpace: EditingSpace?
    @AppStorage(Setting.dimensions) private var showDimensions = true
    @AppStorage(Setting.dimensionStyle) private var dimensionStyle = PlanGeometry.DimensionStyle.walls.rawValue
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
    @State private var showFurniture = false
    @State private var showCamera = false
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoPoint: PlanPoint?
    @State private var resuming = false
    @State private var tapPoint: PlanPoint?
    @State private var inspectorTab = 2          // wide layout: Elements (2) or Review (3) beside the canvas
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Mac and iPad: canvas and lists side by side. iPhone: one column with four tabs.
    private var wide: Bool { UIDevice.current.userInterfaceIdiom != .phone && sizeClass == .regular }
    private var currentSurface: PlanSurface? { room.surfaces.first { $0.id == selected } }
    private var style: PlanGeometry.DimensionStyle { PlanGeometry.DimensionStyle(rawValue: dimensionStyle) ?? .walls }
    var body: some View {
        layout
        .overlay(alignment: .top) {
            if navigation.tour == room.id {
                TourCard(onStep: tourStep, onEnd: { navigation.tour = nil; tab = 0; inspectorTab = 2; selected = nil }).padding(.horizontal).padding(.top, 8)
            }
        }
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
                // Developer aid for layout snapshots: MENSUR_TAB=1 opens the 3D view, MENSUR_INSPECTOR=3 Review.
                if let t = ProcessInfo.processInfo.environment["MENSUR_TAB"].flatMap(Int.init) { tab = t }
                if let t = ProcessInfo.processInfo.environment["MENSUR_INSPECTOR"].flatMap(Int.init) { inspectorTab = t }
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
        let measures = Group {
            stat("Area", summary.totalArea.map { room.units.areaLabel($0) } ?? "Needs review")
            stat("Perimeter", summary.perimeter.map { room.units.length($0) } ?? "—")
            stat("Ceiling", summary.ceilingHeight.map { room.units.length($0) } ?? "—")
        }
        if wide {
            let counts = Group {
                stat("Walls", "\(room.walls.count)")
                stat("Doors", "\(room.activeSurfaces.filter { $0.kind == .door }.count)")
                stat("Windows", "\(room.activeSurfaces.filter { $0.kind == .window }.count)")
            }
            // All six cards in a row when they fit, otherwise two rows of three, instead of squeezing their labels.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { measures.frame(minWidth: 120); counts.frame(minWidth: 120) }
                VStack(spacing: 8) { HStack(spacing: 8) { measures }; HStack(spacing: 8) { counts } }
            }.padding(.horizontal)
        } else {
            HStack(spacing: 8) { measures }.padding(.horizontal)
        }
    }
    private var canvas: some View {
                ZStack(alignment: .bottom) {
                    Group {
                        if tab == 0 { InteractivePlan(room: room, dimensions: showDimensions, furniture: showObjects, areas: true, insets: UIEdgeInsets(top: 30, left: 0, bottom: 66, right: 0), resetKey: resetKey, selected: $selected, onTap: { tapPoint = $0 },
                                                      onEdit: { edited in commit { Geometry.replace(edited, in: &$0, joinCorners: true) } },
                                                      onMove: { id, delta in commit { $0.move(id, by: delta) } }, dimensionStyle: style) }
                        else { ModelPreview(room: room, showObjects: showObjects, resetKey: resetKey) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(0.06)))
                    .overlay(alignment: .topLeading) {
                        Text(tab == 0 && currentSurface != nil ? "Drag the dots to resize · drag the line to move" : tab == 0 && selected != nil ? "Drag it to move" : Self.canvasTip(tab))
                            .font(.caption2).foregroundStyle(.secondary).padding(12).allowsHitTesting(false)
                    }
                    VStack(spacing: 10) {
                        if tab == 0 {
                            if let s = currentSurface { selection(s) }
                            else if let id = selected, room.itemKind(id) != nil { itemSelection(id) }
                        }
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
                    Button("Room details, job and building", systemImage: "pencil") { showNotes = true }
                    Button(room.units == .imperial ? "Display metric" : "Display feet and inches", systemImage: "ruler") {
                        commit { $0.units = $0.units == .imperial ? .metric : .imperial }
                    }
                    #if !targetEnvironment(macCatalyst)
                    if store.canResume(room) { Button("Continue scanning this room", systemImage: "viewfinder") { resuming = true } }
                    #endif
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Room options")
                Menu { exportButtons } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export room")
            }
        }
        .sheet(item: $editing) { s in SurfaceEditor(surface: s, room: room) { updated, join in commit { Geometry.replace(updated, in: &$0, joinCorners: join) } } }
        .sheet(item: $editingItem) { item in ItemEditor(room: room, id: item.id) { updated in commit { $0 = updated }; if updated.itemKind(item.id) == nil { selected = nil } } }
        .sheet(item: $editingSpace) { item in
            let summary = RoomSummary(room)
            if summary.spaces.indices.contains(item.id) {
                SpaceEditor(space: summary.spaces[item.id], label: room.spaceLabel(summary.spaces[item.id]), defaultName: "Space \(item.id < 26 ? String(UnicodeScalar(65 + item.id)!) : "\(item.id + 1)")") { label in
                    commit { $0.setSpaceLabel(label, for: summary.spaces[item.id]) }
                }
            }
        }
        .sheet(isPresented: $showNotes) {
            RoomNotesEditor(room: room, onSave: { updated in commit { $0.name = updated.name; $0.address = updated.address; $0.notes = updated.notes; $0.job = updated.job; $0.level = updated.level } },
                            buildings: Array(Set(store.projects.compactMap(\.level?.building))).sorted())
        }
        .sheet(isPresented: $showFurniture) { FurnitureLibrary(units: room.units) { addFurniture($0) } }
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { image in addPhoto(image) }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $resuming) {
            CaptureScreen(resume: store.resumeContext(room)) { captured, _, measurements in Task { await store.addResumed(captured, into: room.id, measurements: measurements) } }
        }
        #endif
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { addPhoto(image) }
                photoItem = nil
            }
        }
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
            Button("Export PDF set, CAD, BIM, 3D and project") { export() }
        } message: {
            Text("\(room.reviewCount) surface(s) need review. \(room.checkedCount) individual lengths checked. The original USDZ does not include edits; the corrected models do.")
        }
        .confirmationDialog("Re-run scan corrections", isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild from the original scan") {
                do { let fresh = try store.rebuilt(room); commit { $0 = fresh }; selected = nil }
                catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("Walls, windows, doors and furniture are built again from the original scan and its LiDAR measurements with the latest corrections. Name, address, notes, space names, markers, photos, stairs and ceiling features stay. Changes you made to the geometry are replaced; Undo brings them back.")
        }
        .alert("Couldn’t complete action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .overlay { if exporting { ZStack { Color.black.opacity(0.12); ProgressView("Preparing exports…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } } }
    }
    static func canvasTip(_ tab: Int) -> String {
        #if targetEnvironment(macCatalyst)
        return tab == 0 ? "Click a wall to edit · scroll to zoom · drag to move" : "Drag to rotate · scroll to zoom and move"
        #else
        return tab == 0 ? "Tap a wall to edit · pinch to zoom" : "Simplified model · wall thickness as set on the plan"
        #endif
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private func selection(_ s: PlanSurface) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(s.label).font(.headline)
                Text("\(s.kind.title) · \(room.units.length(s.length))" + (s.drawnThickness.map { " · \(room.units.length($0)) thick" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.kind == .wall {
                // RoomPlan misses windows it cannot see as glass, such as ones behind blinds.
                Menu { surfaceButtons } label: { Label("Add here", systemImage: "plus") }.buttonStyle(.bordered)
            }
            Button("Edit") { editing = s }.buttonStyle(.borderedProminent)
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    // The selected marker, photo, stair, ceiling feature or piece of furniture.
    private func itemSelection(_ id: UUID) -> some View {
        let (title, detail): (String, String) = {
            switch room.itemKind(id) {
            case .marker:
                let m = room.markers!.first { $0.id == id }!
                return (m.label.isEmpty ? m.kind.title : "\(m.kind.title) · \(m.label)", m.height.map { "\(room.units.length($0)) above the floor" } ?? m.kind.category.rawValue.capitalized)
            case .photo: let ph = room.photos!.first { $0.id == id }!; return ("Photo", ph.caption.isEmpty ? ph.takenAt.formatted(date: .abbreviated, time: .shortened) : ph.caption)
            case .stair: let s = room.stairs!.first { $0.id == id }!; return (s.label.isEmpty ? "Stair" : s.label, "\(s.up ? "Up" : "Down") · \(s.risers) risers · \(room.units.length(s.width)) wide")
            case .ceiling:
                let f = room.ceilings!.first { $0.id == id }!
                return (f.label.isEmpty ? f.kind.title : f.label, "\(room.units.length(f.low))\(f.high.map { " to " + room.units.length($0) } ?? "") high")
            case .object: let o = room.objects.first { $0.id == id }!; return (o.label, "\(room.units.length(o.size.x)) × \(room.units.length(o.size.z))")
            default: return ("", "")
            }
        }()
        return HStack {
            VStack(alignment: .leading) { Text(title).font(.headline).lineLimit(1); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if [.object, .stair, .ceiling].contains(room.itemKind(id)) {
                Button { commit { $0.rotate(id, by: .pi / 12) } } label: { Image(systemName: "rotate.right") }.buttonStyle(.bordered).accessibilityLabel("Turn 15 degrees")
            }
            Button(room.itemKind(id) == .photo ? "Open" : "Edit") { editingItem = EditingItem(id: id) }.buttonStyle(.borderedProminent)
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    // Plan tools float over the canvas: fit, dimensions, furniture, add, and the PDF sheet.
    private var dock: some View {
        HStack(spacing: 0) {
            Button { resetKey += 1 } label: { dockIcon("arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Fit to view")
            if tab == 0 {
                Menu {
                    Toggle("Show dimensions", isOn: $showDimensions)
                    Picker("Dimension style", selection: $dimensionStyle) {
                        ForEach(PlanGeometry.DimensionStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: { dockIcon("ruler", on: showDimensions) }.menuIndicator(.hidden).frame(maxWidth: .infinity).accessibilityLabel("Dimensions")
            }
            toggle("Furniture and annotations", "sofa", $showObjects)
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
    @ViewBuilder private var surfaceButtons: some View {
        let wall = currentSurface.flatMap { $0.kind == .wall ? $0 : nil }
        ForEach(wall == nil ? SurfaceKind.allCases : [.window, .door, .mirror, .opening]) { kind in
            Button(wall == nil ? "Add \(kind.title.lowercased())" : "Add \(kind.title.lowercased()) here", systemImage: kind.symbol) { add(kind) }
        }
    }
    @ViewBuilder private var addButtons: some View {
        Section { surfaceButtons }
        Section {
            Menu {
                ForEach([MarkerCategory.electrical, .plumbing, .hvac, .other], id: \.self) { category in
                    Section(category == .hvac ? "HVAC" : category.rawValue.capitalized) {
                        ForEach(MarkerKind.allCases.filter { $0.category == category }) { kind in Button(kind.title, systemImage: kind.symbol) { addMarker(kind) } }
                    }
                }
            } label: { Label("Marker", systemImage: "bolt") }
            Menu {
                #if !targetEnvironment(macCatalyst)
                Button("Take photo", systemImage: "camera") { photoPoint = placePoint; showCamera = true }
                #endif
                Button("Choose photo", systemImage: "photo") { photoPoint = placePoint; pickingPhoto = true }
            } label: { Label("Photo", systemImage: "camera") }
            Button("Furniture…", systemImage: "sofa") { showFurniture = true }
            Button("Stair", systemImage: "stairs") { addStair() }
            Menu {
                ForEach(CeilingKind.allCases) { kind in Button(kind.title) { addCeiling(kind) } }
            } label: { Label("Ceiling feature", systemImage: "square.3.layers.3d.top.filled") }
        }
    }
    @ViewBuilder private var sheetButtons: some View {
        ForEach(pdfPortrait ? [true, false] : [false, true], id: \.self) { portrait in
            Button(portrait ? "Portrait" : "Landscape", systemImage: portrait ? "rectangle.portrait" : "rectangle") { exportSheet(portrait: portrait) }
        }
    }
    @ViewBuilder private var exportButtons: some View {
        Section("PDF") {
            Menu { sheetButtons } label: { Label("Plan sheet, 11 × 17", systemImage: "doc.richtext") }
            Button("PDF set: plan, elevations, schedules, photos", systemImage: "doc.on.doc") { exportFile(.pdfSet) }
        }
        Section("Drawings") {
            Button("SVG plan", systemImage: "square.on.circle") { exportFile(.svg) }
            Button("PNG plan, high resolution", systemImage: "photo") { exportFile(.png) }
        }
        Section("CAD, BIM and 3D") {
            Button("DXF · AutoCAD, layered", systemImage: "square.grid.3x3") { exportFile(.dxf) }
            Button("IFC · Revit, ArchiCAD", systemImage: "building.2") { exportFile(.ifc) }
            Button("DAE · SketchUp", systemImage: "cube") { exportFile(.dae) }
            Button("OBJ · 3D model", systemImage: "cube.transparent") { exportFile(.obj) }
        }
        Section {
            Button("All files", systemImage: "square.stack.3d.up") { showExportReview = true }
            Button("Send room to another device", systemImage: "airplayaudio") { sendPackage() }
        }
    }
    private var elements: some View {
        let summary = RoomSummary(room)
        return List {
            if !summary.spaces.isEmpty {
                Section {
                    ForEach(summary.spaces.indices, id: \.self) { i in
                        Button { editingSpace = EditingSpace(id: i) } label: {
                            HStack {
                                Image(systemName: "square.dashed").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.spaceNames[i]).foregroundStyle(.primary)
                                    if let finishes = room.spaceLabel(summary.spaces[i]).flatMap(SVGExporter.finishLine) { Text(finishes).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(room.units.areaLabel(summary.spaces[i].area)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityHint("Names this space and sets its finishes")
                    }
                } header: { Text("Spaces") } footer: { Text("Tap a space to name it and set its finishes. They appear on the plan and in the PDF set’s room schedule.") }
            }
            quantities
            Section("Surfaces") {
                ForEach(room.surfaces) { s in
                    Button { selected = s.id; editing = s } label: {
                        HStack {
                            Image(systemName: s.kind.symbol).foregroundStyle(Color(uiColor: PlanDrawing.color(s.kind)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.label).foregroundStyle(.primary)
                                Text("\(s.kind.title) · \(room.units.length(s.length)) · \(s.evidence.rawValue)" + (s.wallType.map { " · \($0.title.lowercased())" } ?? "") + (s.doorStyle.map { " · \($0.title.lowercased())" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if s.excluded { Text("Excluded").font(.caption).foregroundStyle(.secondary) }
                            else if s.needsReview { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                            else if s.hasCurrentLengthCheck { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                        }
                    }
                }
            }
            if let markers = room.markers, !markers.isEmpty {
                Section("Markers") {
                    ForEach(markers) { m in
                        itemRow(m.id, symbol: m.kind.symbol, tint: Color(uiColor: PlanDrawing.markerColor(m.kind.category)),
                                title: m.label.isEmpty ? m.kind.title : "\(m.kind.title) · \(m.label)", detail: m.height.map { room.units.length($0) + " high" } ?? m.kind.code)
                    }
                }
            }
            if let photos = room.photos, !photos.isEmpty {
                Section("Photos") {
                    ForEach(photos) { ph in itemRow(ph.id, symbol: "camera", tint: .indigo, title: ph.caption.isEmpty ? "Photo" : ph.caption, detail: ph.takenAt.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            if let stairs = room.stairs, !stairs.isEmpty {
                Section("Stairs") {
                    ForEach(stairs) { s in itemRow(s.id, symbol: "stairs", tint: .primary, title: s.label.isEmpty ? "Stair" : s.label, detail: "\(s.up ? "Up" : "Down") · \(s.risers) risers") }
                }
            }
            if let ceilings = room.ceilings, !ceilings.isEmpty {
                Section("Ceiling") {
                    ForEach(ceilings) { f in
                        itemRow(f.id, symbol: "square.3.layers.3d.top.filled", tint: Color(uiColor: PlanDrawing.ceilingTint), title: f.label.isEmpty ? f.kind.title : f.label,
                                detail: "\(room.units.length(f.low))\(f.high.map { " to " + room.units.length($0) } ?? "")\(f.detected ? " · from the LiDAR" : "")")
                    }
                }
            }
            Section {
                ForEach(room.objects) { o in
                    HStack {
                        Button { selected = o.id; tab = 0; editingItem = EditingItem(id: o.id) } label: {
                            VStack(alignment: .leading) { Text(o.label).foregroundStyle(.primary); Text("\(room.units.length(o.size.x)) × \(room.units.length(o.size.z))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(o.excluded ? "Restore" : "Exclude") { commit { p in if let i = p.objects.firstIndex(where: { $0.id == o.id }) { p.objects[i].excluded.toggle() } } }.font(.caption)
                    }
                }
                Button("Add furniture", systemImage: "plus") { showFurniture = true }
            } header: { Text("Furniture") }
        }
    }
    private func itemRow(_ id: UUID, symbol: String, tint: Color, title: String, detail: String) -> some View {
        Button { selected = id; if !wide { tab = 0 }; editingItem = EditingItem(id: id) } label: {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) { Text(title).foregroundStyle(.primary).lineLimit(1); Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    // Floor, ceiling, wall and baseboard quantities for estimating finishes.
    private var quantities: some View {
        let t = Takeoff(room), u = room.units
        return Section {
            LabeledContent("Floor", value: u.areaLabel(t.floorArea))
            LabeledContent("Ceiling", value: u.areaLabel(t.ceilingArea))
            LabeledContent("Volume", value: Takeoff.volumeLabel(t.volume, units: u))
            LabeledContent("Walls, net of openings", value: u.areaLabel(t.wallNet))
            LabeledContent("Walls, gross", value: u.areaLabel(t.wallGross))
            LabeledContent("Baseboard", value: Takeoff.runLabel(t.baseboard, units: u))
            if t.spaces.count > 1 {
                ForEach(t.spaces.indices, id: \.self) { i in
                    let s = t.spaces[i]
                    LabeledContent(s.name, value: "\(u.areaLabel(s.floorArea)) · \(Takeoff.volumeLabel(s.volume, units: u))").font(.caption)
                }
            }
        } header: { Text("Quantities") } footer: {
            Text("From the inside faces of the walls and the ceiling heights, including any soffits, beams, slopes and vaults drawn on the plan. Wall area is one face, less doors, windows and openings; baseboard is the perimeter less door widths. Approximate: add waste for ordering.")
        }
    }
    private var review: some View {
        List {
            healthSection
            if let report = room.scanReport {
                Section("Scan quality") {
                    ForEach(Array(ScanMetrics.summary(report, units: room.units).enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline) }
                }
            }
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
            cleanup
            Section("Capture notes") { ForEach(Array(room.captureWarnings.enumerated()), id: \.offset) { _, note in Text(note).font(.subheadline) } }
        }
    }
    // The plan's health: gaps, loose ends, odd corners, overlaps and crossings. Tapping one selects it.
    private var healthSection: some View {
        let findings = HealthCheck.run(room)
        return Section {
            if findings.isEmpty {
                Label("No gaps, loose ends, odd angles or overlaps found", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            ForEach(findings) { f in
                Button {
                    selected = f.surfaces.first; if !wide { tab = 0 }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: f.severity == .problem ? "xmark.octagon.fill" : f.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(f.severity == .problem ? Color.red : f.severity == .warning ? Color.yellow : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(f.title).foregroundStyle(.primary); Text(f.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } header: { Text("Health check") } footer: {
            Text("Tap a finding to select the walls involved on the plan.")
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
    // Each tour step shows what its tip talks about.
    private func tourStep(_ step: Int) {
        switch step {
        case 0: tab = 0; selected = nil
        case 1: tab = 0; selected = room.surfaces.first { $0.kind == .door }?.id
        case 2: selected = nil; if wide { inspectorTab = 2 } else { tab = 2 }
        case 3: if wide { inspectorTab = 3 } else { tab = 3 }
        default: tab = 0; if wide { inspectorTab = 2 }
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
    // Where new items go: the last tap on the plan, else the middle of the room.
    private var placePoint: PlanPoint {
        tapPoint ?? (room.activeSurfaces.isEmpty ? .zero : PlanBounds(room.activeSurfaces.flatMap { [$0.a, $0.b] }).center)
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
    // Markers snap onto the nearest wall within 30 cm when they're wall-mounted, so they show on elevations.
    private func addMarker(_ kind: MarkerKind) {
        var at = placePoint
        if kind.typicalHeight != nil, let wall = room.walls.min(by: { Geometry.distance(at, to: $0.a, $0.b) < Geometry.distance(at, to: $1.a, $1.b) }),
           Geometry.distance(at, to: wall.a, wall.b) < 0.3 {
            let t = max(0, min(wall.length, (at - wall.a).dot(wall.direction)))
            at = wall.a + wall.direction * t + Geometry.inwardNormal(wall, walls: room.walls, boundary: Geometry.boundary(room.walls)) * 0.08
        }
        let marker = PlanMarker(kind: kind, position: at, height: kind.typicalHeight)
        commit { $0.markers = ($0.markers ?? []) + [marker] }
        selected = marker.id; tab = 0
    }
    private func addFurniture(_ item: FurnitureItem) {
        let at = placePoint
        let object = PlanObject(label: item.name, center: .init(x: at.x, y: item.size.y / 2, z: at.z), size: item.size, yaw: Geometry.dominantAngle(room.walls))
        commit { $0.objects.append(object) }
        selected = object.id; tab = 0; showObjects = true
    }
    private func addStair() {
        let at = placePoint, along = Geometry.rotate(PlanPoint(x: 1, z: 0), by: Geometry.dominantAngle(room.walls))
        let stair = Stair(a: at - along * 1.5, b: at + along * 1.5, width: 0.9, risers: 14, up: true, toFloor: room.level.map { $0.floor + 1 })
        commit { $0.stairs = ($0.stairs ?? []) + [stair] }
        selected = stair.id; tab = 0
    }
    private func addCeiling(_ kind: CeilingKind) {
        let at = placePoint, along = Geometry.rotate(PlanPoint(x: 1, z: 0), by: Geometry.dominantAngle(room.walls))
        let height = RoomSummary(room).ceilingHeight ?? 2.7
        let feature: CeilingFeature
        switch kind {
        case .soffit: feature = CeilingFeature(kind: .soffit, a: at - along, b: at + along, width: 0.6, low: height - 0.3, label: "Soffit")
        case .beam: feature = CeilingFeature(kind: .beam, a: at - along * 2, b: at + along * 2, width: 0.3, low: height - 0.25, label: "Beam")
        case .slope: feature = CeilingFeature(kind: .slope, a: at - along * 1.5, b: at + along * 1.5, width: 3, low: height, high: height + 1, label: "Sloped ceiling")
        case .vault: feature = CeilingFeature(kind: .vault, a: at - along * 2, b: at + along * 2, width: 3, low: height, high: height + 1, label: "Vaulted ceiling")
        }
        commit { $0.ceilings = ($0.ceilings ?? []) + [feature] }
        selected = feature.id; tab = 0
    }
    private func addPhoto(_ image: UIImage) {
        guard let data = PhotoFiles.jpeg(image) else { errorMessage = "Couldn’t read that photo."; return }
        let photo = PinnedPhoto(position: photoPoint ?? placePoint)
        do {
            try store.savePhoto(data, for: room, photo: photo)
            commit { $0.photos = ($0.photos ?? []) + [photo] }
            selected = photo.id; tab = 0
        } catch { errorMessage = error.localizedDescription }
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
    private func exportFile(_ kind: ExportService.Kind) {
        exporting = true
        Task { @MainActor in
            await Task.yield()
            defer { exporting = false }
            do { try deliver(try ExportService.files(room, kind, folder: store.directory(room.id), style: style)) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func sendPackage() {
        exporting = true
        Task { @MainActor in
            await Task.yield()
            defer { exporting = false }
            do { try store.save(room); try deliver([try store.package(room)]) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func export() {
        exporting = true
        Task { @MainActor in
            await Task.yield()
            defer { exporting = false }
            do { try store.save(room); try deliver(try ExportService.export(room, originals: store.directory(room.id), style: style)) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
