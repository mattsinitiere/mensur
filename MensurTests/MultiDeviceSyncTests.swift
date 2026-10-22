import XCTest
@testable import MensurCore

// An iPhone paired with two Macs: rounds run between the phone and one Mac at a time, each pair with its own
// merge base, and edits and deletions made on one Mac reach the other through the phone.
final class MultiDeviceSyncTests: XCTestCase {
    struct Device {
        let id: UUID
        var rooms: [UUID: SyncEntry] = [:]
        var deleted: [UUID: Date] = [:]
        var bases: [UUID: [UUID: Date]] = [:]     // one per peer, as sync-base-<peer>.json
        var manifest: SyncManifest { .init(device: id, entries: rooms.values.sorted { $0.id.uuidString < $1.id.uuidString }, tombstones: deleted) }
        init(_ n: Int) { id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        mutating func save(_ room: UUID, _ t: Double, _ content: String) { rooms[room] = .init(id: room, updatedAt: MultiDeviceSyncTests.at(t), digest: content, originals: []) }
        mutating func delete(_ room: UUID, _ t: Double) { rooms[room] = nil; deleted[room] = MultiDeviceSyncTests.at(t) }
        var copies: [SyncEntry] { rooms.values.filter { $0.digest.hasSuffix("(conflicted copy)") } }
    }
    static func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }
    func at(_ s: Double) -> Date { Self.at(s) }
    let room = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    // One round as SyncService runs it: both plan from the same two manifests and their shared base, apply the
    // plan in the same order as the app (conflict copies, Recently Deleted, deletion records, received rooms),
    // and keep the agreed versions as that pair's base.
    @discardableResult func round(_ a: inout Device, _ b: inout Device) -> (SyncPlan, SyncPlan) {
        let ma = a.manifest, mb = b.manifest
        let pa = SyncPlan.make(local: ma, remote: mb, base: a.bases[b.id] ?? [:])
        let pb = SyncPlan.make(local: mb, remote: ma, base: b.bases[a.id] ?? [:])
        XCTAssertEqual(pa.base, pb.base, "both devices agree on the new base")
        XCTAssertEqual(Set(pa.send), Set(pb.expect)); XCTAssertEqual(Set(pb.send), Set(pa.expect))
        XCTAssertEqual(pa.sendOriginals, pb.expectOriginals); XCTAssertEqual(pb.sendOriginals, pa.expectOriginals)
        apply(pa, to: &a, from: mb); apply(pb, to: &b, from: ma)
        a.bases[b.id] = pa.base; b.bases[a.id] = pb.base
        return (pa, pb)
    }
    func apply(_ plan: SyncPlan, to d: inout Device, from remote: SyncManifest) {
        for id in plan.keepConflictCopy {
            guard var copy = d.rooms[id] else { continue }
            copy.id = UUID(); copy.digest += " (conflicted copy)"; d.rooms[copy.id] = copy
        }
        for id in plan.moveToRecentlyDeleted { d.rooms[id] = nil }
        for (id, date) in plan.adoptDeletions { d.deleted[id] = max(d.deleted[id] ?? date, date) }
        let theirs = Dictionary(uniqueKeysWithValues: remote.entries.map { ($0.id, $0) })
        for id in plan.expect { d.rooms[id] = theirs[id]; d.deleted[id] = nil }
    }
    // Runs the phone's queue the way SyncService does until it is empty, with both Macs connected.
    @discardableResult func drain(_ queue: inout SyncQueue, _ phone: inout Device, _ a: inout Device, _ b: inout Device) -> [UUID] {
        var order: [UUID] = []
        let connected = [a.id, b.id]
        while let next = queue.next(connected: Set(connected)) {
            order.append(next)
            XCTAssertLessThan(order.count, 20, "rounds must stop once every device agrees")
            if order.count >= 20 { break }
            let copiesBefore = phone.copies.count
            let plan = next == a.id ? round(&phone, &a).0 : round(&phone, &b).0
            queue.roundFinished(with: next, plan: plan, madeCopies: phone.copies.count > copiesBefore, connected: connected)
        }
        return order
    }
    // The phone and two Macs, all holding `room` as saved at t = 0, each pair with a base.
    func threeInSync() -> (phone: Device, a: Device, b: Device) {
        var phone = Device(1), a = Device(2), b = Device(3)
        phone.save(room, 0, "v0")
        round(&phone, &a); round(&phone, &b)
        XCTAssertEqual(a.rooms, phone.rooms); XCTAssertEqual(b.rooms, phone.rooms)
        return (phone, a, b)
    }

    func testEditOnOneMacReachesTheOtherThroughThePhone() {
        var (phone, a, b) = threeInSync()
        a.save(room, 10, "edited on A")
        var queue = SyncQueue(); queue.add([a.id])                     // A nudges the phone after the edit
        let order = drain(&queue, &phone, &a, &b)
        XCTAssertEqual(order, [a.id, b.id], "what arrived from A goes on to B")
        XCTAssertEqual(b.rooms[room]?.digest, "edited on A")
        XCTAssertTrue(phone.copies.isEmpty && b.copies.isEmpty, "only A changed it, so no conflict copy")
        XCTAssertEqual(phone.bases[a.id]?[room], at(10)); XCTAssertEqual(phone.bases[b.id]?[room], at(10))
    }

