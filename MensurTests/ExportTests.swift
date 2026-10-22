import XCTest
#if canImport(MensurCore)
@testable import MensurCore
#else
@testable import Mensur
#endif

final class ExportTests: XCTestCase {
    private func richRoom() -> RoomProject {
        var room = RoomProject.demo()
        for i in room.surfaces.indices where room.surfaces[i].kind == .wall { room.surfaces[i].wallType = .block; room.surfaces[i].thickness = 0.2 }
        room.markers = [PlanMarker(kind: .outlet, position: .init(x: 0.1, z: 2), height: 0.4, label: "Duplex"), PlanMarker(kind: .sink, position: .init(x: 4.5, z: 3.5))]
        room.stairs = [Stair(a: .init(x: 1, z: 3.6), b: .init(x: 3.5, z: 3.6), width: 0.8, risers: 12)]
        room.ceilings = [CeilingFeature(kind: .beam, a: .init(x: 0, z: 2), b: .init(x: 5, z: 2), width: 0.3, low: 2.4)]
        let space = RoomSummary(room).spaces[0]
        room.setSpaceLabel(SpaceLabel(name: "Studio & office", anchor: .zero, floorFinish: "LVP", wallFinish: "Paint"), for: space)
        return room
    }

    private func parses(_ xml: String) -> Bool {
        let parser = XMLParser(data: Data(xml.utf8))
        return parser.parse()
    }

    func testSVGIsWellFormedAndShowsTheRoom() {
        for style in PlanGeometry.DimensionStyle.allCases {
            let svg = SVGExporter.text(richRoom(), style: style)
            XCTAssertTrue(parses(svg), "\(style) SVG doesn't parse")
            XCTAssertTrue(svg.contains("Studio &amp; office"))
            XCTAssertTrue(svg.contains("F: LVP · W: Paint"))
        }
        let svg = SVGExporter.text(richRoom())
        XCTAssertTrue(svg.contains("class=\"hatch\""))                 // block walls are hatched
        XCTAssertTrue(svg.contains("<path class=\"door\""))            // the door swing
        XCTAssertTrue(svg.contains(">R</text>"))                       // the outlet marker
        XCTAssertTrue(svg.contains(">UP</text>"))
    }

    func testDXFHasLayersArcsAndDimensions() {
        let dxf = DXFExporter.text(richRoom())
        for layer in ["WALL-HATCH", "DOOR-SWINGS", "DIMENSIONS", "MARKERS", "STAIRS", "CEILING", "SPACES"] { XCTAssertTrue(dxf.contains("\n8\n\(layer)\n"), layer) }
        XCTAssertTrue(dxf.contains("\nARC\n")); XCTAssertTrue(dxf.contains("\nCIRCLE\n"))
        XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        // Group codes and values alternate: an even number of lines.
        XCTAssertEqual(dxf.split(separator: "\n", omittingEmptySubsequences: false).count % 2, 1)
    }

    func testIFCReferencesResolveAndElementsAreThere() throws {
        let room = richRoom()
        let ifc = IFCExporter.text(room)
        XCTAssertTrue(ifc.hasPrefix("ISO-10303-21;")); XCTAssertTrue(ifc.hasSuffix("END-ISO-10303-21;\n"))
        let entities = ifc.split(separator: "\n").filter { $0.hasPrefix("#") }
        var defined = Set<Int>()
        for (i, line) in entities.enumerated() {
            let id = Int(line.dropFirst().prefix { $0.isNumber })!
            XCTAssertEqual(id, i + 1); defined.insert(id)
        }
        let regex = try NSRegularExpression(pattern: "#(\\d+)")
        for line in entities {
            let body = String(line.drop { $0 != "=" })
            for m in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let ref = Int((body as NSString).substring(with: m.range(at: 1)))!
                XCTAssertTrue(defined.contains(ref), "dangling #\(ref)")
            }
        }
        XCTAssertEqual(entities.filter { $0.contains("=IFCWALL(") }.count, room.walls.count)
        XCTAssertEqual(entities.filter { $0.contains("=IFCDOOR(") }.count, 1)
        XCTAssertEqual(entities.filter { $0.contains("=IFCWINDOW(") }.count, 1)
        XCTAssertEqual(entities.filter { $0.contains("=IFCSPACE(") }.count, 1)
        XCTAssertTrue(ifc.contains("'Studio & office'"))
    }

    func testIFCGuidsAreCompressedAndUnique() {
        let guids = (0..<500).map { _ in IFCGuid.make() }
        XCTAssertEqual(Set(guids).count, 500)
        XCTAssertTrue(guids.allSatisfy { $0.count == 22 && "0123".contains($0.first!) })
        XCTAssertEqual(IFCGuid.make(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!), String(repeating: "0", count: 22))
    }

    func testColladaParsesWithEveryPart() {
        let parts = ModelMesh.parts(richRoom())
        let dae = ColladaExporter.text(parts, title: "Studio & office")
        XCTAssertTrue(parses(dae))
        XCTAssertEqual(dae.components(separatedBy: "<geometry ").count - 1, parts.count)
    }

    func testThickWallsMakeThickerModels() {
        let room = richRoom()
        let wall = room.walls[0]
        let patch = ModelMesh.parts(room).first { $0.name.hasPrefix("wall_\(wall.id.uuidString)") }!
        let zs = patch.vertices.map(\.z)
        XCTAssertEqual(zs.max()! - zs.min()!, 0.2, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(zs.max()!, 1e-6)                      // grown outward (z < 0), not into the room
        let closed = ModelMesh.parts(room, closedSolids: true).filter { $0.name.hasPrefix("wall_") }
        XCTAssertTrue(closed.allSatisfy { $0.faces.count == 6 })
    }
}
