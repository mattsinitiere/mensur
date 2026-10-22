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
            .environmentObject(store).environmentObject(sync).environmentObject(navigation)
            .tint((AccentChoice(rawValue: accent) ?? .blue).color)
                .onAppear {
                    sync.attach(store); sync.setActive(phase != .background)
                    #if DEBUG
                    WindowSnapshots.startIfRequested()
                    #endif
                }
                .onChange(of: phase) { _, now in sync.setActive(now != .background) }
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
