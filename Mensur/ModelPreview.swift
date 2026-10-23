import SwiftUI
import SceneKit
import os

// SceneKit attaches its camera gestures on its own schedule; every pan it adds keeps drag-to-rotate but
// leaves scroll wheels and trackpad scrolling to Mensur's own zoom and slide.
final class RoomSceneView: SCNView {
    weak var scrollRecognizer: UIPanGestureRecognizer?
    private func release(_ g: UIGestureRecognizer) {
        if let pan = g as? UIPanGestureRecognizer, pan !== scrollRecognizer { pan.allowedScrollTypesMask = [] }
    }
    override func addGestureRecognizer(_ g: UIGestureRecognizer) { release(g); super.addGestureRecognizer(g) }
    override var gestureRecognizers: [UIGestureRecognizer]? {
        didSet { gestureRecognizers?.forEach(release) }
    }
}

struct ModelPreview: UIViewRepresentable {
    var room: RoomProject
    var showObjects: Bool
    var resetKey: Int
    var parts: [MeshPart]? = nil          // a prepared model, such as a whole building's floors stacked
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        var signature: String = ""; var resetKey = -1
        weak var view: SCNView?
        weak var scroll: UIPanGestureRecognizer?
        private var scrollTotal = CGPoint.zero
        // SceneKit adds its camera gestures lazily (once a scene is shown), so this runs after every update:
        // its recognizers keep drag-to-rotate and pinch but stop reacting to scroll wheels and trackpads.
        func claimScrolling() {
            guard let view else { return }
            for case let pan as UIPanGestureRecognizer in view.gestureRecognizers ?? [] where pan !== scroll { pan.allowedScrollTypesMask = [] }
        }
        // Mouse wheel and trackpad scrolling (Mac, or iPad with a pointer): vertical zooms toward the orbit
        // centre, horizontal slides the view left and right. Dragging still rotates (SceneKit's own control).
        @objc func scrolled(_ gesture: UIPanGestureRecognizer) {
            guard let view, let camera = view.pointOfView else { return }
            let t = gesture.translation(in: view); gesture.setTranslation(.zero, in: view)
            if gesture.state == .began { Logger(subsystem: "com.matthewsinitiere.Mensur", category: "3d").notice("scroll began") }
            scrollTotal.x += t.x; scrollTotal.y += t.y
            if gesture.state == .ended || gesture.state == .cancelled {
                // Local troubleshooting log of scroll direction and the resulting zoom distance.
                let distance = simd_distance(camera.simdWorldPosition, SIMD3<Float>(view.defaultCameraController.target.x, view.defaultCameraController.target.y, view.defaultCameraController.target.z))
                Logger(subsystem: "com.matthewsinitiere.Mensur", category: "3d").notice("scroll x \(Double(self.scrollTotal.x)) y \(Double(self.scrollTotal.y)) → distance \(Double(distance)) m")
                scrollTotal = .zero
            }
            let controller = view.defaultCameraController
            let target = SIMD3<Float>(controller.target.x, controller.target.y, controller.target.z)
            let distance = max(simd_distance(camera.simdWorldPosition, target), 0.01)
            let dy = Float(t.y) * (Setting.bool(Setting.invertScrollZoom, default: false) ? -1 : 1)
            if dy != 0 {
                let away = simd_normalize(camera.simdWorldPosition - target)
                camera.simdWorldPosition = target + away * min(max(distance * exp(-dy * 0.004), 0.3), 500)
            }
            if t.x != 0 {
                // The model follows the scroll direction, so the camera and its orbit centre move the other way.
                let shift = camera.simdWorldRight * Float(-t.x) * distance * 0.0015
                camera.simdWorldPosition += shift
                controller.target = SCNVector3(target + shift)
            }
        }
    }
    func makeUIView(context: Context) -> SCNView {
        let view = RoomSceneView(); view.allowsCameraControl = true; view.autoenablesDefaultLighting = false
        view.backgroundColor = UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.accessibilityLabel = "3D room model. Drag to orbit, pinch or scroll to zoom."
        context.coordinator.view = view
        let scroll = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []          // scroll events only; touches and clicks keep orbiting
        view.scrollRecognizer = scroll
        view.addGestureRecognizer(scroll)
        context.coordinator.scroll = scroll
        context.coordinator.claimScrolling()
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        let signature = String(describing: room.surfaces) + String(describing: room.objects) + "\(showObjects)"
            + (parts.map { "\($0.count):" + ($0.flatMap(\.vertices).prefix(64).map { "\($0.x),\($0.y),\($0.z)" }.joined()) } ?? "")
        guard context.coordinator.signature != signature || context.coordinator.resetKey != resetKey else { return }
        context.coordinator.signature = signature; context.coordinator.resetKey = resetKey
        let scene = SCNScene()
        // One mesh per wall (its pieces around openings merged) and per other part.
        struct Mesh { var name: String; var material: String; var vertices: [SCNVector3] = []; var normals: [SCNVector3] = []; var indices: [Int32] = [] }
        var meshes: [Mesh] = [], byName: [String: Int] = [:]
        let allParts = parts ?? ModelMesh.parts(room, includeObjects: showObjects)
        for part in allParts {
            // Flat-shaded: every face gets its own vertices and a normal pointing out of the part, so walls,
            // frames and furniture show their edges under the lights.
            let points = part.vertices.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
            guard !points.isEmpty else { continue }
            let name = part.material == "wall" ? String(part.name.prefix(41)) : part.name      // "wall_" + the wall's id
            let k = byName[name] ?? { meshes.append(Mesh(name: name, material: part.material)); byName[name] = meshes.count - 1; return meshes.count - 1 }()
            let centre = points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
            for f in part.faces where f.count >= 3 {
                let p = f.map { points[$0] }
                var n = simd_cross(p[1] - p[0], p[2] - p[0])
                guard simd_length(n) > 1e-9 else { continue }
                n = simd_normalize(n)
                let outward = simd_dot(n, p.reduce(SIMD3<Float>(repeating: 0), +) / Float(p.count) - centre)
                if outward < -1e-6 || (abs(outward) <= 1e-6 && n.y < 0) { n = -n }
                let base = Int32(meshes[k].vertices.count)
                meshes[k].vertices += p.map { SCNVector3($0.x, $0.y, $0.z) }; meshes[k].normals += p.map { _ in SCNVector3(n.x, n.y, n.z) }
                for i in 1..<(f.count - 1) { meshes[k].indices += [base, base + Int32(i), base + Int32(i + 1)] }
            }
        }
        for mesh in meshes where !mesh.indices.isEmpty {
            let data = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: mesh.indices.count / 3, bytesPerIndex: MemoryLayout<Int32>.size)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: mesh.vertices), SCNGeometrySource(normals: mesh.normals)], elements: [element])
            let material = SCNMaterial(); material.isDoubleSided = true; material.lightingModel = .lambert
            switch mesh.material {
            case "glass": material.diffuse.contents = UIColor(red: 0.55, green: 0.78, blue: 0.90, alpha: 0.28); material.writesToDepthBuffer = false
            case "frame": material.diffuse.contents = UIColor(white: 0.95, alpha: 1)
            case "mirror": material.diffuse.contents = UIColor(red: 0.52, green: 0.58, blue: 0.68, alpha: 1)
            case "floor": material.diffuse.contents = UIColor(red: 0.85, green: 0.84, blue: 0.79, alpha: 1)
            case "furniture": material.diffuse.contents = UIColor(red: 0.56, green: 0.66, blue: 0.60, alpha: 1)
            default: material.diffuse.contents = UIColor(red: 0.80, green: 0.83, blue: 0.86, alpha: 1)   // opaque: translucent walls showed a line wherever two pieces of a wall met
            }
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry); node.name = mesh.name
            if mesh.material == "glass" { node.renderingOrder = 10 }        // after the solid parts it shows through to
            scene.rootNode.addChildNode(node)
        }
        // Soft overall light, a key light from above and to one side, and a weaker fill from the other.
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 520
        scene.rootNode.addChildNode(ambient)
        for (direction, intensity) in [(SIMD3<Float>(-0.45, -1, -0.3), 620.0), (SIMD3<Float>(0.5, -0.4, 0.6), 260.0)] {
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional; light.light?.intensity = CGFloat(intensity)
            light.simdLook(at: simd_normalize(direction), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            scene.rootNode.addChildNode(light)
        }
        let bounds = parts == nil ? PlanBounds(room.activeSurfaces.flatMap { [$0.a, $0.b] }) : PlanBounds(allParts.flatMap { $0.vertices.map { PlanPoint(x: $0.x, z: $0.z) } })
        let top = parts == nil ? 1.6 : (allParts.flatMap { $0.vertices.map(\.y) }.max() ?? 1.6)
        let span = max(bounds.width, bounds.depth, top)
        let target = SCNVector3(Float(bounds.center.x), Float(top / 2), Float(bounds.center.z))
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zFar = 1000
        camera.position = SCNVector3(target.x + Float(span * 1.1), Float(span * 1.3 + 2), target.z + Float(span * 1.2))
        camera.look(at: target); scene.rootNode.addChildNode(camera)
        view.scene = scene; view.pointOfView = camera
        view.defaultCameraController.target = target
        context.coordinator.claimScrolling()
        DispatchQueue.main.async { context.coordinator.claimScrolling() }   // after SceneKit sets up its gestures
    }
}
