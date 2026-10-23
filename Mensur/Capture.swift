import SwiftUI
import RoomPlan
import ARKit
import AVFoundation
import SceneKit
import os

// Continuing a room scanned earlier: its saved AR world map lets the new scan pick up in the same coordinates.
struct ResumeContext { var roomID: UUID; var name: String; var worldMap: URL; var level: FloorLevel? }

// What the scan starts with: a world map to resume from, the building and floor, and coaching preferences.
struct CaptureSetup { var resumeMap: URL?; var building: String; var floor: Int; var spoken: Bool; var haptics: Bool }

struct CaptureScreen: View {
    var resume: ResumeContext? = nil
    let onCaptured: (CapturedRoom, Bool, URL?) -> Void
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var reflective = false
    @State private var building = ""
    @State private var floor = 0
    @AppStorage(Setting.spokenCoaching) private var spoken = true
    @AppStorage(Setting.hapticCoaching) private var haptics = true
    var body: some View {
        if started {
            RoomCaptureHost(setup: CaptureSetup(resumeMap: resume?.worldMap, building: building.trimmingCharacters(in: .whitespaces), floor: floor, spoken: spoken, haptics: haptics),
                            onRoom: { room, measurements in onCaptured(room, reflective, measurements) }, onDone: { dismiss() })
                .ignoresSafeArea()
        } else {
            NavigationStack {
                Form {
                    Section {
                        Label(resume == nil ? "Capture a room" : "Continue scanning", systemImage: "viewfinder").font(.title2.bold())
                        if let resume {
                            Text("Stand where you finished scanning \(resume.name) and point the camera at walls you scanned before. Scanning starts once Mensur recognises them, and the new walls join the room in the same place.")
                        } else {
                            Text("Walk slowly around the space. Capture every wall, each corner, and the frames around doors and windows. Outlines appear as surfaces are found, and a live plan builds in the corner, coloured by how closely each part of each wall has been seen.")
                        }
                    }
                    Section("Before you begin") {
                        Text("Turn on lights. Open curtains and raise blinds where you can: RoomPlan finds windows by their frame and glass, so a covered window may read as wall. You can add missed windows afterwards from the plan. Keep people out of view. Large spaces can take up to 10 minutes.")
                        Toggle("This room has mirrors or large glass surfaces", isOn: $reflective)
                        if reflective {
                            Text("Scan the solid frame and surrounding wall from several angles. Reflections can create phantom geometry. After capture, mark mirrors, check windows, and enter laser or tape measurements.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if resume == nil {
                        Section {
                            HStack {
                                TextField("Building (optional)", text: $building)
                                let names = Array(Set(store.projects.compactMap(\.level?.building))).sorted()
                                if !names.isEmpty {
                                    Menu { ForEach(names, id: \.self) { name in Button(name) { building = name } } } label: { Image(systemName: "chevron.down.circle") }
                                        .accessibilityLabel("Choose an existing building")
                                }
                            }
                            if !building.trimmingCharacters(in: .whitespaces).isEmpty {
                                Stepper("Floor: \(FloorLevel(building: "x", floor: floor).displayName)", value: $floor, in: -5...60)
                            }
                        } header: { Text("Building") } footer: {
                            Text("Scanning several rooms or floors? Name the building, then use Finish → Next room or Next floor to carry on without stopping. Rooms scanned in one go line up exactly.")
                        }
                    }
                    Section {
                        Toggle("Spoken coaching", isOn: $spoken)
                        Toggle("Haptic feedback", isOn: $haptics)
                    } header: { Text("Coaching") } footer: {
                        Text("Tells you which wall still needs a closer look, and taps when a wall is done.")
                    }
                    Section {
                        Text("A scan produces a simplified architectural model. Wall thickness comes from reveal mode (measure door and window frames) or what you enter. Door swings, markers and finishes are set by you.")
                        Button(resume == nil ? "Start scanning" : "Start") { LocationAddress.shared.prefetch(); started = true }.buttonStyle(.borderedProminent)
                            .disabled(!RoomCaptureSession.isSupported)
                        if !RoomCaptureSession.isSupported {
                            Text("Scanning needs a LiDAR-equipped iPhone or iPad. You can explore the sample project on this device.").foregroundStyle(.orange)
                        }
                    }
                }
                .navigationTitle(resume == nil ? "New scan" : "Continue scan")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { if let level = resume?.level { building = level.building; floor = level.floor } }
            }
        }
    }
}

struct RoomCaptureHost: UIViewControllerRepresentable {
    let setup: CaptureSetup
    let onRoom: (CapturedRoom, URL?) -> Void
    let onDone: () -> Void
    func makeUIViewController(context: Context) -> CaptureController {
        let controller = CaptureController(setup: setup)
        controller.onRoom = onRoom; controller.onDone = onDone
        return controller
    }
    func updateUIViewController(_ uiViewController: CaptureController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: CaptureController, coordinator: ()) { uiViewController.cancelSession() }
}

// Mensur's own capture screen on a RoomCaptureSession: the camera feed with colour-coded outlines of every
// surface RoomPlan has found, coaching text and voice, and a live top-down plan coloured by close-up coverage.
// Markers, photos and reveal measurements can be taken during the scan; Finish can carry on to the next room
// or floor in the same coordinates. RoomBuilder turns the captured data into each CapturedRoom.
final class CaptureController: UIViewController, RoomCaptureSessionDelegate {
    var onRoom: ((CapturedRoom, URL?) -> Void)?
    var onDone: (() -> Void)?
    private let setup: CaptureSetup
    private var recorder: ScanRecorder?
    private var recorderTimer: Timer?
    static let warnAfter = 300.0, stopAfter = 600.0
    // RoomPlan runs on an AR session the app owns, so the app can ask it for LiDAR depth and the labelled
    // scene mesh, which correct walls, find openings RoomPlan missed and measure the ceiling.
    private let arSession = ARSession()
    private lazy var session = RoomCaptureSession(arSession: arSession)
    private let log = Logger(subsystem: "com.matthewsinitiere.Mensur", category: "capture")
    // Wall coverage: for each wall, how many times each half-metre strip has been seen from within 3.5 m,
    // fairly head-on, with LiDAR depth confirming the wall was really in view. Close views help RoomPlan place
    // walls, windows and doors, and give the LiDAR wall correction something to work with.
    private var latestRoom: CapturedRoom?
    private var wallStrips: [UUID: [Int]] = [:]
    private var finishedWalls = Set<UUID>()
    private var askedAboutCoverage = false
    static let stripLength: Float = 0.5, closeEnough: Float = 3.5
    private let sceneView = ARSCNView(frame: .zero)
    private let outlines = SCNNode()
    private var outlineNodes: [UUID: SCNNode] = [:]
    private var outlineSizes: [UUID: simd_float3] = [:]
    private let miniPlan = MiniPlanView()
    private var miniSize: NSLayoutConstraint?
    private let status = UILabel()
    private let finish = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let markButton = UIButton(type: .system), photoButton = UIButton(type: .system), revealButton = UIButton(type: .system)
    private let flash = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var timer: Timer?
    private var timeout: Timer?
    private var startDate = Date()
    private var guidance = "Scan every wall and corner"
    private var note: String?                       // a second status line: the last marker, photo or reveal
    private var lastOutlineUpdate = Date.distantPast, lastPlanUpdate = Date.distantPast
    private var running = false
    private var scanning = false
    private var processing = false
    private var completed = false
    private var requestedCamera = false
    // This session: rooms scanned in one go share its coordinates.
    private let frameID = UUID()
    private var floor: Int
    private var building: String
    private var continueAfter: Int?                 // after this room, scan another: floor change (0 same floor)
    private var waitingToRelocalize = false, sawRelocalizing = false
    // Recorded alongside RoomPlan for the room's extras (see ScanExtras).
    private var poses: [PoseSample] = []
    private var markers: [CapturedMarker] = []
    private var photos: [CapturedPhoto] = []
    private var revealMode = false
    private var revealPoints: [UUID: [Vector3]] = [:]
    private var revealResults: [UUID: (depth: Double, x: Double, z: Double)] = [:]
    private var lastRevealCheck = Date.distantPast
    // Coaching.
    private let speech = AVSpeechSynthesizer()
    private var lastSpoken = Date.distantPast, lastPhrase = "", lastHintCheck = Date.distantPast
    private let impact = UIImpactFeedbackGenerator(style: .light), notify = UINotificationFeedbackGenerator()

    init(setup: CaptureSetup) {
        self.setup = setup; self.floor = setup.floor; self.building = setup.building
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        status.text = "Preparing camera…"; status.numberOfLines = 3; status.font = .preferredFont(forTextStyle: .caption1)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancel.setTitle("Cancel", for: .normal); cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        finish.setTitle("Finish", for: .normal); finish.isEnabled = false
        finish.menu = finishMenu(); finish.showsMenuAsPrimaryAction = setup.resumeMap == nil
        if setup.resumeMap != nil { finish.addTarget(self, action: #selector(finishTapped), for: .touchUpInside) }
        let stack = UIStackView(arrangedSubviews: [cancel, status, spinner, finish]); stack.spacing = 12; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; bar.contentView.addSubview(stack)
        miniPlan.translatesAutoresizingMaskIntoConstraints = false
        miniPlan.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleMiniPlan)))
        view.addSubview(miniPlan)
        // Tools: mark an outlet or fixture, take a reference photo, measure reveals.
        let tools = UIStackView(arrangedSubviews: [markButton, photoButton, revealButton]); tools.axis = .vertical; tools.spacing = 12
        tools.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(tools)
        for (button, symbol, label) in [(markButton, "bolt.fill", "Mark an outlet, switch or fixture"), (photoButton, "camera.fill", "Take a reference photo"), (revealButton, "ruler", "Measure door and window reveals")] {
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: symbol); config.cornerStyle = .capsule; config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
            config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            button.configuration = config; button.accessibilityLabel = label; button.isEnabled = false
        }
        markButton.menu = markMenu(); markButton.showsMenuAsPrimaryAction = true
        photoButton.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
        revealButton.addTarget(self, action: #selector(toggleReveals), for: .touchUpInside)
        flash.backgroundColor = .white; flash.alpha = 0; flash.isUserInteractionEnabled = false; flash.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(flash)
        let size = miniPlan.widthAnchor.constraint(equalToConstant: 150); miniSize = size
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12), bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -12),
                                     miniPlan.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), miniPlan.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12), size, miniPlan.heightAnchor.constraint(equalTo: miniPlan.widthAnchor),
                                     tools.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12), tools.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                                     flash.leadingAnchor.constraint(equalTo: view.leadingAnchor), flash.trailingAnchor.constraint(equalTo: view.trailingAnchor), flash.topAnchor.constraint(equalTo: view.topAnchor), flash.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
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
        guidance = "Memory is low · saving what you’ve scanned"; continueAfter = nil; finishScan()
    }
    private func requestCamera() {
        guard RoomCaptureSession.isSupported else { fail("This device does not support RoomPlan capture."); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { if allowed { self?.begin() } else { self?.fail("Camera access is needed. Enable it in Settings → Mensur.") } }
            }
        default: fail("Camera access is disabled. Enable it in Settings → Mensur.")
        }
    }
    // A fresh scan starts at once; a resumed one first relocalizes against the saved world map.
    private func begin() {
        guard !completed else { return }
        if setup.spoken {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        if let url = setup.resumeMap, let data = try? Data(contentsOf: url),
           let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
            let config = ARWorldTrackingConfiguration(); config.initialWorldMap = map
            arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
            waitingToRelocalize = true; startDate = Date()
            guidance = "Point at walls you scanned before · scanning starts when they’re recognised"
            status.text = guidance
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            return
        }
        startScan()
    }
    private func startScan() {
        guard !completed else { return }
        waitingToRelocalize = false
        scanning = true; running = true; startDate = Date(); finish.isEnabled = true
        [markButton, photoButton, revealButton].forEach { $0.isEnabled = true }
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
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }
    // RoomPlan picks its own ARKit configuration. Ask it to add LiDAR depth (for the coverage guide and
    // reveals) and the labelled scene mesh (wall, window, door, floor, ceiling). Whether RoomPlan keeps them
    // shows in probe-depth.json.
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
        if waitingToRelocalize {
            guard let frame = arSession.currentFrame else { return }
            switch frame.camera.trackingState {
            case .limited(.relocalizing): sawRelocalizing = true
            case .normal where sawRelocalizing:
                if setup.haptics { notify.notificationOccurred(.success) }
                say("Recognised. Carry on scanning.")
                guidance = "Recognised · keep scanning the new walls"; startScan(); return
            default: break
            }
            if Date().timeIntervalSince(startDate) > 40 { status.text = "Not recognised yet · go back to where you finished last time and look at those walls" }
            return
        }
        guard scanning else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        if elapsed >= Self.stopAfter { guidance = "Time limit reached · saving your scan"; continueAfter = nil; finishScan(); return }
        if ProcessInfo.processInfo.thermalState == .critical { guidance = "Device is too hot · saving your scan"; continueAfter = nil; finishScan(); return }
        if let frame = arSession.currentFrame {
            let t = frame.camera.transform
            let heading = PlanPoint(x: Double(-t.columns.2.x), z: Double(-t.columns.2.z))
            let position = PlanPoint(x: Double(t.columns.3.x), z: Double(t.columns.3.z))
            miniPlan.camera = (position, heading)
            poses.append(PoseSample(t: frame.timestamp, x: Double(t.columns.3.x), y: Double(t.columns.3.y), z: Double(t.columns.3.z), tracking: Self.tracking(frame.camera.trackingState)))
            updateCoverage(frame)
            if revealMode { sampleReveals(frame) }
            miniPlan.setNeedsDisplay()
            coach(position: position, heading: heading, elapsed: elapsed)
        }
        let seconds = Int(elapsed)
        let covered = coverage()
        let coverHint = elapsed > 20 && covered.total > 0 && covered.fraction < 0.85
            ? "Walls close up: \(Int(covered.fraction * 100))% · walk within 3 m of the red walls" : nil
        var lines = [guidance]
        if revealMode { lines.append(revealStatus()) } else if let note { lines.append(note) } else if let coverHint { lines.append(coverHint) }
        if elapsed >= Self.warnAfter { lines.append("Large scans can drift · finish soon · \(seconds / 60)m \(String(format: "%02d", seconds % 60))s") }
        status.text = lines.joined(separator: "\n")
    }
    static func tracking(_ state: ARCamera.TrackingState) -> Int {
        switch state {
        case .normal: return 0
        case .limited(.relocalizing): return 2
        default: return 1
        }
    }

    // MARK: Finishing, and carrying on to the next room or floor

    private func finishMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Finish scan", image: UIImage(systemName: "checkmark")) { [weak self] _ in self?.requestFinish(next: nil) },
            UIAction(title: "Next room on this floor", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.requestFinish(next: 0) },
            UIAction(title: "Next floor up", image: UIImage(systemName: "arrow.up.square")) { [weak self] _ in self?.requestFinish(next: 1) },
            UIAction(title: "Next floor down", image: UIImage(systemName: "arrow.down.square")) { [weak self] _ in self?.requestFinish(next: -1) }
        ])
    }
    @objc private func finishTapped() { requestFinish(next: nil) }
    private func requestFinish(next: Int?) {
        // Once per scan: say so if most walls were only seen from far away, which makes the plan less accurate.
        let covered = coverage()
        if !askedAboutCoverage, covered.total >= 3, covered.fraction < 0.6 {
            askedAboutCoverage = true
            let alert = UIAlertController(title: "Some walls weren’t scanned up close",
                                          message: "Only \(Int(covered.fraction * 100))% of the walls were seen from within 3 m. Walk along the red walls on the map for more accurate walls, windows and doors.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
            alert.addAction(UIAlertAction(title: "Finish anyway", style: .default) { [weak self] _ in self?.continueAfter = next; self?.finishScan() })
            present(alert, animated: true); return
        }
        continueAfter = next; finishScan()
    }

    // MARK: Wall coverage and coaching

    private func updateCoverage(_ frame: ARFrame) {
        guard let room = latestRoom else { return }
        let camera = frame.camera, eye = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let size = camera.imageResolution
        let depth = frame.sceneDepth?.depthMap
        var strips: [UUID: [Int]] = [:]
        for wall in room.walls {
            let count = max(1, Int((wall.dimensions.x / Self.stripLength).rounded(.up)))
            var seen = wallStrips[wall.identifier] ?? []
            if seen.count != count {           // the wall grew or shrank: keep what was seen, proportionally
                let old = seen; seen = (0..<count).map { i in old.isEmpty ? 0 : old[min(old.count - 1, i * old.count / count)] }
            }
            let normal = simd_normalize(SIMD3(wall.transform.columns.2.x, wall.transform.columns.2.y, wall.transform.columns.2.z))
            for i in 0..<count where seen[i] < 20 {
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
                    seen[i] += 1; break
                }
            }
            strips[wall.identifier] = seen
            // A tap when a wall of a metre or more has been seen up close end to end.
            if wall.dimensions.x >= 1, seen.allSatisfy({ $0 > 0 }), finishedWalls.insert(wall.identifier).inserted, setup.haptics { notify.notificationOccurred(.success) }
        }
        wallStrips = strips
        miniPlan.strips = strips
    }
    private func coverage() -> (fraction: Double, total: Int) {
        let all = wallStrips.values.flatMap { $0 }
        return (all.isEmpty ? 0 : Double(all.filter { $0 > 0 }.count) / Double(all.count), wallStrips.count)
    }
    // Every few seconds: which wall still needs a close look, spoken if it changed or hasn't been said lately.
    private func coach(position: PlanPoint, heading: PlanPoint, elapsed: Double) {
        guard elapsed > 15, Date().timeIntervalSince(lastHintCheck) > 3, !revealMode else { return }
        lastHintCheck = Date()
        let walls = miniPlan.room.walls.map { ($0, wallStrips[$0.id] ?? []) }
        guard let hint = Coaching.next(position: position, heading: heading, walls: walls) else { return }
        if hint.phrase != lastPhrase || Date().timeIntervalSince(lastSpoken) > 20 { say(hint.phrase); lastPhrase = hint.phrase }
    }
    private func say(_ text: String) {
        guard setup.spoken, !speech.isSpeaking else { return }
        lastSpoken = Date()
        let utterance = AVSpeechUtterance(string: text); utterance.rate = 0.5
        speech.speak(utterance)
    }
    @objc private func toggleMiniPlan() {
        miniSize?.constant = (miniSize?.constant ?? 150) > 160 ? 150 : min(320, view.bounds.width - 100)
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        miniPlan.setNeedsDisplay()
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

    // MARK: Markers and photos

    private func markMenu() -> UIMenu {
        let groups: [(String, MarkerCategory)] = [("Electrical", .electrical), ("Plumbing", .plumbing), ("HVAC", .hvac)]
        return UIMenu(title: "Mark where the camera points", children: groups.map { title, category in
            UIMenu(title: title, options: .displayInline, children: MarkerKind.allCases.filter { $0.category == category }.map { kind in
                UIAction(title: kind.title, image: UIImage(systemName: kind.symbol)) { [weak self] _ in self?.mark(kind) }
            })
        })
    }
    // Drops a marker where the centre of the view meets a surface (or 1.5 m ahead if nothing is found).
    private func mark(_ kind: MarkerKind) {
        guard scanning, let frame = arSession.currentFrame else { return }
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any)
        let p: SIMD3<Float>
        if let hit = arSession.raycast(query).first { p = SIMD3(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z) }
        else { let t = frame.camera.transform; p = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z) - SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z) * 1.5 }
        markers.append(CapturedMarker(kind: kind, x: Double(p.x), y: Double(p.y), z: Double(p.z)))
        note = "\(kind.title) marked · \(markers.count) marker\(markers.count == 1 ? "" : "s")"
        if setup.haptics { impact.impactOccurred() }
    }
    // A reference photo of what the camera sees, pinned where the phone is standing.
    @objc private func takePhoto() {
        guard scanning, let frame = arSession.currentFrame, let folder = recorder?.folder else { return }
        let id = UUID(), t = frame.camera.transform
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = CIContext().createCGImage(image, from: image.extent), let jpeg = PhotoFiles.jpeg(UIImage(cgImage: cg)) else { return }
        let photosFolder = folder.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photosFolder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: photosFolder.appendingPathComponent("\(id.uuidString).jpg"))) != nil else { return }
        photos.append(CapturedPhoto(id: id, x: Double(t.columns.3.x), z: Double(t.columns.3.z), heading: atan2(Double(-t.columns.2.z), Double(-t.columns.2.x))))
        note = "Photo \(photos.count) pinned to the plan"
        flash.alpha = 0.8; UIView.animate(withDuration: 0.35) { self.flash.alpha = 0 }
        if setup.haptics { impact.impactOccurred() }
    }

    // MARK: Reveals

    @objc private func toggleReveals() {
        revealMode.toggle()
        revealButton.configuration?.baseBackgroundColor = revealMode ? UIColor.systemBlue : UIColor.black.withAlphaComponent(0.55)
        guidance = revealMode ? "Reveal mode · stand beside a door or window and aim at the side of its frame" : "Scan every wall and corner"
        if revealMode { say("Aim at the side of a door or window frame") }
    }
    // LiDAR points near the jambs of every door, window and opening within 3.5 m, in each opening's own
    // coordinates (Reveals.depth): u across from its left jamb, v up from its bottom, w out of the wall.
    private func sampleReveals(_ frame: ARFrame) {
        guard let room = latestRoom, let map = frame.sceneDepth?.depthMap else { return }
        let camera = frame.camera, eye = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let openings = (room.doors + room.windows + room.openings).filter {
            simd_distance(SIMD3($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z), eye) < 3.5
        }
        guard !openings.isEmpty else { return }
        CVPixelBufferLockBaseAddress(map, .readOnly); defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        let k = camera.intrinsics, sx = Float(w) / Float(camera.imageResolution.width), sy = Float(h) / Float(camera.imageResolution.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        let inverses = openings.map { $0.transform.inverse }
        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: 0, to: w, by: 3) {
                let d = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: Float32.self).pointee
                guard d > 0.1, d < 4, d.isFinite else { continue }
                // Camera space: x right, y up, looking down −z.
                let pc = SIMD4<Float>((Float(x) - cx) / fx * d, -(Float(y) - cy) / fy * d, -d, 1)
                let world = camera.transform * pc
                for (o, inverse) in zip(openings, inverses) {
                    let local = inverse * world
                    let u = Double(local.x + o.dimensions.x / 2), v = Double(local.y + o.dimensions.y / 2), wOut = Double(local.z)
                    let width = Double(o.dimensions.x)
                    guard (abs(u) < 0.12 || abs(u - width) < 0.12), v > 0, v < Double(o.dimensions.y), abs(wOut) < 0.9 else { continue }
                    if revealPoints[o.identifier, default: []].count < 6000 { revealPoints[o.identifier, default: []].append(Vector3(x: u, y: v, z: wOut)) }
                }
            }
        }
        guard Date().timeIntervalSince(lastRevealCheck) > 1 else { return }
        lastRevealCheck = Date()
        for o in openings {
            guard let depth = Reveals.depth(revealPoints[o.identifier] ?? [], width: Double(o.dimensions.x), height: Double(o.dimensions.y)) else { continue }
            if revealResults[o.identifier] == nil, setup.haptics { notify.notificationOccurred(.success) }
            revealResults[o.identifier] = (depth, Double(o.transform.columns.3.x), Double(o.transform.columns.3.z))
        }
    }
    private func revealStatus() -> String {
        guard let room = latestRoom else { return "Looking for doors and windows…" }
        let units = Setting.defaultUnits
        let named = (room.doors.enumerated().map { ("Door \($0.offset + 1)", $0.element.identifier) } + room.windows.enumerated().map { ("Window \($0.offset + 1)", $0.element.identifier) })
        let found = named.compactMap { name, id in revealResults[id].map { "\(name) \(units.length($0.depth))" } }
        return found.isEmpty ? "No reveal measured yet · get within a metre of the frame's side" : "Reveals: " + found.joined(separator: " · ")
    }

    // MARK: Saving

    private func finishScan() {
        guard scanning && !completed else { return }
        scanning = false; processing = true; finish.isEnabled = false
        [markButton, photoButton, revealButton].forEach { $0.isEnabled = false }
        timer?.invalidate(); recorderTimer?.invalidate()
        recorder?.saveMesh(from: arSession)
        saveExtras()
        status.text = continueAfter == nil ? "Building your room…" : "Saving this room…"; spinner.startAnimating()
        // The world map lets this room be resumed later; it must be taken before the session stops.
        let folder = recorder?.folder
        var stopped = false
        let stop = { [weak self] in guard !stopped else { return }; stopped = true; self?.stopSession() }
        arSession.getCurrentWorldMap { map, _ in
            if let map, let folder, let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) {
                try? data.write(to: folder.appendingPathComponent("WorldMap.arworldmap"))
            }
            DispatchQueue.main.async { stop() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { stop() }
        timeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.fail("Room processing took too long. Try a shorter scan with better lighting.")
        }
    }
    // Poses, markers, photos, reveals and the building context, for ScanExtras.
    private func saveExtras() {
        guard let folder = recorder?.folder else { return }
        func write<T: Encodable>(_ value: T, _ name: String) { if let data = try? JSONEncoder().encode(value) { try? data.write(to: folder.appendingPathComponent(name)) } }
        write(poses, "poses.json")
        if !markers.isEmpty { write(markers, "markers.json") }
        if !photos.isEmpty { write(photos, "photos.json") }
        if !revealResults.isEmpty { write(revealResults.map { CapturedReveal(opening: $0.key, depth: $0.value.depth, x: $0.value.x, z: $0.value.z) }, "reveals.json") }
        // Rooms scanned in one go always join a building, so they appear together.
        if building.isEmpty && (continueAfter != nil || floor != setup.floor) { building = "Building · " + startDate.formatted(date: .abbreviated, time: .omitted) }
        write(CaptureContext(building: building.isEmpty ? nil : building, floor: floor, floorName: nil, frame: frameID), "capture.json")
    }
    private func complete(_ room: CapturedRoom) {
        // The recorder hands over its folder before cancelSession would discard it.
        let recorder = self.recorder; self.recorder = nil
        let next = continueAfter
        let deliver: (URL?) -> Void = { [weak self] folder in
            guard let self else { return }
            self.onRoom?(room, folder)
            if let next { self.nextRoom(floorChange: next) } else { self.cancelSession(); self.onDone?() }
        }
        guard let recorder else { deliver(nil); return }
        recorder.finish { folder in deliver(folder) }
    }
    // Carries on in the same AR session: the next room shares this one's coordinates.
    private func nextRoom(floorChange: Int) {
        floor += floorChange
        latestRoom = nil; wallStrips = [:]; finishedWalls = []; askedAboutCoverage = false
        outlineNodes.values.forEach { $0.removeFromParentNode() }; outlineNodes = [:]; outlineSizes = [:]
        miniPlan.room = RoomProject(); miniPlan.strips = [:]; miniPlan.setNeedsDisplay()
        poses = []; markers = []; photos = []; revealPoints = [:]; revealResults = [:]; note = nil
        processing = false; timeout?.invalidate(); spinner.stopAnimating(); continueAfter = nil
        guidance = floorChange == 0 ? "Next room · scan its walls and corners" : "\(FloorLevel(building: "x", floor: floor).displayName) · scan its walls and corners"
        say(guidance.replacingOccurrences(of: " · ", with: ". "))
        startScan()
    }
    @objc private func cancelTapped() {
        let alert = UIAlertController(title: "Discard this scan?", message: "The current scan has not been saved.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.cancelSession(); self?.onDone?() })
        present(alert, animated: true)
    }
    @objc private func backgrounded() {
        // Tracking stops in the background; keep what was captured rather than discarding it.
        guard scanning else { return }
        guidance = "Scanning paused when the app left the screen · saving what you scanned"; continueAfter = nil; finishScan()
    }
    private func stopSession() {
        guard running else { return }
        running = false
        // Keep the AR session running between rooms so the next one shares its coordinates.
        session.stop(pauseARSession: continueAfter == nil)
    }
    func cancelSession() {
        completed = true; scanning = false; timer?.invalidate(); timeout?.invalidate(); recorderTimer?.invalidate()
        recorder?.discard(); recorder = nil; speech.stopSpeaking(at: .immediate)
        session.delegate = nil; continueAfter = nil; stopSession(); arSession.pause(); UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(self)
    }
    private func fail(_ message: String) {
        guard !completed else { return }
        cancelSession(); spinner.stopAnimating(); finish.isEnabled = false; status.text = "Scan interrupted"
        let alert = UIAlertController(title: "Couldn’t finish scan", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in self?.onDone?() })
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
            let before = self.guidance
            switch instruction {
            case .moveCloseToWall: self.guidance = "Move closer to the wall"
            case .moveAwayFromWall: self.guidance = "Step back from the wall"
            case .slowDown: self.guidance = "Slow down"
            case .turnOnLight: self.guidance = "More light needed"
            case .lowTexture: self.guidance = "Aim at areas with more detail"
            case .normal: self.guidance = self.revealMode ? "Reveal mode · aim at the side of a door or window frame" : "Scan every wall and corner"
            @unknown default: self.guidance = "Scan every wall and corner"
            }
            guard self.guidance != before, instruction != .normal else { return }
            if self.setup.haptics { self.impact.impactOccurred(intensity: instruction == .slowDown ? 1 : 0.6) }
            if Date().timeIntervalSince(self.lastSpoken) > 6 { self.say(self.guidance) }
        }
    }
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.completed else { return }
            if let error { self.fail(error.localizedDescription); return }
            // A session the system ended on its own is processed like a finished one, so nothing is lost.
            if !self.processing { self.continueAfter = nil; self.finishScan() }
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

