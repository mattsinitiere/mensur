import SwiftUI
import UIKit

// Preferences for this device. They don't sync: each device keeps its own.
enum Setting {
    static let units = "defaultUnits", pdfPortrait = "pdfPortrait", squareCorners = "autoSquareCorners"
    static let hideStubs = "autoHideStubs", dimensions = "planDimensions", furniture = "planFurniture"
    static let accent = "accentColor", monochrome = "planMonochrome", autoAddress = "autoAddress"
    static let invertScrollZoom = "invertScrollZoom"
    static var defaultUnits: DisplayUnits { UserDefaults.standard.string(forKey: units).flatMap(DisplayUnits.init(rawValue:)) ?? .imperial }
    static func bool(_ key: String, default value: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? value }
    static var monochromePlans: Bool { bool(monochrome, default: false) }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, teal, green, orange, graphite
    var id: String { rawValue }
    var title: String { self == .blue ? "Mensur blue" : rawValue.capitalized }
    var color: Color {
        switch self {
        case .blue: return .brandBlue
        case .teal: return Color(red: 0.06, green: 0.46, blue: 0.43)
        case .green: return Color(red: 0.18, green: 0.49, blue: 0.20)
        case .orange: return Color(red: 0.76, green: 0.25, blue: 0.05)
        case .graphite: return Color(red: 0.22, green: 0.25, blue: 0.32)
        }
    }
    // Menus redraw SF Symbols in one tint, so the swatch is a pre-coloured image that keeps its colour.
    var swatch: Image {
        let size = CGSize(width: 16, height: 16), fill = UIColor(color)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            fill.setFill(); UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }
}

// Which top-level tab is showing, so other screens can send the user to Settings.
final class AppNavigation: ObservableObject {
    enum Tab: Hashable { case rooms, settings }
    // The Mac's sidebar selection.
    enum MacItem: Hashable { case overview, room(UUID), settings }
    @Published var tab = Tab.rooms
    @Published var macItem: MacItem? = .overview
    func showSettings() { tab = .settings; macItem = .settings }
}

struct SettingsView: View {
    @EnvironmentObject private var store: ProjectStore
    @AppStorage(Setting.units) private var units = DisplayUnits.imperial.rawValue
    @AppStorage(Setting.pdfPortrait) private var pdfPortrait = false
    @AppStorage(Setting.squareCorners) private var squareCorners = true
    @AppStorage(Setting.hideStubs) private var hideStubs = false
    @AppStorage(Setting.dimensions) private var dimensions = true
    @AppStorage(Setting.furniture) private var furniture = true
    @AppStorage(Setting.accent) private var accent = AccentChoice.blue.rawValue
    @AppStorage(Setting.monochrome) private var monochrome = false
    @AppStorage(Setting.autoAddress) private var autoAddress = true
    @AppStorage(Setting.invertScrollZoom) private var invertScrollZoom = false
    var body: some View {
        NavigationStack {
            Form {
                SyncSettings()
                Section {
                    Picker("Units for new rooms", selection: $units) {
                        Text("Feet and inches").tag(DisplayUnits.imperial.rawValue)
                        Text("Meters").tag(DisplayUnits.metric.rawValue)
                    }
                    Picker("PDF sheet layout", selection: $pdfPortrait) {
                        Label("Landscape", systemImage: "rectangle").tag(false)
                        Label("Portrait", systemImage: "rectangle.portrait").tag(true)
                    }
                    Toggle("Show dimensions on plans", isOn: $dimensions)
                    Toggle("Show furniture on plans", isOn: $furniture)
                } header: { Text("Defaults") } footer: {
                    Text("Each room can still switch units from its ⋯ menu. The PDF button exports in this layout; hold it (or right-click on Mac) for the other.")
                }
                #if targetEnvironment(macCatalyst)
                Section {
                    Toggle("Reverse scroll zoom", isOn: $invertScrollZoom)
                } header: { Text("Plan and 3D view") } footer: {
                    Text("Scroll up to zoom in and down to zoom out, around the pointer on the plan; scroll left and right to move. Drag to move the plan or rotate the 3D model. Turn this on if zoom goes the wrong way with your mouse or trackpad.")
                }
                #else
                Section {
                    Toggle("Square rounded corners", isOn: $squareCorners)
                    Toggle("Hide short wall stubs", isOn: $hideStubs)
                    Toggle("Fill in the address from my location", isOn: $autoAddress)
                } header: { Text("After each scan") } footer: {
                    Text("Corners and stubs can be undone per room in Review. The address can be changed any time in Room details; looking it up sends only your coordinates to Apple, and you’ll be asked for location access the first time.")
                }
                #endif
                Section {
                    Picker("Accent colour", selection: $accent) {
                        ForEach(AccentChoice.allCases) { choice in
                            Label { Text(choice.title) } icon: { choice.swatch }.tag(choice.rawValue)
                        }
                    }
                    Toggle("Black-and-white plans", isOn: $monochrome)
                } header: { Text("Appearance") } footer: {
                    Text("Black-and-white plans print clearly on any printer: windows and mirrors are double lines, doors and openings are dashed, and every opening keeps its tag on the PDF sheet.")
                }
                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    LabeledContent("Rooms", value: "\(store.projects.count)")
                    #if targetEnvironment(macCatalyst)
                    LabeledContent("Rooms folder", value: "Documents › Mensur")
                    Button("Show rooms folder in Finder", systemImage: "folder") { UIApplication.shared.open(AppPaths.documents) }
                    LabeledContent("PDF exports", value: "Downloads")
                    #else
                    LabeledContent("Rooms folder", value: "Files › On My iPhone › Mensur")
                    #endif
                }
            }
            #if targetEnvironment(macCatalyst)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)     // readable line length in a wide window
            .background(Color(uiColor: .systemGroupedBackground))
            #endif
            .navigationTitle("Settings")
        }
    }
}
