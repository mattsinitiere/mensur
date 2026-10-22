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
    // On the Mac the sidebar handles navigation and search: cards select the room instead of pushing it.
    var onOpen: ((UUID) -> Void)? = nil
    private var filtered: [RoomProject] {
        query.isEmpty ? store.projects : store.projects.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.address ?? "").localizedCaseInsensitiveContains(query) }
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
                    HStack {
                        Text("Your rooms").font(.title3.bold())
                        Spacer(); Text("\(store.projects.count)").foregroundStyle(.secondary)
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(filtered) { room in
                            Group {
                                if let onOpen { Button { onOpen(room.id) } label: { ProjectCard(room: room) } }
                                else { NavigationLink { RoomDetail(room: room) } label: { ProjectCard(room: room) } }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Delete room", role: .destructive) { deleting = room } }
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
                            Button("Import project JSON", systemImage: "square.and.arrow.down") { importing = true }
                            Button("Add sample room", systemImage: "rectangle.3.group") { store.addDemo() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .fullScreenCover(isPresented: $scanning) {
                    CaptureScreen { captured, reflective, measurements in Task { await store.addCaptured(captured, reflective: reflective, measurements: measurements) } }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do { try store.importProject(result.get()) } catch { store.errorMessage = error.localizedDescription }
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
        if enabled { content.searchable(text: $query, prompt: "Find a room or address") } else { content }
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
