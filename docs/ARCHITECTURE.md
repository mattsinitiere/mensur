# Architecture and implementation decisions

## Data flow

`RoomCaptureView` performs live capture and Apple's coaching. The view delegate permits RoomPlan's processing, then receives `CapturedRoom`. The original is encoded before conversion, and the native mesh is exported with `.mesh`.

`RoomAdapter` converts surfaces from local X endpoints through their world transforms, projects them to the X/Z plan, normalizes their elevation against the lowest captured wall bottom, and retains identifiers, confidence, parent links, original length, and geometry caveats. The adapter resolves missing parent links only for nearby, aligned walls; unresolved openings remain visible for manual review.

The app edits its own Codable `RoomProject`. It does not mutate or re-encode `CapturedRoom` internals to fake native edits. Read-only RoomPlan properties therefore do not prevent editing the app's model, and the native scan remains an audit reference.

`ProjectStore` persists one JSON document atomically per project. Edits commit immediately when Save is pressed; cancel does not write. Undo stores the previous 30 project states in memory for the open room. Undo history is intentionally not durable across app restarts.

## Plan and area

The display uses the AR X/Z plane. DXF maps it to X/-Z in the conventional CAD XY plane. All units are meters. PDF labels use the chosen display units while the schedule explicitly uses meters.

Area computation accepts one non-self-intersecting connected wall cycle only. It joins endpoints within 80 mm for the area calculation but never silently changes the actual stored or exported coordinates. It rejects duplicate walls, branching graphs, unclosed loops, and multiple disconnected loops. The area is approximate wall-plane area, not gross/rentable/building area.

## Corrected 3D geometry

Walls become rectangular surface patches. Attached valid openings introduce X and Y partition boundaries; cells inside each opening are omitted. Windows receive translucent panels. Mirrors receive solid colored panels and do not create holes or synthetic reflections. Furniture uses detected oriented boxes.

Wall thickness is a fixed 60 mm **visual convention**, not inferred structural thickness. Door swing and trim are omitted because they are not independently measured. Floor triangulation uses ear clipping on the valid boundary, preserving concave shapes. Missing boundaries suppress the floor and area instead of filling a convex hull.

Curved walls and nonuniform heights are flagged and retained in the original native data. Corrected exports currently approximate these as straight rectangular envelopes. Reflection review does not remove raw LiDAR rays or modify RoomPlan's neural models.

## Measurement provenance

Each surface stores captured/manual/edited evidence separately from Apple's recognition confidence. A length check records measured meters, original/reference meters, date, and method. A current-length check only means the stored length matches the entered measured value within 5 mm numerical bookkeeping tolerance; that threshold is **not scanner accuracy**.

Applying a measurement changes one segment along its existing direction. Connected-corner edits propagate only to nearby wall endpoints; this invalidates adjacent walls' previous length checks. Attached openings keep their offset/width relative to their parent start and are rechecked for overflow. It is not a whole-room calibration or least-squares constraint solver.

## Exports

All corrected outputs read the same RoomProject. The plan on screen and PDF share PlanDrawing. DXF and the drawing share visible wall segments. SceneKit and OBJ share ModelMesh. The unedited RoomPlan USDZ remains explicitly named Original-RoomPlan.usdz.

The generated PDF contains vector drawing commands, a print-scale statement, dimensions, review status, and notes. DXF uses ASCII R12 LINE/TEXT entities and semantic layers, with meter units documented in the file and README. OBJ is Y-up with a companion MTL.

## Wi-Fi sync

Sync is peer to peer on the local network (`Sync.swift`), with no server or account. Each Mac advertises `_mensur._tcp` over Bonjour (TXT `name`, `id`, `mode`); the iPhone browses and connects. Connections are TLS 1.2 with a pre-shared key: a key derived from the 6-digit code while pairing, then a random 256-bit key per pairing, kept in the Keychain under the "Mensur sync" service as one list (account "pairings", or `pairings.json` in Application Support when a Mac build has no keychain entitlement).

The iPhone keeps a list of paired Macs (`SyncPairings`) and one connection per Mac it finds. Rounds run one at a time through `SyncQueue`, whichever Mac they're with, so two Macs never change the library at once and each round plans from a current manifest. A round in which anything changed on the iPhone (rooms or files received, conflict copies, rooms moved to Recently Deleted, deletions learned) queues a round with each other connected Mac; rounds that change nothing on the iPhone queue nothing, so the rounds stop once every device agrees. A Mac stays with one iPhone; pairing another iPhone replaces it.

`SyncPlan.make` is a three-way merge against a base: the versions both devices agreed on at the end of their last round. Each pair of devices has its own base (`sync-base-<peer id>.json`) and last-sync date, so pairing or unpairing one Mac leaves the others' history alone. A room changed on both sides since the base is a conflict: the newer save wins and the other is kept as a "(conflicted copy)". Deletions are tombstones (`deletions.json`, kept 180 days) that win only over versions saved before them. A device records the deletions it learns from a peer (`adoptDeletions`, with the original date), so with three devices a deletion spreads instead of the room returning from the device that hasn't heard yet. Original RoomPlan files are only ever added, never replaced.

Earlier builds kept one pairing (Keychain account "pairing", or `pairing.json`), one `sync-base.json` and one `syncLastDate`. The first launch after the update moves them to the new list and to that pairing's own base and date; the old Keychain item is removed only after the list is saved.

## Local privacy

Apart from the Wi-Fi sync above and Apple's address lookup (README), no network client exists. Native originals and corrected projects remain in the application's Documents directory until the user shares or deletes them. OS backups may include this directory. The provided privacy manifest declares no tracking or collected data; re-evaluate disclosures and required-reason APIs before any App Store release or adding new dependencies.

## Scope

Single-room capture. No multi-room merger, construction-grade guarantee, photorealistic texturing, background capture, user accounts, cloud processing, or automatic mirror segmentation. The source is intended to be extended after physical-device validation.
