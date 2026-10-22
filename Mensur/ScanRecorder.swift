import ARKit
import RoomPlan
import Foundation
import os

// Measurements recorded alongside the RoomPlan scan to make the plan more accurate. No photos are kept.
//   wallpoints.bin      centres of LiDAR mesh triangles ARKit labels wall (Float32 x, y, z, world frame);
//                       wallpoints-upright.bin instead, all upright triangles, when ARKit doesn't label them
//   windowpoints.bin    centres of triangles labelled window, and doorpoints.bin door: openings RoomPlan missed
//   levels.json         floor and ceiling heights measured from floor- and ceiling-labelled triangles
//   windows.json        for each window RoomPlan found, up to three straightened greyscale close-ups of it
//                       (from the most head-on, closest views), for finding the dividers between panes
//   probe.json          what the scan session offered (depth, mesh), for diagnosis
final class ScanRecorder {
    let folder: URL
    private let queue = DispatchQueue(label: "Mensur.scanrecorder", qos: .utility)
    private let log = Logger(subsystem: "com.matthewsinitiere.Mensur", category: "capture")
    private var probed = false
    private var probeName = "probe.json"

    // centre, axis (the window's own x axis) and size: where RoomPlan had the window when this close-up was
    // taken (world frame), since its estimate changes during the scan. Absent in scans before October 22, 2026.
    struct WindowView: Codable {
        var width: Int; var height: Int; var pixels: Data; var score: Float; var time: Double
        var centre: [Float]? = nil; var axis: [Float]? = nil; var size: [Float]? = nil
    }
    struct WindowRecord: Codable { var id: UUID; var size: [Float]; var centre: [Float]; var views: [WindowView] }
    static let pixelsPerMeter: Float = 120
    private var windows: [UUID: WindowRecord] = [:]