    func testDeletionOnOneMacReachesTheOtherThroughThePhone() {
        var (phone, a, b) = threeInSync()
        a.delete(room, 20)
        var queue = SyncQueue(); queue.add([a.id])
        drain(&queue, &phone, &a, &b)
        XCTAssertNil(phone.rooms[room]); XCTAssertNil(b.rooms[room], "B moved its copy to Recently Deleted")
        XCTAssertEqual(phone.deleted[room], at(20), "the phone records A's deletion, keeping A's date")
        XCTAssertEqual(b.deleted[room], at(20))
        // A later round with A finds nothing to do, and the room doesn't come back from either Mac.
        let (p, _) = round(&phone, &a)
        XCTAssertFalse(p.changesHere); XCTAssertNil(phone.rooms[room]); XCTAssertNil(a.rooms[room])
    }

    func testRoomEditedOnAMacAfterADeletionElsewhereComesBack() {
        var (phone, a, b) = threeInSync()
        a.delete(room, 20)
        b.save(room, 30, "edited on B after A deleted it")
        var queue = SyncQueue(); queue.add([a.id, b.id])
        drain(&queue, &phone, &a, &b)
        for d in [phone, a, b] {
            XCTAssertEqual(d.rooms[room]?.digest, "edited on B after A deleted it")
            XCTAssertNil(d.deleted[room], "receiving the newer version clears the deletion record")
        }
    }

    func testEditsOnBothMacsKeepOneConflictCopyEverywhere() {
        var (phone, a, b) = threeInSync()
        a.save(room, 10, "A's edit")
        b.save(room, 20, "B's edit")
        var queue = SyncQueue(); queue.add([a.id, b.id])
        drain(&queue, &phone, &a, &b)
        XCTAssertEqual(phone.rooms, a.rooms); XCTAssertEqual(phone.rooms, b.rooms)
        XCTAssertEqual(phone.rooms[room]?.digest, "B's edit", "the newest save wins")
        XCTAssertEqual(phone.copies.map(\.digest), ["A's edit (conflicted copy)"], "the older edit is kept once, on every device")
    }

    func testNewMacPairedLaterGetsEverythingAndOldHistoryStays() {
        var (phone, a, b) = threeInSync()
        let baseA = phone.bases[a.id]
        var c = Device(4)
        c.save(UUID(), 5, "scanned on C")
        round(&phone, &c)
        XCTAssertEqual(phone.bases[a.id], baseA, "pairing C leaves the history with A alone")
        XCTAssertEqual(c.rooms[room]?.digest, "v0")
        var queue = SyncQueue(); queue.roundFinished(with: c.id, plan: SyncPlan.make(local: phone.manifest, remote: c.manifest, base: [:]), madeCopies: false, connected: [a.id, c.id])
        XCTAssertTrue(queue.waiting.isEmpty, "nothing new for the phone on a second look")
        round(&phone, &a); round(&phone, &b)
        XCTAssertEqual(a.rooms.count, 2); XCTAssertEqual(b.rooms, a.rooms)
    }

    func testPlanRecordsThePeersDeletionsUnlessThisDeviceHasANewerVersion() {
        let me = Device(1).id, peer = Device(2).id, kept = UUID(), gone = UUID(), elsewhere = UUID(), known = UUID()
        let local = SyncManifest(device: me, entries: [.init(id: kept, updatedAt: at(60), digest: "k", originals: []),
                                                      .init(id: gone, updatedAt: at(10), digest: "g", originals: [])],
                                 tombstones: [known: at(40)])
        let remote = SyncManifest(device: peer, entries: [], tombstones: [kept: at(50), gone: at(50), elsewhere: at(50), known: at(30)])
        let plan = SyncPlan.make(local: local, remote: remote, base: [:])
        XCTAssertEqual(plan.moveToRecentlyDeleted, [gone])
        XCTAssertEqual(plan.adoptDeletions, [gone: at(50), elsewhere: at(50)], "kept is newer here; known is already recorded")
        XCTAssertEqual(plan.send, [kept]); XCTAssertTrue(plan.changesHere)
    }

    func testFilesExpectedFromThePeerCountAsAChange() {
        let id = UUID(), files = SyncPlan.originalFiles
        let local = SyncManifest(device: Device(1).id, entries: [.init(id: id, updatedAt: at(0), digest: "x", originals: [])], tombstones: [:])
        let remote = SyncManifest(device: Device(2).id, entries: [.init(id: id, updatedAt: at(0), digest: "x", originals: files)], tombstones: [:])
        let plan = SyncPlan.make(local: local, remote: remote, base: [id: at(0)])
        XCTAssertEqual(plan.expectOriginals[id], files); XCTAssertTrue(plan.expect.isEmpty); XCTAssertTrue(plan.changesHere)
        XCTAssertFalse(SyncPlan.make(local: remote, remote: remote, base: [id: at(0)]).changesHere)
    }

