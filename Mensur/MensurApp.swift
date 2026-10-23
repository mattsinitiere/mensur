import SwiftUI
import MetricKit

@main struct MensurApp: App {
    @StateObject private var store = ProjectStore()
    @StateObject private var sync = SyncService()
    @StateObject private var navigation = AppNavigation()
    @AppStorage(Setting.accent) private var accent = AccentChoice.blue.rawValue
    @Environment(\.scenePhase) private var phase
    init() { DiagnosticsRecorder.shared.start() }
    var body: some Scene {
        WindowGroup {
            Group {
                #if targetEnvironment(macCatalyst)
                MacRootView()
                    .onAppear {
                        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                            scene.sizeRestrictions?.minimumSize = CGSize(width: 1000, height: 680)
                        }
                    }
                #else
                TabView(selection: $navigation.tab) {
                    ProjectLibrary().tabItem { Label("Rooms", systemImage: "square.grid.2x2") }.tag(AppNavigation.Tab.rooms)
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppNavigation.Tab.settings)
                }
                #endif
            }
            // First launch, or Settings → Help: the welcome pages and the tour.
            .sheet(isPresented: $navigation.showWelcome) { WelcomeView() }
            .onAppear { if !UserDefaults.standard.bool(forKey: Setting.onboardingSeen) && store.projects.isEmpty { navigation.showWelcome = true } }
            .environmentObject(store).environmentObject(sync).environmentObject(navigation)
            .tint((AccentChoice(rawValue: accent) ?? .blue).color)
                .onAppear {
                    sync.attach(store); sync.setActive(phase != .background)
                    #if DEBUG
                    WindowSnapshots.startIfRequested()
                    ExportCheck.runIfRequested(store)
                    #endif
                }
                .onChange(of: phase) { _, now in sync.setActive(now != .background) }
                // A room sent from another device (AirDrop, Messages, Files, or a .mensur file opened in Finder).
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "mensur" else { return }
                    do {
                        let room = try store.importPackage(url)
                        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
                        navigation.macItem = .room(room.id); navigation.tab = .rooms
                    } catch { store.errorMessage = error.localizedDescription }
                }
        }
    }
}

// Crash and hang reports from MetricKit, kept on the device only in Documents/Diagnostics so a problem can
// be read back over USB or from the Files app. Nothing is sent anywhere.
final class DiagnosticsRecorder: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsRecorder()
    func start() { MXMetricManager.shared.add(self) }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let dir = AppPaths.documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        for payload in payloads {
            let stamp = formatter.string(from: payload.timeStampEnd).replacingOccurrences(of: ":", with: "-")
            try? payload.jsonRepresentation().write(to: dir.appendingPathComponent("diagnostic-\(stamp).json"), options: .atomic)
        }
    }
}

#if DEBUG
// Developer aid: with MENSUR_EXPORT=/some/folder the app writes every export of every room there once at launch
// (PDF set, sheet, SVG, PNG, DXF, IFC, DAE, OBJ, package), so exports can be checked without clicking through.
enum ExportCheck {
    @MainActor static func runIfRequested(_ store: ProjectStore) {
        guard let folder = ProcessInfo.processInfo.environment["MENSUR_EXPORT"] else { return }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        for room in store.projects {
            let dir = root.appendingPathComponent(room.id.uuidString.prefix(8) + " " + room.name.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var files: [URL] = []
            for kind in [ExportService.Kind.pdfSet, .svg, .png, .dxf, .ifc, .dae, .obj] {
                files += (try? ExportService.files(room, kind, folder: store.directory(room.id), style: .chained)) ?? []
            }
            if let sheet = try? ExportService.sheet(room, portrait: false) { files.append(sheet) }
            if let package = try? store.package(room) { files.append(package) }
            for file in files { try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent)) }
        }
        try? Data("done".utf8).write(to: root.appendingPathComponent("DONE"))
    }
}

// Developer aid: with MENSUR_SNAPSHOTS=/some/folder the app saves an image of each of its windows there
// every two seconds, so layout can be reviewed without screen-recording permission.
enum WindowSnapshots {
    static func startIfRequested() {
        guard let folder = ProcessInfo.processInfo.environment["MENSUR_SNAPSHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            for (i, window) in windows.enumerated() where !window.isHidden && window.bounds.width > 0 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try? image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("window\(i).png"))
            }
        }
    }
}
#endif
