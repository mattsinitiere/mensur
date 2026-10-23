import Foundation

// A device this one is paired with: its sync identity, the name it showed while pairing, and the random 256-bit
// key both devices keep for the encrypted connection.
struct SyncPeer: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var key: Data
}

// The pairings this device keeps. The iPhone keeps one per Mac and syncs with each Mac it can reach; the Mac
// stays with one iPhone. Each pairing has its own sync history (merge base and last-sync date), so pairing or
// unpairing one Mac leaves the history kept with the others alone.
struct SyncPairings: Equatable {
    private(set) var peers: [SyncPeer] = []

    init(_ peers: [SyncPeer] = []) {
        for peer in peers { add(peer, keepOthers: true) }
    }
    func peer(_ id: UUID) -> SyncPeer? { peers.first { $0.id == id } }

    // Adds a pairing, replacing an earlier one with the same device in place. With `keepOthers` false (the Mac,
    // which stays with one iPhone) it replaces every pairing. Returns the pairings replaced, whose sync history
    // no longer applies: a new pairing with the same device starts without shared history too.
    @discardableResult mutating func add(_ peer: SyncPeer, keepOthers: Bool) -> [SyncPeer] {
        let replaced = keepOthers ? peers.filter { $0.id == peer.id } : peers
        if keepOthers, let i = peers.firstIndex(where: { $0.id == peer.id }) { peers[i] = peer }
        else if keepOthers { peers.append(peer) }
        else { peers = [peer] }
        return replaced
    }
    @discardableResult mutating func remove(_ id: UUID) -> SyncPeer? {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return nil }
        return peers.remove(at: i)
    }

    // Saved as a JSON list. Builds that kept one pairing saved a single object, which reads as a list of one.
    func encoded() -> Data { (try? JSONEncoder().encode(peers)) ?? Data("[]".utf8) }
    static func decode(_ data: Data) -> SyncPairings? {
        if let list = try? JSONDecoder().decode([SyncPeer].self, from: data) { return SyncPairings(list) }
        if let one = try? JSONDecoder().decode(SyncPeer.self, from: data) { return SyncPairings([one]) }
        return nil
    }
}

// Where each pairing's sync history is kept: a merge base file in Application Support and a last-sync date in
// the preferences. Builds that kept one pairing used a single `sync-base.json` and `syncLastDate`.
enum SyncHistory {
    static let legacyBase = "sync-base.json"
    static let legacyLastSync = "syncLastDate"
    static func baseFile(_ peer: UUID) -> String { "sync-base-\(peer.uuidString).json" }
    static func lastSyncKey(_ peer: UUID) -> String { "syncLastDate-\(peer.uuidString)" }
    // The pairing the single-pairing history belongs to: the only one there is. With none (or, after a
    // downgrade and upgrade, several) it isn't clear whose it was, so it isn't moved.
    static func legacyOwner(_ pairings: SyncPairings) -> UUID? { pairings.peers.count == 1 ? pairings.peers[0].id : nil }
}

// The order of the iPhone's sync rounds. One round runs at a time, whichever Mac it is with, so two Macs never
// change the library at once and each round plans from an up-to-date manifest.
struct SyncQueue: Equatable {
    private(set) var waiting: [UUID] = []

    mutating func add(_ peers: [UUID]) {
        for id in peers where !waiting.contains(id) { waiting.append(id) }
    }
    mutating func remove(_ peer: UUID) { waiting.removeAll { $0 == peer } }
    // The next waiting peer that is connected. Peers that aren't connected are dropped: they get a round when
    // their connection is ready.
    mutating func next(connected: Set<UUID>) -> UUID? {
        while !waiting.isEmpty {
            let id = waiting.removeFirst()
            if connected.contains(id) { return id }
        }
        return nil
    }
    // After a round with `peer`: conflict copies made here are new rooms that peer hasn't seen, so it gets
    // another round; anything that changed here (rooms or files received, rooms moved to Recently Deleted,
    // deletions learned) goes on to the other connected peers. Rounds that change nothing here add nothing,
    // so the rounds stop once every device agrees.
    mutating func roundFinished(with peer: UUID, plan: SyncPlan, madeCopies: Bool, connected: [UUID]) {
        if madeCopies { add([peer]) }
        if plan.changesHere || madeCopies { add(connected.filter { $0 != peer }) }
    }
}
