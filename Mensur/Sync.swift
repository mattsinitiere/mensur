import Foundation
import Combine
import CryptoKit
import Network
import os
import Security
import SwiftUI

// Wi-Fi sync between the iPhone and the Mac app, with no servers or accounts. Each Mac advertises a Bonjour
// service and the phone connects to it. Every connection is TLS with a pre-shared key: a 6-digit code for
// the one-time pairing, then a random 256-bit key both devices keep in their Keychains. Rooms only move
// between paired devices, and only while both apps are open on the same network. The phone can be paired
// with several Macs: it keeps one connection to each Mac it finds and runs one sync round at a time, so an
// edit made on one Mac reaches the others through the phone. A Mac stays with one iPhone.
@MainActor final class SyncService: ObservableObject {
    enum Role { case host, client }
    typealias Peer = SyncPeer
    struct Found: Identifiable, Equatable { let id: String; let name: String; let endpoint: NWEndpoint; let pairing: Bool; let device: UUID? }

    static let service = "_mensur._tcp"
    #if targetEnvironment(macCatalyst)
    let role = Role.host
    #else
    let role = Role.client
    #endif
    @Published private(set) var peers: [Peer] = []                 // iPhone: its paired Macs; Mac: its iPhone
    @Published private(set) var status = ""
    @Published private(set) var syncing = false
    @Published private(set) var connected = false                  // connected to at least one paired device
    @Published private(set) var connectedPeers: Set<UUID> = []
    @Published private(set) var syncingPeer: UUID?
    @Published private(set) var lastSyncs: [UUID: Date] = [:]
    @Published private(set) var pairingCode: String?
    @Published private(set) var found: [Found] = []
    @Published var problem: String?
    @Published private(set) var networkBlocked = false   // Local Network permission is off for Mensur
    // Pairing and sync steps go to the device's own log (Console / log show), for troubleshooting. Nothing
    // personal is logged and nothing leaves the device.
    nonisolated static let log = Logger(subsystem: "com.matthewsinitiere.Mensur", category: "sync")
    static func isBlocked(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code): return code == -65570          // kDNSServiceErr_PolicyDenied
        case .posix(let code): return code == .EPERM || code == .EACCES
        default: return false
        }
    }
    private func networkError(_ error: NWError, while doing: String) {
        Self.log.error("\(doing, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        if Self.isBlocked(error) { networkBlocked = true; problem = Self.blockedHelp }
    }
    static var blockedHelp: String {
        #if targetEnvironment(macCatalyst)
        return "Mensur isn’t allowed on your local network. Turn it on in System Settings → Privacy & Security → Local Network, then try again."
        #else
        return "Mensur isn’t allowed on your local network. Turn on Settings → Privacy & Security → Local Network → Mensur, then try again."
        #endif
    }
    let deviceID: UUID
    let deviceName: String
    private weak var store: ProjectStore?
    private var active = false
    private var pairings = SyncPairings() { didSet { peers = pairings.peers } }
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [UUID: Link] = [:]                           // one per paired device, by its identifier
    private var pairingLink: Link?
    private var pairingFailures = 0
    private var pairingTimer: Timer?
    private var round = Round()
    private var queue = SyncQueue()                                 // iPhone: Macs waiting for a round
    private var stallTimer: Timer?
    private var watch: AnyCancellable?
    private var debounce: Timer?
    private func baseFile(_ peer: UUID) -> URL { AppPaths.support.appendingPathComponent(SyncHistory.baseFile(peer)) }

    // State of one sync round with one peer: both sides exchange manifests, send what the plan says, then "done".
    private struct Round {
        var peer: UUID?
        var running = false, sentManifest = false, sentDone = false, peerDone = false
        var plan: SyncPlan?
        var madeCopies = false
    }

    init() {
        if let saved = Prefs.string("syncDeviceID").flatMap(UUID.init(uuidString:)) { deviceID = saved }
        else { deviceID = UUID(); Prefs.set(deviceID.uuidString, "syncDeviceID") }
        #if targetEnvironment(macCatalyst)
        // UIDevice reports a generic name on Mac Catalyst; the Bonjour host name is the computer's name.
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "").replacingOccurrences(of: "-", with: " ")
        let words = host.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        deviceName = host.isEmpty || host == "localhost" ? "Mac" : String(words.replacingOccurrences(of: "Macbook", with: "MacBook").replacingOccurrences(of: "Imac", with: "iMac").prefix(40))
        #else
        deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        pairings = Keychain.load()            // also converts the single pairing saved by earlier builds
        peers = pairings.peers
        migrateHistory()
        for peer in pairings.peers {
            lastSyncs[peer.id] = Prefs.string(SyncHistory.lastSyncKey(peer.id)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
        updateStatus()
    }
    // Earlier builds kept one pairing with one merge base (sync-base.json) and one last-sync date. They become
    // that pairing's own, so updating doesn't make every room look changed on both sides.
    private func migrateHistory() {
        let legacy = AppPaths.support.appendingPathComponent(SyncHistory.legacyBase)
        let legacyDate = Prefs.string(SyncHistory.legacyLastSync)
        guard FileManager.default.fileExists(atPath: legacy.path) || legacyDate != nil, let owner = SyncHistory.legacyOwner(pairings) else { return }
        if !FileManager.default.fileExists(atPath: baseFile(owner).path) { try? FileManager.default.moveItem(at: legacy, to: baseFile(owner)) }
        try? FileManager.default.removeItem(at: legacy)
        if let legacyDate, Prefs.string(SyncHistory.lastSyncKey(owner)) == nil { Prefs.set(legacyDate, SyncHistory.lastSyncKey(owner)) }
        Prefs.set(nil, SyncHistory.legacyLastSync)
        Self.log.notice("moved the sync history to its pairing")
    }

    func attach(_ store: ProjectStore) {
        guard self.store == nil else { return }
        self.store = store
        // Local edits start a round shortly after they settle; a Mac nudges the phone, which drives rounds.
        watch = store.$localRevision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.debounce?.invalidate()
            self.debounce = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.localChanged() }
            }
        }
    }

    // Runs only while the app is in the foreground. The phone browses only once paired or while pairing,
    // so the Local Network prompt appears when the user asks for sync.
    func setActive(_ value: Bool) {
        active = value
        if value { start() } else { stop() }
    }
    private func start() {
        #if DEBUG
        if peers.isEmpty, let code = testCode, role == .host { pairingCode = code }
        if testCode != nil, role == .client { browse() }
        #endif
        if role == .host { if !peers.isEmpty || pairingCode != nil { listen() } }
        else if !peers.isEmpty { browse() }
        updateStatus()
    }
    #if DEBUG
    // Developer aid for end-to-end tests: launch the apps with MENSUR_TEST_PAIR_CODE=123456. A Mac with no
    // iPhone offers that code, and the phone pairs with each Mac offering one that it isn't paired with yet.
    private var testCode: String? { ProcessInfo.processInfo.environment["MENSUR_TEST_PAIR_CODE"] }
    #endif
    private func stop() {
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        for link in links.values { link.close() }
        links = [:]; pairingLink?.close(); pairingLink = nil
        connectedPeers = []; connected = false; endRound(); queue = SyncQueue(); found = []
        updateStatus()
    }

    // MARK: Pairing

    // Mac: show a code and accept one phone that knows it, for three minutes.
    func beginPairing() {
        guard role == .host else { return }
        pairingCode = String(format: "%06d", Int.random(in: 0..<1_000_000)); pairingFailures = 0
        listen()
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in Task { @MainActor in self?.cancelPairing() } }
        updateStatus()
    }
    func cancelPairing() {
        pairingCode = nil; pairingTimer?.invalidate(); pairingLink?.close(); pairingLink = nil
        if active { listen() }
        updateStatus()
    }
    // Phone: look for Macs, including ones showing a pairing code.
    func lookForMacs() { if role == .client { browse() } }
    func pair(with mac: Found, code: String) {
        guard role == .client, code.count == 6 else { problem = "Enter the 6-digit code shown on your Mac."; return }
        let link = Link(NWConnection(to: mac.endpoint, using: .mensur(key: Self.pairingKey(code), identity: "pair")))
        pairingLink = link
        Self.log.notice("pairing: connecting to Mac")
        link.onReady = { [weak self] in
            guard let self else { return }
            Self.log.notice("pairing: connected, sending hello")
            link.send(.init(kind: .hello, device: self.deviceID, name: self.deviceName))
        }
        link.onMessage = { [weak self] message in
            guard let self, message.kind == .welcome, let device = message.device, let key = message.key else { return }
            self.adopt(Peer(id: device, name: message.name ?? "Mac", key: key))
            link.close(); self.pairingLink = nil
        }
        link.onFailure = { [weak self] error in
            guard let self, self.pairingLink === link else { return }
            self.pairingLink = nil
            Self.log.error("pairing: failed: \(error.map { String(describing: $0) } ?? "closed", privacy: .public)")
            if let error = error as? NWError, Self.isBlocked(error) { self.networkBlocked = true; self.problem = Self.blockedHelp; return }
            self.problem = "Couldn’t pair. Check the code on your Mac and that both devices are on the same Wi-Fi."
        }
        link.start()
        status = "Pairing with \(mac.name)…"
    }
    // Unpairs one device. On the phone the other Macs stay paired and keep their sync history.
    func unpair(_ id: UUID) {
        guard pairings.remove(id) != nil else { return }
        Self.log.notice("unpaired a device")
        forget(id)
        Keychain.save(pairings)
        if role == .host { stop(); if active { start() } }
        else { browse(); runNext() }   // the pairing screen keeps looking for Macs to pair with
        updateStatus()
    }
    private func adopt(_ new: Peer) {
        Self.log.notice("pairing: complete, saving pairing")
        // The phone keeps its other Macs; a Mac stays with one iPhone. A pairing that replaces an earlier one
        // (another iPhone, or this same device paired again) starts with no shared history.
        for old in pairings.add(new, keepOthers: role == .client) { forget(old.id) }
        Keychain.save(pairings)
        pairingCode = nil; pairingTimer?.invalidate()
        if role == .host { listen() } else { browse(); connectFound() }
        updateStatus()
    }
    // Drops a device's connection, queued round and sync history.
    private func forget(_ id: UUID) {
        links[id]?.close(); links[id] = nil
        connectedPeers.remove(id); connected = !connectedPeers.isEmpty
        queue.remove(id)
        if round.peer == id { endRound() }
        try? FileManager.default.removeItem(at: baseFile(id))
        Prefs.set(nil, SyncHistory.lastSyncKey(id)); lastSyncs[id] = nil
    }
    static func pairingKey(_ code: String) -> Data { Data(SHA256.hash(data: Data("mensur-pairing-v1:\(code)".utf8))) }

    // MARK: Network

    private func listen() {
        listener?.cancel(); listener = nil
        let pairing = pairingCode != nil
        guard let key = pairing ? pairingCode.map(Self.pairingKey) : peers.first?.key else { return }
        do {
            let l = try NWListener(using: .mensur(key: key, identity: pairing ? "pair" : "sync"))
            var txt = NWTXTRecord(); txt["name"] = deviceName; txt["id"] = deviceID.uuidString; txt["mode"] = pairing ? "pair" : "sync"
            // The advertised name is unique to this install, so two Macs with the same name never get mixed up;
            // people see the friendly name from the TXT record.
            l.service = NWListener.Service(name: "Mensur-\(deviceID.uuidString.prefix(8))", type: Self.service, txtRecord: txt)
            l.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection, pairing: pairing) } }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: Self.log.notice("listener ready (\(pairing ? "pairing" : "sync", privacy: .public))"); self.networkBlocked = false
                    case .waiting(let error): self.networkError(error, while: "listener")
                    case .failed(let error): self.networkError(error, while: "listener"); if !Self.isBlocked(error) { self.problem = "Sync couldn’t start: \(error.localizedDescription)" }
                    default: break
                    }
                }
            }
            l.serviceRegistrationUpdateHandler = { change in
                if case .add = change { Self.log.notice("advertising on the local network") }
            }
            l.start(queue: .main); listener = l
        } catch { problem = "Sync couldn’t start: \(error.localizedDescription)" }
    }
    private func accept(_ connection: NWConnection, pairing: Bool) {
        let link = Link(connection)
        Self.log.notice("incoming connection (\(pairing ? "pairing" : "sync", privacy: .public))")
        if pairing {
            link.onMessage = { [weak self] message in
                guard let self, message.kind == .hello, let device = message.device else { return }
                Self.log.notice("pairing: hello received, sending key")
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                link.send(.init(kind: .welcome, device: self.deviceID, name: self.deviceName, key: key)) { [weak self] in
                    self?.adopt(Peer(id: device, name: message.name ?? "iPhone", key: key))
                }
            }
            link.onFailure = { [weak self] error in
                // Wrong codes fail the TLS handshake; stop offering pairing after repeated failures.
                guard let self else { return }
                Self.log.error("pairing connection ended: \(error.map { String(describing: $0) } ?? "closed", privacy: .public)")
                self.pairingFailures += 1
                if self.pairingFailures >= 20 { self.cancelPairing(); self.problem = "Pairing stopped after repeated wrong codes. Start again." }
            }
            pairingLink = link; link.start(); return
        }
        // The sync listener's key belongs to the Mac's one iPhone, so only that phone completes the handshake.
        guard let phone = peers.first else { connection.cancel(); return }
        use(link, for: phone.id)
    }
    private func browse() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in Task { @MainActor in self?.update(results) } }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: Self.log.notice("browsing for Macs"); self.networkBlocked = false
                case .waiting(let error): self.networkError(error, while: "browser")
                case .failed(let error): self.networkError(error, while: "browser"); if !Self.isBlocked(error) { self.problem = "Couldn’t look for your Mac: \(error.localizedDescription)" }
                default: break
                }
            }
        }
        b.start(queue: .main); browser = b
    }
    private func update(_ results: Set<NWBrowser.Result>) {
        found = results.compactMap { r in
            guard case let .service(name, _, _, _) = r.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = r.metadata { txt = record.dictionary }
            return Found(id: "\(name)|\(txt["mode"] ?? "")", name: txt["name"] ?? name, endpoint: r.endpoint, pairing: txt["mode"] == "pair", device: txt["id"].flatMap(UUID.init(uuidString:)))
        }.sorted { $0.name < $1.name }
        Self.log.notice("found \(self.found.count) Mac(s), \(self.found.filter(\.pairing).count) showing a pairing code")
        #if DEBUG
        if pairingLink == nil, let code = testCode,
           let mac = found.first(where: { mac in mac.pairing && !peers.contains { $0.id == mac.device } }) { pair(with: mac, code: code) }
        #endif
        connectFound()
        updateStatus()
    }
    // Phone: connects to each paired Mac it can see and has no connection with.
    private func connectFound() {
        guard role == .client else { return }
        for peer in peers where links[peer.id] == nil {
            guard let mac = found.first(where: { !$0.pairing && $0.device == peer.id }) else { continue }
            use(Link(NWConnection(to: mac.endpoint, using: .mensur(key: peer.key, identity: "sync"))), for: peer.id)
        }
    }
    // On the Mac a new connection replaces the current one only after its encrypted handshake succeeds, so a
    // failed or stray attempt can't drop a working sync. The iPhone keeps one connection per Mac and only
    // connects to a Mac it has no connection with.
    private func use(_ new: Link, for id: UUID) {
        if role == .client || links[id] == nil { replaceLink(id, with: new) }
        new.onReady = { [weak self] in
            guard let self else { return }
            if self.links[id] !== new { self.replaceLink(id, with: new) }
            Self.log.notice("sync connection ready")
            self.connectedPeers.insert(id); self.connected = true; self.updateStatus()
            if self.role == .client { self.queue.add([id]); self.runNext() }
        }
        new.onMessage = { [weak self] message in
            guard let self, self.links[id] === new else { return }
            self.handle(message, from: id)
        }
        new.onFailure = { [weak self] error in
            guard let self else { return }
            guard self.links[id] === new else {
                Self.log.notice("ignored a connection that failed before it was ready: \(error.map { String(describing: $0) } ?? "closed", privacy: .public)")
                return
            }
            Self.log.notice("sync connection ended: \(error.map { String(describing: $0) } ?? "closed", privacy: .public)")
            self.links[id] = nil; self.connectedPeers.remove(id); self.connected = !self.connectedPeers.isEmpty
            self.queue.remove(id)
            if self.round.peer == id { self.endRound(); self.runNext() }
            if error != nil, self.role == .client {
                self.problem = "Lost the connection to \(self.pairings.peer(id)?.name ?? "your Mac"). It reconnects when both apps are open."
            }
            self.updateStatus()
        }
        new.start()
    }
    private func replaceLink(_ id: UUID, with new: Link) {
        links[id]?.close(); links[id] = new
        if round.peer == id { endRound() }
    }

    // MARK: Rounds

    func syncNow() {
        if role == .client { connectFound(); queue.add(peers.map(\.id)); runNext() }
        else { for (id, link) in links where connectedPeers.contains(id) { link.send(.init(kind: .changed)) } }
    }
    private func localChanged() {
        if role == .client { queue.add(peers.map(\.id).filter(connectedPeers.contains)); runNext() }
        else { for (id, link) in links where connectedPeers.contains(id) { link.send(.init(kind: .changed)) } }
    }
    // Phone: starts the next queued round unless one is running. Rounds never overlap, so two Macs never
    // change the library at once.
    private func runNext() {
        guard role == .client, !round.running, let store else { return }
        guard let id = queue.next(connected: connectedPeers), let link = links[id] else { return }
        beginRound(with: id, link: link, store: store)
    }
    private func beginRound(with id: UUID, link: Link, store: ProjectStore) {
        round = Round(peer: id, running: true, sentManifest: true); syncing = true; syncingPeer = id
        armStallTimer(); updateStatus()
        link.send(.init(kind: .manifest, manifest: store.manifest(device: deviceID)))
    }
    private func endRound() {
        round = Round(); syncing = false; syncingPeer = nil
        stallTimer?.invalidate(); stallTimer = nil
    }
    // Phone: a round that hears nothing from its Mac for two minutes is abandoned and that connection closed,
    // so the other Macs aren't held up. Sync now, or the Mac reappearing on the network, reconnects it.
    private func armStallTimer() {
        stallTimer?.invalidate(); stallTimer = nil
        guard role == .client else { return }
        stallTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.roundStalled() }
        }
    }
    private func roundStalled() {
        guard round.running, let id = round.peer else { return }
        Self.log.error("sync round stalled, closing that connection")
        links[id]?.close(); links[id] = nil
        connectedPeers.remove(id); connected = !connectedPeers.isEmpty
        endRound(); runNext(); updateStatus()
    }
    private func handle(_ message: Message, from id: UUID) {
        guard let store, let link = links[id] else { return }
        if round.peer == id { armStallTimer() }
        switch message.kind {
        case .manifest:
            guard let theirs = message.manifest, theirs.device == id else { return }
            if round.peer != id || !round.sentManifest {
                // The Mac answers the phone's manifest; the phone only gets one in reply to its own.
                guard role == .host, !round.running else { Self.log.notice("ignored a manifest outside a round"); return }
                beginRound(with: id, link: link, store: store)
            }
            let plan = SyncPlan.make(local: store.manifest(device: deviceID), remote: theirs, base: loadBase(id))
            round.plan = plan
            Self.log.notice("sync round: sending \(plan.send.count), expecting \(plan.expect.count), conflicts \(plan.keepConflictCopy.count), deletions \(plan.moveToRecentlyDeleted.count)")
            do {
                for room in plan.keepConflictCopy { try store.keepConflictCopy(room); round.madeCopies = true }
                for room in plan.moveToRecentlyDeleted { try store.moveToRecentlyDeleted(room) }
            } catch { problem = "Sync couldn’t update a room: \(error.localizedDescription)" }
            // Deletions learned here travel on to this device's other peers.
            store.adoptDeletions(plan.adoptDeletions)
            let rooms = Set(plan.send).union(plan.sendOriginals.keys)
            for room in rooms.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let t = store.transfer(room, project: plan.send.contains(room), originals: plan.sendOriginals[room] ?? []) { link.send(.init(kind: .room, room: t)) }
            }
            round.sentDone = true; link.send(.init(kind: .done))
            finishIfComplete()
        case .room:
            guard round.peer == id, let t = message.room else { return }
            do { try store.receive(t); Self.log.notice("received a room (\(t.project == nil ? "original files" : "project", privacy: .public))") }
            catch { Self.log.error("couldn’t save received room: \(error.localizedDescription, privacy: .public)"); problem = "A room from your other device couldn’t be saved: \(error.localizedDescription)" }
        case .done:
            guard round.peer == id else { return }
            round.peerDone = true; finishIfComplete()
        case .changed:
            if role == .client { queue.add([id]); runNext() }
        case .hello, .welcome: break
        }
    }
    private func finishIfComplete() {
        guard round.sentDone, round.peerDone, let plan = round.plan, let id = round.peer else { return }
        saveBase(plan.base, for: id)
        Self.log.notice("sync round complete")
        let now = Date()
        lastSyncs[id] = now; Prefs.set("\(now.timeIntervalSince1970)", SyncHistory.lastSyncKey(id))
        let madeCopies = round.madeCopies
        endRound()
        if role == .client {
            // Conflict copies are new rooms this Mac hasn't seen; whatever changed here goes on to the other Macs.
            queue.roundFinished(with: id, plan: plan, madeCopies: madeCopies, connected: peers.map(\.id).filter(connectedPeers.contains))
            runNext()
        } else if madeCopies { links[id]?.send(.init(kind: .changed)) }
        updateStatus()
    }
    private func loadBase(_ peer: UUID) -> [UUID: Date] {
        guard let data = try? Data(contentsOf: baseFile(peer)) else { return [:] }
        return (try? ProjectStore.decoder().decode([UUID: Date].self, from: data)) ?? [:]
    }
    private func saveBase(_ base: [UUID: Date], for peer: UUID) {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? ProjectStore.encoder().encode(base).write(to: baseFile(peer), options: .atomic)
    }

    // MARK: Status

    private func updateStatus() {
        let other = role == .host ? "iPhone" : "Mac"
        if pairingCode != nil { status = "Waiting for your iPhone to enter the code"; return }
        guard !peers.isEmpty else { status = "Not paired"; return }
        if let id = syncingPeer, let peer = pairings.peer(id) { status = "Syncing with \(peer.name)…"; return }
        let linked = peers.filter { connectedPeers.contains($0.id) }
        let last = peers.compactMap { lastSyncs[$0.id] }.max()
        if peers.count == 1, let peer = peers.first {
            if !linked.isEmpty { status = lastSyncs[peer.id].map { "Synced with \(peer.name) \($0.formatted(.relative(presentation: .named)))" } ?? "Connected to \(peer.name)" }
            else if !active { status = "Paired with \(peer.name)" }
            else { status = "Waiting for \(peer.name) · open Mensur on your \(other) on the same Wi-Fi" }
            return
        }
        if !linked.isEmpty {
            let names = ListFormatter.localizedString(byJoining: linked.map(\.name))
            status = "Connected to \(names)" + (last.map { " · synced \($0.formatted(.relative(presentation: .named)))" } ?? "")
        }
        else if !active { status = "Paired with \(peers.count) Macs" }
        else { status = "Waiting for your Macs · open Mensur on a Mac on the same Wi-Fi" }
    }
    // One paired device's line in Settings.
    func statusLine(for peer: Peer) -> String {
        if syncingPeer == peer.id { return "Syncing…" }
        let last = lastSyncs[peer.id].map { $0.formatted(.relative(presentation: .named)) }
        if connectedPeers.contains(peer.id) { return last.map { "Connected · synced \($0)" } ?? "Connected" }
        return last.map { "Not connected · last synced \($0)" } ?? "Not connected · not synced yet"
    }
}

