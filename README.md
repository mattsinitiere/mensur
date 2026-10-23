# Mensur

**0.1.0 alpha (build 3), October 22, 2026.** Start with
[START_HERE.md](START_HERE.md) for the Claude Code → Xcode → iPhone walkthrough.
[CHANGELOG.md](CHANGELOG.md) lists this handoff's changes.

A local-first iPhone/iPad application built with Apple's RoomPlan. Walk around a room, review the detected structure, correct reflective surfaces, and export a floor plan and a simplified 3D model.

## Start here

1. Unzip this project on your Mac.
2. Install and open **a stable Xcode release compatible with your phone's iOS version**, including its iOS platform support. The project was generated for Xcode 16 or later and targets **iOS/iPadOS 17 or later**.
3. Open **Mensur.xcodeproj**. No package manager or third-party app dependencies are required.
4. Select the **Mensur** target → **Signing & Capabilities**. Choose your Apple development team and change `com.matthewsinitiere.Mensur` if Xcode asks for a unique bundle identifier.
5. Connect your LiDAR-equipped iPhone/iPad, trust the Mac, enable Developer Mode if prompted, and select that device as the run destination.
6. Press Run. Grant camera access, then choose **Scan a room**.

A simulator can exercise the sample, editing, and exports but cannot scan a physical room. A non-LiDAR phone can explore projects but cannot capture. An Apple account is required for device signing; distribution through TestFlight/App Store involves Apple's separate enrollment and review process.

**Build status:** The source and Xcode project have been generated and structurally checked. They have NOT been compiled against Apple's SDK or tested on a physical device in the delivery environment (Linux, without Xcode). Treat this as a complete source implementation awaiting the Mac build and device acceptance checks below, not a signed or production-validated app.

## What is implemented

- Mensur's own live capture screen on a RoomPlan session: colour-coded outlines of each wall, window, door and opening as it is found, RoomPlan coaching text, and a live mini-plan with your position. Apple's RoomBuilder processes the result.
- Camera permission, device support, cancel/discard, error, interruption, processing timeout, and thermal handling.
- Ten-minute automatic scan stop for large spaces, with a drift warning from five minutes. Leaving the app, low memory, or critical heat finish and save the scan instead of discarding it.
- Automatic corner squaring after each scan: short RoomPlan pieces at corners are hidden and the two walls extended to meet. Review can also hide short wall stubs, and restores the original pieces in one tap.
- Add a window, door, mirror or opening at a tapped point on a selected wall, for openings RoomPlan missed (such as windows behind blinds).
- Local room library, search, import of corrected project JSON, delete confirmation, and sample project.
- Interactive 2D plan with pinch/drag, tap-to-select, furniture toggle, dimension labels, and fit-to-view.
- Orbitable 3D preview with actual openings in rectangular wall geometry, glass panels, mirror panels, and furniture boxes.
- Surface editor: wall endpoints; height and elevation; parent wall; window/door/mirror width and offset.
- Independent laser/tape length corrections and discrepancy records. Optional connected-corner updates.
- Explicit reflective-surface flags, visual review, exclusion of phantom geometry, and undo.
- Geometry checks for disconnected/crossing boundaries, invalid openings, and unsupported curved/nonuniform walls.
- Imperial/metric display; all edit fields and internal geometry consistently use meters.
- Atomic project JSON writes and unchanged original RoomPlan JSON/USDZ.
- PDF, DXF, OBJ/MTL, JSON, and original USDZ sharing through the system share sheet.

## What this does NOT promise

This is a **parametric room model**, not a photorealistic digital twin. Furniture is represented by bounding boxes. It does not create detailed textures, model hidden surfaces, identify structural wall thickness, determine surveyed door swings, produce certified as-builts, or guarantee a measurement tolerance.

**Mirrors and glass remain a sensor limitation.** The app helps you identify and manually correct affected geometry; it does not automatically detect every mirror, mask depth rays, or make LiDAR see reliably through/against reflective surfaces. High recognition confidence is not a statement of dimensional accuracy.

