import SwiftUI
import PhotosUI
import Combine

// First launch: four short pages, then an optional 30-second tour of a sample office.
struct WelcomeView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var navigation: AppNavigation
    @AppStorage(Setting.onboardingSeen) private var seen = false
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    private struct Page { var symbol: String; var title: String; var text: String }
    private let pages = [
        Page(symbol: "viewfinder", title: "Measure a room in minutes",
             text: "Walk around with a LiDAR iPhone. Mensur builds the plan as you go, coaches you to the walls it hasn’t seen up close, and can carry on to the next room or floor."),
        Page(symbol: "checkmark.seal", title: "Check it before you trust it",
             text: "Every wall is checked against the LiDAR. The health check finds gaps and odd corners, reveal mode measures wall thickness at doors and windows, and the scan report says how far tracking drifted."),
        Page(symbol: "doc.on.doc", title: "Drawings people can use",
             text: "Thick hatched walls, door swings, dimension strings, finishes and markers. Export a PDF set with elevations and schedules, DXF for AutoCAD, IFC for Revit, or a SketchUp model."),
        Page(symbol: "play.rectangle", title: "Take the 30-second tour",
             text: "Open a sample office to see what a finished plan carries. You can delete it afterwards.")
    ]
    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 18) {
                        if i == 0 { MensurMark(size: 84) } else { Image(systemName: pages[i].symbol).font(.system(size: 56, weight: .light)).foregroundStyle(.tint) }
                        Text(pages[i].title).font(.title.bold()).multilineTextAlignment(.center)
                        Text(pages[i].text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    }
                    .padding(.horizontal, 28).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            VStack(spacing: 10) {
                if page == pages.count - 1 {
                    Button { startTour() } label: { Text("Start the tour").font(.headline).frame(maxWidth: 360).padding(.vertical, 6) }.buttonStyle(.borderedProminent)
                    Button("Skip") { seen = true; dismiss() }
                } else {
                    Button { withAnimation { page += 1 } } label: { Text("Continue").font(.headline).frame(maxWidth: 360).padding(.vertical, 6) }.buttonStyle(.borderedProminent)
                    Button("Skip") { seen = true; dismiss() }
                }
            }
            .padding(.bottom, 28)
        }
        .background(Color.canvas.ignoresSafeArea())
    }
    private func startTour() {
        seen = true
        var room = RoomProject.showcase(); room.units = Setting.defaultUnits
        do { try store.save(room); navigation.tour = room.id; navigation.macItem = .room(room.id); navigation.tab = .rooms } catch { store.errorMessage = error.localizedDescription }
        dismiss()
    }
}

// The tour: one tip at a time over the sample room, moving on every six seconds (about 30 seconds in all),
// or sooner with Next.
struct TourCard: View {
    let onStep: (Int) -> Void
    let onEnd: () -> Void
    @State private var step = 0
    @State private var timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    static let steps: [(String, String)] = [
        ("square.split.2x1", "Walls are drawn at their real thickness and hatched by construction; the doors show their swing and the window its panes."),
        ("hand.tap", "Tap a wall, door, marker or piece of furniture to select it. Drag it to move it; Edit sets its type, size and details."),
        ("list.bullet.rectangle", "Elements lists the spaces with their finishes, the quantities for flooring, paint and baseboard, and every marker."),
        ("checkmark.seal", "Review runs the health check: gaps, loose wall ends, odd corners. After a real scan it also says how far tracking drifted."),
        ("square.and.arrow.up", "Export gives a PDF set with elevations and schedules, DXF, IFC for Revit, SketchUp, or the whole room to send by AirDrop.")
    ]
    var body: some View {
        let (symbol, text) = Self.steps[step]
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text("Tour · \(step + 1) of \(Self.steps.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("End tour") { onEnd() }.font(.subheadline)
                    Spacer()
                    Button(step == Self.steps.count - 1 ? "Done" : "Next") { advance() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(16).frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onReceive(timer) { _ in advance() }
        .onAppear { onStep(0) }
    }
    private func advance() {
        if step == Self.steps.count - 1 { timer.upstream.connect().cancel(); onEnd(); return }
        step += 1; onStep(step)
    }
}

// Settings → Title block: your company on PDF sheets, PNG plans and the plan set.
struct TitleBlockSettings: View {
    @AppStorage(Setting.companyName) private var company = ""
    @AppStorage(Setting.companyContact) private var contact = ""
    @State private var pick: PhotosPickerItem?
    @State private var hasLogo = Branding.logo != nil
    @State private var errorMessage: String?
    var body: some View {
        Section {
            TextField("Company name", text: $company)
            TextField("Phone, email or website", text: $contact)
            HStack {
                if let logo = Branding.logo, hasLogo { Image(uiImage: logo).resizable().scaledToFit().frame(width: 44, height: 44) }
                PhotosPicker(selection: $pick, matching: .images) { Label(hasLogo ? "Change logo" : "Add logo", systemImage: "photo") }
                if hasLogo { Spacer(); Button("Remove", role: .destructive) { try? Branding.setLogo(nil); hasLogo = false } }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        } header: { Text("Title block") } footer: {
            Text("Shown on the PDF sheet, the plan set and PNG plans instead of the Mensur mark. Kept on this device.")
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    do { try Branding.setLogo(image); hasLogo = true; errorMessage = nil } catch { errorMessage = error.localizedDescription }
                }
                pick = nil
            }
        }
    }
}