// A live top-down plan of what has been captured so far, with the device's position and heading. Each wall
// is drawn as a heat-map of half-metre strips: red not yet seen up close, yellow glimpsed, green well covered.
// Tap it to make it bigger.
final class MiniPlanView: UIView {
    var room = RoomProject()
    var camera: (position: PlanPoint, heading: PlanPoint)?
    var strips: [UUID: [Int]] = [:]          // per wall, how often each half-metre strip has been seen up close
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.88); isOpaque = false; contentMode = .redraw
        layer.cornerRadius = 16; clipsToBounds = true
        accessibilityLabel = "Live floor plan of the walls found so far. Tap to enlarge."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static func heat(_ count: Int) -> UIColor { count == 0 ? .systemRed : count < 4 ? .systemYellow : .systemGreen }
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
        PlanDrawing.draw(room, context: c, projection: projection, dimensions: false, furniture: false, grid: false, annotations: false)
        c.setLineWidth(rect.width > 200 ? 6 : 4); c.setLineCap(.butt)
        for wall in room.walls {
            guard let seen = strips[wall.id], !seen.isEmpty else { continue }
            for (i, count) in seen.enumerated() {
                let a = wall.a + (wall.b - wall.a) * (Double(i) / Double(seen.count)), b = wall.a + (wall.b - wall.a) * (Double(i + 1) / Double(seen.count))
                c.setStrokeColor(Self.heat(count).cgColor)
                c.move(to: projection.screen(a)); c.addLine(to: projection.screen(b)); c.strokePath()
            }
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
            let text = words(attribute.rawValue)
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
