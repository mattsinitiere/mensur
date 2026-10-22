import SwiftUI

// A building: its floors one at a time (with the floor below as a faint ghost, to check they line up), the
// whole building stacked in 3D, its rooms by floor, and exports for the whole building.
struct BuildingView: View {
    @EnvironmentObject private var store: ProjectStore
    let name: String
    var onOpen: ((UUID) -> Void)? = nil            // the Mac selects the room in its sidebar instead of pushing it
    @State private var floorIndex = 0
    @State private var show3D = false
    @State private var message: String?
    @State private var sharing: ShareFiles?
    @State private var savedFile: URL?
    @State private var errorMessage: String?
    private var building: BuildingPlan.Building? { BuildingPlan.buildings(store.projects).first { $0.name == name } }

    var body: some View {
        Group {
            if let building, !building.floors.isEmpty {
                let floors = building.floors, index = min(floorIndex, floors.count - 1), floor = floors[index]
                let plan = BuildingPlan.composite(floor, building: name)
                let ghost = index > 0 ? BuildingPlan.composite(floors[index - 1], building: name) : nil
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            stat("Floors", "\(floors.count)")
                            stat("Rooms", "\(floors.reduce(0) { $0 + $1.rooms.count })")
                            stat("Floor area", plan.units.areaLabel(floors.reduce(0.0) { $0 + Takeoff(BuildingPlan.composite($1, building: name)).floorArea }))
                        }
                        HStack {
                            Picker("Floor", selection: $floorIndex) { ForEach(floors.indices, id: \.self) { Text(floors[$0].name).tag($0) } }
                                .pickerStyle(.menu)
                            Spacer()
                            Picker("View", selection: $show3D) { Text("Plan").tag(false); Text("3D").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 200)
                        }
                        Group {
                            if show3D { ModelPreview(room: plan, showObjects: true, resetKey: 0, parts: BuildingPlan.parts(building)) }
                            else { FloorCanvas(plan: plan, ghost: ghost) }
                        }
                        .frame(height: 440).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(0.06)))
                        if !show3D && ghost != nil {
                            Text("The faint plan is \(floors[index - 1].name). Line floors up by their stairs, or set each room’s floor and placement in its details.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Line up floors by their stairs", systemImage: "stairs") { align() }.buttonStyle(.bordered)
                            Spacer()
                            Menu {
                                Button("PDF · one sheet per floor", systemImage: "doc.on.doc") { export(.pdf) }
                                Button("IFC · Revit, ArchiCAD", systemImage: "building.2") { export(.ifc) }
                                Button("DAE · SketchUp", systemImage: "cube") { export(.dae) }
                            } label: { Label("Export building", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                        }
                        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(floors) { f in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(f.name).font(.headline)
                                ForEach(f.rooms) { room in roomRow(room) }
                            }
                            .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("No rooms in \(name)", systemImage: "building.2", description: Text("Set a room’s building in its details to add it here."))
            }
        }
        .background(Color.canvas)
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { ActivitySheet(urls: $0.urls) }
        .alert("Saved to Downloads", isPresented: Binding(get: { savedFile != nil }, set: { if !$0 { savedFile = nil } })) {
            Button("Show in Finder") { if let url = savedFile { UIApplication.shared.open(url.deletingLastPathComponent()) }; savedFile = nil }
            Button("OK", role: .cancel) { savedFile = nil }
        } message: { Text(savedFile?.lastPathComponent ?? "") }
        .alert("Couldn’t export", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
    @ViewBuilder private func roomRow(_ room: RoomProject) -> some View {
        let label = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).foregroundStyle(.primary)
                Text(RoomSummary(room).totalArea.map { room.units.areaLabel($0) } ?? "Area needs review").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
        if let onOpen { Button { onOpen(room.id) } label: { label }.buttonStyle(.plain) }
        else { NavigationLink { RoomDetail(room: room) } label: { label }.buttonStyle(.plain) }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func align() {
        let rooms = store.projects.filter { $0.level?.building == name }
        let moved = BuildingPlan.alignByStairs(rooms)
        do {
            for var room in moved { room.updatedAt = Date(); try store.save(room) }
            message = moved.isEmpty
                ? "Nothing to line up. Add a stair on each floor (+ → Stair), set the floor it connects to in the stair’s details, then try again."
                : "\(moved.count) room\(moved.count == 1 ? "" : "s") placed over the floor below by their stairs."
        } catch { errorMessage = error.localizedDescription }
    }
    private enum Format { case pdf, ifc, dae }
    private func export(_ format: Format) {
        guard let building else { return }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mensur-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            let url: URL
            switch format {
            case .pdf:
                url = dir.appendingPathComponent("\(safe) – Floor plans.pdf")
                let data = UIGraphicsPDFRenderer(bounds: PDFPlan.landscape).pdfData { pdf in
                    for floor in building.floors {
                        pdf.beginPage(); PDFPlan.drawSheet(BuildingPlan.composite(floor, building: name), page: PDFPlan.landscape, context: pdf.cgContext)
                    }
                }
                try data.write(to: url, options: .atomic)
            case .ifc:
                url = dir.appendingPathComponent("\(safe).ifc")
                let storeys = building.floors.map { floor in
                    IFCExporter.Storey(name: floor.name, elevation: floor.rooms.compactMap(\.level?.elevation).first ?? Double(floor.floor) * 3.0,
                                       rooms: floor.rooms.map { room in (room, { (p: PlanPoint) in room.level!.place(p) }) })
                }
                try Data(IFCExporter.text(project: name, building: name, storeys: storeys).utf8).write(to: url, options: .atomic)
            case .dae:
                url = dir.appendingPathComponent("\(safe).dae")
                try Data(ColladaExporter.text(BuildingPlan.parts(building), title: name).utf8).write(to: url, options: .atomic)
            }
            #if targetEnvironment(macCatalyst)
            savedFile = try ExportService.saveToDownloads([url], folderName: name)
            #else
            sharing = ShareFiles(urls: [url])
            #endif
        } catch { errorMessage = error.localizedDescription }
    }
}

// A floor's plan with the floor below drawn faintly underneath.
private struct FloorCanvas: View {
    let plan: RoomProject
    let ghost: RoomProject?
    var body: some View {
        Canvas { context, size in
            context.withCGContext { c in
                // Plan labels draw with UIKit text, which needs this context to be the current one.
                UIGraphicsPushContext(c); defer { UIGraphicsPopContext() }
                let rect = CGRect(origin: .zero, size: size)
                c.setFillColor(UIColor.white.cgColor); c.fill(rect)
                var both = plan; if let ghost { both.surfaces += ghost.surfaces }
                let fit = PlanDrawing.projection(both, in: rect.insetBy(dx: 30, dy: 30))
                let projection = PlanProjection(scale: fit.scale, center: fit.center, viewport: rect, rotation: fit.rotation)
                if let ghost {
                    c.saveGState(); c.setAlpha(0.2)
                    PlanDrawing.draw(ghost, context: c, projection: projection, dimensions: false, furniture: false, grid: false, annotations: false)
                    c.restoreGState()
                }
                PlanDrawing.draw(plan, context: c, projection: projection, dimensions: false, furniture: true, grid: ghost == nil, areas: true)
            }
        }
        .accessibilityLabel("Floor plan of this floor")
    }
}
