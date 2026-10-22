import SwiftUI
import RoomPlan
import ARKit
import AVFoundation
import SceneKit
import os

struct CaptureScreen: View {
    let onCaptured: (CapturedRoom, Bool, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var reflective = false
    var body: some View {
        if started {
            RoomCaptureHost(onComplete: { room, measurements in onCaptured(room, reflective, measurements); dismiss() }, onCancel: { dismiss() })
                .ignoresSafeArea()
        } else {
            NavigationStack {
                Form {
                    Section {
                        Label("Capture a room", systemImage: "viewfinder").font(.title2.bold())
                        Text("Walk slowly around the space. Capture every wall, each corner, and the frames around doors and windows. Outlines appear as surfaces are found, and a live plan builds in the corner.")
                    }
                    Section("Before you begin") {
                        Text("Turn on lights. Open curtains and raise blinds where you can: RoomPlan finds windows by their frame and glass, so a covered window may read as wall. You can add missed windows afterwards from the plan. Keep people out of view. Large spaces can take up to 10 minutes.")
                        Toggle("This room has mirrors or large glass surfaces", isOn: $reflective)
                        if reflective {
                            Text("Scan the solid frame and surrounding wall from several angles. Reflections can create phantom geometry. After capture, mark mirrors, check windows, and enter laser or tape measurements.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text("A scan produces a simplified architectural model. Fine textures, unseen surfaces, wall thickness, and door swing directions are not measured by this app.")
                        Button("Start scanning") { LocationAddress.shared.prefetch(); started = true }.buttonStyle(.borderedProminent)
                            .disabled(!RoomCaptureSession.isSupported)
                        if !RoomCaptureSession.isSupported {
                            Text("Scanning needs a LiDAR-equipped iPhone or iPad. You can explore the sample project on this device.").foregroundStyle(.orange)
                        }
                    }
                }
                .navigationTitle("New scan")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }
}

struct RoomCaptureHost: UIViewControllerRepresentable {
    let onComplete: (CapturedRoom, URL?) -> Void
    let onCancel: () -> Void
    func makeUIViewController(context: Context) -> CaptureController {
        let controller = CaptureController()
        controller.onComplete = onComplete; controller.onCancel = onCancel
        return controller
    }
    func updateUIViewController(_ uiViewController: CaptureController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: CaptureController, coordinator: ()) { uiViewController.cancelSession() }
}

// Mensur's own capture screen on a RoomCaptureSession: the camera feed with colour-coded outlines of every
// surface RoomPlan has found, coaching text, and a live top-down plan. RoomBuilder turns the captured data
// into the final CapturedRoom once scanning stops.
final class CaptureController: UIViewController, RoomCaptureSessionDelegate {
    var onComplete: ((CapturedRoom, URL?) -> Void)?
    private var recorder: ScanRecorder?
    private var recorderTimer: Timer?
    var onCancel: (() -> Void)?
    static let warnAfter = 300.0, stopAfter = 600.0
    // RoomPlan runs on an AR session the app owns, so the app can ask it for LiDAR depth and the labelled
    // scene mesh, which correct walls, find openings RoomPlan missed and measure the ceiling.
    private let arSession = ARSession()
    private lazy var session = RoomCaptureSession(arSession: arSession)
    private let log = Logger(subsystem: "com.matthewsinitiere.Mensur", category: "capture")
    // Wall coverage: for each wall, which half-metre strips have been seen from within 3.5 m, fairly
    // head-on, with LiDAR depth confirming the wall was really in view. Close views help RoomPlan place
    // walls, windows and doors, and give the LiDAR wall correction something to work with.
    private var latestRoom: CapturedRoom?
    private var wallStrips: [UUID: [Bool]] = [:]
    private var askedAboutCoverage = false
    static let stripLength: Float = 0.5, closeEnough: Float = 3.5
    private let sceneView = ARSCNView(frame: .zero)
    private let outlines = SCNNode()
    private var outlineNodes: [UUID: SCNNode] = [:]
    private var outlineSizes: [UUID: simd_float3] = [:]
    private let miniPlan = MiniPlanView()
    private let status = UILabel()
    private let finish = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var timer: Timer?
    private var timeout: Timer?
    private var startDate = Date()
    private var guidance = "Scan every wall and corner"
    private var lastOutlineUpdate = Date.distantPast, lastPlanUpdate = Date.distantPast
    private var running = false
    private var scanning = false
    private var processing = false
    private var completed = false
    private var requestedCamera = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        session.delegate = self
        sceneView.session = arSession
        sceneView.automaticallyUpdatesLighting = false
        sceneView.scene.rootNode.addChildNode(outlines)
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor), sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor), sceneView.topAnchor.constraint(equalTo: view.topAnchor), sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        bar.translatesAutoresizingMaskIntoConstraints = false; bar.layer.cornerRadius = 18; bar.clipsToBounds = true
        view.addSubview(bar)
        status.text = "Preparing camera…"; status.numberOfLines = 2; status.font = .preferredFont(forTextStyle: .caption1)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancel.setTitle("Cancel", for: .normal); cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        finish.setTitle("Finish scan", for: .normal); finish.addTarget(self, action: #selector(finishButton), for: .touchUpInside); finish.isEnabled = false
        let stack = UIStackView(arrangedSubviews: [cancel, status, spinner, finish]); stack.spacing = 12; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; bar.contentView.addSubview(stack)
        miniPlan.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(miniPlan)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12), bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -12),
                                     miniPlan.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), miniPlan.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12), miniPlan.widthAnchor.constraint(equalToConstant: 150), miniPlan.heightAnchor.constraint(equalToConstant: 150)])
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Permission failures need a visible controller to present their alert.
        guard !requestedCamera, !completed else { return }
        requestedCamera = true
        requestCamera()
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Finishing keeps everything captured so far instead of risking the whole scan.
        guard scanning else { return }
        guidance = "Memory is low · saving what you’ve scanned"; finishScan()
    }
    private func requestCamera() {
        guard RoomCaptureSession.isSupported else { fail("This device does not support RoomPlan capture."); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startScan()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { if allowed { self?.startScan() } else { self?.fail("Camera access is needed. Enable it in Settings → Mensur.") } }
            }
        default: fail("Camera access is disabled. Enable it in Settings → Mensur.")
        }
    }
    private func startScan() {
        guard !completed else { return }
        scanning = true; running = true; startDate = Date(); finish.isEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        session.run(configuration: RoomCaptureSession.Configuration())
        if let r = ScanRecorder() {
            recorder = r
            // Window close-ups a few times a second; cheap, and only for windows in good view.
            recorderTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, self.scanning, let frame = self.arSession.currentFrame else { return }
                self.recorder?.consider(frame, session: self.arSession, windows: self.latestRoom?.windows ?? [])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestDepth() }
        }
        status.text = guidance
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }
    // RoomPlan picks its own ARKit configuration. Ask it to add LiDAR depth (for the coverage guide) and the
    // labelled scene mesh (wall, window, door, floor, ceiling). Whether RoomPlan keeps them shows in
    // probe-depth.json.
    private func requestDepth() {
        guard scanning, let config = arSession.configuration as? ARWorldTrackingConfiguration else {
            log.notice("depth request skipped: configuration \(String(describing: self.arSession.configuration), privacy: .public)"); return
        }
        var changed = false
        if type(of: config).supportsFrameSemantics(.sceneDepth), !config.frameSemantics.contains(.sceneDepth) { config.frameSemantics.insert(.sceneDepth); changed = true }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification), !config.sceneReconstruction.contains(.meshWithClassification) {
            config.sceneReconstruction.insert(.meshWithClassification); changed = true
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh), !config.sceneReconstruction.contains(.mesh) { config.sceneReconstruction.insert(.mesh); changed = true }
        log.notice("depth request: \(String(describing: type(of: config)), privacy: .public) changed \(changed)")
        if changed { arSession.run(config) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recorder?.reprobe("probe-depth.json") }
    }
    private func tick() {
        guard scanning else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        if elapsed >= Self.stopAfter { guidance = "Time limit reached · saving your scan"; finishScan(); return }
        if ProcessInfo.processInfo.thermalState == .critical { guidance = "Device is too hot · saving your scan"; finishScan(); return }
        if let frame = arSession.currentFrame {
            let t = frame.camera.transform
            miniPlan.camera = (PlanPoint(x: Double(t.columns.3.x), z: Double(t.columns.3.z)), PlanPoint(x: Double(-t.columns.2.x), z: Double(-t.columns.2.z)))
            updateCoverage(frame)
            miniPlan.setNeedsDisplay()
        }
        let seconds = Int(elapsed)
        let covered = coverage()
        let coverHint = elapsed > 20 && covered.total > 0 && covered.fraction < 0.85
            ? "Walls close up: \(Int(covered.fraction * 100))% · walk within 3 m of the orange walls" : nil
        status.text = elapsed >= Self.warnAfter
            ? "\(guidance)\nLarge scans can drift · finish soon · \(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
            : coverHint.map { "\(guidance)\n\($0)" } ?? guidance
    }
    @objc private func finishButton() {
        // Once per scan: say so if most walls were only seen from far away, which makes the plan less accurate.
        let covered = coverage()
        if !askedAboutCoverage, covered.total >= 3, covered.fraction < 0.6 {
            askedAboutCoverage = true
            let alert = UIAlertController(title: "Some walls weren’t scanned up close",
                                          message: "Only \(Int(covered.fraction * 100))% of the walls were seen from within 3 m. Walk along the orange walls on the map for more accurate walls, windows and doors.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
            alert.addAction(UIAlertAction(title: "Finish anyway", style: .default) { [weak self] _ in self?.finishScan() })
            present(alert, animated: true); return
        }
        finishScan()
    }

    // MARK: Wall coverage

    private func updateCoverage(_ frame: ARFrame) {
        guard let room = latestRoom else { return }
        let camera = frame.camera, eye = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let size = camera.imageResolution
        let depth = frame.sceneDepth?.depthMap
        var strips: [UUID: [Bool]] = [:]
        for wall in room.walls {
            let count = max(1, Int((wall.dimensions.x / Self.stripLength).rounded(.up)))
            var seen = wallStrips[wall.identifier] ?? []
            if seen.count != count {           // the wall grew or shrank: keep what was seen, proportionally
                let old = seen; seen = (0..<count).map { i in old.isEmpty ? false : old[min(old.count - 1, i * old.count / count)] }
            }
            let normal = simd_normalize(SIMD3(wall.transform.columns.2.x, wall.transform.columns.2.y, wall.transform.columns.2.z))
            for i in 0..<count where !seen[i] {
                let x = -wall.dimensions.x / 2 + (Float(i) + 0.5) * wall.dimensions.x / Float(count)
                for y: Float in [-0.4, 0.4] {
                    let w = wall.transform * SIMD4(x, y * wall.dimensions.y / 2, 0, 1), p = SIMD3(w.x, w.y, w.z)
                    let toPoint = p - eye, dist = simd_length(toPoint)
                    guard dist <= Self.closeEnough, abs(simd_dot(toPoint / dist, normal)) >= 0.5 else { continue }
                    let local = camera.transform.inverse * SIMD4(p, 1)
                    guard local.z < -0.1 else { continue }
                    let pixel = camera.projectPoint(p, orientation: .landscapeRight, viewportSize: size)
                    guard pixel.x > 0, pixel.y > 0, pixel.x < size.width, pixel.y < size.height else { continue }
                    if let depth, let measured = Self.depth(depth, at: CGPoint(x: pixel.x / size.width, y: pixel.y / size.height)),
                       abs(measured - -local.z) > 0.35 { continue }       // something in front, or the wall isn't there
                    seen[i] = true; break
                }
            }
            strips[wall.identifier] = seen
        }
        wallStrips = strips
        miniPlan.coverage = strips.mapValues { s in Double(s.filter { $0 }.count) / Double(max(1, s.count)) }
    }
    private func coverage() -> (fraction: Double, total: Int) {
        let all = wallStrips.values.flatMap { $0 }
        return (all.isEmpty ? 0 : Double(all.filter { $0 }.count) / Double(all.count), wallStrips.count)
    }
    // LiDAR depth (meters) at a normalised image position, or nil where there's no reading.
    private static func depth(_ map: CVPixelBuffer, at uv: CGPoint) -> Float? {
        CVPixelBufferLockBaseAddress(map, .readOnly); defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        let x = min(w - 1, max(0, Int(uv.x * CGFloat(w)))), y = min(h - 1, max(0, Int(uv.y * CGFloat(h))))
        let d = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: Float32.self).pointee
        return d > 0.05 && d.isFinite ? d : nil
    }
    private func finishScan() {
        guard scanning && !completed else { return }
        scanning = false; processing = true; finish.isEnabled = false
        timer?.invalidate(); recorderTimer?.invalidate()
        recorder?.saveMesh(from: arSession)
        status.text = "Building your room…"; spinner.startAnimating()
        stopSession()
        timeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.fail("Room processing took too long. Try a shorter scan with better lighting.")
        }
    }
    private func complete(_ room: CapturedRoom) {
        // The recorder hands over its folder before cancelSession would discard it.
        let recorder = self.recorder; self.recorder = nil
        guard let recorder else { cancelSession(); onComplete?(room, nil); return }
        recorder.finish { [weak self] folder in self?.cancelSession(); self?.onComplete?(room, folder) }
    }
    @objc private func cancelTapped() {
        let alert = UIAlertController(title: "Discard this scan?", message: "The current scan has not been saved.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.cancelSession(); self?.onCancel?() })
        present(alert, animated: true)
    }
    @objc private func backgrounded() {
        // Tracking stops in the background; keep what was captured rather than discarding it.
        guard scanning else { return }
        guidance = "Scanning paused when the app left the screen · saving what you scanned"; finishScan()
    }
    private func stopSession() {
        guard running else { return }
        running = false; session.stop()
    }
    func cancelSession() {
        completed = true; scanning = false; timer?.invalidate(); timeout?.invalidate(); recorderTimer?.invalidate()
        recorder?.discard(); recorder = nil
        session.delegate = nil; stopSession(); arSession.pause(); UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(self)
    }
    private func fail(_ message: String) {
        guard !completed else { return }
        cancelSession(); spinner.stopAnimating(); finish.isEnabled = false; status.text = "Scan interrupted"
        let alert = UIAlertController(title: "Couldn’t finish scan", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in self?.onCancel?() })
        if presentedViewController == nil { present(alert, animated: true) }
        else { dismiss(animated: false) { [weak self] in self?.present(alert, animated: true) } }
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanning else { return }
            self.latestRoom = room
            let now = Date()
            if now.timeIntervalSince(self.lastOutlineUpdate) >= 0.15 { self.lastOutlineUpdate = now; self.drawOutlines(room) }
            if now.timeIntervalSince(self.lastPlanUpdate) >= 0.5 {
                self.lastPlanUpdate = now
                self.miniPlan.room = RoomAdapter.project(from: room, reflective: false); self.miniPlan.setNeedsDisplay()
            }
        }
    }
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scanning else { return }
            switch instruction {
            case .moveCloseToWall: self.guidance = "Move closer to the wall"
            case .moveAwayFromWall: self.guidance = "Step back from the wall"
            case .slowDown: self.guidance = "Slow down"
            case .turnOnLight: self.guidance = "More light needed"
            case .lowTexture: self.guidance = "Aim at areas with more detail"
            case .normal: self.guidance = "Scan every wall and corner"
            @unknown default: self.guidance = "Scan every wall and corner"
            }
        }
    }
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.completed else { return }
            if let error { self.fail(error.localizedDescription); return }
            // A session the system ended on its own is processed like a finished one, so nothing is lost.
            if !self.processing { self.finishScan() }
            Task { @MainActor [weak self] in
                do {
                    let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                    guard let self, !self.completed else { return }
                    guard !room.walls.isEmpty else { self.fail("No walls were recognized. Move slowly and scan the room’s corners."); return }
                    self.complete(room)
                } catch { self?.fail(error.localizedDescription) }
            }
        }
    }

    // MARK: Live outlines

    private func drawOutlines(_ room: CapturedRoom) {
        let found: [(CapturedRoom.Surface, UIColor)] = room.walls.map { ($0, .white) } + room.doors.map { ($0, .systemGreen) }
            + room.windows.map { ($0, .systemCyan) } + room.openings.map { ($0, .systemYellow) }
        var seen = Set<UUID>()
        for (surface, color) in found {
            let id = surface.identifier; seen.insert(id)
            let node: SCNNode
            if let existing = outlineNodes[id] { node = existing } else {
                node = SCNNode(); node.opacity = 0; outlines.addChildNode(node); outlineNodes[id] = node
                node.runAction(.fadeIn(duration: 0.35))
            }
            if outlineSizes[id].map({ simd_distance($0, surface.dimensions) > 0.01 }) ?? true {
                node.childNodes.forEach { $0.removeFromParentNode() }
                Self.edges(of: surface.dimensions, color: color).forEach(node.addChildNode)
                outlineSizes[id] = surface.dimensions
            }
            node.simdTransform = surface.transform
        }
        for id in Array(outlineNodes.keys) where !seen.contains(id) {
            outlineNodes[id]?.runAction(.sequence([.fadeOut(duration: 0.2), .removeFromParentNode()]))
            outlineNodes[id] = nil; outlineSizes[id] = nil
        }
    }
    // The four edges of a RoomPlan surface, which spans ±width/2 and ±height/2 in its local x/y plane.
    static func edges(of size: simd_float3, color: UIColor) -> [SCNNode] {
        let w = CGFloat(size.x), h = CGFloat(size.y), t: CGFloat = 0.012
        let material = SCNMaterial(); material.diffuse.contents = color; material.lightingModel = .constant
        func bar(_ width: CGFloat, _ height: CGFloat, _ x: Float, _ y: Float) -> SCNNode {
            let box = SCNBox(width: width, height: height, length: t, chamferRadius: 0); box.materials = [material]
            let node = SCNNode(geometry: box); node.simdPosition = .init(x, y, 0); return node
        }
        return [bar(w + t, t, 0, Float(h / 2)), bar(w + t, t, 0, -Float(h / 2)), bar(t, h, -Float(w / 2), 0), bar(t, h, Float(w / 2), 0)]
    }
}

