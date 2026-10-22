import SwiftUI
import UniformTypeIdentifiers

struct ProjectLibrary: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var navigation: AppNavigation
    @State private var scanning = false
    @State private var importing = false
    @State private var deleting: RoomProject?
    @State private var query = ""
    @State private var touring: RoomProject?          // the tour's sample room, open over the library
    @AppStorage("libraryGrouping") private var grouping = "none"
    // On the Mac the sidebar handles navigation and search: cards select the room instead of pushing it.
    var onOpen: ((UUID) -> Void)? = nil
    var onOpenBuilding: ((String) -> Void)? = nil
    private var filtered: [RoomProject] { store.projects.filter { RoomQuery.matches($0, query) } }
    // Rooms in sections: by client and project, by building, or all together.
    private var groups: [(title: String?, rooms: [RoomProject])] {
        switch grouping {
        case "project":
            let named = Dictionary(grouping: filtered) { $0.job?.groupName ?? "" }
            return named.keys.sorted { ($0.isEmpty ? "~" : $0).localizedStandardCompare($1.isEmpty ? "~" : $1) == .orderedAscending }
                .map { ($0.isEmpty ? "No project" : $0, named[$0]!) }
        case "building":
            let named = Dictionary(grouping: filtered) { $0.level.map { "\($0.building)" } ?? "" }
            return named.keys.sorted { ($0.isEmpty ? "~" : $0).localizedStandardCompare($1.isEmpty ? "~" : $1) == .orderedAscending }
                .map { key in (key.isEmpty ? "No building" : key, named[key]!.sorted { ($0.level?.floor ?? 0, $0.name) < ($1.level?.floor ?? 0, $1.name) }) }
        default: return [(nil, filtered)]
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        MensurMark(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mensur").font(.title2.bold())
                            Text("Scan a room, check it, share the plan.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                    VStack(alignment: .leading, spacing: 12) {
                        #if targetEnvironment(macCatalyst)
                        // The Mac has no LiDAR: rooms are scanned on the iPhone and sync here.
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Scan rooms with Mensur on your iPhone", systemImage: "iphone.gen3").font(.headline)
                                Text("Scans and edits sync to this Mac over Wi-Fi while Mensur is open on both.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { navigation.showSettings() } label: { Label(sync.peer == nil ? "Pair your iPhone" : "Sync settings", systemImage: "arrow.triangle.2.circlepath") }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        #else
                        Button { scanning = true } label: { Label("Scan a room", systemImage: "viewfinder").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }
                            .buttonStyle(.borderedProminent)
                        HStack { Label("LiDAR capture", systemImage: "camera.metering.matrix"); Spacer(); Label("Saved on this device", systemImage: "lock") }
                            .font(.caption).foregroundStyle(.secondary)
                        #endif
                        if sync.peer != nil {
                            Button { navigation.showSettings() } label: {
                                Label(sync.status, systemImage: sync.connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                    .font(.caption).foregroundStyle(sync.connected ? Color.green : Color.secondary).lineLimit(2)
                            }.buttonStyle(.plain)
                        }
                    }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    let buildings = BuildingPlan.buildings(store.projects)
                    if !buildings.isEmpty && query.isEmpty {
                        Text("Buildings").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(buildings) { building in
                                    let card = BuildingCard(building: building)
                                    if let onOpenBuilding { Button { onOpenBuilding(building.name) } label: { card }.buttonStyle(.plain) }
                                    else { NavigationLink { BuildingView(name: building.name) } label: { card }.buttonStyle(.plain) }
                                }
                            }
                        }
                    }
                    HStack {
                        Text("Your rooms").font(.title3.bold())
                        Spacer()
                        Menu {
                            Picker("Group", selection: $grouping) {
                                Text("All rooms").tag("none"); Text("By client and project").tag("project"); Text("By building").tag("building")
                            }
                        } label: { Label("Group", systemImage: "rectangle.3.group") }.menuStyle(.button).buttonStyle(.borderless)
                        Text("\(store.projects.count)").foregroundStyle(.secondary)
                    }
                    if store.projects.isEmpty {
                        ContentUnavailableView {
                            Label("Start with a space", systemImage: "square.dashed")
                        } description: {
                            Text("Scan with a LiDAR-equipped iPhone or iPad, or explore an editable sample room.")
                        } actions: { Button("Open sample room") { store.addDemo() }.buttonStyle(.bordered) }
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(groups, id: \.title) { group in
                        if let title = group.title { Text(title).font(.headline).foregroundStyle(.secondary).padding(.top, 4) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(group.rooms) { room in
                                Group {
                                    if let onOpen { Button { onOpen(room.id) } label: { ProjectCard(room: room) } }
                                    else { NavigationLink { RoomDetail(room: room) } label: { ProjectCard(room: room) } }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Delete room", role: .destructive) { deleting = room } }
                            }
                        }
                    }
                    Text("Mensur · Measured details, clear decisions.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical)
                }
                .padding(onOpen == nil ? 20 : 28).frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)          // the canvas colour fills the whole width, content stays centred
            }.background(Color.canvas)
                .navigationTitle(onOpen == nil ? "Rooms" : "All rooms").navigationBarTitleDisplayMode(.inline)
                .modifier(RoomSearch(enabled: onOpen == nil && !store.projects.isEmpty, query: $query))
                .onChange(of: store.projects.isEmpty) { _, empty in if empty { query = "" } }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Import room or project JSON", systemImage: "square.and.arrow.down") { importing = true }
                            Button("Add sample room", systemImage: "rectangle.3.group") { store.addDemo() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                // iPhone and iPad: the tour's sample room opens over the library.
                .onChange(of: navigation.tour) { _, id in
                    if onOpen == nil, let id, let room = store.projects.first(where: { $0.id == id }) { touring = room }
                }
                .fullScreenCover(item: $touring) { room in
                    NavigationStack {
                        RoomDetail(room: room).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { navigation.tour = nil; touring = nil } } }
                    }
                }
                .fullScreenCover(isPresented: $scanning) {
                    CaptureScreen { captured, reflective, measurements in Task { await store.addCaptured(captured, reflective: reflective, measurements: measurements) } }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.mensurRoom, .json]) { result in
                    do {
                        let url = try result.get()
                        if url.pathExtension.lowercased() == "mensur" { try store.importPackage(url) } else { try store.importProject(url) }
                    } catch { store.errorMessage = error.localizedDescription }
                }
                .alert("Mensur", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("OK") { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
                .confirmationDialog("Delete this room and its original scan?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Delete room", role: .destructive) {
                        if let room = deleting { do { try store.remove(room) } catch { store.errorMessage = error.localizedDescription } }
                        deleting = nil
                    }
                }
                .overlay {
                    if store.busy {
                        ZStack { Color.black.opacity(0.15).ignoresSafeArea(); ProgressView("Saving your room…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) }
                    }
                }
        }
    }
}

/// Search appears only once there are rooms; on iOS 26+ the floating search field would otherwise cover the empty-state actions.
private struct RoomSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $query, prompt: "Find a room, address, client or tag") } else { content }
    }
}

