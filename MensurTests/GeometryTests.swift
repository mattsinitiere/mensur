import XCTest
#if canImport(MensurCore)
@testable import MensurCore
#else
@testable import Mensur
#endif

final class GeometryTests: XCTestCase {
    func walls(_ points: [PlanPoint]) -> [PlanSurface] {
        points.indices.map { i in PlanSurface(label: "Wall \(i)", kind: .wall, a: points[i], b: points[(i + 1) % points.count]) }
    }
    func testRectangleArea() {
        XCTAssertEqual(Geometry.boundary(RoomProject.demo().walls).area ?? 0, 20, accuracy: 0.0001)
    }
    func testConcaveRoomDoesNotUseConvexHull() {
        let p: [PlanPoint] = [.init(x: 0,z: 0),.init(x: 4,z: 0),.init(x: 4,z: 2),.init(x: 2,z: 2),.init(x: 2,z: 4),.init(x: 0,z: 4)]
        XCTAssertEqual(Geometry.boundary(walls(p)).area ?? 0, 12, accuracy: 0.0001)
        let triangles = ModelMesh.triangulate(p)
        let area = triangles.reduce(0.0) { total, face in total + abs(Geometry.signedArea(face.map { p[$0] })) }
        XCTAssertEqual(area, 12, accuracy: 0.0001)
    }
    func testMissingWallSuppressesArea() {
        var w = RoomProject.demo().walls; w.removeLast()
        XCTAssertNil(Geometry.boundary(w).area)
    }
    func testCrossingWallsSuppressArea() {
        let p: [PlanPoint] = [.init(x: 0,z: 0),.init(x: 4,z: 4),.init(x: 0,z: 4),.init(x: 4,z: 0)]
        XCTAssertNil(Geometry.boundary(walls(p)).area)
    }
    func testDisconnectedLoopsSuppressArea() {
        var w = RoomProject.demo().walls
        var other = RoomProject.demo().walls
        for i in other.indices { other[i].a.x += 20; other[i].b.x += 20 }
        w += other
        XCTAssertNil(Geometry.boundary(w).area)
    }
    func testDuplicateWallSuppressesArea() {
        var w = RoomProject.demo().walls; w.append(w[0])
        XCTAssertNil(Geometry.boundary(w).area)
    }
    func testSmallEndpointGapDoesNotChangeExportedCoordinates() {
        var room = RoomProject.demo(); room.surfaces[0].b.x -= 0.02
        let before = room.surfaces[0].b
        XCTAssertNotNil(Geometry.boundary(room.walls).area)
        XCTAssertEqual(before, room.surfaces[0].b)
    }
    func testLargeGapSuppressesArea() {
        var w = RoomProject.demo().walls; w[0].b.x -= 0.3
        XCTAssertNil(Geometry.boundary(w).area)
    }
    func testCutoutDoesNotLeaveWallThroughWindow() {
        let room = RoomProject.demo(), window = room.activeSurfaces.first { $0.kind == .window }!
        let wall = room.walls.first { $0.id == window.parentID }!
        let patches = ModelMesh.parts(room).filter { $0.name.hasPrefix("wall_\(wall.id.uuidString)") }
        let inside = Vector3(x: window.midpoint.x, y: window.bottom + window.height / 2, z: window.midpoint.z)
        let hasSolid = patches.contains { part in
            let xs = part.vertices.map(\.x), ys = part.vertices.map(\.y), zs = part.vertices.map(\.z)
            return inside.x > xs.min()! && inside.x < xs.max()! && inside.y > ys.min()! && inside.y < ys.max()! && inside.z > zs.min()! && inside.z < zs.max()!
        }
        XCTAssertFalse(hasSolid)
        XCTAssertFalse(patches.isEmpty)
    }
    func testMirrorDoesNotCutWall() {
        let room = RoomProject.demo(), mirror = room.activeSurfaces.first { $0.kind == .mirror }!
        let patches = ModelMesh.parts(room).filter { $0.name.hasPrefix("wall_\(mirror.parentID!.uuidString)") }
        XCTAssertEqual(patches.count, 1)
    }
    func testOpeningBeyondParentIsFlagged() {
        var room = RoomProject.demo(); let i = room.surfaces.firstIndex { $0.kind == .window }!
        room.surfaces[i].b.z = 10
        XCTAssertNotNil(Geometry.openingIssue(room.surfaces[i], in: room))
    }
    func testCornerEditInvalidatesAdjacentLengthCheck() {
        var room = RoomProject.demo()
        room.surfaces[1].lengthCheck = .init(measuredMeters: 4, referenceMeters: 4)
        var wall = room.surfaces[0]; wall.b.x = 6
        Geometry.replace(wall, in: &room, joinCorners: true)
        XCTAssertEqual(room.surfaces[1].a.x, 6)
        XCTAssertNil(room.surfaces[1].lengthCheck)
    }
    func testExcludedWallExcludesAttachedOpenings() {
        var room = RoomProject.demo(); var wall = room.surfaces[1]; wall.excluded = true
        Geometry.replace(wall, in: &room, joinCorners: false)
        XCTAssertTrue(room.surfaces.filter { $0.parentID == wall.id }.allSatisfy(\.excluded))
    }
    func testStaleLengthCheckIsNotCurrent() {
        var s = RoomProject.demo().surfaces[0]
        s.lengthCheck = .init(measuredMeters: 4, referenceMeters: 5)
        XCTAssertFalse(s.hasCurrentLengthCheck)
        s.lengthCheck = .init(measuredMeters: 5, referenceMeters: 5)
        XCTAssertTrue(s.hasCurrentLengthCheck)
    }
    func testNoUnintentionalProjectScaleChange() {
        var room = RoomProject.demo(); let opposite = room.surfaces[2]
        var wall = room.surfaces[0]; wall.b.x = 5.1
        Geometry.replace(wall, in: &room, joinCorners: false)
        XCTAssertEqual(opposite, room.surfaces[2])
    }
    func testDXFUsesMetersAndSeparateLayers() {
        let dxf = DXFExporter.text(.demo())
        XCTAssertTrue(dxf.contains("WINDOWS")); XCTAssertTrue(dxf.contains("MIRRORS"))
        XCTAssertTrue(dxf.contains("5.000000")); XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        XCTAssertTrue(dxf.contains("METERS"))
    }
    func testOBJFaceIndicesAreValid() {
        let obj = ModelMesh.obj(.demo()), lines = obj.split(separator: "\n")
        let count = lines.filter { $0.hasPrefix("v ") }.count
        XCTAssertGreaterThan(count, 0)
        for face in lines.filter({ $0.hasPrefix("f ") }) {
            for token in face.split(separator: " ").dropFirst() {
                let index = Int(token)!
                XCTAssertTrue(index >= 1 && index <= count)
            }
        }
    }
    func testRoundTripPreservesMeasurementsAndExclusions() throws {
        var room = RoomProject.demo(); room.surfaces[0].lengthCheck = .init(measuredMeters: 5, referenceMeters: 4.98)
        room.surfaces[1].excluded = true
        let decoded = try JSONDecoder().decode(RoomProject.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(room.surfaces, decoded.surfaces)
        XCTAssertNoThrow(try decoded.validated())
    }
    func testRejectsInvalidDimensionsAndDuplicateIDs() {
        var room = RoomProject.demo(); room.surfaces[0].height = -1
        XCTAssertThrowsError(try room.validated())
        room = .demo(); room.surfaces.append(room.surfaces[0]); XCTAssertThrowsError(try room.validated())
        room = .demo(); room.schemaVersion = 999; XCTAssertThrowsError(try room.validated())
    }
    func reversed(_ s: PlanSurface) -> PlanSurface { var r = s; (r.a, r.b) = (s.b, s.a); return r }
    func assertNormalsFaceInside(_ walls: [PlanSurface], _ inside: [PlanPoint], file: StaticString = #filePath, line: UInt = #line) {
        let boundary = Geometry.boundary(walls)
        for wall in walls {
            let n = Geometry.inwardNormal(wall, walls: walls, boundary: boundary)
            XCTAssertEqual(n.magnitude, 1, accuracy: 1e-9, file: file, line: line)
            XCTAssertTrue(Geometry.contains(inside, wall.midpoint + n * 0.1), "\(wall.label) faces out", file: file, line: line)
        }
    }
    func testInwardNormalIgnoresCapturedWallDirection() {
        var w = RoomProject.demo().walls
        for i in [1, 3] { w[i] = reversed(w[i]) }
        assertNormalsFaceInside(w, [.init(x: 0, z: 0), .init(x: 5, z: 0), .init(x: 5, z: 4), .init(x: 0, z: 4)])
        w = w.map(reversed)
        assertNormalsFaceInside(w, [.init(x: 0, z: 0), .init(x: 5, z: 0), .init(x: 5, z: 4), .init(x: 0, z: 4)])
    }
    func testInwardNormalInConcaveRoom() {
        let p: [PlanPoint] = [.init(x: 0,z: 0),.init(x: 4,z: 0),.init(x: 4,z: 2),.init(x: 2,z: 2),.init(x: 2,z: 4),.init(x: 0,z: 4)]
        var w = walls(p); w[2] = reversed(w[2]); w[3] = reversed(w[3])
        assertNormalsFaceInside(w, p)
    }
    func testInwardNormalWithoutClosedBoundaryFacesCentroid() {
        var w = RoomProject.demo().walls; w.removeLast(); w[0] = reversed(w[0])
        XCTAssertNil(Geometry.boundary(w).area)
        let n = Geometry.inwardNormal(w[0], walls: w, boundary: Geometry.boundary(w))
        XCTAssertGreaterThan(n.z, 0.99)
    }
    func testUprightTextAngleReadsLeftToRightOrBottomToTop() {
        XCTAssertEqual(Geometry.uprightTextAngle(dx: 1, dy: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(Geometry.uprightTextAngle(dx: -1, dy: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(Geometry.uprightTextAngle(dx: 0, dy: 1), -.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(Geometry.uprightTextAngle(dx: 0, dy: -1), -.pi / 2, accuracy: 1e-12)
        // Scanned walls are rarely exactly vertical; both sides of vertical must read the same way.
        for dy in [1.0, -1.0] {
            for dx in [0.0002, -0.0002, 0.1, -0.1] {
                XCTAssertEqual(Geometry.uprightTextAngle(dx: dx, dy: dy), -.pi / 2, accuracy: 0.11)
            }
        }
        XCTAssertEqual(Geometry.uprightTextAngle(dx: -1, dy: -1), .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(Geometry.uprightTextAngle(dx: -1, dy: 1), -.pi / 4, accuracy: 1e-12)
    }
    func testTapPrefersOpeningOverItsParentWall() {
        let room = RoomProject.demo(), window = room.activeSurfaces.first { $0.kind == .window }!
        XCTAssertEqual(Geometry.surface(at: window.midpoint, in: room.activeSurfaces, threshold: 0.3, openingBias: 0.1), window.id)
        XCTAssertEqual(Geometry.surface(at: window.midpoint + PlanPoint(x: 0.02, z: 0), in: room.activeSurfaces, threshold: 0.3, openingBias: 0.1), window.id)
    }
    func testTapBesideOpeningSelectsWall() {
        let room = RoomProject.demo(), window = room.activeSurfaces.first { $0.kind == .window }!
        let beyond = PlanPoint(x: 5, z: window.b.z + 0.25)
        XCTAssertEqual(Geometry.surface(at: beyond, in: room.activeSurfaces, threshold: 0.3, openingBias: 0.1), window.parentID)
        XCTAssertNil(Geometry.surface(at: .init(x: 2.5, z: 2), in: room.activeSurfaces, threshold: 0.3, openingBias: 0.1))
        XCTAssertNil(Geometry.surface(at: window.midpoint, in: [], threshold: 0.3, openingBias: 0.1))
    }
    // 5 × 4 m room whose (0,0) corner RoomPlan closed with two short pieces around a boxed column.
    func boxedCornerRoom() -> RoomProject {
        var room = RoomProject(name: "Boxed corner")
        room.surfaces = [
            PlanSurface(label: "South", kind: .wall, a: .init(x: 0.4, z: 0), b: .init(x: 5, z: 0)),
            PlanSurface(label: "East", kind: .wall, a: .init(x: 5, z: 0), b: .init(x: 5, z: 4)),
            PlanSurface(label: "North", kind: .wall, a: .init(x: 5, z: 4), b: .init(x: 0, z: 4)),
            PlanSurface(label: "West", kind: .wall, a: .init(x: 0, z: 4), b: .init(x: 0, z: 0.3)),
            PlanSurface(label: "Piece 1", kind: .wall, a: .init(x: 0, z: 0.3), b: .init(x: 0.4, z: 0.3)),
            PlanSurface(label: "Piece 2", kind: .wall, a: .init(x: 0.4, z: 0.3), b: .init(x: 0.4, z: 0))
        ]
        return room
    }
    func testSquareCornersExtendsWallsThroughBoxedCorner() throws {
        var room = boxedCornerRoom()
        XCTAssertEqual(Geometry.squareCorners(&room), 1)
        let south = room.surfaces[0], west = room.surfaces[3]
        XCTAssertEqual(south.a.distance(to: .zero), 0, accuracy: 1e-9)
        XCTAssertEqual(west.b.distance(to: .zero), 0, accuracy: 1e-9)
        XCTAssertTrue(room.surfaces[4].excluded && room.surfaces[5].excluded)
        XCTAssertEqual(Geometry.boundary(room.walls).area ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(Geometry.squareCorners(&room), 0, "already square")
        XCTAssertNoThrow(try room.validated())
    }
    func testSquareCornersKeepsOpeningsAndRestores() {
        var room = boxedCornerRoom()
        let window = Geometry.attach(PlanSurface(label: "Window", kind: .window, a: .zero, b: .zero), to: room.surfaces[0], offset: 1, width: 1.2)
        room.surfaces.append(window)
        let before = room.surfaces
        Geometry.squareCorners(&room)
        XCTAssertEqual(room.surfaces.last!.a, window.a); XCTAssertEqual(room.surfaces.last!.b, window.b)
        XCTAssertNil(Geometry.openingIssue(room.surfaces.last!, in: room))
        XCTAssertEqual(Geometry.restoreCleanup(&room), 4)
        XCTAssertEqual(room.surfaces.map(\.a), before.map(\.a)); XCTAssertEqual(room.surfaces.map(\.b), before.map(\.b))
        XCTAssertEqual(room.surfaces.map(\.excluded), before.map(\.excluded))
        XCTAssertTrue(room.surfaces.allSatisfy { $0.autoCleanup == nil })
    }
    func testSquareCornersLeavesRealGeometryAlone() {
        var hosted = boxedCornerRoom()
        hosted.surfaces.append(Geometry.attach(PlanSurface(label: "Hatch", kind: .opening, a: .zero, b: .zero), to: hosted.surfaces[4], offset: 0.05, width: 0.3))
        XCTAssertTrue(Geometry.squarableCorners(hosted).isEmpty, "a piece hosting an opening is real")
        // A short jog between two parallel walls is a step in the wall, not a corner.
        var step = RoomProject(name: "Step")
        step.surfaces = [PlanSurface(label: "A", kind: .wall, a: .init(x: 0, z: 0), b: .init(x: 3, z: 0)),
                         PlanSurface(label: "Jog", kind: .wall, a: .init(x: 3, z: 0), b: .init(x: 3, z: 0.3)),
                         PlanSurface(label: "B", kind: .wall, a: .init(x: 3, z: 0.3), b: .init(x: 6, z: 0.3))]
        XCTAssertTrue(Geometry.squarableCorners(step).isEmpty)
        var demo = RoomProject.demo()
        XCTAssertEqual(Geometry.squareCorners(&demo), 0)
    }
    func testStubsAndBumpsAreFoundButCornersAreNot() {
        var room = RoomProject.demo()
        let stub = PlanSurface(label: "Stub", kind: .wall, a: .init(x: 2, z: 0), b: .init(x: 2, z: 0.3))
        let bump1 = PlanSurface(label: "Bump 1", kind: .wall, a: .init(x: 5, z: 3), b: .init(x: 4.8, z: 3.1))
        let bump2 = PlanSurface(label: "Bump 2", kind: .wall, a: .init(x: 4.8, z: 3.1), b: .init(x: 5, z: 3.25))
        room.surfaces += [stub, bump1, bump2]
        XCTAssertEqual(Set(Geometry.wallStubs(room)), [stub.id, bump1.id, bump2.id])
        XCTAssertEqual(Geometry.hideStubs(&room), 3)
        XCTAssertTrue(Geometry.wallStubs(room).isEmpty)
        XCTAssertTrue(Geometry.wallStubs(boxedCornerRoom()).isEmpty, "corner pieces touch two walls")
    }
    func testUnchangedWallSaveDoesNotSnapNeighbours() {
        var room = RoomProject.demo(); room.surfaces[1].a.x += 0.05   // 5 cm gap at a corner, within join tolerance
        let before = room.surfaces
        Geometry.replace(room.surfaces[0], in: &room, joinCorners: true)
        XCTAssertEqual(room.surfaces, before)
        var moved = room.surfaces[0]; moved.b.x = 6
        Geometry.replace(moved, in: &room, joinCorners: true)
        XCTAssertEqual(room.surfaces[1].a.x, 6, "a moved end still pulls its neighbour")
    }
    func testDropInvalidGeometryKeepsTheRestOfACapture() throws {
        var room = RoomProject.demo()
        room.surfaces.append(PlanSurface(label: "Sliver", kind: .wall, a: .zero, b: .init(x: 0.001, z: 0)))
        room.surfaces.append(PlanSurface(label: "Bad", kind: .wall, a: .init(x: .nan, z: 0), b: .zero))
        var orphan = PlanSurface(label: "Orphan", kind: .door, a: .init(x: 1, z: 0), b: .init(x: 2, z: 0)); orphan.parentID = UUID()
        room.surfaces.append(orphan)
        room.objects.append(PlanObject(label: "Flat", center: .init(x: 0, y: 0, z: 0), size: .init(x: 1, y: 0, z: 1), yaw: 0))
        XCTAssertThrowsError(try room.validated())
        XCTAssertEqual(room.dropInvalidGeometry(), 3)
        XCTAssertNoThrow(try room.validated())
        XCTAssertNil(room.surfaces.last!.parentID)
        XCTAssertEqual(room.walls.count, 4)
        XCTAssertEqual(RoomProject.demo().surfaces.count + 1, room.surfaces.count)
    }
    func testPlaceOpeningCentresOnTapAndStaysInsideWall() {
        var room = RoomProject.demo(); let wall = room.surfaces[0]   // 5 m along x, 2.7 m high
        let window = Geometry.placeOpening(.window, on: wall, near: .init(x: 2.5, z: 0.1), label: "Window")
        XCTAssertEqual(window.a.x, 1.9, accuracy: 1e-9); XCTAssertEqual(window.b.x, 3.1, accuracy: 1e-9)
        XCTAssertEqual(window.parentID, wall.id)
        let atEnd = Geometry.placeOpening(.door, on: wall, near: .init(x: 4.95, z: 0), label: "Door")
        XCTAssertEqual(atEnd.b.x, 5, accuracy: 1e-9)
        room.surfaces += [window, atEnd]
        XCTAssertNil(Geometry.openingIssue(window, in: room)); XCTAssertNil(Geometry.openingIssue(atEnd, in: room))
    }
    func testCleanupRecordIsBackwardCompatible() throws {
        let plain = try JSONEncoder().encode(RoomProject.demo())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("autoCleanup"), "unchanged projects keep the old format")
        var room = boxedCornerRoom(); Geometry.squareCorners(&room)
        let decoded = try JSONDecoder().decode(RoomProject.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded.surfaces, room.surfaces)
    }
    func testSpacesSplitByPartitionAtTJunctions() {
        var w = walls([.init(x: 0, z: 0), .init(x: 6, z: 0), .init(x: 6, z: 4), .init(x: 0, z: 4)])
        w.append(PlanSurface(label: "Partition", kind: .wall, a: .init(x: 3, z: 0), b: .init(x: 3, z: 4)))
        w.append(PlanSurface(label: "Stub", kind: .wall, a: .init(x: 1, z: 4), b: .init(x: 1, z: 3.6)))
        XCTAssertNil(Geometry.boundary(w).area)
        let layout = Geometry.spaces(w)
        XCTAssertEqual(layout.spaces.map(\.area), [12, 12])
        XCTAssertEqual(layout.total ?? 0, 24, accuracy: 1e-9)
        XCTAssertEqual(layout.perimeter, 20, accuracy: 1e-9)
        XCTAssertEqual(Geometry.floorArea(w) ?? 0, 24, accuracy: 1e-9)
    }
    func testSpacesFromCrossingWallsAndConcaveRooms() {
        // An L-shaped room plus a wall that overshoots a corner, crossing its neighbour.
        let p: [PlanPoint] = [.init(x: 0,z: 0),.init(x: 4,z: 0),.init(x: 4,z: 2),.init(x: 2,z: 2),.init(x: 2,z: 4),.init(x: 0,z: 4)]
        var w = walls(p); w[0].a.x = -0.3
        XCTAssertEqual(Geometry.spaces(w).total ?? 0, 12, accuracy: 1e-9)
        let label = Geometry.labelPoint(p)
        XCTAssertTrue(Geometry.contains(p, label, margin: 0.5), "label sits inside the L, clear of the notch")
    }
    func testOpenRoomHasNoSpacesAndSingleLoopMatchesBoundary() {
        var open = RoomProject.demo().walls; open.removeLast()
        XCTAssertNil(Geometry.spaces(open).total)
        XCTAssertNil(Geometry.floorArea(open))
        XCTAssertEqual(Geometry.spaces(RoomProject.demo().walls).total ?? 0, 20, accuracy: 1e-9)
        var curved = RoomProject.demo().walls; curved[0].geometryCaveat = "Curved"
        XCTAssertNil(Geometry.floorArea(curved))
    }
    func testSummaryTagsOpeningsAndWeightsCeilingHeight() {
        var room = RoomProject.demo(); room.surfaces[0].height = 3.0   // 5 m wall at 3.0, the rest at 2.7
        let summary = RoomSummary(room)
        XCTAssertEqual(summary.totalArea ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(summary.perimeter ?? 0, 18, accuracy: 1e-9)
        XCTAssertEqual(summary.ceilingHeight ?? 0, (3.0 * 5 + 2.7 * 13) / 18, accuracy: 1e-9)
        XCTAssertEqual(summary.openings.map(\.tag), ["D1", "W1", "M1"])
        XCTAssertEqual(summary.openings.first?.wall, "Wall 1")
    }
    func testDominantAngleFindsTheRoomsAxes() {
        let rect: [PlanPoint] = [.init(x: 0, z: 0), .init(x: 4, z: 0), .init(x: 4, z: 3), .init(x: 0, z: 3)]
        for degrees in [0.0, 16, 30, -20, 44] {
            let r = degrees * .pi / 180
            var w = walls(rect.map { Geometry.rotate($0, by: r) }); w[1] = reversed(w[1])
            XCTAssertEqual(Geometry.dominantAngle(w), r, accuracy: 1e-9)
        }
        let p = PlanPoint(x: 1.5, z: -2), back = Geometry.rotate(Geometry.rotate(p, by: 0.7), by: -0.7)
        XCTAssertEqual(back.distance(to: p), 0, accuracy: 1e-12)
    }
    func partitionedRoom() -> RoomProject {
        var room = RoomProject(name: "Suite")
        room.surfaces = walls([.init(x: 0, z: 0), .init(x: 6, z: 0), .init(x: 6, z: 4), .init(x: 0, z: 4)])
            + [PlanSurface(label: "Partition", kind: .wall, a: .init(x: 4, z: 0), b: .init(x: 4, z: 4))]
        return room
    }
    func testSpaceNamesFollowTheirSpaceAfterEdits() throws {
        var room = partitionedRoom()
        let spaces = RoomSummary(room).spaces
        XCTAssertEqual(room.spaceNames(spaces), ["Space A", "Space B"])
        room.nameSpace(spaces[1], "  Office  "); room.nameSpace(spaces[0], "Showroom")
        XCTAssertEqual(RoomSummary(room).spaceNames, ["Showroom", "Office"])
        // Move the partition: both spaces change shape, the names stay with them.
        var partition = room.surfaces[4]; partition.a.x = 3.5; partition.b.x = 3.5
        Geometry.replace(partition, in: &room, joinCorners: false)
        XCTAssertEqual(RoomSummary(room).spaceNames, ["Showroom", "Office"])
        room.nameSpace(RoomSummary(room).spaces[1], "")
        XCTAssertEqual(RoomSummary(room).spaceNames, ["Showroom", "Space B"])
        room.address = "1 Main St, Springfield"
        let decoded = try JSONDecoder().decode(RoomProject.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded.address, room.address); XCTAssertEqual(decoded.spaceLabels, room.spaceLabels)
        XCTAssertNoThrow(try decoded.validated())
        room.address = String(repeating: "x", count: 301); XCTAssertThrowsError(try room.validated())
    }
    func testProjectsWithoutAddressOrNamesStillDecode() throws {
        let json = try JSONEncoder().encode(RoomProject.demo())
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("address"))
        let room = try JSONDecoder().decode(RoomProject.self, from: json)
        XCTAssertNil(room.address); XCTAssertEqual(RoomSummary(room).spaceNames, ["Space A"])
    }
    // MARK: Sync planning
    let phone = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, mac = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }
    func entry(_ id: UUID, _ t: Double, _ digest: String, _ originals: [String] = []) -> SyncEntry { .init(id: id, updatedAt: at(t), digest: digest, originals: originals) }
    func plans(_ phoneEntries: [SyncEntry], _ macEntries: [SyncEntry], base: [UUID: Date] = [:],
               phoneDeleted: [UUID: Date] = [:], macDeleted: [UUID: Date] = [:]) -> (phone: SyncPlan, mac: SyncPlan) {
        let p = SyncManifest(device: phone, entries: phoneEntries, tombstones: phoneDeleted)
        let m = SyncManifest(device: mac, entries: macEntries, tombstones: macDeleted)
        return (SyncPlan.make(local: p, remote: m, base: base), SyncPlan.make(local: m, remote: p, base: base))
    }
    func testSyncSendsNewRoomsAndTheirOriginalsBothWays() {
        let a = UUID(), b = UUID()
        let (p, m) = plans([entry(a, 0, "a", SyncPlan.originalFiles)], [entry(b, 0, "b")])
        XCTAssertEqual(p.send, [a]); XCTAssertEqual(p.sendOriginals[a], SyncPlan.originalFiles); XCTAssertEqual(p.expect, [b])
        XCTAssertEqual(m.send, [b]); XCTAssertEqual(m.expect, [a])
        XCTAssertEqual(p.base, m.base)
    }
    func testSyncSkipsIdenticalCopiesAndNewerOneSideWins() {
        let same = UUID(), edited = UUID()
        let base = [same: at(0), edited: at(0)]
        let (p, m) = plans([entry(same, 0, "x"), entry(edited, 50, "new")], [entry(same, 0, "x"), entry(edited, 0, "old")], base: base)
        XCTAssertEqual(p.send, [edited]); XCTAssertTrue(p.expect.isEmpty); XCTAssertTrue(p.keepConflictCopy.isEmpty)
        XCTAssertEqual(m.expect, [edited]); XCTAssertTrue(m.keepConflictCopy.isEmpty, "only one side changed")
        XCTAssertEqual(p.base[edited], at(50)); XCTAssertEqual(p.base, m.base)
    }
    func testSyncConflictKeepsTheOlderEditAsACopy() {
        let id = UUID()
        let (p, m) = plans([entry(id, 30, "phone edit")], [entry(id, 20, "mac edit")], base: [id: at(0)])
        XCTAssertEqual(p.send, [id]); XCTAssertTrue(p.keepConflictCopy.isEmpty)
        XCTAssertEqual(m.expect, [id]); XCTAssertEqual(m.keepConflictCopy, [id], "the Mac keeps its losing edit")
        // Same second: both sides pick the same winner.
        let (p2, m2) = plans([entry(id, 30, "a")], [entry(id, 30, "b")], base: [id: at(0)])
        XCTAssertEqual(p2.send.count + m2.send.count, 1); XCTAssertEqual(p2.keepConflictCopy.count + m2.keepConflictCopy.count, 1)
    }
    func testSyncDeletionsWinOnlyOverOlderVersions() {
        let gone = UUID(), revived = UUID()
        let (p, m) = plans([], [entry(gone, 10, "g"), entry(revived, 90, "r")], base: [gone: at(10), revived: at(10)],
                           phoneDeleted: [gone: at(50), revived: at(50)])
        XCTAssertEqual(m.moveToRecentlyDeleted, [gone]); XCTAssertTrue(p.expect.contains(revived)); XCTAssertFalse(p.expect.contains(gone))
        XCTAssertEqual(m.send, [revived], "edited after the delete, so it comes back")
    }
    // MARK: Dragging on the plan
    func testWallEndSnapsToCornerOrStraightens() {
        let room = RoomProject.demo(), wall = room.surfaces[0]          // (0,0) → (5,0)
        let snapped = PlanEdit.moveWallEnd(wall, atA: false, to: .init(x: 5.05, z: 3.97), in: room, snap: 0.1)!
        XCTAssertEqual(snapped.b, .init(x: 5, z: 4), "snaps to the room's far corner")
        let straight = PlanEdit.moveWallEnd(wall, atA: false, to: .init(x: 6, z: 0.15), in: room, snap: 0.1)!
        XCTAssertEqual(straight.b.z, 0, accuracy: 1e-9); XCTAssertEqual(straight.b.x, 6.0019, accuracy: 0.001)
        let angled = PlanEdit.moveWallEnd(wall, atA: false, to: .init(x: 6, z: 1), in: room, snap: 0.1)!
        XCTAssertEqual(angled.b, .init(x: 6, z: 1), "a deliberate angle is kept")
        XCTAssertNil(PlanEdit.moveWallEnd(wall, atA: false, to: .init(x: 0.05, z: 0), in: room, snap: 0.01), "too short")
    }
    func testDraggedCornerMovesConnectedWalls() {
        var room = RoomProject.demo(), wall = room.surfaces[0]
        let moved = PlanEdit.moveWallEnd(wall, atA: false, to: .init(x: 6, z: 0), in: room, snap: 0.05)!
        Geometry.replace(moved, in: &room, joinCorners: true)
        XCTAssertEqual(room.surfaces[1].a, .init(x: 6, z: 0), "the next wall's end follows")
        wall = room.surfaces[0]
        Geometry.replace(PlanEdit.moveWall(wall, by: .init(x: 0.3, z: -0.5)), in: &room, joinCorners: true)
        XCTAssertEqual(room.surfaces[0].a.x, wall.a.x, accuracy: 1e-9, "sliding along the wall is ignored")
        XCTAssertEqual(room.surfaces[0].a.z, -0.5, accuracy: 1e-9); XCTAssertEqual(room.surfaces[3].b.z, -0.5, accuracy: 1e-9)
        XCTAssertNotNil(Geometry.boundary(room.walls).area)
    }
    func testOpeningSlidesStaysInsideAndChangesWall() {
        let room = RoomProject.demo(), window = room.surfaces[5]        // 1.8 m on Wall 2 (x = 5, z 1…2.8)
        let slid = PlanEdit.moveOpening(window, in: room, from: .init(x: 5, z: 1.5), to: .init(x: 5, z: 2.0), reach: 0.3)!
        XCTAssertEqual(slid.a.z, 1.5, accuracy: 1e-9); XCTAssertEqual(slid.length, 1.8, accuracy: 1e-9)
        let clamped = PlanEdit.moveOpening(window, in: room, from: .init(x: 5, z: 1.5), to: .init(x: 5, z: 9), reach: 0.3)!
        XCTAssertEqual(max(clamped.a.z, clamped.b.z), 4, accuracy: 1e-9, "stops at the wall's end")
        let moved = PlanEdit.moveOpening(window, in: room, from: .init(x: 5, z: 1.5), to: .init(x: 2.5, z: 0.1), reach: 0.3)!
        XCTAssertEqual(moved.parentID, room.surfaces[0].id, "dropped near Wall 1")
        XCTAssertEqual(moved.a.z, 0, accuracy: 1e-9); XCTAssertEqual(moved.midpoint.x, 2.5, accuracy: 1e-9)
        var placed = room; placed.surfaces[5] = moved
        XCTAssertNil(Geometry.openingIssue(moved, in: placed))
    }
    func testOpeningEndResizes() {
        let room = RoomProject.demo(), door = room.surfaces[4]          // Entry: x 0.5…1.4 on Wall 1
        let wider = PlanEdit.resizeOpening(door, atA: false, in: room, to: .init(x: 1.8, z: 0.2))!
        XCTAssertEqual(wider.a.x, 0.5, accuracy: 1e-9); XCTAssertEqual(wider.b.x, 1.8, accuracy: 1e-9)
        let flipped = PlanEdit.resizeOpening(door, atA: true, in: room, to: .init(x: 2.0, z: 0))!
        XCTAssertEqual(flipped.a.x, 1.4, accuracy: 1e-9); XCTAssertEqual(flipped.b.x, 2.0, accuracy: 1e-9)
        XCTAssertNil(PlanEdit.resizeOpening(door, atA: false, in: room, to: .init(x: 0.55, z: 0)))
    }
    func testImperialRoundingCarriesToNextFoot() {
        XCTAssertEqual(DisplayUnits.imperial.length(0.304799), "1′ 0.00″")
        XCTAssertEqual(DisplayUnits.metric.length(1.234), "1.23 m")
    }

    // MARK: Walls from the LiDAR mesh

    // Points every 2 cm along a segment, as the mesh would give on a wall surface.
    private func wallPoints(_ a: PlanPoint, _ b: PlanPoint, jitter: Double = 0.005) -> [PlanPoint] {
        let n = Int(a.distance(to: b) / 0.02)
        return (0...n).map { k in
            let p = a + (b - a) * (Double(k) / Double(n))
            return p + PlanPoint(x: (k % 3 == 0 ? 1 : -1) * jitter, z: (k % 2 == 0 ? 1 : -1) * jitter)
        }
    }
    func testWallsMoveOntoLidarSurfaceWithCornersAndOpenings() {
        var room = RoomProject.demo()           // 5 × 4 m; RoomPlan's wall 2 (x = 5) is 10 cm too far in
        let real = [PlanPoint(x: 0, z: 0), .init(x: 5.1, z: 0), .init(x: 5.1, z: 4), .init(x: 0, z: 4)]
        let points = (0..<4).flatMap { wallPoints(real[$0], real[($0 + 1) % 4]) }
        let report = WallFit.apply(&room, points: points)
        XCTAssertEqual(report.aligned, 1)
        let wall2 = room.surfaces[1]
        XCTAssertEqual(wall2.a.x, 5.1, accuracy: 0.01); XCTAssertEqual(wall2.b.x, 5.1, accuracy: 0.01)
        XCTAssertEqual(room.surfaces[0].b.x, 5.1, accuracy: 0.01, "the joined corner follows")
        XCTAssertEqual(room.surfaces[2].a.x, 5.1, accuracy: 0.01)
        let window = room.surfaces[5]
        XCTAssertEqual(window.a.x, 5.1, accuracy: 0.01); XCTAssertEqual(window.length, 1.8, accuracy: 0.01, "the window keeps its size")
        XCTAssertEqual(window.a.z, 1, accuracy: 0.02, "and its place along the wall")
        XCTAssertEqual(Geometry.restoreCleanup(&room) > 0, true)
        XCTAssertEqual(room.surfaces[1].a.x, 5, accuracy: 1e-9, "Restore puts RoomPlan's wall back")
    }
    func testFurtherThanTheSearchBandIsLeftAlone() {
        var room = RoomProject.demo()
        let real = [PlanPoint(x: 0, z: 0), .init(x: 5.5, z: 0), .init(x: 5.5, z: 4), .init(x: 0, z: 4)]
        let points = wallPoints(real[0], real[1]) + wallPoints(real[1], real[2]) + wallPoints(real[2], real[3]) + wallPoints(real[3], real[0])
        WallFit.apply(&room, points: points)
        XCTAssertEqual(room.surfaces[1].a.x, 5, accuracy: 1e-9, "50 cm away is a different surface, not this wall")
    }
    func testUnconfirmedStubIsHiddenAndMissingWallIsAdded() {
        var room = RoomProject.demo()
        room.surfaces.append(PlanSurface(label: "Stub", kind: .wall, a: .init(x: 2, z: 4), b: .init(x: 2, z: 3.6), height: 2.7))
        let p = [PlanPoint(x: 0, z: 0), .init(x: 5, z: 0), .init(x: 5, z: 4), .init(x: 0, z: 4)]
        var points = (0..<4).flatMap { wallPoints(p[$0], p[($0 + 1) % 4]) }
        points += wallPoints(.init(x: 2.5, z: 1), .init(x: 2.5, z: 3))        // a 2 m partition RoomPlan missed
        let report = WallFit.apply(&room, points: points)
        XCTAssertEqual(report.unconfirmed, 1)
        XCTAssertTrue(room.surfaces.first { $0.label == "Stub" }!.excluded)
        XCTAssertEqual(report.added, 1)
        let added = room.walls.last!
        XCTAssertEqual(added.a.x, 2.5, accuracy: 0.03); XCTAssertEqual(added.length, 2, accuracy: 0.1)
        XCTAssertNotNil(added.reviewNote)
        Geometry.restoreCleanup(&room)
        XCTAssertFalse(room.surfaces.first { $0.label == "Stub" }!.excluded)
        XCTAssertTrue(room.surfaces.last!.excluded, "Restore hides the added wall")
    }

    // MARK: Window panes, LiDAR openings and ceiling

    // A straightened window close-up: light glass, darker frame bars at the given positions (meters), with
    // a little noise and an optional partial object seen through the glass.
    private func windowView(width: Double, height: Double, vertical: [Double], horizontal: [Double] = [],
                            blinds: Double? = nil, object: Bool = false, seed: Int = 1) -> WindowPanes.View {
        let ppm = 120.0, w = Int(width * ppm), h = Int(height * ppm)
        var pixels = [UInt8](repeating: 200, count: w * h), r = UInt64(seed)
        for y in 0..<h { for x in 0..<w {
            r = r &* 6364136223846793005 &+ 1442695040888963407
            var v = 200 + Int(r >> 61) * 3
            let mx = Double(x) / ppm, my = height - Double(y) / ppm
            if vertical.contains(where: { abs(mx - $0) < 0.025 }) || horizontal.contains(where: { abs(my - $0) < 0.025 }) { v = 90 }
            if let pitch = blinds, Int(mx / pitch) % 2 == 0 { v -= 60 }
            if object, mx > 0.3, mx < 0.36, my > 0.2, my < 0.6 { v = 40 }       // a post seen through the glass, short
            pixels[y * w + x] = UInt8(max(0, min(255, v)))
        } }
        return .init(width: w, height: h, pixels: pixels)
    }
    func testWindowDividersAreFoundAndShortEdgesIgnored() {
        let views = (1...3).map { windowView(width: 1.8, height: 1.4, vertical: [0.9], horizontal: [0.5], object: true, seed: $0) }
        let found = WindowPanes.find(views, size: (1.8, 1.4))!
        XCTAssertEqual(found.vertical.count, 1); XCTAssertEqual(found.vertical[0], 0.9, accuracy: 0.03)
        XCTAssertEqual(found.horizontal.count, 1); XCTAssertEqual(found.horizontal[0], 0.5, accuracy: 0.03)
        let plain = WindowPanes.find([windowView(width: 1.2, height: 1.0, vertical: [])], size: (1.2, 1.0))!
        XCTAssertTrue(plain.vertical.isEmpty && plain.horizontal.isEmpty, "a single pane")
    }
    func testBlindsHideThePanes() {
        let found = WindowPanes.find([windowView(width: 2.0, height: 1.4, vertical: [1.0], blinds: 0.09)], size: (2.0, 1.4))!
        XCTAssertTrue(found.vertical.isEmpty, "evenly spaced slats are blinds, not dividers")
    }
    func testLidarFindsAMissedWindowAndDoorButNotOnesAlreadyThere() {
        var room = RoomProject.demo()              // wall 1 runs x 0…5 at z 0 (door at 0.5–1.4); wall 3 at z 4
        func patch(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, z: Double) -> [LidarOpenings.Point] {
            stride(from: x0, through: x1, by: 0.05).flatMap { x in stride(from: y0, through: y1, by: 0.05).map { y in .init(plan: .init(x: x, z: z), height: y) } }
        }
        let windows = patch(3.6, 4.6, 1.0, 2.0, z: 0.02) + patch(2.3, 3.2, 0.5, 2.2, z: 3.98)   // the second is the mirror's place
        let doors = patch(0.6, 1.3, 0.05, 2.0, z: 0) + patch(3.6, 4.5, 0.05, 2.05, z: 4)   // the first is the existing door
        let found = LidarOpenings.add(&room, windows: windows, doors: doors)
        XCTAssertEqual(found.windows, 1); XCTAssertEqual(found.doors, 1)
        let window = room.surfaces.first { $0.kind == .window && $0.autoCleanup?.reason == .lidarAdded }!
        XCTAssertEqual(window.length, 1.1, accuracy: 0.15); XCTAssertEqual(window.bottom, 1.0, accuracy: 0.1)
        XCTAssertNotNil(window.reviewNote); XCTAssertEqual(window.parentID, room.surfaces[0].id)
        XCTAssertNoThrow(try room.validated())
    }
    func testCeilingFromLidarCorrectsWallHeightsAndRestores() {
        var room = RoomProject.demo()              // walls 2.7 m
        XCTAssertEqual(LidarLevels.apply(&room, floor: -1.45, ceiling: 1.37), 4)
        XCTAssertEqual(room.walls[0].height, 2.82, accuracy: 1e-9)
        XCTAssertEqual(LidarLevels.apply(&room, floor: 0, ceiling: 4), 0, "a 1.2 m difference is not a correction")
        Geometry.restoreCleanup(&room)
        XCTAssertEqual(room.walls[0].height, 2.7, accuracy: 1e-9)
    }
    func testWindowPanesSurviveSavingAndAreValidated() throws {
        var room = RoomProject.demo()
        room.surfaces[5].dividers = [0.9]; room.surfaces[5].rails = [0.7]
        let decoded = try JSONDecoder().decode(RoomProject.self, from: JSONEncoder().encode(room)).validated()
        XCTAssertEqual(decoded.surfaces[5].dividers, [0.9]); XCTAssertEqual(decoded.surfaces[5].paneDescription, "2 × 2 panes")
        room.surfaces[5].dividers = [5]
        XCTAssertThrowsError(try room.validated())
    }
    func testWindowDividersAppearInTheDXF() {
        var plain = RoomProject.demo(); plain.surfaces[5].dividers = nil
        let lines = { (room: RoomProject) in DXFExporter.text(room).components(separatedBy: "WINDOWS").count }
        XCTAssertEqual(lines(RoomProject.demo()), lines(plain) + 1, "one bar across the window's double line")
    }

    // MARK: Wall joins and opening tidying

    func testWallsNearlySquareAreSquaredAndCornersStayJoined() {
        var room = RoomProject.demo()
        room.surfaces[1].b = .init(x: 5.12, z: 4)          // wall 2 leans 1.7°; wall 3 starts where it ends
        room.surfaces[2].a = .init(x: 5.12, z: 4)
        let report = WallJoins.apply(&room)
        XCTAssertEqual(report.squared, 1)
        XCTAssertEqual(room.surfaces[1].a.x, room.surfaces[1].b.x, accuracy: 1e-9, "wall 2 runs straight")
        XCTAssertEqual(room.surfaces[1].b.distance(to: room.surfaces[2].a), 0, accuracy: 1e-9, "the corner is still joined")
        XCTAssertEqual(room.surfaces[0].b.distance(to: room.surfaces[1].a), 0, accuracy: 1e-9)
        XCTAssertNoThrow(try room.validated())
        Geometry.restoreCleanup(&room)
        XCTAssertEqual(room.surfaces[1].b.x, 5.12, accuracy: 1e-9)
    }
    func testDeliberateAnglesAreLeftAlone() {
        var room = RoomProject.demo()
        room.surfaces.append(PlanSurface(label: "Angled", kind: .wall, a: .init(x: 0, z: 2), b: .init(x: 1.5, z: 3.2), height: 2.7))
        let angled = room.surfaces.last!
        WallJoins.apply(&room)
        XCTAssertEqual(room.surfaces.last!.b, angled.b, "38° is a real angle, not an error")
    }
    func testCornerGapsCloseAsLAndT() {
        var room = RoomProject.demo()
        room.surfaces[0].b = .init(x: 4.86, z: 0)          // wall 1 stops 14 cm short of wall 2
        room.surfaces[1].a = .init(x: 5, z: 0.1)           // and wall 2 starts 10 cm late: an open L corner
        room.surfaces.append(PlanSurface(label: "Partition", kind: .wall, a: .init(x: 2.5, z: 0.2), b: .init(x: 2.5, z: 2), height: 2.7))
        let report = WallJoins.apply(&room)
        XCTAssertEqual(report.joined, 2)
        XCTAssertEqual(room.surfaces[0].b.distance(to: .init(x: 5, z: 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(room.surfaces[1].a.distance(to: .init(x: 5, z: 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(room.walls.last!.a.z, 0, accuracy: 1e-6, "the partition runs onto wall 1 (a T)")
        let door = room.surfaces[4]
        XCTAssertEqual(door.a.x, 0.5, accuracy: 1e-6, "the door keeps its place")
    }
    func testSplitWallMergesWithItsOpenings() {
        var room = RoomProject.demo()
        // Split wall 1 (0…5 at z 0) into 0…3 and 3…5; the door is on the first piece; add a window on the second.
        let second = PlanSurface(label: "Wall 1b", kind: .wall, a: .init(x: 3, z: 0.01), b: .init(x: 5, z: 0), height: 2.7)
        room.surfaces[0].b = .init(x: 3, z: 0)
        room.surfaces.append(second)
        room.surfaces.append(PlanSurface(label: "Window B", kind: .window, a: .init(x: 3.5, z: 0.005), b: .init(x: 4.5, z: 0.0025), bottom: 1, height: 1.2, parentID: second.id))
        let report = WallJoins.apply(&room)
        XCTAssertEqual(report.merged, 1)
        XCTAssertEqual(room.surfaces[0].length, 5, accuracy: 0.01)
        XCTAssertTrue(room.surfaces.first { $0.id == second.id }!.excluded)
        let window = room.surfaces.last!
        XCTAssertEqual(window.parentID, room.surfaces[0].id); XCTAssertEqual(window.a.x, 3.5, accuracy: 0.01)
        XCTAssertNil(Geometry.openingIssue(window, in: room)); XCTAssertNoThrow(try room.validated())
        Geometry.restoreCleanup(&room)
        XCTAssertEqual(room.surfaces.last!.parentID, second.id); XCTAssertFalse(room.surfaces.first { $0.id == second.id }!.excluded)
    }
    func testOpeningEdgesShareAndLineUp() {
        var room = RoomProject.demo()
        let wall = room.surfaces[2]                          // 5 m, runs x 5 → 0 at z 4; mirror at 2.2…3.3
        room.surfaces.removeAll { $0.kind == .mirror }
        room.surfaces += [
            PlanSurface(label: "W2", kind: .window, a: .init(x: 4.97, z: 4), b: .init(x: 3.6, z: 4), bottom: 0.92, height: 1.4, parentID: wall.id),
            PlanSurface(label: "W3", kind: .window, a: .init(x: 3.56, z: 4), b: .init(x: 2.2, z: 4), bottom: 0.9, height: 1.41, parentID: wall.id)]
        OpeningJoins.apply(&room)
        let w2 = room.surfaces.first { $0.label == "W2" }!, w3 = room.surfaces.first { $0.label == "W3" }!
        XCTAssertEqual(w2.a.x, 5, accuracy: 1e-9, "into the corner")
        XCTAssertEqual(w2.b.x, w3.a.x, accuracy: 1e-9, "one shared edge"); XCTAssertEqual(w2.b.x, 3.58, accuracy: 1e-9)
        XCTAssertEqual(w2.bottom, w3.bottom, accuracy: 1e-9); XCTAssertEqual(w2.bottom + w2.height, w3.bottom + w3.height, accuracy: 1e-9)
        Geometry.restoreCleanup(&room)
        XCTAssertEqual(room.surfaces.first { $0.label == "W2" }!.bottom, 0.92, accuracy: 1e-9)
    }
    func testLidarCheckConfirmsWallsThePointsSupport() {
        var room = RoomProject.demo()
        let real = [PlanPoint(x: 0, z: 0), .init(x: 5, z: 0), .init(x: 5, z: 4), .init(x: 0, z: 4)]
        let points = wallPoints(real[0], real[1]) + wallPoints(real[1], real[2]) + wallPoints(real[2], PlanPoint(x: 4, z: 4))
        let result = WallFit.check(&room, points: points)
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(room.surfaces[0].lidarCheck?.level, .confirmed)
        XCTAssertEqual(room.surfaces[2].lidarCheck?.level, .partly, "only part of wall 3 was seen")
        XCTAssertEqual(room.surfaces[3].lidarCheck?.level, .unconfirmed)
        var moved = room.surfaces[0]; moved.b = .init(x: 5.2, z: 0)
        Geometry.replace(moved, in: &room, joinCorners: true)
        XCTAssertNil(room.surfaces[0].lidarCheck, "an edit makes the check out of date")
    }

    // MARK: Grille bars, LiDAR opening edges, LiDAR floor, bulkheads, 3D frames

    // Glass (dark) between light frames, with light bars 3 cm wide: the glass meeting its frame is a single
    // step, not a bar.
    private func framedView(width: Double, height: Double, glass: ClosedRange<Double>, bars: [Double], left: Double = 0) -> WindowPanes.View {
        let ppm = 120.0, w = Int(width * ppm), h = Int(height * ppm)
        var pixels = [UInt8](repeating: 235, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let mx = left + Double(x) / ppm, my = Double(y) / ppm
            if glass.contains(mx) && my > 0.15 && my < height - 0.15 && !bars.contains(where: { abs(mx - $0) < 0.015 }) {
                pixels[y * w + x] = UInt8(90 + (x * 7 + y * 13) % 11)
            }
        } }
        return .init(width: w, height: h, pixels: pixels, left: left)
    }
    func testGrilleBarsAreFoundButGlassEdgesAreNot() {
        let found = WindowPanes.find([framedView(width: 1.5, height: 1.2, glass: 0.15...1.35, bars: [0.55, 0.95])], size: (1.5, 1.2))!
        XCTAssertEqual(found.vertical.count, 2, "two bars; the glass edges at 0.15 and 1.35 m are not bars")
        XCTAssertEqual(found.vertical[0], 0.55, accuracy: 0.02); XCTAssertEqual(found.vertical[1], 0.95, accuracy: 0.02)
    }
    func testCloseUpsTakenAtDifferentWindowSizesAgree() {
        // RoomPlan had the window 1.2 m wide, starting 0.3 m in, when the second close-up was taken.
        let whole = framedView(width: 1.5, height: 1.2, glass: 0.15...1.35, bars: [0.55, 0.95])
        let part = framedView(width: 1.2, height: 1.2, glass: 0.15...1.35, bars: [0.55, 0.95], left: 0.3)
        let found = WindowPanes.find([whole, part], size: (1.5, 1.2))!
        XCTAssertEqual(found.vertical.count, 2)
        XCTAssertEqual(found.vertical[0], 0.55, accuracy: 0.02); XCTAssertEqual(found.vertical[1], 0.95, accuracy: 0.02)
    }
    // Points on the face of wall 2 of the sample room (x = 5, z 0…4) every 2–3 cm, leaving out a gap and
    // whatever `hidden` covers.
    private func wall2Points(gap: (z: ClosedRange<Double>, h: ClosedRange<Double>), hidden: (Double, Double) -> Bool = { _, _ in false }) -> [LidarOpenings.Point] {
        stride(from: 0.02, through: 3.98, by: 0.02).flatMap { z in stride(from: 0.05, through: 2.65, by: 0.03).compactMap { h -> LidarOpenings.Point? in
            guard !(gap.z.contains(z) && gap.h.contains(h)), !hidden(z, h) else { return nil }
            return .init(plan: .init(x: 5 + (Int(z * 100) % 3 == 0 ? 0.004 : -0.004), z: z), height: h)
        } }
    }
    func testWindowEdgesMoveToTheGapInTheWall() {
        var room = RoomProject.demo()                 // window on wall 2: z 1.0…2.8, sill 0.9, head 2.3, a bar at 0.9 m
        XCTAssertEqual(LidarOpeningEdges.apply(&room, wallPoints: wall2Points(gap: (0.95...2.9, 0.8...2.3))), 1)
        let window = room.surfaces[5]
        XCTAssertEqual(window.a.z, 0.95, accuracy: 0.025); XCTAssertEqual(window.b.z, 2.9, accuracy: 0.025)
        XCTAssertEqual(window.bottom, 0.8, accuracy: 0.025); XCTAssertEqual(window.bottom + window.height, 2.3, accuracy: 0.025)
        XCTAssertEqual(window.dividers?.first ?? 0, 0.95, accuracy: 0.025, "the bar stays at z 1.9")
        XCTAssertEqual(room.surfaces[4].length, 0.9, accuracy: 1e-9, "the door's wall had no points: unchanged")
        Geometry.restoreCleanup(&room)
        XCTAssertEqual(room.surfaces[5].a.z, 1, accuracy: 1e-9); XCTAssertEqual(room.surfaces[5].bottom, 0.9, accuracy: 1e-9)
    }
    func testHiddenOrDisagreeingEdgesStay() {
        var room = RoomProject.demo()
        // Something in front of the wall just left of the window (only a 4 cm sliver of wall seen beside it):
        // that side can't be confirmed, the other moves.
        LidarOpeningEdges.apply(&room, wallPoints: wall2Points(gap: (0.95...2.9, 0.8...2.3), hidden: { z, h in z > 0.6 && z < 0.91 && h > 0.6 }))
        XCTAssertEqual(room.surfaces[5].a.z, 1, accuracy: 1e-9); XCTAssertEqual(room.surfaces[5].b.z, 2.9, accuracy: 0.025)
        // Hidden all the way along: as far as the LiDAR can tell the gap runs on, so neither side moves.
        var hidden = RoomProject.demo()
        LidarOpeningEdges.apply(&hidden, wallPoints: wall2Points(gap: (0.95...2.9, 0.8...2.3), hidden: { z, h in z < 0.95 && h > 0.6 }))
        XCTAssertEqual(hidden.surfaces[5].a.z, 1, accuracy: 1e-9); XCTAssertEqual(hidden.surfaces[5].b.z, 2.8, accuracy: 1e-9)
        // A gap 40 cm wider than RoomPlan's window on one side: not this window's edge, so neither side moves.
        var other = RoomProject.demo()
        LidarOpeningEdges.apply(&other, wallPoints: wall2Points(gap: (0.6...2.85, 0.9...2.3)))
        XCTAssertEqual(other.surfaces[5].a.z, 1, accuracy: 1e-9); XCTAssertEqual(other.surfaces[5].b.z, 2.8, accuracy: 1e-9)
    }
    func testHeightsAreMeasuredFromTheLidarFloor() {
        var room = RoomProject.demo()                 // RoomPlan's floor 4 cm below the measured one
        LidarLevels.apply(&room, floor: 0.04, ceiling: 2.74, roomFloor: 0)
        XCTAssertEqual(room.walls[0].height, 2.7, accuracy: 1e-9, "the walls were already the measured height")
        XCTAssertEqual(room.surfaces[5].bottom, 0.86, accuracy: 1e-9, "window sill")
        XCTAssertEqual(room.surfaces[4].bottom, 0, accuracy: 1e-9); XCTAssertEqual(room.surfaces[4].height, 2.06, accuracy: 1e-9, "door head")
        Geometry.restoreCleanup(&room)
        XCTAssertEqual(room.surfaces[5].bottom, 0.9, accuracy: 1e-9); XCTAssertEqual(room.surfaces[4].height, 2.1, accuracy: 1e-9)
    }
    func testBulkheadIsNotAddedAsAWall() {
        var room = RoomProject.demo()
        let p = [PlanPoint(x: 0, z: 0), .init(x: 5, z: 0), .init(x: 5, z: 4), .init(x: 0, z: 4)]
        let walls = (0..<4).flatMap { wallPoints(p[$0], p[($0 + 1) % 4]) }
        let bulkhead = wallPoints(.init(x: 1, z: 1.1), .init(x: 4, z: 1.1))        // seen only above 2.3 m
        let report = WallFit.apply(&room, points: walls + bulkhead, missingFrom: walls)
        XCTAssertEqual(report.added, 0)
    }
    func testWindowsGetAFrameAndBarsIn3D() {
        let names = ModelMesh.parts(RoomProject.demo()).map(\.name)
        XCTAssertEqual(names.filter { $0.hasPrefix("frame_") }.count, 4)
        XCTAssertEqual(names.filter { $0.hasPrefix("mullion_") }.count, 1)
    }
    func testSteppedWallTopDoesNotHideTheArea() throws {
        var room = RoomProject.demo()
        room.surfaces[0].geometryCaveat = RoomProject.nonuniformHeight          // as rooms saved before October 22, 2026
        XCTAssertNil(RoomSummary(room).totalArea)
        let moved = room.movingReviewNotes()
        XCTAssertNil(moved.surfaces[0].geometryCaveat); XCTAssertEqual(moved.surfaces[0].reviewNote, RoomProject.nonuniformHeight)
        XCTAssertEqual(RoomSummary(moved).totalArea ?? 0, 20, accuracy: 1e-9)
        room.surfaces[0].geometryCaveat = "Curved surface represented by a straight chord in the corrected model; original USDZ retained. " + RoomProject.nonuniformHeight
        XCTAssertNil(RoomSummary(room.movingReviewNotes()).totalArea, "a curved wall still hides it")
    }
}
