# Delivery validation status

**Source release 1.0.1 (build 2), checked October 20, 2026.** This is an
updated development handoff, not a signed installable app. The host is Linux;
neither Swift nor Xcode is installed. Do not mark the gates below complete
until they have actually run on a Mac and physical device.

## Completed in the authoring environment

- 13 application Swift source files referenced by the generated Xcode project.
- 15 Swift files (application, package manifest, and test source) parsed with Tree-sitter Swift: **zero syntax errors**.
- Xcode project parsed with the Python pbxproj library.
- Project object identifiers and references checked for duplicates/dangling references.
- Shared Xcode scheme parsed as XML.
- Info.plist and PrivacyInfo.xcprivacy parsed successfully.
- Asset catalog JSON and referenced icon file paths checked.
- Mac verification shell script passed `bash -n` syntax validation.
- 20 substantive XCTest cases included for topology, concave room area, apertures, mirror geometry, coordinate edits, provenance, serialization, and export indices.
- The above structural and Swift syntax checks were rerun for 1.0.1 after the
  camera-permission lifecycle change; all passed.
- Python script syntax, local documentation links, and 1.0.1/build 2 metadata
  checked successfully.
- `bash scripts/verify-on-mac.sh` was invoked on Linux and correctly stopped
  with exit status 1 and a macOS/full-Xcode requirement message. It did not run
  core tests or either Apple SDK build. Its Mac execution remains untested.

## Not completed here

- Swift type-checking or execution of XCTest: no Swift compiler was installed.
- iOS SDK compilation: Xcode and Apple's SDKs were not available on the Linux host.
- Simulator UI rendering or visual inspection.
- Native RoomPlan processing, original USDZ export, and camera permission behavior on hardware.
- Actual PDF/DXF/OBJ export rendering on iOS.
- Measured accuracy trials, windows, mirrors, device interruptions, and thermal behavior.

A source parser is not a compiler, and project-file validity is not proof of runtime behavior. Run `bash scripts/verify-on-mac.sh`, then complete `docs/DEVICE_TESTS.md` before treating the app as ready for operational use.

## Mac verification — October 20, 2026

Run on the local Mac in `~/Downloads/Mensur` (no Git worktree).

Environment: macOS 27.0 (26A428), Xcode 27.0 (27A266a) at
`/Applications/Xcode.app/Contents/Developer`, Apple Swift 6.4
(swiftlang-6.4.0.34.1), iOS 27.0 and iOS Simulator 27.0 SDKs.

Command: `bash scripts/verify-on-mac.sh`

1. First run (`build-logs/20261020-095819-12567/`): core tests passed
   (20 tests, 0 failures); the Simulator build failed with
   `PlanDrawing.swift:144: method 'move' with Objective-C selector 'move:'
   conflicts with method 'move' from superclass 'UIResponder'` and
   `PlanDrawing.swift:126: ambiguous use of 'move'`. The iOS 27 SDK adds
   `UIResponder.move(_:)`, which collides with the plan canvas's private pan
   gesture handler.
2. Fix: renamed `PlanCanvas.move(_:)` to `panPlan(_:)` and its `#selector`.
   No behavior change; no other source, project, or signing edits.
3. Second run (`build-logs/20261020-095859-13414/`): exit status 0.
   Core tests 20/20 passed; `** BUILD SUCCEEDED **` for the unsigned
   iOS Simulator build and for the unsigned iPhone (`generic/platform=iOS`)
   build. No Swift compiler warnings.

Simulator smoke test (iPhone 18 Pro simulator, iOS 27.0, unsigned Debug build):

- Open sample room: the sample project was created and listed (4 walls, 215.3 sq ft).
- Plan: rendered with dimensions; drag-to-pan worked (the renamed handler);
  tap selected a wall and showed the Edit card.
- 3D: rendered walls with the door cutout, window and mirror panels, and the table box.
- Elements → Window: changed Width from 1.8 m to 1.5 m and tapped Save. The list
  showed 4′ 11.00″; `Project.json` on disk recorded a length of 1.5 m (schemaVersion 1).
- Persistence: force-quit and relaunched the app; the window still read 4′ 11.00″.
- Export: the share sheet listed six files (51 KB). `Floorplan.pdf` had 3 pages at
  1224×792 pt (17×11 in). Its schedule listed Window 1.500 m. At 1:50 the 5 m wall
  measured 284 pt (expected 283.5) and the 1 m scale bar 57 pt (expected 56.7).
  DXF (R12 layers), OBJ (148 vertices, 110 faces), MTL, Project.json, and
  READ-ME.txt were also written. No original USDZ/JSON, as expected for the sample.

UI fixes after the first smoke test (same day):

- Library: the search field is attached only once rooms exist (and the query
  clears if the library empties), so on iOS 26+ the floating search bar no longer
  covers "Open sample room". Checked on a fresh iPhone 17 simulator (iOS 27.0):
  tapping the button's lower half added the sample; search appeared afterwards.
- Plan tap: openings get a 6 pt bias over their parent wall. Tapping the window
  selected Window, tapping the mirror selected Mirror, and tapping Wall 2 17 pt
  past the window still selected Wall 2.
- Dimension labels: rotated to align with their wall (kept upright) and centered
  12 pt off the wall, between the wall and a dimension line moved from 17 to
  22 pt. Left/right labels no longer overlap the wall stroke, and the bottom label
  clears the mirror outline. Checked in the plan view and in a fresh `Floorplan.pdf`.