    init?() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MensurScan-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
    }

    func reprobe(_ name: String) { probeName = name; probed = false }

    // Called a few times a second during the scan with the latest frame and RoomPlan's current windows.
    func consider(_ frame: ARFrame, session: ARSession, windows found: [CapturedRoom.Surface]) {
        if !probed { probed = true; probe(frame, session: session) }
        guard case .normal = frame.camera.trackingState else { return }
        let camera = frame.camera, eye = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        for w in found {
            let centre = SIMD3(w.transform.columns.3.x, w.transform.columns.3.y, w.transform.columns.3.z)
            let normal = simd_normalize(SIMD3(w.transform.columns.2.x, w.transform.columns.2.y, w.transform.columns.2.z))
            let toEye = eye - centre, distance = simd_length(toEye)
            let facing = abs(simd_dot(toEye / distance, normal))
            guard facing > 0.75, distance > 0.6, distance < 4.5 else { continue }
            // Prefer head-on and close (but far enough to see the whole window).
            let score = facing * min(1, 2.5 / distance)
            var record = windows[w.identifier] ?? WindowRecord(id: w.identifier, size: [w.dimensions.x, w.dimensions.y], centre: [centre.x, centre.y, centre.z], views: [])
            record.size = [w.dimensions.x, w.dimensions.y]; record.centre = [centre.x, centre.y, centre.z]
            // Keep the three best views, at least half a second apart (different moments, different blur).
            let worst = record.views.count < 3 ? 0 : record.views.map(\.score).min()!
            guard score > worst, !record.views.contains(where: { abs($0.time - frame.timestamp) < 0.5 && $0.score >= score }),
                  let view = Self.rectify(frame, window: w) else { windows[w.identifier] = record; continue }
            record.views.removeAll { abs($0.time - frame.timestamp) < 0.5 }
            record.views.append(WindowView(width: view.width, height: view.height, pixels: view.pixels, score: score, time: frame.timestamp,
                                           centre: [centre.x, centre.y, centre.z], axis: [w.transform.columns.0.x, w.transform.columns.0.y, w.transform.columns.0.z],
                                           size: [w.dimensions.x, w.dimensions.y]))
            record.views.sort { $0.score > $1.score }
            if record.views.count > 3 { record.views.removeLast(record.views.count - 3) }
            windows[w.identifier] = record
        }
    }

    // The window as seen in this frame, straightened onto its own plane: greyscale, row 0 at the top,
    // `pixelsPerMeter` across. Nil unless the whole window is in view.
    static func rectify(_ frame: ARFrame, window w: CapturedRoom.Surface) -> (width: Int, height: Int, pixels: Data)? {
        let image = frame.capturedImage, camera = frame.camera
        CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPlaneCount(image) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
        let iw = CVPixelBufferGetWidthOfPlane(image, 0), ih = CVPixelBufferGetHeightOfPlane(image, 0), row = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let k = camera.intrinsics, toCamera = camera.transform.inverse
        let sx = Float(iw) / Float(camera.imageResolution.width), sy = Float(ih) / Float(camera.imageResolution.height)
        func pixel(_ x: Float, _ y: Float) -> SIMD2<Float>? {
            let p = w.transform * SIMD4(x, y, 0, 1), c = toCamera * p
            guard c.z < -0.1 else { return nil }
            return SIMD2((k[0][0] * c.x / -c.z + k[2][0]) * sx, (k[1][1] * -c.y / -c.z + k[2][1]) * sy)
        }
        let hw = w.dimensions.x / 2, hh = w.dimensions.y / 2
        for (x, y) in [(-hw, -hh), (hw, -hh), (-hw, hh), (hw, hh)] {
            guard let p = pixel(x, y), p.x > 4, p.y > 4, p.x < Float(iw - 4), p.y < Float(ih - 4) else { return nil }
        }
        let width = max(8, min(600, Int(w.dimensions.x * pixelsPerMeter))), height = max(8, min(600, Int(w.dimensions.y * pixelsPerMeter)))
        var out = Data(count: width * height)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for j in 0..<height {
                let y = hh - (Float(j) + 0.5) / Float(height) * w.dimensions.y
                for i in 0..<width {
                    let x = -hw + (Float(i) + 0.5) / Float(width) * w.dimensions.x
                    guard let p = pixel(x, y) else { continue }
                    dst[j * width + i] = luma[min(ih - 1, max(0, Int(p.y))) * row + min(iw - 1, max(0, Int(p.x)))]
                }
            }
        }
        return (width, height, out)
    }

    // At the end of the scan: labelled LiDAR points and floor/ceiling levels from the scene mesh.
    func saveMesh(from session: ARSession) {
        let anchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        log.notice("mesh anchors at finish: \(anchors.count)")
        let windowRecords = Array(windows.values)
        queue.async { [self] in
            if let data = try? JSONEncoder().encode(windowRecords) { try? data.write(to: folder.appendingPathComponent("windows.json")) }
            guard !anchors.isEmpty else { return }
            let labelled = anchors.contains { $0.geometry.classification != nil }
            var walls = Data(), windows = Data(), doors = Data(), floors: [Float] = [], ceilings: [Float] = []
            for anchor in anchors {
                let g = anchor.geometry, vertices = g.vertices, faces = g.faces
                let bytes = faces.bytesPerIndex, perFace = faces.indexCountPerPrimitive
                func vertex(_ i: Int) -> SIMD3<Float> {
                    let p = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * i).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    let w = anchor.transform * SIMD4(p, 1); return SIMD3(w.x, w.y, w.z)
                }
                for f in 0..<faces.count {
                    var ids: [Int] = []
                    for k in 0..<perFace {
                        let at = faces.buffer.contents().advanced(by: (f * perFace + k) * bytes)
                        ids.append(bytes == 4 ? Int(at.assumingMemoryBound(to: UInt32.self).pointee) : Int(at.assumingMemoryBound(to: UInt16.self).pointee))
                    }
                    guard ids.count == 3 else { continue }
                    let a = vertex(ids[0]), b = vertex(ids[1]), c = vertex(ids[2]), centre = (a + b + c) / 3
                    func append(_ data: inout Data) {
                        var p = centre
                        withUnsafeBytes(of: &p.x) { data.append(contentsOf: $0) }; withUnsafeBytes(of: &p.y) { data.append(contentsOf: $0) }
                        withUnsafeBytes(of: &p.z) { data.append(contentsOf: $0) }
                    }
                    if let labels = g.classification {
                        let raw = labels.buffer.contents().advanced(by: labels.offset + labels.stride * f).assumingMemoryBound(to: UInt8.self).pointee
                        switch ARMeshClassification(rawValue: Int(raw)) ?? .none {
                        case .wall: append(&walls)
                        case .window: append(&windows)
                        case .door: append(&doors)
                        case .floor: floors.append(centre.y)
                        case .ceiling: ceilings.append(centre.y)
                        default: break
                        }
                    } else {
                        let n = simd_cross(b - a, c - a), len = simd_length(n)
                        if len > 1e-9, abs(n.y / len) < 0.3 { append(&walls) }
                    }
                }
            }
            try? walls.write(to: folder.appendingPathComponent(labelled ? "wallpoints.bin" : "wallpoints-upright.bin"))
            if !windows.isEmpty { try? windows.write(to: folder.appendingPathComponent("windowpoints.bin")) }
            if !doors.isEmpty { try? doors.write(to: folder.appendingPathComponent("doorpoints.bin")) }
            func median(_ v: [Float]) -> Float? { v.count < 200 ? nil : v.sorted()[v.count / 2] }
            let levels: [String: Any] = ["floor": median(floors) as Any, "ceiling": median(ceilings) as Any, "floorPoints": floors.count, "ceilingPoints": ceilings.count]
            if let data = try? JSONSerialization.data(withJSONObject: levels.compactMapValues { $0 is NSNull ? nil : $0 }) {
                try? data.write(to: folder.appendingPathComponent("levels.json"))
            }
        }
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        queue.async { [self] in
            log.notice("scan measurements saved: \(self.windows.count) window close-ups")
            DispatchQueue.main.async { done(self.folder) }
        }
    }
    func discard() { queue.async { [folder] in try? FileManager.default.removeItem(at: folder) } }

    private func probe(_ frame: ARFrame, session: ARSession) {
        var info: [String: Any] = [
            "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
            "configuration": session.configuration.map { String(describing: type(of: $0)) } ?? "none",
            "sceneDepth": frame.sceneDepth != nil, "imageSize": [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)]
        ]
        if let world = session.configuration as? ARWorldTrackingConfiguration {
            info["sceneReconstruction"] = world.sceneReconstruction.rawValue; info["frameSemantics"] = world.frameSemantics.rawValue
        }
        log.notice("capture probe: \(String(describing: info), privacy: .public)")
        if let json = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: folder.appendingPathComponent(probeName))
        }
    }
}
