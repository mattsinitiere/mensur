import Foundation

// What one device holds, sent to the paired device at the start of each sync round.
struct SyncEntry: Codable, Hashable {
    var id: UUID
    var updatedAt: Date          // whole seconds, as stored in Project.json
    var digest: String           // hash of the encoded project, so identical copies are skipped
    var originals: [String]      // native RoomPlan files present, e.g. "Original-RoomPlan.json"
}

struct SyncManifest: Codable, Hashable {
    var device: UUID
    var entries: [SyncEntry]
    var tombstones: [UUID: Date] // rooms deleted on this device, and when
}

struct SyncPlan: Equatable {
    var send: [UUID] = []                    // this device's version goes to the peer
    var sendOriginals: [UUID: [String]] = [:] // native files the peer lacks
    var expect: [UUID] = []                  // the peer's version replaces or adds to ours
    var expectOriginals: [UUID: [String]] = [:] // native files the peer sends us
    var keepConflictCopy: [UUID] = []        // our version is duplicated before the peer's newer one arrives
    var moveToRecentlyDeleted: [UUID] = []   // deleted on the peer and not edited here since
    var adoptDeletions: [UUID: Date] = [:]   // the peer's deletions to record here, so they reach our other peers
    var base: [UUID: Date] = [:]             // agreed versions once the round completes

    // The round changes this device's library or deletion records, so its other peers need a round too.
    var changesHere: Bool { !expect.isEmpty || !expectOriginals.isEmpty || !keepConflictCopy.isEmpty || !moveToRecentlyDeleted.isEmpty || !adoptDeletions.isEmpty }

    static let originalFiles = ["Original-RoomPlan.json", "Original-RoomPlan.usdz"]

    // Both devices run this with the same manifests and shared `base` (the versions agreed at the end of
    // the last round between these two devices), so they reach the same decisions. A room changed on both
    // sides since `base` is a conflict: the newer save wins and the older is kept as a separate copy. Ties go
    // to the device with the larger identifier. Deletions win only over versions saved before the deletion.
    // A device paired with several others keeps one base per peer; deletions it learns from one peer are
    // recorded locally (`adoptDeletions`) so the next peer it syncs with removes its copy as well.
    static func make(local: SyncManifest, remote: SyncManifest, base: [UUID: Date]) -> SyncPlan {
        var plan = SyncPlan()
        let mine = Dictionary(uniqueKeysWithValues: local.entries.map { ($0.id, $0) })
        let theirs = Dictionary(uniqueKeysWithValues: remote.entries.map { ($0.id, $0) })
        for id in Set(mine.keys).union(theirs.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            switch (mine[id], theirs[id]) {
            case let (l?, r?):
                let missing = l.originals.filter { !r.originals.contains($0) }
                if !missing.isEmpty { plan.sendOriginals[id] = missing }
                let coming = r.originals.filter { !l.originals.contains($0) }
                if !coming.isEmpty { plan.expectOriginals[id] = coming }
                if l.digest == r.digest { plan.base[id] = max(l.updatedAt, r.updatedAt); continue }
                let localChanged = base[id].map { l.updatedAt > $0 } ?? true
                let remoteChanged = base[id].map { r.updatedAt > $0 } ?? true
                let conflict = localChanged && remoteChanged
                let localWins = l.updatedAt != r.updatedAt ? l.updatedAt > r.updatedAt : local.device.uuidString > remote.device.uuidString
                if localWins { plan.send.append(id); plan.base[id] = l.updatedAt }
                else {
                    plan.expect.append(id); plan.base[id] = r.updatedAt
                    if conflict { plan.keepConflictCopy.append(id) }
                }
            case let (l?, nil):
                if let deleted = remote.tombstones[id], deleted >= l.updatedAt { plan.moveToRecentlyDeleted.append(id) }
                else {
                    plan.send.append(id); plan.base[id] = l.updatedAt
                    let files = l.originals; if !files.isEmpty { plan.sendOriginals[id] = files }
                }
            case let (nil, r?):
                if let deleted = local.tombstones[id], deleted >= r.updatedAt { continue }  // the peer removes its copy
                plan.expect.append(id); plan.base[id] = r.updatedAt
                if !r.originals.isEmpty { plan.expectOriginals[id] = r.originals }
            case (nil, nil): break
            }
        }
        // A deletion is recorded here unless this device holds a version saved after it (which the peer then
        // receives instead) or already records the deletion.
        for (id, deleted) in remote.tombstones where theirs[id] == nil {
            if let l = mine[id], l.updatedAt > deleted { continue }
            if let known = local.tombstones[id], known >= deleted { continue }
            plan.adoptDeletions[id] = deleted
        }
        return plan
    }
}