- Re-ran `bash scripts/verify-on-mac.sh` (`build-logs/20261020-100937-18008/`):
  exit 0, 20/20 core tests, both unsigned builds succeeded, no Swift warnings.

Edge-case pass (same day):

- Moved plan tap selection, dimension-side choice, and label angle into
  MensurCore (`Geometry.surface(at:)`, `inwardNormal`, `uprightTextAngle`,
  `contains`) and added 6 core tests (26 total).
- Captured walls take their direction from each RoomPlan wall's own axis, so
  dimension lines previously could fall inside the room for some walls and outside
  for others. They now face the room interior: the side of the wall that lies inside
  the closed boundary, or toward the wall-endpoint centroid when no boundary closes.
- Walls within 10° of vertical all read bottom-to-top; before, a wall a fraction
  of a degree off vertical could read the other way from its opposite wall.
- Dimension end ticks are drawn at 45° to their line, so they stay visible on
  diagonal walls (they were fixed screen diagonals).
- A label longer than its wall now points straight out from the wall's outer face.
- Simulator fixtures (iPhone 17, iOS 27.0), generated with the Core models and
  copied into the app's `Documents/Rooms`; all are named "Test ·" and contain no
  scan data: rectangle rotated 30° with reversed walls; walls 0.3° off axis;
  concave L with a 0.35 m jog, adjacent window and door, metric units, and a
  checked length; open boundary with an unassigned window and an excluded wall;
  pentagon with a 45° wall. All loaded without errors. Areas matched hand
  calculations (13.02, 17.28, 19.48, none, 20.88 m²), dimension lines faced inside,
  labels read upright, and the jog label cleared adjacent walls.