// Small sync settings: UserDefaults normally, a file inside the test folder during end-to-end tests.
enum Prefs {
    private static var file: URL? { AppPaths.testRoot == nil ? nil : AppPaths.support.appendingPathComponent("prefs.json") }
    private static func all() -> [String: String] { file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
    static func string(_ key: String) -> String? { file == nil ? UserDefaults.standard.string(forKey: key) : all()[key] }
    static func set(_ value: String?, _ key: String) {
        guard let file else { UserDefaults.standard.set(value, forKey: key); return }
        var values = all(); values[key] = value
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(values).write(to: file)
    }
}

// MARK: Wire format

struct Message: Codable {
    enum Kind: String, Codable { case hello, welcome, manifest, room, done, changed }
    var kind: Kind
    var device: UUID? = nil
    var name: String? = nil
    var key: Data? = nil
    var manifest: SyncManifest? = nil
    var room: RoomTransfer? = nil
}

// One connection, framed as 4-byte big-endian lengths followed by JSON messages.
@MainActor final class Link {
    static let limit = 64 * 1024 * 1024
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Message) -> Void)?
    var onFailure: ((Error?) -> Void)?
    private var closed = false
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.onReady?(); self.receive()
                case .failed(let error): self.fail(error)
                case .waiting(let error): self.fail(error)
                case .cancelled: self.fail(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    func send(_ message: Message, then: (() -> Void)? = nil) {
        guard !closed, let body = try? ProjectStore.encoder().encode(message) else { return }
        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body
        connection.send(content: frame, completion: .contentProcessed { error in
            Task { @MainActor in if error == nil { then?() } }
        })
    }
    func close() { closed = true; connection.cancel() }
    private func fail(_ error: Error?) {
        guard !closed else { return }
        closed = true; connection.cancel(); onFailure?(error)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard let header, header.count == 4, error == nil else { self.fail(error); return }
                let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
                guard length > 0, length <= Self.limit else { self.fail(nil); return }
                self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                    Task { @MainActor in
                        guard let self, !self.closed else { return }
                        guard let body, body.count == length, error == nil,
                              let message = try? ProjectStore.decoder().decode(Message.self, from: body) else { self.fail(error); return }
                        self.onMessage?(message); self.receive()
                    }
                }
            }
        }
    }
}