// A live top-down plan of what has been captured so far, with the device's position and heading.
final class MiniPlanView: UIView {
    var room = RoomProject()
    var camera: (position: PlanPoint, heading: PlanPoint)?
    var coverage: [UUID: Double] = [:]          // per wall, 0…1 of its length scanned up close
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.88); isOpaque = false
        layer.cornerRadius = 16; clipsToBounds = true; isUserInteractionEnabled = false
        accessibilityLabel = "Live floor plan of the walls found so far"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        var points = room.activeSurfaces.flatMap { [$0.a, $0.b] }
        if let camera { points.append(camera.position) }
        guard room.walls.count > 0 || camera != nil else {
            PlanDrawing.text("Walls appear here", at: CGPoint(x: rect.midX, y: rect.midY), size: 11, centered: true); return
        }
        let bounds = PlanBounds(points), inset = rect.insetBy(dx: 14, dy: 14)
        let scale = max(1, min(Double(inset.width) / (bounds.width + 0.6), Double(inset.height) / (bounds.depth + 0.6)))
        let projection = PlanProjection(scale: scale, center: bounds.center, viewport: rect)
        PlanDrawing.draw(room, context: c, projection: projection, dimensions: false, furniture: false, grid: false)
        // Walls coloured by close-up coverage: orange still to do, green done.
        c.setLineWidth(4); c.setLineCap(.round)
        for wall in room.walls {
            guard let done = coverage[wall.id] else { continue }
            c.setStrokeColor((done >= 0.8 ? UIColor.systemGreen : done >= 0.3 ? UIColor.systemYellow : UIColor.systemOrange).cgColor)
            c.move(to: projection.screen(wall.a)); c.addLine(to: projection.screen(wall.b)); c.strokePath()
        }
        guard let camera else { return }
        let p = projection.screen(camera.position), heading = camera.heading
        let length = max(0.001, heading.magnitude), d = CGPoint(x: heading.x / length, y: heading.z / length)
        c.setFillColor(UIColor.systemBlue.withAlphaComponent(0.25).cgColor)
        c.move(to: p)
        c.addLine(to: CGPoint(x: p.x + (d.x * 0.94 - d.y * 0.34) * 22, y: p.y + (d.y * 0.94 + d.x * 0.34) * 22))
        c.addLine(to: CGPoint(x: p.x + (d.x * 0.94 + d.y * 0.34) * 22, y: p.y + (d.y * 0.94 - d.x * 0.34) * 22))
        c.closePath(); c.fillPath()
        c.setFillColor(UIColor.systemBlue.cgColor); c.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
    }
}