- Known limit: a wall shorter than about 11 pt on screen (about 0.3 m at the
  PDF's 1:50) still crowds its label; the PDF schedule lists every length.
- `bash scripts/verify-on-mac.sh` (`build-logs/20261020-102144-21724/`): exit 0,
  26/26 core tests, both unsigned builds succeeded, no Swift warnings.

First phone feedback and round 3 (same day):

- Signed install on iPhone 16 Pro Max (iOS 27.2) with the Personal Team worked; the first real
  scan saved (26 walls, 8 windows, 4 doors, 1 opening, 43 objects, 3 RoomPlan sections).
- Reported: rounded corners, windows behind blinds read as wall, wish for a different scan
  animation, one crash while viewing or editing.
- Diagnosis from a local copy of the scan (kept on the Mac, not committed): three corners were
  closed by pairs of 0.3–0.5 m wall pieces, plus eight short stubs/bumps on long walls. No
  Mensur crash report exists on the phone, and the crash did not reproduce in the Simulator with
  the same scan; MetricKit reports are now saved on device for next time. Found and fixed: saving an
  unchanged wall snapped neighbouring corners.
- Changes: see CHANGELOG Unreleased. 8 new core tests (34 total).
- Simulator (iPhone 17, iOS 27.0) with the scan copy: Review offered "Square 3 rounded corners" and
  "Hide 8 short wall stubs"; after both, 12 walls remained, corners were sharp in Plan and 3D, no
  opening issues; Add here → window placed Window 9 at the tapped point of Wall 1; restore returns
  all 19 changed walls (core harness).
- The new live capture screen compiles for device and Simulator but RoomPlan capture cannot run in
  the Simulator: **its outlines, mini-plan, coaching and processing are untested until scanned on
  the phone.**
- `bash scripts/verify-on-mac.sh` (`build-logs/20261020-105507-31674/`): exit 0, 34/34 core tests,
  both unsigned builds succeeded, no Swift warnings. Signed Debug build installed on the phone with
  `devicectl`; the existing scan files were preserved.

Round 4 — logo, UI, PDF sheet (same day):

- Icon/logo: after the user's sketch, the "balanced" L-plus-square mark; `AppIcon.png` regenerated at
  1024 px, no alpha (verify run `build-logs/20261020-111947-39496/`: exit 0, 39/39). UI direction "Clean blueprint" built. 5 new core tests (39 total).
- Area on the user's scan copy: was "Needs review"; now 2,582 sq ft (Space A 2,238, Space B 344),
  perimeter 224′ 3.5″, from enclosed-space detection.
- PDF sheets rendered in the Simulator (iPhone 17, iOS 27.0) for all seven local projects in both
  orientations via a DEBUG-only render hook, and reviewed visually: user scan at 1/8″ = 1′-0″
  landscape and 3/32″ portrait; sample, L-shape (metric, 1:20), angled walls (1/2″). Exported from the
  dock in the app: one page, 1224 × 792 pt, shared through the share sheet. Full export Floorplan.pdf:
  5 pages (sheet, schedule, notes). **Not yet printed or checked against a ruler.**
- `bash scripts/verify-on-mac.sh` (`build-logs/20261020-111459-38034/`): exit 0, 39/39 core tests, both
  unsigned builds succeeded, no Swift warnings. Signed build installed on the iPhone; scan files kept.

Round 5 — dark mode, space names, address (same day):

- Reported on the phone: white text on light screens in dark mode. Fixed by locking the app to light
  appearance; checked in the Simulator with dark appearance on (library, room screen, alert, sheet).
- Space names and addresses added (2 new core tests, 41 total). In the Simulator: named Space A
  "Showroom" and set a test address; both saved to Project.json, shown on the room screen and plan,
  and in both PDF orientations (address wraps; portrait title band enlarged to fit).
- `bash scripts/verify-on-mac.sh` (`build-logs/20261020-112640-41949/`): exit 0, 41/41 core tests, both
  unsigned builds succeeded. Signed build installed on the iPhone; scan files kept.

Round 6 — Mac app, Wi-Fi sync, Settings, Downloads, automatic address (same day):

- Mac Catalyst enabled (`SUPPORTS_MACCATALYST = YES`; signing team and bundle ID unchanged). Signed Mac
  Debug build installed to /Applications and launched; it created ~/Documents/Mensur.
- 4 new core tests for sync planning (45 total).
- End-to-end sync, iPhone 17 Simulator ↔ Mac app (Mac run with isolated test data, never the real library):
  pairing with the code (test hook, then by hand through Settings), initial merge (7 + 1 rooms, identical
  files both sides), conflict (phone's newer edit won on both; Mac kept "(conflicted copy)", which synced
  back), deletion (moved to Recently Deleted), unpair, and a live edit (address appeared on the Mac within
  seconds). Fixed: browsing didn't restart after unpair; Mac reported its name as "iPad".
- Mac Downloads export (test folder): sheet PDF, "… 2.pdf" on repeat, All files in one room-named folder.
- "Use current location" in the Simulator (simulated Apple Park) filled "1 Apple Park Way, Cupertino CA
  95014". The after-scan lookup shares that code but needs a real scan to test.
- **Not tested:** sync between the physical iPhone and this Mac (needs you to pair), the Mac app's
  screens by eye (no screen-recording permission here), and the Local Network permission prompts.
- `bash scripts/verify-on-mac.sh` (`build-logs/20261020-115549-51436/`): exit 0, 45/45, both unsigned
  builds succeeded. Signed iPhone build installed; scan files kept.

Round 7 — Mac 3D scrolling (same day):

- Scroll-to-zoom and horizontal scroll pan added to the 3D view (scroll events only). Touch-drag orbit in
  the Simulator unchanged. Scroll behaviour itself is **not tested here** (no way to send scroll input to
  the Mac app); direction can be flipped in Settings. verify run `build-logs/20261020-120639-54984/`:
  exit 0. Mac app in /Applications and the iPhone build updated; scan files kept.
- Real iPhone ↔ Mac pairing: as of this round the Mac had no saved pairing and wasn't advertising, so no
  rooms had synced; re-pairing is pending.

Round 8 — real-device pairing investigation (same day):

- Neither the iPhone nor the Mac had a saved pairing; the Mac's Rooms folder was empty. Mac system log:
  the installed Mac app advertised a pairing code at 12:06:05 and received no connection from the phone
  before the app was replaced by an update at 12:06:47 (that update interrupted the attempt). Likely
  cause on the phone side: Local Network permission, which the app previously failed on silently.
- Added explicit Local Network messages and tips, and local logging (subsystem
  com.matthewsinitiere.Mensur). Simulator ↔ test-Mac sync re-verified with the logging. verify run
  `build-logs/20261020-122018-58763/`: exit 0, 45/45. Both apps reinstalled; scan files kept.
- **Real iPhone ↔ Mac pairing and Mac 3D scrolling remain untested.**

Round 9 — real iPhone ↔ Mac pairing (same day):

- Paired at 12:21:26 (Mac log: incoming pairing connection, hello, key, sync listener). First sync at
  12:21:28 received 1 room. The Mac's copy matches the iPhone's: Project.json same content,
  Original-RoomPlan.json and .usdz byte-identical. The Mac stores the pairing key in its fallback file
  (Application Support/Mensur/pairing.json, mode 600): this development build has no keychain entitlement.
- Mac 3D scroll: the log showed one scroll gesture (y +275, zoomed in to 17.7 m) and nothing after it.
  Cause: SceneKit attaches its camera gestures later and those took over scrolling. Fixed with a
  scene-view subclass; touch rotation re-checked in the Simulator; verify run
  `build-logs/20261020-122408-59953/` exit 0, 45/45. Mac app updated. Scroll direction still to confirm.

Round 10 — single-scan photo capture (same day):

- Added KeyframeRecorder (photos + pose + intrinsics, depth/mesh if available, probe.json). Builds for
  iPhone, Simulator and Mac; verify run `build-logs/20261020-123137-61887/` exit 0, 45/45. Installed on
  the iPhone. **Untested until a real scan**; whether RoomPlan exposes depth/mesh is unknown until then.

Round 11 — first real capture (same day):

- Test scan (18.5 s, 2 walls): 27 photos, 1920×1440, poses and intrinsics recorded; 12 MB. probe.json:
  ARRoomCaptureConfiguration, frameSemantics 0, no sceneDepth, no mesh anchors. **RoomPlan does not expose
  LiDAR depth or its mesh**, so the photoreal model must come from photos + poses + RoomPlan geometry.
- Projected RoomPlan walls onto photos with recorded poses: lines plausible (window corner) but this scan
  had few walls in view; alignment not yet confirmed on a full room.
- Apple PhotogrammetrySession (macOS) on the 27 photos: 16 used, 14 s, result a crumpled fragment; pose
  fit to ARKit 18.5 cm RMS. Conclusion: walk-through photogrammetry is unsuitable for rooms. Chosen
  approach: project the photos onto RoomPlan's measured surfaces on the Mac (no depth needed).
- Sharpness varied widely (several motion-blurred frames); content-dependent, so the recorder now picks
  the sharpest frame within short windows. verify `build-logs/20261020-124215-64665/` exit 0; installed.

Round 12 — Mac layout and sync robustness (same day):

- Mac UI reviewed through a DEBUG window-snapshot hook (MENSUR_SNAPSHOTS) since screen recording isn't
  permitted here: overview, room and Settings checked; the window toolbar (title, undo, export) is drawn by
  macOS and not captured, so it is unverified. iPhone library and room screens re-checked in the Simulator.
- Sync log showed the Mac dropping a good connection when a stray attempt with the wrong key arrived (the
  real iPhone, over the device link, reaching a test copy with the same advertised name). Fixed both
  behaviours; re-tested Simulator ↔ test Mac. verify `build-logs/20261020-125554-68832/` exit 0, 45/45.
  Mac app (/Applications) and iPhone updated.

Round 13 — Gaussian splat feasibility (same day):

- Downloaded Brush v0.3.0 (brush-app-aarch64-apple-darwin.tar.xz, 41,447,012 bytes) from the project's
  GitHub release with the user's approval; SHA-256 65b26313…a1048c matches both published checksum files.
  Ad-hoc signed, not notarized; kept in the session scratch folder, not installed.
- Converted the 27-photo test scan with scripts/mensur_to_nerfstudio.py (13,494 starting points) and
  trained 3,000 steps with every 9th photo held out: 74 s on M2 Ultra, 7.2 MB splat. Held-out renders
  place objects correctly (confirms the ARKit poses work as-is), but are blurry or streaky from too few
  photos. A full-room scan is needed for a real quality check.
- Not built yet: photo sync to the Mac, running training from the Mac app, an in-app splat viewer.
- Full-room scan (82 photos, camera positions spread about 1 m in each direction): 30,000 Brush steps in
  17 min 15 s on M2 Ultra, 724,575 splats (171 MB). Held-out photos at 20k and 30k steps render with
  everything in the right place (door panels, hinges, mirror frame, sink, soap bottle) but streaky, and the
  mirror's reflection smears. Viewed from above as a dollhouse it is hazy: large splats that only look right
  from the capture spot fog the room. Trimming to the room box or to within 12 cm of measured surfaces barely
  helped; capping splat size removes the haze but leaves holes. 30k steps looked no better than 20k, so the
  capture (photos from one area, mostly turning) is the limit, not training length.

## Round 14 — drag to edit on the 2D plan (October 20, 2026)

- New Core/PlanEdit.swift (moveWallEnd, moveWall, moveOpening, resizeOpening) with 4 new tests;
  `swift test`: 49 tests, 0 failures.
- `bash scripts/verify-on-mac.sh`: PASS (core tests and both unsigned builds),
  logs `build-logs/20261020-131758-75173`. Mac Catalyst Debug build: BUILD SUCCEEDED.
- iPhone 17 Simulator, clean test data with the sample room: selected a window and dragged it along its
  wall, dragged its end dot past the corner (clamped at the wall end, width 5′ 10¾″ → 7′ 2″), dragged the
  right wall outward (adjoining walls stretched, 215 → 227 sq ft, door moved with it), added a window with
  + (placed on the longest wall, selected), dragged it onto another wall, and dragged a corner up with a
  sideways wobble (wall straightened). Undo enabled after each drag.
- Found and fixed during that test: the plan refitted to the room on every frame of a wall drag, so the
  wall ran away from the pointer and collapsed the room. The framing is now held during and after a drag.
  The one room damaged by the bug was Simulator sample data.
- Signed Debug build installed on the iPhone 16 Pro Max with devicectl; Mac app replaced in /Applications
  after its log showed no sync in progress. Drag editing not yet tried by hand on either device.

## Round 15 — photo-textured dollhouse prototype (October 20, 2026)

- The splat dollhouse was rejected as unusable. Built scripts/dollhouse instead: photos projected onto the
  measured surfaces. Overlaying RoomPlan edges on photos confirmed RoomPlan coordinates equal ARKit world
  coordinates (applying referenceOriginTransform misplaces everything); edges land within a few cm.
- Full-room scan (82 photos): baked in about 2 s on M2 Ultra at 4 mm per texel; walls 76–97% seen, floor 83%.
  Iterations: plain weighted blend (sharp but ghost legs/feet on the floor and exposure patches) → consensus
  rejection (feet gone, blocky seams) → soft agreement with a coarse consensus → linear-light blending →
  per-photo, per-surface smooth gain maps (removed a white blotch two over-bright photos left on the upper wall).
- Result: door, grab bars, paper holders, sink, toilet, vanity, baseboards and floor planks crisp in dollhouse
  views. Remaining: fixtures are RoomPlan boxes, so their unseen sides are plain grey; one shoe at the floor
  edge; faint seams on the plain upper walls. Exported USDZ reloaded in SceneKit and rendered correctly
  (photo in the emissive channel so viewers don't re-light it). Quick Look thumbnailing hung in this
  environment, so Quick Look itself was not checked.

- Sharpness round: comparing a best-single-photo texture with the blend showed the photos carry the detail
  but sit 1–2 cm apart, so blending averaged it away. Added per-photo, per-surface alignment (correlation,
  coarse to fine; median shift 1.8 cm, max 9 cm) and one-photo-per-4-cm-patch selection with feathered seams,
  local-detail scoring and a "floor under the camera is feet" rule; 2 mm texels; bake 9–11 s. Walls, door
  (grain, hinge, knob), switch and floor planks are now sharp. Fixtures stay smeared: RoomPlan gives only
  boxes. The SDK offers RoomCaptureSession(arSession:) and RoomCaptureView(frame:arSession:); whether RoomPlan
  then allows LiDAR depth, the scene mesh or high-resolution stills is untested (needs a device scan).

## Round 16 — capture for photogrammetry/splats, dollhouse tuning (October 20, 2026)

- Capture.swift: RoomCaptureSession(arSession:) with an app-owned ARSession; one second after start the running
  ARRoomCaptureConfiguration (an ARWorldTrackingConfiguration subclass) is re-run with .sceneDepth and
  .mesh added. Untested on device: RoomPlan may reject or ignore it; probe-depth.json and the log will tell.
  Fallback: if under a quarter of keyframes have depth, Finish runs a 60 s walk-around with
  ARWorldTrackingConfiguration (depth, mesh, high-resolution video format) without resetting tracking.
- KeyframeRecorder: captureHighResolutionFrame stills (max 250, ≥0.6 s apart, disabled after first refusal),
  keyframes every 10 cm / 6°, depth and still counts, walked distance, pass tag, notes.json.
- Built: signed iPhone Debug, Mac Catalyst Debug, both BUILD SUCCEEDED; installed on the iPhone 16 Pro Max.
  Not yet scanned with; capture changes are untested on device.
- scripts/dollhouse: new hole fill (multi-radius smooth fill plus borrowed fine texture), unseen fixture
  sides coloured from the fixture's seen sides, full-resolution stills preferred (loaded at ≤3000 px), and
  LiDAR mesh fixtures (triangles inside each object box, minus wall/floor triangles, per-triangle photo
  choice smoothed across neighbours, atlas). Mesh path tested only with a stand-in mesh made from a box.

## Round 17 — first scan with depth and mesh (October 20, 2026)

- Office at 1004 Priya Ln (about 21 × 17 m, 20 walls, 9 windows, 45 objects), scanned with the Round 16 build.
  probe-depth.json: RoomPlan accepted .sceneDepth and .mesh (frameSemantics 8, sceneReconstruction 25), so
  no walk-around was needed. 231 keyframes, all with 256×192 depth; 133 stills, but only 2016×1512 (RoomPlan's
  video format allows nothing larger); mesh.obj 1.7 M triangles; camera travelled about 16 m.
- RoomPlan walls overlay the photos within millimetres (pillar edges, ceiling line).
- scripts/dollhouse reworked for large rooms: depth-based visibility, per-photo footprints, adaptive texel,
  footprint-cropped alignment, mesh off the walls/floor textured in 2 m tiles with a depth-built visibility
  grid. Fixed: walls of non-convex rooms faced outward (now oriented by the floor outline); unseen mesh
  triangles hidden; low-confidence depth treated as not visible. Bake: 53 s, 7.9 GB peak memory.
  Rendering the model from photo poses matches walls, doors, windows, cabinets; furniture is rough (LiDAR
  mesh detail is about 5 cm).
- Splat (Brush, seeded from mesh vertices, 469k points): at 10k steps held-out views are close to the photos
  (each has a full-resolution twin in training, so that is optimistic); from above it is hazy and the floor
  greyish. 30k steps still running at the time of writing.

## Round 18 — splat route, wall correction, coverage guide (October 20, 2026)

- Photo-projection dollhouse rejected by Matthew as unusable. Direction: Gaussian splatting from the single
  scan, trained on the Mac; bundling Brush (Apache-2.0, ~150 MB) in the Mac app approved. Mac pipeline not
  built yet (next round).
- A top-down LiDAR slice of the office showed most walls had little close coverage (camera stayed mid-room).
- Core/WallFit.swift with 3 new tests; `swift test`: 52 tests, 0 failures. On the office mesh (upright
  triangles, since that scan predates labelled meshes): 11 walls moved 0–14 cm (long walls 2–9 cm), 1 flagged,
  0 added; 0.03 s. Earlier versions moved window walls outward onto things seen through the glass, and
  pillar faces up to 37 cm; fixed by ignoring opening spans and capping short walls.
- `bash scripts/verify-on-mac.sh`: PASS, logs build-logs/20261020-152209-9317. Signed iPhone and Mac Catalyst
  Debug builds succeeded; installed on the iPhone 16 Pro Max (launch refused: phone locked) and Mac
  (/Applications, after its log showed no activity). Wall coverage guide, white-balance lock, labelled mesh
  and the in-app wall correction are untested on a real scan.

## Round 19 — Mac splat pipeline (October 20, 2026)

- Capture sync (SyncPlan.sendCapture, FileChunk, ProjectStore.receive(_:FileChunk), SyncService uploads), the
  bundled Brush build phase, SplatTrainer.swift (dataset export, posix_spawn training, progress, status) and
  SplatView.swift (Metal splat viewer) added; 2 new tests, `swift test`: 54 tests, 0 failures.
- `bash scripts/verify-on-mac.sh`: PASS, logs build-logs/20261020-153551-13700. Signed iPhone and Mac builds
  succeeded; helper verified signed with the app's Apple Development identity (`codesign --verify --deep`).
- End to end with isolated test data (iPhone 17 Simulator holding the office scan, a test Mac instance, test
  pairing code): paired, room synced, all 1,097 capture files (370 MB) arrived in about 40 s over localhost and
  were byte-identical (`diff -rq`); training started by itself and finished in 26 min (30,000 steps,
  1,798,044 splats, 112 MB, vs 1.6 GB uncapped); the Photoreal tab loaded it in 0.47 s.
- The capped (2 M, SH degree 0) splat shows more needle-like streaks at the edges than the uncapped 5 M one;
  quality tuning still to do.
- Installed: iPhone 16 Pro Max (new build) and Mac (/Applications, after its log showed no activity).
  Not yet tested: real Wi-Fi transfer from the phone, viewer mouse/trackpad interaction by hand.

## Round 20 — one scan for plan and splat, steadiness coach (October 20, 2026)

- Matthew: keep the site plan, and get the splat from the same scan, with guidance to move more steadily.
- Capture.swift: 4K video format requested alongside depth/mesh (Setting.photos4K), activeMaxExposureDuration
  capped at 1/120 s once white balance is locked, motion measured at 12 Hz (smoothed turn and walk rates) with
  a badge and warning haptic; KeyframeRecorder keeps frames only when steady and saves frames wider than
  2560 px downscaled with intrinsics scaled to match ("cameraSize" records the original).
- `bash scripts/verify-on-mac.sh`: PASS, logs build-logs/20261020-164831-32788. Signed iPhone build installed.
- Untested on device: whether RoomPlan keeps running on the 4K format, the shutter cap, and the badge. RoomPlan
  doesn't run in the Simulator, so none of this could be exercised there.

## Round 21 — splats dropped; panes, LiDAR openings and ceiling (October 20, 2026)

- Matthew: steadiness coaching far too sensitive; drop 3D splatting; focus on plan and 3D model accuracy,
  PDF/DXF export, and recognising objects, windows, doors and window splits.
- Removed SplatTrainer, SplatView, photo capture (KeyframeRecorder), capture sync, Vendor/Brush and its build
  phase, the Photoreal tab and settings; Sync.swift, ProjectStore.swift and SyncPlan.swift restored from the
  copies taken just before photo sync was added. Archive: docs/archive/splat-pipeline-2026-10-20.zip.
- New ScanRecorder.swift (labelled LiDAR points, levels, window close-ups; no photos) and Core/Openings.swift
  (WindowPanes, LidarOpenings, LidarLevels); PlanSurface.dividers/rails (optional; schemaVersion stays 1);
  AutoCleanup.originalHeight. 6 new tests; `swift test`: 58 tests, 0 failures.
- iPhone 17 Simulator, sample room (its window given one divider): divider shown on the plan and room card,
  a frame bar in the 3D view, "Window 2 × 1" in the PDF schedule; DXF gets the divider line (test).
- `bash scripts/verify-on-mac.sh`: PASS, logs build-logs/20261020-171838-45093. Signed iPhone build installed;
  Mac app rebuilt (6.1 MB) and installed in /Applications after its log showed no activity.
- Untested on device: window close-ups and pane detection on real windows, LiDAR-found openings, ceiling
  correction, object detail names. RoomPlan doesn't run in the Simulator.

## Round 22 — wall joins, opening tidying, LiDAR check (October 20, 2026)

- Matthew asked for better wall and window joins and "99% accurate every time". No scan method can guarantee
  that, so this round tidies geometry and adds a per-wall LiDAR check that shows when a plan is confirmed.
- Core/Joins.swift (WallJoins: square, close, merge; OpeningJoins), WallFit.check (LidarCheck on walls),
  PlanSurface.reviewNote (LiDAR findings no longer block the area), AutoCleanup originalBottom/originalParent,
  reasons tidied/merged. 6 new tests; `swift test`: 64 tests, 0 failures.
- Office scan (RoomPlan geometry restored, upright mesh triangles as wall points): walls confirmed 2 of 7
  checkable as scanned → 6 of 7 after (11 short pillar/glass pieces have too little solid wall to check);
  5 walls squared, 3 corner gaps closed, 1 opening edge tidied, 0 merges; area 211.0 → 213.2 m²; valid.
  First version scattered points by RMS and marked mostly-glass walls unconfirmed; now median-based and
  skipped. Simulator (iPhone 17, test data): office opens at 2,295 sq ft; Review shows the LiDAR check.
- `bash scripts/verify-on-mac.sh`: PASS, logs build-logs/20261020-172947-51393. Signed iPhone build installed;
  Mac app replaced after its last sync round had completed.
- Accent colour menu dots fixed (pre-coloured images; menus retint SF Symbols). Checked in the Simulator: blue,
  teal, green, orange and graphite dots each show their colour. Reinstalled on iPhone and Mac.
- Not measured: true accuracy against tape measurements. Needs a scan plus independent measurements
  (docs/DEVICE_TESTS.md).

## Round 23 — window panes, LiDAR opening edges, 3D windows (October 22, 2026)

- Matthew (phone connected): edges not detected well, windows in 3D "super weird with the white bars", accuracy
  needs to be much better. Copies of the two October 21 scans were taken from the phone with `devicectl device
  copy from` into the session scratch folder (not the project) and analysed.
- Findings on the 11:06 PM scan: a 0.74 m 6-over-6 window had 3 × 7 "dividers" (sash edges, both sides of the
  meeting rail), drawn as full-depth white slabs; windows were 6–8 cm narrower than the gap in the LiDAR wall
  points and one sill 10–15 cm too high; RoomPlan's floor sat 4.4 cm below the LiDAR floor; a ceiling bulkhead
  (wall-labelled points only 2.3–3.0 m above the floor) had been added as a full-height wall, which also hid the
  area; walls with a stepped top ("Nonuniform wall height") hide the area as well.
- Changes: see CHANGELOG Unreleased. New/changed Core: WindowPanes (ridge bars, per-close-up placement),
  LidarOpeningEdges, LidarLevels(roomFloor:), WallFit(missingFrom:), RoomProject.movingReviewNotes, ModelMesh
  frames; ProjectStore.build/rebuilt (Review → Re-run scan corrections). 8 new tests; `swift test`: 72 tests,
  0 failures.
- Scratch harness (Core sources + the scan copies): both windows now 2 × 3 bars, matching the close-ups;
  windows 0.739 → 0.820 m and 0.778 → 0.840 m wide, sill 0.823 → 0.723 m; the door keeps RoomPlan's width
  (sparse trim points on both sides make the LiDAR edge ambiguous); 10:26 AM glass wall 2.55 → 2.70 m.
- iPhone 17 Simulator, launched with MENSUR_TEST_DATA holding the two scan copies (no sync, real library
  untouched): Re-run scan corrections removed the bulkhead wall; the room went from "Area needs review · 5 walls"
  to 533 sq ft · 4 walls, perimeter 94′ 5.5″ (8.71 × 5.68 m = 49.5 m²); 3D shows lit, opaque walls and framed
  3 × 4-lite windows without seams.
- `bash scripts/verify-on-mac.sh`: PASS, logs build-logs/20261022-124203-6849 (72 tests; both unsigned builds;
  one existing warning, Capture.swift:445). Signed Debug build installed on the iPhone 16 Pro Max with
  devicectl; its 7 rooms are still there. The phone's own rooms were not re-run.
- Not verified: any of this against a tape measure. The LiDAR-gap edges are measurements of where the wall
  surface stops, which for windows includes the frame and for doors may include trim; new window close-ups now
  record RoomPlan's window position, which is untested until the next real scan.

## Round 24 — Mensur name and new icon (October 22, 2026)

- Everything is named Mensur: the display and bundle names, bundle ID `com.matthewsinitiere.Mensur`, the target,
  scheme and project (`Mensur.xcodeproj`), the source folder (`Mensur/`), the core package (`MensurCore`), its
  tests (`MensurTests/`), the Documents and Application Support folders, the `_mensur._tcp` sync service, the
  pairing salt and Keychain entry, the logger subsystem, scripts and docs. `DEVELOPMENT_TEAM` (KM25U2VHNT)
  and every other build setting are kept.
- AppIcon set: light, dark and tinted 1024 px PNGs (from `swift scripts/make_icons.swift brand/icon`). The
  previous icon is kept at brand/legacy/previous-icon.png. `BrandMark` (library header, PDF) draws the same
  dot room.
- `bash scripts/verify-on-mac.sh` in `~/Downloads/Mensur` (`build-logs/20261022-131808-20539/`): core tests 72,
  0 failures; unsigned Simulator and iPhone builds succeeded. The built app's Info.plist reads Mensur /
  com.matthewsinitiere.Mensur / `_mensur._tcp`, and no file in the app bundle contains the old name.
- Simulator (iPhone 18 Pro, iOS 27.0): Mensur launches with its own empty storage (new bundle ID), shows the
  Mensur header and dot mark, and creates and saves the sample room. Earlier in this round, an 11 × 17 PDF
  export showed Mensur and the dot mark in its title block.
- This Mac's six rooms were copied to `~/Documents/Mensur` (the copies are identical; three splat image links
  now point inside the copy). Sync bookkeeping wasn't copied, so the iPhone pairs again from scratch.
- Mac: `xcodebuild -project Mensur.xcodeproj -scheme Mensur -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build-signed -allowProvisioningUpdates build`
  (`build-logs/20261022-132445-mac/`) BUILD SUCCEEDED, signed com.matthewsinitiere.Mensur / KM25U2VHNT,
  installed as /Applications/Mensur.app and launched. Matthew installed the iPhone build himself.
- Not checked: that the Mac app lists the six rooms (its window wasn't visible from here), re-pairing and
  syncing rooms to the new iPhone app, and the dark and tinted icons on screen (the simulator's home-screen icon style is Light).

## Round 25 — Mac sidebar Settings, Clear all rooms (October 22, 2026)

- Mac sidebar: Settings moved out of the room list into the pinned area at the bottom, above the sync status,
  so it stays visible with a long list. ⌘, also opens it.
- Settings → Rooms → Clear all rooms (`ProjectStore.removeAll`): each room moves to Documents/Recently Deleted
  and gets a deletion record, so a paired device moves its copies to its own Recently Deleted on the next sync.
  With no rooms, the row reads "No rooms to clear".
- `bash scripts/verify-on-mac.sh` (`build-logs/20261022-133048-27233/`): 72 tests, 0 failures; unsigned
  Simulator and iPhone builds succeeded. Signed Mac Catalyst build (`build-logs/20261022-133055-mac/`)
  succeeded and was installed as /Applications/Mensur.app.
- Simulator (iPhone 18 Pro, iOS 27.0, sample room): the confirmation reads "Clear 1 room?" and points at the
  button; confirming left 0 rooms, moved the room to Documents/Recently Deleted, and wrote deletions.json. The
  room stayed cleared after a relaunch.
- Not checked: the Mac sidebar on screen (this session can't capture the screen), and a clear propagating
  to a paired device.

## Round 26 — narrow-window stat cards, plan stretching (October 22, 2026)

- Matthew's Mac screenshots: the six stat cards squeezed their labels in a narrower window, and the plan was
  stretched sideways after a resize. The cards now use `ViewThatFits` (one row of six at least 120 pt wide,
  otherwise two rows of three), and `PlanCanvas` and the capture screen's mini-plan use `contentMode = .redraw`.
- `bash scripts/verify-on-mac.sh` (`build-logs/20261022-133344-28523/`): 72 tests, 0 failures; both unsigned
  builds succeeded. Signed Mac Catalyst build (`build-logs/20261022-133356-mac/`) installed as
  /Applications/Mensur.app.
- Not checked on screen: this session can't capture the Mac display.

## Round 27 — iPhone syncs with several Macs (October 22, 2026)

- Matthew works from three Macs (two Mac Studios, an M1 MacBook Pro) and wants the iPhone to sync with all of
  them. The iPhone now keeps a list of paired Macs, one connection per Mac it finds, and runs one sync round at
  a time (`SyncQueue`); a round that changes anything on the iPhone queues a round with each other connected
  Mac, so an edit made on one Mac reaches the others. A Mac still pairs with one iPhone. Details in CHANGELOG
  Unreleased and docs/ARCHITECTURE.md → Wi-Fi sync.
- Per-pairing history: `sync-base-<peer id>.json` and `syncLastDate-<peer id>` instead of one `sync-base.json`
  and `syncLastDate`. Migration on first launch: the Keychain item "pairing" (or `pairing.json`) becomes the
  list "pairings" (or `pairings.json`); the old item is removed only after the list saved. `sync-base.json` and
  the last-sync date move to that one pairing. Keychain service "Mensur sync", `_mensur._tcp`, bundle ID and
  project `schemaVersion` 1 unchanged; the wire format is unchanged.
- Found while writing the three-device tests: a device that applied a peer's deletion kept no deletion record
  of its own, so with two Macs the room came straight back from the other Mac (and, in the simulation, rounds
  never stopped). `SyncPlan.adoptDeletions` now records the peer's deletion, with its date, on the receiving
  device. Also new: `SyncPlan.expectOriginals` and `changesHere`.
- New Core file `Mensur/Core/SyncPeers.swift` (`SyncPeer`, `SyncPairings`, `SyncHistory`, `SyncQueue`), added
  to `Mensur.xcodeproj/project.pbxproj` by hand (IDs 5A1C0D2E9B7F4A6C8E3D1F6D/6E); `scripts/generate_project.py`
  was not run. New tests: `MensurTests/MultiDeviceSyncTests.swift` (13), including a phone-and-two-Macs
  simulation that runs real `SyncPlan` rounds with per-pair bases through the queue.
- Run in a Linux cloud session (no Xcode), with Swift 5.10.1 from Ubuntu's `swiftlang` package:
  `swift test` → 85 tests, 0 failures (72 before this change, also 0 failures on `main`). With deletion
  recording removed from the simulation, the deletion test fails (5 assertions, rounds hit the 20-round limit),
  so the test exercises the fix.
- `python3 scripts/check_structure.py` → PASS (24 Swift files referenced; Swift syntax parsing of 27 files with
  tree-sitter-swift 0.7.4). On `main` it failed with "Missing Xcode source: SurfaceEditor.swift": it expected
  quoted paths and IDs without Xcode's `/* name */` comments. Fixed in the script; it still fails when a source
  file is missing from the project.
- `Sync.swift` service code (SyncService, Prefs, Message, Link, Keychain) type-checked on Linux against
  hand-written stand-ins for Network, Combine, os.Logger, Security and CryptoKit. SwiftUI (SyncSettings, the
  Settings/Mac sidebar changes) was not type-checked.
- Not run: any Xcode build (iOS Simulator, iPhone or Mac Catalyst), `bash scripts/verify-on-mac.sh`, the
  Simulator, or a device. Multi-Mac sync, the Settings screens and the migration from a single pairing are
  untested on Apple hardware; see the PR's Mac checklist and docs/DEVICE_TESTS.md.

## Handoff to a second Mac (October 20, 2026)

- docs/NEW_MAC_SETUP.md: setting up another Mac from Xcode onwards. a handoff zip
  (300 KB, 69 files): the project without build folders or logs, plus Claude's project notes. An unzipped copy
  passed `swift test` (64 tests, 0 failures) and an unsigned iOS Simulator build. Removed `target/`, a GPU
  cache the Brush trainer left in the project folder.

## Mac/device handoff record

| Gate | Status | Record |
|---|---|---|
| Core XCTest execution | PASS | Swift 6.4, 72 tests, 0 failures, latest `build-logs/20261022-131808-20539/core-tests.log` |
| Simulator SDK build | PASS | Xcode 27.0 (27A266a), iOS Simulator 27.0 SDK, unsigned Debug |
| iPhone SDK build | PASS | Xcode 27.0 (27A266a), iOS 27.0 SDK, unsigned Debug |
| Simulator smoke test | PASS (sample only) | iPhone 18 Pro and iPhone 17 sims, iOS 27.0: sample, plan/3D, edit, save, relaunch, PDF/DXF/OBJ export, UI fixes |
| Signed iPhone install | PASS | iPhone 16 Pro Max, iOS 27.2, Personal Team; launched after trusting the developer |
| iPhone ↔ Mac sync | PASS | Paired; scan synced with identical originals |
| iPhone ↔ several Macs sync | NOT BUILT | Round 27 source only: Core tests pass on Linux; no Xcode build or device test yet |
| Real room capture | PARTIAL | One large space saved with the original RoomCaptureView build; new capture screen untested |
| Camera-denial alert lifecycle change | NOT DEVICE-TESTED | Deny, close, enable permission, retry |
| Window/mirror trials | NOT RUN | Defects, corrections, withheld measurements |
| PDF/CAD/3D export verification | PARTIAL | Sample PDF page size/scale checked in Simulator; CAD/3D viewer import and real-scan exports not run |
| LiDAR measurement accuracy | NOT RUN | Requires physical device and independent measurements |

Build success alone does not establish dimensional accuracy. Simulator results
use synthetic sample data and do not exercise RoomPlan capture or LiDAR.