    // MARK: Pairings and migration

    func peer(_ n: Int, _ name: String) -> SyncPeer { .init(id: Device(n).id, name: name, key: Data(repeating: UInt8(n), count: 32)) }

    func testPhoneKeepsEveryMacAndReplacesOnlyARepairedOne() {
        var pairings = SyncPairings([peer(2, "Studio A")])
        XCTAssertEqual(pairings.add(peer(3, "Studio B"), keepOthers: true), [])
        XCTAssertEqual(pairings.add(peer(4, "MacBook Pro"), keepOthers: true), [])
        XCTAssertEqual(pairings.peers.map(\.name), ["Studio A", "Studio B", "MacBook Pro"])
        var again = peer(3, "Studio B"); again.key = Data(repeating: 9, count: 32)
        XCTAssertEqual(pairings.add(again, keepOthers: true), [peer(3, "Studio B")], "the old pairing's history is cleared")
        XCTAssertEqual(pairings.peers.map(\.name), ["Studio A", "Studio B", "MacBook Pro"], "order kept")
        XCTAssertEqual(pairings.peer(again.id)?.key, again.key)
        XCTAssertEqual(pairings.remove(peer(2, "").id)?.name, "Studio A")
        XCTAssertNil(pairings.remove(peer(2, "").id))
        XCTAssertEqual(pairings.peers.map(\.name), ["Studio B", "MacBook Pro"])
    }

    func testMacStaysWithOneIPhone() {
        var pairings = SyncPairings([peer(1, "iPhone")])
        XCTAssertEqual(pairings.add(peer(5, "iPad"), keepOthers: false), [peer(1, "iPhone")])
        XCTAssertEqual(pairings.peers, [peer(5, "iPad")])
    }

    func testSinglePairingFromEarlierBuildsReadsAsAListOfOne() throws {
        // Earlier builds saved one pairing, encoded with a plain JSONEncoder, in the Keychain or pairing.json.
        let legacy = try JSONEncoder().encode(peer(2, "Studio A"))
        XCTAssertEqual(SyncPairings.decode(legacy)?.peers, [peer(2, "Studio A")])
        let list = SyncPairings([peer(2, "Studio A"), peer(3, "Studio B")])
        XCTAssertEqual(SyncPairings.decode(list.encoded()), list)
        XCTAssertEqual(SyncPairings.decode(SyncPairings().encoded())?.peers, [], "unpairing every Mac saves an empty list")
        XCTAssertNil(SyncPairings.decode(Data("not a pairing".utf8)))
        XCTAssertEqual(SyncPairings([peer(2, "old"), peer(2, "new")]).peers.map(\.name), ["new"], "one pairing per device")
    }

    func testOldSyncHistoryGoesToTheOnlyPairing() {
        let a = peer(2, "Studio A")
        XCTAssertEqual(SyncHistory.legacyOwner(SyncPairings([a])), a.id)
        XCTAssertNil(SyncHistory.legacyOwner(SyncPairings()))
        XCTAssertNil(SyncHistory.legacyOwner(SyncPairings([a, peer(3, "Studio B")])))
        XCTAssertEqual(SyncHistory.baseFile(a.id), "sync-base-00000000-0000-0000-0000-000000000002.json")
        XCTAssertNotEqual(SyncHistory.baseFile(a.id), SyncHistory.legacyBase)
        XCTAssertNotEqual(SyncHistory.lastSyncKey(a.id), SyncHistory.legacyLastSync)
    }

    // MARK: Round order

    func testQueueRunsConnectedMacsOnceEachInOrder() {
        let a = Device(2).id, b = Device(3).id, c = Device(4).id
        var queue = SyncQueue()
        queue.add([a, b]); queue.add([b, a, c])
        XCTAssertEqual(queue.waiting, [a, b, c], "no duplicates")
        XCTAssertEqual(queue.next(connected: [b, c]), b, "A isn't connected: dropped, it syncs when it connects")
        queue.remove(c)
        XCTAssertNil(queue.next(connected: [a, b, c]))
    }

    func testRoundThatChangesNothingHereStartsNoOtherRounds() {
        let a = Device(2).id, b = Device(3).id
        var queue = SyncQueue()
        var plan = SyncPlan(); plan.send = [UUID()]
        queue.roundFinished(with: a, plan: plan, madeCopies: false, connected: [a, b])
        XCTAssertTrue(queue.waiting.isEmpty, "sending to A doesn't concern B")
        plan.expect = [UUID()]
        queue.roundFinished(with: a, plan: plan, madeCopies: false, connected: [a, b])
        XCTAssertEqual(queue.waiting, [b])
        queue = SyncQueue()
        queue.roundFinished(with: a, plan: plan, madeCopies: true, connected: [a, b])
        XCTAssertEqual(queue.waiting, [a, b], "A gets the conflict copy, then B")
    }
}
