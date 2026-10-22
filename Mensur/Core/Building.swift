import Foundation

// Rooms grouped into buildings and floors, and floors lined up with each other.
enum BuildingPlan {
    struct Floor: Identifiable { var floor: Int; var name: String; var rooms: [RoomProject]; var id: Int { floor } }
    struct Building: Identifiable { var name: String; var floors: [Floor]; var id: String { name } }

    // Every building named on at least one room, floors from the lowest up.
    static func buildings(_ rooms: [RoomProject]) -> [Building] {
        let named = rooms.filter { $0.level != nil }
        return Dictionary(grouping: named) { $0.level!.building }.map { name, rooms in
            let floors = Dictionary(grouping: rooms) { $0.level!.floor }.map { floor, rooms in
                Floor(floor: floor, name: rooms.compactMap(\.level?.name).first(where: { !$0.isEmpty }) ?? rooms[0].level!.displayName,
                      rooms: rooms.sorted { $0.name < $1.name })
            }.sorted { $0.floor < $1.floor }
            return Building(name: name, floors: floors)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // The offset and rotation that place `stair` (in its room's own coordinates) over `target`, a stair on
    // another floor placed by `targetLevel`. A stair going up from the lower floor and the same stair going
    // down on the upper floor share a footprint with their ends swapped.
    static func align(_ stair: Stair, onto target: Stair, targetLevel: FloorLevel) -> (offset: PlanPoint, rotation: Double) {
        let ta = targetLevel.place(target.a), tb = targetLevel.place(target.b)
        let (from, to) = stair.up == target.up ? (ta, tb) : (tb, ta)
        let mine = stair.b - stair.a, theirs = to - from
        let rotation = atan2(theirs.z, theirs.x) - atan2(mine.z, mine.x)
        let offset = from - Geometry.rotate(stair.a, by: rotation)
        return (offset, rotation)
    }

    // One floor as a single plan: every room on it moved to its place in the building.
    static func composite(_ floor: Floor, building: String) -> RoomProject {
        var plan = RoomProject(name: "\(building) · \(floor.name)")
        plan.units = floor.rooms.first?.units ?? .imperial
        for room in floor.rooms {
            let level = room.level ?? FloorLevel(building: building)
            func place(_ p: PlanPoint) -> PlanPoint { level.place(p) }
            plan.surfaces += room.surfaces.map { s in var s = s; s.a = place(s.a); s.b = place(s.b); return s }
            plan.objects += room.objects.map { o in
                var o = o; let c = place(PlanPoint(x: o.center.x, z: o.center.z)); o.center.x = c.x; o.center.z = c.z; o.yaw += level.rotation; return o
            }
            if let m = room.markers { plan.markers = (plan.markers ?? []) + m.map { var m = $0; m.position = place(m.position); return m } }
            if let s = room.stairs { plan.stairs = (plan.stairs ?? []) + s.map { var s = $0; s.a = place(s.a); s.b = place(s.b); return s } }
            if let c = room.ceilings { plan.ceilings = (plan.ceilings ?? []) + c.map { var c = $0; c.a = place(c.a); c.b = place(c.b); return c } }
            if let l = room.spaceLabels { plan.spaceLabels = (plan.spaceLabels ?? []) + l.map { var l = $0; l.anchor = place(l.anchor); return l } }
        }
        return plan
    }

    // Places each room over the floor below by matching a stair on it with the stair it connects to there
    // (a stair whose toFloor is the other's floor). Rooms scanned in the same session as an aligned room take
    // its placement. Returns the rooms whose placement changed.
    static func alignByStairs(_ rooms: [RoomProject]) -> [RoomProject] {
        var placed = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        var changed = Set<UUID>()
        let ordered = rooms.filter { $0.level != nil }.sorted { $0.level!.floor < $1.level!.floor }
        for room in ordered {
            let level = room.level!
            let below = ordered.filter { $0.level!.building == level.building && $0.level!.floor == level.floor - 1 }.compactMap { placed[$0.id] }
            var match: (Stair, Stair, FloorLevel)?
            for s in room.stairs ?? [] {
                for other in below {
                    if let t = (other.stairs ?? []).first(where: { $0.toFloor == level.floor && (s.toFloor == nil || s.toFloor == other.level!.floor) }) {
                        match = (s, t, other.level!); break
                    }
                }
                if match != nil { break }
            }
            var updated = room
            if let (s, t, targetLevel) = match {
                let fit = align(s, onto: t, targetLevel: targetLevel)
                updated.level!.offset = fit.offset; updated.level!.rotation = fit.rotation
            } else if let frame = level.frame, let twin = placed.values.first(where: { $0.id != room.id && $0.level?.frame == frame && changed.contains($0.id) }) {
                updated.level!.offset = twin.level!.offset; updated.level!.rotation = twin.level!.rotation
            } else { continue }
            if updated.level != room.level { placed[room.id] = updated; changed.insert(room.id) }
        }
        return rooms.compactMap { changed.contains($0.id) ? placed[$0.id] : nil }
    }

    // A building's 3D model: every room's parts moved to its place and lifted to its floor's elevation.
    static func parts(_ building: Building, storey: Double = 3.0) -> [MeshPart] {
        building.floors.flatMap { floor in
            floor.rooms.flatMap { room -> [MeshPart] in
                let level = room.level!
                let lift = level.elevation ?? Double(level.floor) * storey
                return ModelMesh.parts(room).map { part in
                    var moved = part
                    moved.name = "\(room.id.uuidString.prefix(8))_\(part.name)"
                    moved.vertices = part.vertices.map { v in
                        let p = level.place(PlanPoint(x: v.x, z: v.z)); return Vector3(x: p.x, y: v.y + lift, z: p.z)
                    }
                    return moved
                }
            }
        }
    }
}

// Common furniture and fixtures at standard sizes (meters: x width, y height, z depth), to place on a plan.
struct FurnitureItem: Identifiable, Hashable {
    var name: String
    var category: String
    var size: Vector3
    var id: String { name }
    init(_ name: String, _ category: String, _ w: Double, _ h: Double, _ d: Double) {
        self.name = name; self.category = category; self.size = Vector3(x: w, y: h, z: d)
    }
}

enum FurnitureCatalog {
    static let inch = 0.0254
    static func item(_ name: String, _ category: String, w: Double, h: Double, d: Double) -> FurnitureItem {
        FurnitureItem(name, category, w * inch, h * inch, d * inch)
    }
    static let items: [FurnitureItem] = [
        item("Sofa · 3 seat", "Living", w: 84, h: 34, d: 36), item("Loveseat", "Living", w: 64, h: 34, d: 36),
        item("Armchair", "Living", w: 34, h: 34, d: 34), item("Coffee table", "Living", w: 48, h: 18, d: 24),
        item("Side table", "Living", w: 22, h: 24, d: 22), item("TV stand", "Living", w: 60, h: 22, d: 18),
        item("Bookcase", "Living", w: 36, h: 72, d: 12), item("Area rug · 8×10", "Living", w: 96, h: 0.5, d: 120),
        item("Dining table · 6", "Dining", w: 72, h: 30, d: 36), item("Dining table · 4", "Dining", w: 48, h: 30, d: 36),
        item("Dining chair", "Dining", w: 18, h: 36, d: 20), item("Sideboard", "Dining", w: 60, h: 34, d: 18),
        item("King bed", "Bedroom", w: 76, h: 24, d: 80), item("Queen bed", "Bedroom", w: 60, h: 24, d: 80),
        item("Full bed", "Bedroom", w: 54, h: 24, d: 75), item("Twin bed", "Bedroom", w: 38, h: 24, d: 75),
        item("Nightstand", "Bedroom", w: 22, h: 26, d: 18), item("Dresser", "Bedroom", w: 60, h: 34, d: 20),
        item("Desk", "Office", w: 60, h: 30, d: 30), item("Office chair", "Office", w: 26, h: 40, d: 26),
        item("Conference table · 10", "Office", w: 144, h: 30, d: 48), item("File cabinet", "Office", w: 15, h: 52, d: 25),
        item("Workstation · cubicle", "Office", w: 72, h: 52, d: 72), item("Reception desk", "Office", w: 84, h: 42, d: 30),
        item("Refrigerator", "Kitchen", w: 36, h: 70, d: 30), item("Range", "Kitchen", w: 30, h: 36, d: 26),
        item("Dishwasher", "Kitchen", w: 24, h: 34, d: 24), item("Base cabinet · 24″", "Kitchen", w: 24, h: 36, d: 24),
        item("Kitchen island", "Kitchen", w: 72, h: 36, d: 36), item("Sink base · 36″", "Kitchen", w: 36, h: 36, d: 24),
        item("Toilet", "Bath", w: 15, h: 30, d: 28), item("Vanity · 36″", "Bath", w: 36, h: 34, d: 21),
        item("Bathtub", "Bath", w: 60, h: 20, d: 30), item("Shower · 36×36", "Bath", w: 36, h: 78, d: 36),
        item("Washer", "Laundry", w: 27, h: 38, d: 30), item("Dryer", "Laundry", w: 27, h: 38, d: 30),
        item("Water heater", "Utility", w: 22, h: 60, d: 22), item("Shelving unit", "Utility", w: 48, h: 72, d: 18),
        item("Piano · upright", "Other", w: 58, h: 48, d: 24), item("Pallet rack bay", "Other", w: 96, h: 144, d: 42)
    ]
    static var categories: [String] { var seen: [String] = []; for i in items where !seen.contains(i.category) { seen.append(i.category) }; return seen }
}