Curved walls and nonuniform wall heights are flagged, and their original native representation is preserved. The corrected editor/model currently uses straight, vertical rectangular wall envelopes. Whole-building merging, multiple levels, and jointly optimized room alignment are not implemented; each project captures one room.

## First use

1. Tap **Open sample room** to try editing and exporting before scanning.
2. Tap **Scan a room**. Improve lighting and reveal window frames. Flag the room if it contains large mirrors/glass.
3. Walk slowly, covering every wall and corner from multiple viewpoints. Tap **Finish scan**.
4. Open the saved room. Use **Plan**, **3D**, **Elements**, and **Review**.
5. Tap an element to edit it. For a missing mirror/window, use the `+` menu, select its parent wall, and enter offset, width, bottom elevation, and height in meters.
6. For a phantom wall or furniture item, exclude it. Excluding a wall also excludes its attached elements. Undo restores the previous project state.
7. Enter a measured length and tap **Apply measured length**, then **Save**. A check verifies only that element's length. It does not validate its position, angle, height, or neighboring geometry.
8. Review any remaining issues. Export using the share button, then select Save to Files or AirDrop.

### Entering measurements

All numeric geometry fields use **meters** to avoid mixed-unit ambiguity. For example, 12 feet = 3.6576 meters. Imperial display is rounded to the nearest quarter inch and is not a claim that the scan is that accurate. Metric labels round to 0.01 m; the export schedule reports more digits for reproducibility, not certainty.

Applying a measured wall length keeps its start fixed. With **Move connected corners too** enabled, endpoints within 80 mm of its original corners follow the edit. Recheck the resulting adjacent lengths and openings. This is not a global constraint solver.

## Export files

| File | Meaning |
|---|---|
| `Floorplan.pdf` | Page 1 is the 11×17 landscape sheet (below), followed by the full dimension/review schedule (meters), review notes, and measurement records. Print at **100%**, not Fit to Page. |
| `Floorplan.dxf` | Editable R12 linework with separate wall/door/window/opening/mirror/furniture/annotation layers. **Set import units to meters.** Dimensions are text/linework, not associative CAD DIMENSION entities. |
| `Corrected-model.obj` + `.mtl` | Corrected simplified mesh, meters, Y-up. Keep the MTL next to the OBJ. Walls have a **60 mm visual thickness**, which is not surveyed thickness. |
| `Project.json` | Corrected editable project. Import this file to continue editing. |
| `Original-RoomPlan.json` | Original CapturedRoom result before edits; available after a real capture. |
| `Original-RoomPlan.usdz` | Original RoomPlan mesh before edits; available if the native export succeeds. **Does not include your corrections.** |
| `READ-ME.txt` | Export conventions and limitations. |

The corrected OBJ/plan use a floor datum shifted from the original RoomPlan coordinates. The native USDZ/JSON retain their original reference frame. This distinction is intentional and documented, not a seamless interchange of coordinate frames.

### 11 × 17 PDF sheet