extension NWParameters {
    // TLS 1.2 with a pre-shared key: both ends must hold the same key or the handshake fails, and all
    // traffic is encrypted. Peer-to-peer Wi-Fi is allowed so it works without a shared router too.
    static func mensur(key: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, idData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options(); tcp.enableKeepalive = true; tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

// The pairings (each peer's identity and shared key) live in this device's Keychain, as one list under the
// "Mensur sync" service. A Mac build signed without a keychain entitlement can't use it, so there they fall
// back to a file only this user can read. Earlier builds kept a single pairing under the account "pairing"
// (or in pairing.json); the first launch after the update moves it into the list.
enum Keychain {
    private static let account = "pairings"
    private static let legacyAccount = "pairing"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Mensur sync", kSecAttrAccount as String: account]
    }
    private static func fallback(_ account: String) -> URL { AppPaths.support.appendingPathComponent("\(account).json") }

    static func load() -> SyncPairings {
        if let data = read(account), let saved = SyncPairings.decode(data) { return saved }
        guard let data = read(legacyAccount), let old = SyncPairings.decode(data) else { return SyncPairings() }
        // The old item is removed only once the list is safely saved, so a failed save tries again next launch.
        if save(old) { remove(legacyAccount); SyncService.log.notice("moved the saved pairing into the list of pairings") }
        return old
    }
    // Saves the whole list, even when empty, so unpairing every device never brings back an old pairing.
    @discardableResult static func save(_ pairings: SyncPairings) -> Bool {
        remove(account)
        let data = pairings.encoded()
        var item = query(account); item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if AppPaths.testRoot == nil, SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: fallback(account).path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    private static func read(_ account: String) -> Data? {
        var item = query(account); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if AppPaths.testRoot == nil, SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
        return try? Data(contentsOf: fallback(account))
    }
    private static func remove(_ account: String) {
        if AppPaths.testRoot == nil { SecItemDelete(query(account) as CFDictionary) }
        try? FileManager.default.removeItem(at: fallback(account))
    }
}

// MARK: Sync screen

// The sync controls, shown as sections of the Settings screen on both devices.
struct SyncSettings: View {
    @EnvironmentObject private var sync: SyncService
    @State private var code = ""
    @State private var chosen: SyncService.Found?
    @State private var unpairing: SyncService.Peer?
    @State private var addingMac = false
    @State private var showTips = false
    var body: some View {
        Group {
            if sync.networkBlocked {
                Section {
                    Label(SyncService.blockedHelp, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                    Button("Open Settings", systemImage: "gear") {
                        #if targetEnvironment(macCatalyst)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { UIApplication.shared.open(url) }
                        #else
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        #endif
                    }
                }
            }
            Section {
                Label(sync.status, systemImage: sync.connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(sync.connected ? Color.green : Color.secondary)
                if sync.syncing { ProgressView() }
                if sync.role == .host, let phone = sync.peers.first {
                    LabeledContent("Paired iPhone", value: phone.name)
                    if sync.pairingCode == nil { Button("Pair a different iPhone", systemImage: "iphone") { sync.beginPairing() } }
                    Button("Unpair", systemImage: "minus.circle", role: .destructive) { unpairing = phone }
                }
                if sync.role == .client && !sync.peers.isEmpty {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }.disabled(sync.syncing)
                }
            } header: { Text(sync.role == .host ? "Sync with iPhone" : "Sync with Mac") } footer: {
                Text(sync.role == .host
                     ? "Rooms sync automatically while Mensur is open on both devices on the same Wi-Fi. Nothing goes through the internet. If a room changes on both, the newest save wins and the other is kept as a “(conflicted copy)”."
                     : "Rooms sync automatically with each paired Mac while Mensur is open on both, on the same Wi-Fi. Nothing goes through the internet. If a room changes in two places, the newest save wins and the other is kept as a “(conflicted copy)”.")
            }
            if sync.role == .host { hostPairing }
            else {
                if !sync.peers.isEmpty { pairedMacs }
                if sync.peers.isEmpty || addingMac { clientPairing }
            }
        }
        .alert("Sync", isPresented: Binding(get: { sync.problem != nil }, set: { if !$0 { sync.problem = nil } })) { Button("OK") { sync.problem = nil } } message: { Text(sync.problem ?? "") }
        .confirmationDialog(unpairing.map { "Unpair \($0.name)?" } ?? "Unpair?", isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
                            titleVisibility: .visible, presenting: unpairing) { peer in
            Button("Unpair", role: .destructive) { sync.unpair(peer.id); unpairing = nil }
        } message: { peer in
            if sync.role == .host { Text("Rooms already synced stay on both devices. Pair again any time.") }
            else { Text("Rooms already synced stay on this \(sync.deviceName) and on \(peer.name).\(sync.peers.count > 1 ? " Your other Macs stay paired." : "") Pair again any time.") }
        }
        .onChange(of: sync.peers.map(\.id)) { _, _ in addingMac = false; chosen = nil; code = "" }
        .onAppear { sync.lookForMacs() }
    }
    @ViewBuilder private var hostPairing: some View {
        if let code = sync.pairingCode {
            Section("Pairing code") {
                Text(code.prefix(3) + " " + code.suffix(3)).font(.system(size: 44, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity)
                Text("Keep this window open. On your iPhone, open Mensur → Settings (tap Pair another Mac if it already syncs with a Mac), choose this Mac and enter the code. It expires in 3 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Cancel pairing", role: .cancel) { sync.cancelPairing() }
            }
        } else if sync.peers.isEmpty {
            Section {
                Button("Pair your iPhone", systemImage: "iphone.gen3") { sync.beginPairing() }
            } footer: {
                Text("Shows a 6-digit code to enter on your iPhone. Pairing is needed once. Your iPhone can be paired with several Macs and keeps them all in step.")
            }
        }
    }
    // Phone: each paired Mac with its own status, and unpairing one at a time.
    @ViewBuilder private var pairedMacs: some View {
        Section {
            ForEach(sync.peers) { mac in
                let linked = sync.connectedPeers.contains(mac.id)
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name)
                            Text(sync.statusLine(for: mac)).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: linked ? "checkmark.circle.fill" : "desktopcomputer").foregroundStyle(linked ? Color.green : Color.secondary)
                    }
                    Spacer()
                    Button("Unpair", role: .destructive) { unpairing = mac }.buttonStyle(.borderless)
                }
            }
            if !addingMac { Button("Pair another Mac", systemImage: "plus.circle") { addingMac = true; sync.lookForMacs() } }
        } header: { Text("Paired Macs") } footer: {
            Text("This \(sync.deviceName) syncs with each paired Mac it finds, one at a time, so a room edited on one Mac reaches the others through it.")
        }
    }
    @ViewBuilder private var clientPairing: some View {
        let macs = sync.found.filter(\.pairing)
        Section {
            if macs.isEmpty {
                HStack { ProgressView(); Text("Looking for your Mac…").foregroundStyle(.secondary) }
                    .task { try? await Task.sleep(for: .seconds(8)); showTips = true }
                if showTips {
                    Text("Not finding it? Check that Mensur on your Mac is showing a pairing code, both are on the same Wi-Fi network, and Local Network is allowed for Mensur in Settings → Privacy & Security → Local Network.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Open Settings", systemImage: "gear") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
            }
            ForEach(macs) { mac in
                Button { chosen = mac; code = "" } label: { Label(mac.name, systemImage: chosen == mac ? "checkmark.circle.fill" : "desktopcomputer") }
            }
            if let mac = chosen {
                TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).font(.title3.monospacedDigit())
                    .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
                Button("Pair with \(mac.name)") { sync.pair(with: mac, code: code) }.disabled(code.count != 6)
            }
            if addingMac { Button("Cancel", role: .cancel) { addingMac = false; chosen = nil; code = "" } }
        } header: { Text(sync.peers.isEmpty ? "Pair with your Mac" : "Pair another Mac") } footer: {
            Text("On your Mac, open Mensur → Settings → Pair your iPhone. Both devices need to be on the same Wi-Fi. Macs already paired stay paired.")
        }
    }
}
