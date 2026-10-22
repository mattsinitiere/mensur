import SwiftUI

// The Mac window: a sidebar of rooms and Settings, with the selected room filling the rest of the window.
struct MacRootView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var navigation: AppNavigation
    @State private var query = ""
    @State private var deleting: RoomProject?
    private var filtered: [RoomProject] {
        query.isEmpty ? store.projects : store.projects.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.address ?? "").localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.macItem) {
                Label("All rooms", systemImage: "square.grid.2x2").tag(AppNavigation.MacItem.overview)
                Section("Rooms") {
                    ForEach(filtered) { room in
                        RoomRow(room: room).tag(AppNavigation.MacItem.room(room.id))
                            .contextMenu { Button("Delete room", role: .destructive) { deleting = room } }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Find a room or address")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
            // Settings and sync status stay pinned below the list, however many rooms there are.
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Button { navigation.macItem = .settings } label: {
                        Label("Settings", systemImage: "gearshape")
                            .foregroundStyle(navigation.macItem == .settings ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(navigation.macItem == .settings ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
                    Button { navigation.macItem = .settings } label: {
                        Label(sync.peer == nil ? "iPhone not paired" : sync.status, systemImage: sync.connected ? "checkmark.circle.fill" : "iphone.gen3")
                            .font(.caption).foregroundStyle(sync.connected ? Color.green : Color.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 8)
                }
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        } detail: {
            switch navigation.macItem {
            case .room(let id):
                if let room = store.projects.first(where: { $0.id == id }) {
                    NavigationStack { RoomDetail(room: room) }.id(id)
                } else {
                    ContentUnavailableView("Room not available", systemImage: "square.dashed", description: Text("It may have been deleted on your iPhone."))
                }
            case .settings: SettingsView()
            default: ProjectLibrary(onOpen: { navigation.macItem = .room($0) })
            }
        }
        #if DEBUG
        // Developer aid for layout snapshots: MENSUR_OPEN=settings, or the index of a room to open.
        .onAppear {
            guard let open = ProcessInfo.processInfo.environment["MENSUR_OPEN"] else { return }
            if open == "settings" { navigation.macItem = .settings }
            else if let i = Int(open), store.projects.indices.contains(i) { navigation.macItem = .room(store.projects[i].id) }
        }
        #endif
        .onChange(of: store.projects.map(\.id)) { _, ids in
            if case .room(let id) = navigation.macItem, !ids.contains(id) { navigation.macItem = .overview }
        }
        .confirmationDialog("Delete this room and its original scan?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete room", role: .destructive) {
                if let room = deleting { do { try store.remove(room) } catch { store.errorMessage = error.localizedDescription } }
                deleting = nil
            }
        }
        .alert("Mensur", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private struct RoomRow: View {
    let room: RoomProject
    var body: some View {
        let summary = RoomSummary(room)
        VStack(alignment: .leading, spacing: 2) {
            Text(room.name).lineLimit(1)
            Text([summary.totalArea.map { room.units.areaLabel($0) }, "\(room.walls.count) walls"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