Share → **PDF sheet, 11 × 17 → Landscape or Portrait** (also on the plan's tool dock) exports one page:
the Mensur logo and title block; total area plus each enclosed space, perimeter, average ceiling
height and counts; a door and window schedule tagged on the plan (D1, W1…); a numbered wall table;
and a 2D plan squared to the page with dimensions, space areas and an architectural scale
(1/8″ = 1′-0″ and similar in feet and inches; 1:50 and similar in metric) with a scale bar. Areas
come from the enclosed spaces the walls form, so partitions and T-junctions work; a space whose walls
don't close (a gap left by RoomPlan) has no area. Print at 100%.

## Mac app and sync

The same project builds a Mac app (Mac Catalyst; scheme Mensur, destination "My Mac"). It can view,
edit and export rooms; scanning stays on the iPhone. Mac rooms live in `~/Documents/Mensur/Rooms`,
and PDF and file exports save straight into **Downloads** (never overwriting: a repeat gets " 2").

To sync: on the Mac, Settings → **Pair your iPhone** shows a 6-digit code; on the iPhone, Settings →
choose the Mac (or **Pair another Mac** when it already syncs with one) and enter the code. After that, rooms
sync automatically whenever Mensur is open on both devices on the same Wi-Fi. The iPhone can be paired with
several Macs and syncs with each one it finds, so an edit made on one Mac reaches the others through the iPhone. If the same room changed on both, the newest save wins and the other is kept as a
"(conflicted copy)" room. A room deleted on one device moves to `Recently Deleted` in the other device's
Mensur folder. Original RoomPlan files are copied but never replaced. Unpair from Settings at any time.

## Settings

Both apps have a Settings tab: sync and pairing; units for new rooms; default PDF layout; whether plans
show dimensions and furniture; after-scan corner squaring, stub hiding and automatic address (iPhone);
accent colour; and black-and-white plans for printing. Settings stay on each device.

## Storage and privacy

Projects live on the device in `Documents/Rooms/<UUID>/`. Each scan has its own folder. Find them in the Files app under **On My iPhone/iPad → Mensur → Rooms**, or use Finder File Sharing. Keep a copy of the full folder to retain native originals; importing `Project.json` alone does not import USDZ/native JSON.

The app includes no analytics, account login, advertisements, or external AI service, and room data never goes to the internet. Two features use the network: **Wi-Fi sync** talks only to your paired Mac or iPhone on the local network, encrypted with a key created at pairing; and **automatic addresses** send the device's coordinates (not room data) to Apple's geocoding service when a scan is saved or "Use current location" is tapped. Turn the address lookup off in Settings → After each scan. Crash and hang reports that iOS provides through MetricKit are saved only on the device, in `Documents/Diagnostics/`, so a problem can be inspected later; they are never sent anywhere. Processing and saves are local. Standard device backups and destinations you choose in the share sheet may transfer data according to your Apple/device settings. Deleting the app can delete its local data; export backups first.

## Verify on your Mac

From Terminal in this project directory:

```bash
bash scripts/verify-on-mac.sh
```

This runs the pure Swift geometry/export tests, then builds both the iOS Simulator and iPhone app with signing disabled. Logs and result bundles are retained in `build-logs/`. To run just the core tests:

```bash
swift test
```

## Install on your Mac and iPhone

Once Xcode is signed in to your Apple Account (see START_HERE.md), plug in and unlock the iPhone, then run:

```bash
bash scripts/install.sh
```

It pulls the latest commit, builds and signs with the project's team, replaces /Applications/Mensur.app and
installs on every connected iPhone. Saved rooms are kept. With a free Personal Team the iPhone copy stops
opening after 7 days, so run it again to renew it. `--no-pull`, `--mac-only` and `--iphone-only` narrow it,
and logs go to `build-logs/`.

Core tests belong to the Swift package; the app's Xcode scheme does not embed an XCTest target. To inspect these tests in Xcode, open `Package.swift` separately.

After a successful build, follow [the device acceptance checklist](docs/DEVICE_TESTS.md), especially the reflection cases and export consistency checks. The simulator cannot validate RoomPlan capture or LiDAR accuracy.

## Project layout

- `Mensur/Core/` — Codable models, boundary/area validation, corner edits, aperture cutting, triangulation, OBJ, and DXF.
- `Mensur/Capture.swift` — RoomPlan capture lifecycle and native-to-editable model adapter.
- `Mensur/ProjectStore.swift` — local persistence and original scan retention.
- `Mensur/PlanDrawing.swift` — shared plan renderer for interactive view and PDF.
- `Mensur/ModelPreview.swift` — corrected SceneKit viewer.
- `Mensur/SurfaceEditor.swift` — measured corrections and reflection review.
- `Mensur/ExportService.swift` — vector PDF and export package.
- `MensurTests/` — 20 core tests (execution requires Swift).
- `scripts/generate_project.py` — deterministic project-file generator, if sources are added.
- `docs/` — implementation details, accuracy limitations, source references, and test status.

## Next development steps after device testing

1. Capture reference datasets in an ordinary room, a window-heavy room, and a full-height mirror room.
2. Establish measured error distributions using independent checks, not the dimensions used to correct the model.
3. Improve opening alignment and corner editing based on those scans.
4. Add polygonal/curved corrected surfaces if your property inventory needs them.
5. Consider multi-room capture and StructureBuilder only after single-room behavior is validated.