enum RoomAdapter {
    // "Chair · swivel, with arms" rather than "chair": RoomPlan's category in words plus the details it
    // recognised (iOS 17 attributes such as chair, table, sofa and storage types).
    static func objectLabel(_ o: CapturedRoom.Object) -> String {
        func words(_ raw: String) -> String {
            raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
        }
        let name = words(String(describing: o.category))
        let details = o.attributes.compactMap { attribute -> String? in
            guard let raw = (attribute as? any RawRepresentable)?.rawValue as? String else { return nil }
            let text = words(raw)
            return text == "unidentified" || text == "unknown" ? nil : text
        }
        let label = name.prefix(1).uppercased() + name.dropFirst()
        return details.isEmpty ? label : "\(label) · \(details.joined(separator: ", "))"
    }
    static func project(from room: CapturedRoom, reflective: Bool) -> RoomProject {
        let floorY = room.walls.map { Double($0.transform.columns.3.y - $0.dimensions.y / 2) }.min() ?? 0
        var project = RoomProject(name: "Room · " + Date().formatted(date: .abbreviated, time: .shortened))
        func confidence(_ c: CapturedRoom.Confidence) -> ScanConfidence {
            switch c { case .high: return .high; case .medium: return .medium; case .low: return .low; @unknown default: return .unknown }
        }
        func convert(_ s: CapturedRoom.Surface, kind: SurfaceKind, index: Int) -> PlanSurface {
            let half = s.dimensions.x / 2
            let av = s.transform * SIMD4<Float>(-half, 0, 0, 1), bv = s.transform * SIMD4<Float>(half, 0, 0, 1)
            var caveats: [String] = [], note: String?
            if s.curve != nil { caveats.append("Curved surface represented by a straight chord in the corrected model; original USDZ retained.") }
            if !s.polygonCorners.isEmpty && kind == .wall {
                // A stepped or sloping top doesn't change the floor plan: a note to review, not a caveat on the area.
                let heights = Set(s.polygonCorners.map { Int(($0.y * 100).rounded()) })
                if heights.count > 2 { note = RoomProject.nonuniformHeight }
            }
            return PlanSurface(id: s.identifier, label: "\(kind.title) \(index + 1)", kind: kind,
                               a: .init(x: Double(av.x), z: Double(av.z)), b: .init(x: Double(bv.x), z: Double(bv.z)),
                               bottom: Double(s.transform.columns.3.y - s.dimensions.y / 2) - floorY,
                               height: Double(s.dimensions.y), parentID: kind == .wall ? nil : s.parentIdentifier,
                               confidence: confidence(s.confidence), evidence: .captured, originalLength: Double(s.dimensions.x),
                               reflectiveRisk: kind == .window, geometryCaveat: caveats.isEmpty ? nil : caveats.joined(separator: " "), reviewNote: note)
        }
        project.surfaces = room.walls.enumerated().map { convert($0.element, kind: .wall, index: $0.offset) }
            + room.doors.enumerated().map { convert($0.element, kind: .door, index: $0.offset) }
            + room.windows.enumerated().map { convert($0.element, kind: .window, index: $0.offset) }
            + room.openings.enumerated().map { convert($0.element, kind: .opening, index: $0.offset) }
        // Resolve absent parent links conservatively; leave distant surfaces unassigned for review.
        let walls = project.walls
        for i in project.surfaces.indices where project.surfaces[i].kind != .wall {
            let s = project.surfaces[i]
            if !walls.contains(where: { $0.id == s.parentID }) {
                project.surfaces[i].parentID = nil
                let candidates = walls.filter { abs($0.direction.dot(s.direction)) > 0.95 }
                if let nearest = candidates.min(by: { Geometry.distance(s.midpoint, to: $0.a, $0.b) < Geometry.distance(s.midpoint, to: $1.a, $1.b) }),
                   Geometry.distance(s.midpoint, to: nearest.a, nearest.b) < 0.20 {
                    project.surfaces[i].parentID = nearest.id
                }
            }
            if let wall = walls.first(where: { $0.id == project.surfaces[i].parentID }),
               wall.direction.dot(project.surfaces[i].direction) < 0 {
                let start = project.surfaces[i].a
                project.surfaces[i].a = project.surfaces[i].b
                project.surfaces[i].b = start
            }
        }
        project.objects = room.objects.map { o in
            PlanObject(id: o.identifier, label: objectLabel(o),
                       center: .init(x: Double(o.transform.columns.3.x), y: Double(o.transform.columns.3.y) - floorY, z: Double(o.transform.columns.3.z)),
                       size: .init(x: Double(o.dimensions.x), y: Double(o.dimensions.y), z: Double(o.dimensions.z)),
                       yaw: atan2(Double(o.transform.columns.0.z), Double(o.transform.columns.0.x)))
        }
        if reflective { project.captureWarnings.append("Mirrors or large glass surfaces were reported before scanning. Review their boundaries and any phantom walls manually.") }
        project.captureWarnings.append("Recognition confidence is not a dimensional accuracy estimate. Validate important dimensions independently.")
        return project
    }
}
