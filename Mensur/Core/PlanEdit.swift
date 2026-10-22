import Foundation

// Direct-manipulation edits on the plan: the geometry behind dragging walls, corners and openings.
// Each function returns the edited surface (or nil when the result would be invalid); callers apply it
// with Geometry.replace(_, in:, joinCorners: true) so connected corners and attached openings follow.
enum PlanEdit {
    static let minimumLength = 0.1
    static let axisSnap = 3 * Double.pi / 180

    // Moves one end of a wall to `target`. It snaps to another wall's end within `snap` meters; otherwise
    // the wall straightens to horizontal or vertical (in the frame `axisAngle` turns to the screen) when
    // within 3°. Ends already joined to the moving end are not snap targets, since they follow it.
    static func moveWallEnd(_ wall: PlanSurface, atA: Bool, to target: PlanPoint, in room: RoomProject,
                            snap: Double, axisAngle: Double = 0) -> PlanSurface? {
        let original = atA ? wall.a : wall.b, fixed = atA ? wall.b : wall.a
        var point = target
        let candidates = room.walls.filter { $0.id != wall.id }.flatMap { [$0.a, $0.b] }.filter { $0.distance(to: original) > 0.08 }
        if let nearest = candidates.min(by: { $0.distance(to: point) < $1.distance(to: point) }), nearest.distance(to: point) <= snap {
            point = nearest
        } else {
            let v = Geometry.rotate(point - fixed, by: axisAngle)
            let angle = atan2(v.z, v.x), square = (angle / (.pi / 2)).rounded() * (.pi / 2)
            if abs(angle - square) < axisSnap {
                point = fixed + Geometry.rotate(PlanPoint(x: cos(square) * v.magnitude, z: sin(square) * v.magnitude), by: -axisAngle)
            }
        }
        guard point.distance(to: fixed) >= minimumLength else { return nil }
        var moved = wall
        if atA { moved.a = point } else { moved.b = point }
        return moved
    }

    // A whole wall slides square to itself only, so a shaky drag doesn't skew the walls joined to it.
    static func moveWall(_ wall: PlanSurface, by delta: PlanPoint) -> PlanSurface {
        let normal = PlanPoint(x: -wall.direction.z, z: wall.direction.x), shift = normal * delta.dot(normal)
        var moved = wall; moved.a = wall.a + shift; moved.b = wall.b + shift; return moved
    }

    // Slides an opening along its wall by the pointer's movement since `start`, kept inside the wall. When
    // the pointer comes within `reach` of a different wall long enough to hold it, the opening moves there.
    static func moveOpening(_ s: PlanSurface, in room: RoomProject, from start: PlanPoint, to pointer: PlanPoint, reach: Double) -> PlanSurface? {
        guard let parent = room.walls.first(where: { $0.id == s.parentID }) else { return nil }
        let width = s.length
        let nearby = room.walls.filter { $0.id != parent.id && $0.length >= width && Geometry.distance(pointer, to: $0.a, $0.b) <= reach }
            .min { Geometry.distance(pointer, to: $0.a, $0.b) < Geometry.distance(pointer, to: $1.a, $1.b) }
        let parentDistance = Geometry.distance(pointer, to: parent.a, parent.b)
        if let other = nearby, Geometry.distance(pointer, to: other.a, other.b) < parentDistance {
            let offset = min(max(0, (pointer - other.a).dot(other.direction) - width / 2), other.length - width)
            return fitHeight(Geometry.attach(s, to: other, offset: offset, width: width), on: other)
        }
        let dir = parent.direction
        let start0 = min((s.a - parent.a).dot(dir), (s.b - parent.a).dot(dir))
        let offset = min(max(0, start0 + (pointer - start).dot(dir)), max(0, parent.length - width))
        return Geometry.attach(s, to: parent, offset: offset, width: min(width, parent.length))
    }

    // Drags one end of an opening along its wall, changing its width; the other end stays put.
    static func resizeOpening(_ s: PlanSurface, atA: Bool, in room: RoomProject, to pointer: PlanPoint) -> PlanSurface? {
        guard let wall = room.walls.first(where: { $0.id == s.parentID }) else { return nil }
        let dir = wall.direction
        let moving = min(max(0, (pointer - wall.a).dot(dir)), wall.length)
        let other = ((atA ? s.b : s.a) - wall.a).dot(dir)
        guard abs(moving - other) >= minimumLength else { return nil }
        return Geometry.attach(s, to: wall, offset: min(moving, other), width: abs(moving - other))
    }

    // An opening moved to a lower wall keeps its sill but is trimmed to the wall's height.
    private static func fitHeight(_ s: PlanSurface, on wall: PlanSurface) -> PlanSurface {
        var fitted = s
        fitted.bottom = max(wall.bottom, min(s.bottom, wall.bottom + wall.height - 0.1))
        fitted.height = max(0.1, min(s.height, wall.bottom + wall.height - fitted.bottom))
        return fitted
    }
}