struct ProjectCard: View {
    let room: RoomProject
    var body: some View {
        let summary = RoomSummary(room)
        VStack(alignment: .leading, spacing: 0) {
            InteractivePlan(room: room, dimensions: false, selected: .constant(nil)).frame(height: 180).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(room.name).font(.headline).lineLimit(1); Spacer()
                    if room.isDemo { Text("SAMPLE").font(.caption2.bold()).foregroundStyle(.tint).padding(.horizontal, 7).padding(.vertical, 3).background(.tint.opacity(0.1), in: Capsule()) }
                }
                HStack(spacing: 6) {
                    Text(summary.totalArea.map { room.units.areaLabel($0) } ?? "Area needs review").fontWeight(.semibold).foregroundStyle(.primary)
                    if summary.spaces.count > 1 { Text("· \(summary.spaces.count) spaces") }
                    Text("· \(room.walls.count) walls")
                }.font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                if let job = room.job, let line = [job.groupName, job.number.isEmpty ? nil : "Job \(job.number)"].compactMap({ $0 }).joined(separator: " · ") as String?, !line.isEmpty {
                    Label(line, systemImage: "briefcase").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let level = room.level { Label("\(level.building) · \(level.displayName)", systemImage: "building.2").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                // Every card keeps the address line, so cards in a row line up.
                Label(room.address?.replacingOccurrences(of: "\n", with: ", ") ?? "No address", systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(room.address == nil ? .tertiary : .secondary).lineLimit(1)
                Text(room.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension Color {
    static let brandBlue = Color(uiColor: BrandMark.blue)
    static let canvas = Color(red: 0.961, green: 0.965, blue: 0.973)   // #F5F6F8
}

// The app icon's mark, drawn by the same code as the PDF title block.
struct MensurMark: View {
    var size: CGFloat
    var body: some View {
        Canvas { context, canvas in
            context.withCGContext { BrandMark.draw(in: CGRect(origin: .zero, size: canvas), context: $0) }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

// Search across a room's name, address, job details, tags and building.
enum RoomQuery {
    static func matches(_ room: RoomProject, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let fields = [room.name, room.address ?? "", room.job?.client ?? "", room.job?.project ?? "", room.job?.number ?? "",
                      room.level?.building ?? "", room.level?.displayName ?? ""] + (room.job?.tags ?? [])
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

struct BuildingCard: View {
    let building: BuildingPlan.Building
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "building.2").font(.title2).foregroundStyle(.tint)
            Text(building.name).font(.headline).lineLimit(1)
            Text("\(building.floors.count) floor\(building.floors.count == 1 ? "" : "s") · \(building.floors.reduce(0) { $0 + $1.rooms.count }) rooms")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 220, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
