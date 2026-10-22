import XCTest
#if canImport(MensurCore)
@testable import MensurCore
#else
@testable import Mensur
#endif

// Annotations, takeoffs, health checks, plan symbols, ceiling detection, scan tools and buildings.
final class FeatureTests: XCTestCase {
    private func square(_ size: Double = 4, height: Double = 2.7) -> RoomProject {
        let p = [PlanPoint(x: 0, z: 0), .init(x: size, z: 0), .init(x: size, z: size), .init(x: 0, z: size)]
        var room = RoomProject(name: "Square")
        room.surfaces = (0..<4).map { PlanSurface(label: "Wall \($0 + 1)", kind: .wall, a: p[$0], b: p[($0 + 1) % 4], height: height) }
        return room
    }

    // MARK: Model

    func testProjectsWithoutNewFieldsStillDecode() throws {
        let old = try JSONEncoder().encode(RoomProject.demo())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        for key in ["job", "level", "markers", "photos", "ceilings", "stairs", "scanReport"] { json[key] = nil }
        let room = try JSONDecoder().decode(RoomProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(room.markers); XCTAssertNil(room.level)
        XCTAssertNoThrow(try room.validated())
    }

    func testNewFieldsRoundTrip() throws {
        var room = RoomProject.demo()
        room.job = JobInfo(client: "Acme", project: "Lobby refit", number: "J-104", tags: ["flooring"])
        room.level = FloorLevel(building: "HQ", floor: 1, elevation: 3.2)
        room.markers = [PlanMarker(kind: .outlet, position: .init(x: 1, z: 0.1), height: 0.4)]
        room.photos = [PinnedPhoto(position: .init(x: 2, z: 2), caption: "Panel")]
        room.ceilings = [CeilingFeature(kind: .soffit, a: .init(x: 1, z: 1), b: .init(x: 3, z: 1), width: 1, low: 2.4)]
        room.stairs = [Stair(a: .init(x: 4, z: 1), b: .init(x: 4, z: 3.5))]
        room.surfaces[0].wallType = .block; room.surfaces[0].thickness = 0.2
        room.surfaces[4].doorStyle = .pocket
        let decoded = try JSONDecoder().decode(RoomProject.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded.job, room.job); XCTAssertEqual(decoded.level, room.level)
        XCTAssertEqual(decoded.markers, room.markers); XCTAssertEqual(decoded.stairs, room.stairs)
        XCTAssertEqual(decoded.surfaces[0].wallType, .block); XCTAssertEqual(decoded.surfaces[4].doorStyle, .pocket)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testValidationRejectsBadAnnotations() {
        var room = RoomProject.demo()
        room.markers = [PlanMarker(kind: .outlet, position: .init(x: .nan, z: 0))]
        XCTAssertThrowsError(try room.validated())
        room.markers = nil; room.surfaces[0].thickness = 5
        XCTAssertThrowsError(try room.validated())
        room.surfaces[0].thickness = nil; room.stairs = [Stair(a: .zero, b: .init(x: 0.1, z: 0))]
        XCTAssertThrowsError(try room.validated())
    }

    func testRenamingKeepsFinishes() {
        var room = square()
        let space = RoomSummary(room).spaces[0]
        room.setSpaceLabel(SpaceLabel(name: "", anchor: .zero, floorFinish: "LVP"), for: space)
        XCTAssertEqual(room.spaceNames([space]), ["Space A"])
        room.nameSpace(space, "Office")
        XCTAssertEqual(room.spaceLabel(space)?.floorFinish, "LVP")
        XCTAssertEqual(room.spaceNames([space]), ["Office"])
        room.setSpaceLabel(SpaceLabel(name: "", anchor: .zero), for: space)
        XCTAssertNil(room.spaceLabels)
    }

    // MARK: Takeoffs

    func testTakeoffOfSampleRoom() {
        let t = Takeoff(RoomProject.demo())
        XCTAssertEqual(t.floorArea, 20, accuracy: 1e-6)
        XCTAssertEqual(t.wallGross, 18 * 2.7, accuracy: 1e-6)
        // Door 0.9 × 2.1 and window 1.8 × 1.4 come off; the mirror hangs on the wall and doesn't.
        XCTAssertEqual(t.wallOpenings, 0.9 * 2.1 + 1.8 * 1.4, accuracy: 1e-6)
        XCTAssertEqual(t.volume, 20 * 2.7, accuracy: 1e-6)
        XCTAssertEqual(t.baseboard, 18 - 0.9, accuracy: 1e-6)
    }

    func testCeilingFeaturesChangeAreaAndVolume() {
        var room = RoomProject.demo()
        room.ceilings = [CeilingFeature(kind: .soffit, a: .init(x: 1, z: 1), b: .init(x: 3, z: 1), width: 1, low: 2.4)]
        let t = Takeoff(room)
        XCTAssertEqual(t.volume, 54 - 2 * 0.3, accuracy: 1e-6)
        XCTAssertEqual(t.ceilingArea, 20 + 2 * (2 + 1) * 0.3, accuracy: 1e-6)
        let slope = CeilingFeature(kind: .slope, a: .zero, b: .init(x: 4, z: 0), width: 3, low: 2.4, high: 3.4)
        XCTAssertEqual(slope.surfaceArea(roomCeiling: 2.4), 3 * (16 + 1).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(slope.height(at: .init(x: 2, z: 0)), 2.9, accuracy: 1e-9)
        // A semicircular vault 2 m wide and 1 m high: half a circle of radius 1, times its length.
        let vault = CeilingFeature(kind: .vault, a: .zero, b: .init(x: 5, z: 0), width: 2, low: 2.5, high: 3.5)
        XCTAssertEqual(vault.surfaceArea(roomCeiling: 2.5), .pi * 5, accuracy: 1e-3)
    }

    // MARK: Health

    func testHealthyRoomHasNoProblems() {
        XCTAssertTrue(HealthCheck.run(RoomProject.demo()).filter { $0.severity == .problem }.isEmpty)
    }

    func testGapsAnglesAndCrossingsAreFound() {
        var room = square()
        room.surfaces[1].b = .init(x: 4, z: 3.4)                 // 60 cm short of the corner
        let findings = HealthCheck.run(room)
        XCTAssertTrue(findings.contains { $0.severity == .problem && $0.title.hasPrefix("Gap of") })
        var skew = square()
        skew.surfaces[0].b = .init(x: 4, z: 0.5); skew.surfaces[1].a = .init(x: 4, z: 0.5)
        XCTAssertTrue(HealthCheck.run(skew).contains { $0.title.contains("meet at") })
        var crossed = square()
        crossed.surfaces.append(PlanSurface(label: "Wall 5", kind: .wall, a: .init(x: 2, z: -1), b: .init(x: 2, z: 5)))
        XCTAssertTrue(HealthCheck.run(crossed).contains { $0.title.contains("crosses") })
    }

    // MARK: Plan symbols

    func testThickWallsMitreAtCornersAndStopAtOpenings() {
        var room = RoomProject.demo()
        for i in room.surfaces.indices where room.surfaces[i].kind == .wall { room.surfaces[i].thickness = 0.2 }
        let bands = PlanGeometry.wallBands(room)
        XCTAssertEqual(bands.count, 4)
        let first = bands.first { $0.wall.label == "Wall 1" }!
        XCTAssertEqual(first.pieces.count, 2)                    // split by the entry door
        XCTAssertEqual(first.jambs.count, 2)
        // The outer edge meets the neighbouring outer edge at the corner, outside the room.
        let corner = first.pieces[0][3]
        XCTAssertEqual(corner.x, -0.2, accuracy: 1e-6); XCTAssertEqual(corner.z, -0.2, accuracy: 1e-6)
    }

    func testHatchStaysInsideThePolygon() {
        let poly = [PlanPoint(x: 0, z: 0), .init(x: 2, z: 0), .init(x: 2, z: 0.2), .init(x: 0, z: 0.2)]
        let lines = PlanGeometry.hatch(poly, type: .block, spacing: 0.05)
        XCTAssertFalse(lines.isEmpty)
        for (a, b) in lines { for p in [a, b] { XCTAssertTrue(p.x > -1e-6 && p.x < 2 + 1e-6 && p.z > -1e-6 && p.z < 0.2 + 1e-6) } }
        XCTAssertTrue(PlanGeometry.hatch(poly, type: .stud, spacing: 0.05).isEmpty)
    }

    func testDoorSwingOpensIntoTheRoom() {
        let room = RoomProject.demo()
        let door = room.surfaces.first { $0.kind == .door }!
        let symbol = PlanGeometry.doorSymbol(door, room: room)
        XCTAssertEqual(symbol.arcs.count, 1)
        XCTAssertEqual(symbol.arcs[0].radius, door.length, accuracy: 1e-9)
        XCTAssertGreaterThan(symbol.solid[0].1.z, 0.5)           // the leaf stands into the room (z > 0)
        var out = door; out.opensOut = true; out.doorStyle = .double
        XCTAssertEqual(PlanGeometry.doorSymbol(out, room: room).arcs.count, 2)
        XCTAssertLessThan(PlanGeometry.doorSymbol(out, room: room).solid[0].1.z, 0)
    }

    func testDimensionChainsIncludeOpeningEdges() {
        let chains = PlanGeometry.chains(RoomProject.demo())
        XCTAssertEqual(chains.count, 4)
        let entry = chains.first { abs($0.direction.x) > 0.9 && abs($0.origin.z) < 0.01 }!
        XCTAssertEqual(entry.ticks.map { ($0 * 100).rounded() / 100 }, [0, 0.5, 1.4, 5])
    }

    func testElevationShowsOpeningsFromInside() {
        let elevations = Elevation.all(RoomProject.demo())
        XCTAssertEqual(elevations.count, 4)
        let entry = elevations.first { $0.items.contains { $0.kind == .door } }!
        let door = entry.items.first { $0.kind == .door }!
        XCTAssertEqual(door.x1 - door.x0, 0.9, accuracy: 1e-6)
        XCTAssertTrue(door.x0 >= 0 && door.x1 <= entry.width + 1e-9)
        XCTAssertEqual(door.y1, 2.1, accuracy: 1e-9)
    }

    // MARK: Ceiling

    private func ceilingPoints(_ height: (Double, Double) -> Double) -> [Vector3] {
        var pts: [Vector3] = []
        for i in 0..<100 { for j in 0..<80 {
            let x = Double(i) * 0.05, z = Double(j) * 0.05
            pts.append(Vector3(x: x, y: height(x, z), z: z))
        } }
        return pts
    }

    func testSoffitAndBeamAreFound() throws {
        let pts = ceilingPoints { x, z in
            if x >= 1 && x < 3 && z >= 1 && z < 2 { return 2.4 }          // 2 × 1 m soffit
            if z >= 3 && z < 3.3 && x >= 0.5 && x < 4 { return 2.5 }      // 3.5 m beam, 30 cm wide
            return 2.7
        }
        let result = try XCTUnwrap(CeilingAnalysis.analyse(pts, floorY: 0))
        XCTAssertEqual(result.main, 2.7, accuracy: 0.02)
        let soffit = try XCTUnwrap(result.features.first { $0.kind == .soffit })
        XCTAssertEqual(soffit.low, 2.4, accuracy: 0.02)
        XCTAssertEqual(soffit.footprintArea, 2, accuracy: 0.6)
        let beam = try XCTUnwrap(result.features.first { $0.kind == .beam })
        XCTAssertEqual(beam.length, 3.5, accuracy: 0.3)
    }

    func testSlopeAndVaultAreFound() throws {
        let slope = try XCTUnwrap(CeilingAnalysis.analyse(ceilingPoints { x, _ in 2.4 + 0.2 * x }, floorY: 0)?.features.first)
        XCTAssertEqual(slope.kind, .slope)
        XCTAssertEqual(slope.low, 2.4, accuracy: 0.05); XCTAssertEqual(slope.high ?? 0, 3.4, accuracy: 0.05)
        let vault = try XCTUnwrap(CeilingAnalysis.analyse(ceilingPoints { _, z in 3.0 - 0.15 * (z - 2) * (z - 2) }, floorY: 0)?.features.first)
        XCTAssertEqual(vault.kind, .vault)
        XCTAssertEqual(vault.high ?? 0, 3.0, accuracy: 0.05)
    }

    // MARK: Scan tools

    func testTrackingReportFindsCorrections() {
        var samples = (0...40).map { PoseSample(t: Double($0) * 0.25, x: Double($0) * 0.25, y: 1.4, z: 0, tracking: 0) }
        samples[20].x += 0.6; for i in 21...40 { samples[i].x += 0.6 }     // a 60 cm jump
        samples[30].tracking = 2
        let r = ScanMetrics.report(samples)
        XCTAssertEqual(r.corrections, 1)
        XCTAssertEqual(r.largestCorrection, 0.6 + 0.25 - ScanMetrics.walkingSpeed * 0.25, accuracy: 1e-6)
        XCTAssertEqual(r.relocalizations, 1)
        XCTAssertEqual(r.pathLength, 39 * 0.25, accuracy: 1e-6)
        XCTAssertEqual(r.duration, 10, accuracy: 1e-9)
    }

    func testCoachingPointsToTheUnseenWall() {
        let room = square()
        let walls = room.walls.map { w in (wall: w, seen: w.label == "Wall 2" ? [0, 0, 0, 0] : [1, 1, 1, 1]) }
        // Standing in the middle, facing -z: Wall 2 (x = 4) is on the right.
        let hint = Coaching.next(position: .init(x: 2, z: 2), heading: .init(x: 0, z: -1), walls: walls)
        XCTAssertEqual(hint?.side, .right)
        XCTAssertEqual(hint?.phrase, "Move closer to the wall on your right")
        XCTAssertNil(Coaching.next(position: .init(x: 2, z: 2), heading: .init(x: 0, z: -1), walls: room.walls.map { ($0, [1, 1]) }))
    }

    func testRevealDepthFromJambPoints() {
        var pts: [Vector3] = []
        for i in 0..<60 { let w = Double(i) / 59 * 0.18; pts += [Vector3(x: 0.02, y: 1, z: w), Vector3(x: 0.88, y: 1.2, z: w)] }
        pts += (0..<40).map { Vector3(x: 0.45, y: 1, z: Double($0) * 0.01) }      // the door leaf: not a jamb
        XCTAssertEqual(Reveals.depth(pts, width: 0.9, height: 2.1) ?? 0, 0.18, accuracy: 0.02)
        XCTAssertNil(Reveals.depth(Array(pts.prefix(10)), width: 0.9, height: 2.1))
        var room = RoomProject.demo()
        let door = room.surfaces.firstIndex { $0.kind == .door }!
        room.surfaces[door].revealDepth = 0.16
        XCTAssertEqual(Reveals.applyToWalls(&room), 1)
        XCTAssertEqual(room.surfaces.first { $0.id == room.surfaces[door].parentID }?.thickness, 0.16)
    }

    func testResumedScanAddsOnlyNewWalls() {
        let room = RoomProject.demo()
        var next = RoomProject(name: "Pass 2")
        next.surfaces = [PlanSurface(label: "Wall 1", kind: .wall, a: .init(x: 0.02, z: 0.03), b: .init(x: 4.9, z: 0.03)),   // already there
                         PlanSurface(label: "Wall 2", kind: .wall, a: .init(x: 5, z: 4), b: .init(x: 8, z: 4))]
        let merged = ScanMerge.merge(next, into: room)
        XCTAssertEqual(merged.walls, 1)
        XCTAssertEqual(merged.room.walls.count, 5)
        XCTAssertEqual(merged.room.scanReport?.passes, 2)
        XCTAssertNoThrow(try merged.room.validated())
    }

    // MARK: Buildings

    func testStairsLineUpTwoFloors() {
        let lower = Stair(a: .init(x: 1, z: 1), b: .init(x: 1, z: 4), up: true)
        let level = FloorLevel(building: "HQ", floor: 0)
        // The same stair scanned on the upper floor, in coordinates turned 90° and moved: drawn going down.
        let upperStair = Stair(a: .init(x: 10, z: 5), b: .init(x: 7, z: 5), up: false)
        let placement = BuildingPlan.align(upperStair, onto: lower, targetLevel: level)
        let upper = FloorLevel(building: "HQ", floor: 1, offset: placement.offset, rotation: placement.rotation)
        XCTAssertEqual(upper.place(upperStair.a).distance(to: lower.b), 0, accuracy: 1e-9)
        XCTAssertEqual(upper.place(upperStair.b).distance(to: lower.a), 0, accuracy: 1e-9)
    }

    func testShowcaseIsAValidRichRoom() throws {
        let room = try RoomProject.showcase().validated()
        let summary = RoomSummary(room)
        XCTAssertEqual(summary.spaces.count, 2)
        XCTAssertEqual(Set(summary.spaceNames), ["Office", "Store"])
        XCTAssertEqual(PlanGeometry.wallBands(room).count, 5)
        XCTAssertTrue(HealthCheck.run(room).filter { $0.severity == .problem }.isEmpty)
        XCTAssertFalse(Elevation.all(room).flatMap(\.marks).isEmpty)       // wall-mounted markers on elevations
    }

    func testPlanItemsCanBeFoundMovedTurnedAndRemoved() {
        var room = RoomProject.showcase()
        let outlet = room.markers![0]
        XCTAssertEqual(room.annotation(at: outlet.position + PlanPoint(x: 0.05, z: 0), pin: 0.1), outlet.id)
        let desk = room.objects[0]
        XCTAssertEqual(room.annotation(at: PlanPoint(x: desk.center.x, z: desk.center.z), pin: 0.1), desk.id)
        XCTAssertEqual(room.itemKind(desk.id), .object)
        room.move(outlet.id, by: .init(x: 0.5, z: 0))
        XCTAssertEqual(room.markers![0].position.x, outlet.position.x + 0.5, accuracy: 1e-9)
        let beam = room.ceilings![1]
        room.rotate(beam.id, by: .pi / 2)
        let turned = room.ceilings![1]
        XCTAssertEqual(turned.direction.dot(beam.direction), 0, accuracy: 1e-9)
        XCTAssertEqual(((turned.a + turned.b) * 0.5).distance(to: (beam.a + beam.b) * 0.5), 0, accuracy: 1e-9)
        room.removeItem(outlet.id); room.removeItem(desk.id)
        XCTAssertNil(room.itemKind(outlet.id)); XCTAssertNil(room.itemKind(desk.id))
        XCTAssertNoThrow(try room.validated())
    }

    func testFloorsCombineAndAlignByStairs() {
        var lower = RoomProject.demo(); lower.level = FloorLevel(building: "HQ", floor: 0)
        lower.stairs = [Stair(a: .init(x: 1, z: 1), b: .init(x: 1, z: 3.5), up: true, toFloor: 1)]
        var upper = RoomProject.demo(); upper.id = UUID()
        upper.surfaces = upper.surfaces.map { var s = $0; s.id = UUID(); return s }
        upper.surfaces = upper.surfaces.map { s in var s = s; if s.kind != .wall { s.parentID = upper.surfaces.first { $0.kind == .wall }!.id }; return s }
        upper.level = FloorLevel(building: "HQ", floor: 1)
        // The same stair on the upper floor's own (turned) coordinates.
        upper.stairs = [Stair(a: .init(x: 8, z: 2), b: .init(x: 5.5, z: 2), up: false, toFloor: 0)]
        let moved = BuildingPlan.alignByStairs([lower, upper])
        XCTAssertEqual(moved.map(\.id), [upper.id])
        let placed = moved[0].level!
        XCTAssertEqual(placed.place(upper.stairs![0].a).distance(to: lower.stairs![0].b), 0, accuracy: 1e-9)
        let building = BuildingPlan.buildings([lower, moved[0]])[0]
        let ground = BuildingPlan.composite(building.floors[0], building: "HQ")
        XCTAssertEqual(ground.walls.count, 4); XCTAssertEqual(ground.stairs?.count, 1)
    }

    func testOnlyKnownFilesSync() {
        XCTAssertTrue(SyncPlan.isSyncedFile("Original-RoomPlan.json"))
        XCTAssertTrue(SyncPlan.isSyncedFile("Original-RoomPlan-3.json"))
        XCTAssertTrue(SyncPlan.isSyncedFile("Photos/\(UUID().uuidString).jpg"))
        for bad in ["Photos/../Project.json", "Photos/x.jpg", "../Original-RoomPlan.json", "Original-RoomPlan-99.json", "Measurements/wallpoints.bin"] {
            XCTAssertFalse(SyncPlan.isSyncedFile(bad), bad)
        }
    }

    func testBuildingsGroupFloors() {
        var a = RoomProject.demo(); a.level = FloorLevel(building: "HQ", floor: 1)
        var b = RoomProject.demo(); b.id = UUID(); b.level = FloorLevel(building: "HQ", floor: 0)
        let c = RoomProject.demo()
        let buildings = BuildingPlan.buildings([a, b, c])
        XCTAssertEqual(buildings.count, 1)
        XCTAssertEqual(buildings[0].floors.map(\.floor), [0, 1])
        XCTAssertFalse(BuildingPlan.parts(buildings[0]).isEmpty)
    }
}
