# Changes

## Unreleased

- Sync with several Macs: the iPhone keeps a list of paired Macs and syncs with each one it finds on the Wi-Fi,
  one round at a time, so a room edited or deleted on one Mac reaches the others through the iPhone. Settings on
  the iPhone lists the paired Macs with each one's status and last sync, **Pair another Mac**, and **Unpair** per
  Mac; pairing or unpairing one Mac leaves the others paired. A Mac still pairs with one iPhone.
- Each pairing keeps its own sync history (`sync-base-<device>.json` and its own last-sync date) instead of one
  shared `sync-base.json`, so a new pairing no longer wipes the history kept with the other Macs.
- Deletions now travel on: a room deleted on one device is recorded on each device that hears about it, so a
  device paired with several others passes the deletion on instead of receiving the room back from another.
- Updating keeps the existing pairing: on first launch the single saved pairing (Keychain item "pairing", or
  `pairing.json`) becomes the first entry of the new list (Keychain item "pairings", or `pairings.json`), and
  `sync-base.json` and the last-sync date become that pairing's. Nobody needs to pair again. The "Mensur sync"
  Keychain service, the `_mensur._tcp` Bonjour service and the room files are unchanged.
- A sync round that hears nothing from its Mac for two minutes is abandoned and that connection closed, so one
  unresponsive Mac can't hold up the others; Sync now reconnects it.
- `scripts/check_structure.py` matched project paths only in quotes and object IDs only without Xcode's
  `/* name */` comments, so it failed on the current project; it now accepts Xcode's format.

- Room view: the six measurement cards wrap into two rows of three when the window is narrow, instead of
  squeezing labels like "AREA" to a letter per line. The floor plan redraws when the window is resized,
  instead of stretching the previous drawing.
- Mac: Settings and the sync status are pinned to the bottom of the sidebar, so they stay visible however long
  the room list gets (⌘, opens Settings too).
- Settings → Rooms → Clear all rooms (iPhone and Mac). Every room moves to the Recently Deleted folder in the
  rooms folder instead of being erased, and the deletions sync, so a paired device moves its copies there too.
- The app is now Mensur, with bundle ID com.matthewsinitiere.Mensur. It installs as a new app with its own
  storage: rooms live in Documents/Mensur on the Mac, and the iPhone needs pairing again (Settings → Pair).
  Rooms then sync across from the Mac. New app icon with light, dark and tinted variants: an isometric room
  built from even dots (brand/icon, made by scripts/make_icons.swift). The in-app and PDF logo uses the same
  artwork.
- Window panes: dividers are now found as thin bars (lighter or darker than the glass on both sides), so the
  glass meeting its frame or the sash meeting the jamb no longer counts as a bar. On a real 6-over-6 window the
  old detector reported 3 × 7 bars; it now reports 2 × 3. Close-ups record where RoomPlan had the window when
  they were taken (its estimate changes during a scan), and bars are placed on the final window accordingly;
  a bar needs half the close-ups covering its place to agree and must sit at least 10 cm inside the window.
- Window and door edges from the LiDAR: each edge moves to the edge of the gap the opening leaves in the
  measured wall surface (up to 15 cm sideways, 20 cm up or down), only where solid wall is measured beyond it.
  On a real scan: windows 6–8 cm wider and one sill 10 cm lower than RoomPlan had them. When one side's
  evidence disagrees by more than that, the opening keeps RoomPlan's sides. Window bars keep their place.
- Heights measured from the LiDAR floor: RoomPlan's floor can be a few centimetres off (4.4 cm low on a real
  scan), which moved every sill and head height by as much. Within 15 cm, window and mirror heights and the
  tops of doors and openings are now measured from the floor the LiDAR found.
- Ceiling bulkheads and soffits are no longer added as walls "RoomPlan missed": missing walls are searched for
  only in wall points 0.9–1.9 m above the floor.
- 3D view: lit and flat-shaded (walls, frames and furniture show their edges) instead of flat colour, with
  opaque walls (translucent ones showed lines wherever a wall was split around a window); windows get a 4 cm
  frame and 2.5 cm bars instead of full-depth white slabs. The OBJ export gets the same frames, and no longer
  has faces inside walls between the pieces around openings.
- Area: a wall with a stepped or sloping top ("Nonuniform wall height") no longer hides the room's area; it
  becomes a note to review. Only curved walls still hide it. Rooms saved earlier are converted when opened.
- Review → Re-run scan corrections rebuilds a room from its original RoomPlan scan and LiDAR measurements with
  the latest corrections, keeping its name, address, notes and space names (Undo restores the previous version).
- Fixed: the accent colour menu in Settings showed every colour dot in the same tint; each dot is now drawn in
  its own colour.
- Wall joins after each scan (Core/Joins.swift): walls within 3° of the room's axes are squared exactly (the
  axis taken from walls that already agree), joined corners rejoined where the new lines cross; free wall ends
  within 35 cm of each other are joined as an L corner, or run onto a nearby wall as a T; two pieces of one
  straight wall (in line within 2° and 3 cm, nothing else at the joint) become one wall, its openings moving
  with it.
- Window and door tidying: edges within 4 cm of a wall end go into the corner; neighbouring openings that nearly
  touch or slightly overlap share one edge; windows on the same wall with sills or heads within 3 cm line up;
  doors within 5 cm of the floor start at it.
- LiDAR check: after a scan each wall records how well the LiDAR confirms it (share of its solid length seen,
  offset and scatter of the measured surface). Review shows "N of M walls confirmed by the LiDAR" and each wall's
  status, unconfirmed first; the PDF sheet lists LiDAR-confirmed walls. Edits clear a wall's check.
- Fixed: walls flagged by the LiDAR ("not confirmed", "found by the LiDAR") stopped the room's area being shown.
  Those notes are now a separate review note; rooms saved earlier are converted when opened.
- All of these record RoomPlan's original, and Review → Restore original corners and stubs undoes them.
- Photoreal 3D removed (Gaussian splats, photo capture, steadiness coach, photo sync, bundled Brush, Photoreal tab);
  archived in docs/archive/splat-pipeline-2026-10-20.zip. Scans record no photos again, and the Mac app is back
  to about 6 MB.
- Scans now record LiDAR measurements (a few megabytes, kept in the room's Measurements folder): mesh points
  labelled wall, window, door, floor and ceiling, and small straightened greyscale close-ups of each window.
- Window panes: dividers between panes are found from the window close-ups (straight edges spanning most of the
  window, agreed by at least half the views; blinds are recognised and ignored) and shown on the plan, in the
  3D model and OBJ (frame bars), in the PDF schedule ("Window 2 × 1") and as DXF lines. Each window's details
  have Panes across / Panes up steppers to correct them.
- Windows and doors RoomPlan missed are added from LiDAR window/door labels on the walls, marked for review.
- Wall heights corrected to the floor-to-ceiling height the LiDAR measured (3–40 cm differences only).
  Review → Restore undoes heights too.
- Objects named with RoomPlan's recognised details, e.g. "Chair · swivel" or "Storage · cabinet", instead of
  bare categories.
- One scan, plan and photoreal 3D together, with better photos: the scan asks the camera for 4K (Settings →
  Use 4K camera for the photos, on by default; frames saved at 2560 px with matching lens data), caps the
  shutter at 1/120 s against blur, and a steadiness coach under the status bar shows Steady / Slow down a
  little / Too fast · hold still (with a warning buzz). Frames taken while turning faster than 35°/s or
  walking faster than 0.5 m/s are never kept.
- Photoreal 3D on the Mac. Scan photos (Capture folder: photos, poses, LiDAR depth and mesh) now sync from the
  iPhone to the Mac in 4 MB pieces, one file at a time, alongside normal sync; interrupted files restart, and
  the Mac never sends them back. Once every photo has arrived, the Mac trains a Gaussian splat with the
  bundled Brush trainer (30,000 steps, at most 2 million splats; one room at a time, in the background) and
  saves it as Splat/splat.ply in the room's folder (a standard 3DGS file other viewers open too).
- Room view on the Mac: a Photoreal tab beside Plan and 3D. It shows photos still arriving, training
  progress with time left, Build now / Try again, and the finished model in a Metal splat viewer (drag to
  rotate, scroll or pinch to zoom, ceiling hidden for a dollhouse view, toggle in the dock).
- Settings → Photoreal 3D (Mac): Build photoreal 3D automatically (on by default).
- Brush v0.3.0 (Apache-2.0) is bundled in the Mac app at Contents/Helpers/brush, signed with the app's
  identity; licence at Contents/Resources/BrushLICENSE; provenance in Vendor/Brush/README.md.
- Walls corrected from the LiDAR mesh after each scan (Core/WallFit.swift): each wall with enough LiDAR
  points on its solid parts (not across windows or doors) moves onto the measured surface, up to 30 cm and
  4° (10 cm for pieces under 1 m); joined corners and the wall's openings follow. Short walls the LiDAR
  doesn't confirm are hidden, longer ones marked for review; with ARKit's wall labels, missing walls found
  in the mesh are added for review. Review → Restore original corners and stubs undoes all of it.
- Scan screen: a wall-coverage guide. Walls on the live map turn orange → yellow → green as they're seen
  from within 3.5 m (checked against LiDAR depth); the status line shows the percentage, and Finish asks
  once if under 60% of the walls were scanned up close.
- Capture for Gaussian splats: a keyframe every 5 cm or 3° (up to 1,500), white balance locked after it
  settles, ISO and shutter recorded per photo, labelled LiDAR mesh requested; 2016×1512 "stills" dropped.
- Scanning for the 3D model: RoomPlan now runs on the app's own AR session, which asks for LiDAR depth and the
  scene mesh at the start of the scan; full-resolution stills are taken alongside keyframes when the session
  allows; keyframes are kept more often (every 10 cm or 6°). After 25 s of turning on the spot the scan
  says to walk around too. If the scan recorded no depth, Finish starts an optional 60 s "3D detail"
  walk-around in the same session (depth, mesh, full-resolution stills), with Done and Skip; the room is
  built meanwhile. notes.json records how far tracking jumped between the two.
- scripts/dollhouse: photos aligned per surface and taken one photo per patch (much sharper); better fill
  for unseen areas; fixtures use the LiDAR mesh when a capture has one.
- scripts/dollhouse: development tool that turns a scan's keyframe photos into a photo-textured dollhouse
  by projecting them onto RoomPlan's measured walls, floor and fixture boxes; writes renders and a USDZ.
  Not in the app yet.
- 2D plan: drag to edit. Select a wall, door, window or opening, then drag its line to move it or its end
  dots to resize it. Walls slide square to themselves; dragging a corner moves the walls joined to it,
  snaps to nearby wall ends and straightens to 0°/90° within 3°. Openings slide along their wall, stay
  inside it, and move to another wall when dragged onto it. Each drag is one undo step.
- Add (+) and Add here now drop the new element straight onto the plan, selected and ready to drag;
  Edit opens its details. With no wall selected, a door/window/opening goes on the longest wall and a
  new wall goes across the middle of the plan.
- Fixed: the plan no longer refits while dragging, which made a wall drag run away from the pointer.
- 2D plan: scroll up/down zooms in/out around the mouse pointer and horizontal scroll moves it (Mac, or
  iPad with a pointer); pinch now zooms around the fingers; zoom range 0.5–20×. The Reverse scroll zoom
  setting applies to both the plan and 3D view.
- scripts/mensur_to_nerfstudio.py: converts a room's Capture folder and RoomPlan geometry into a
  Nerfstudio dataset (photos, ARKit poses, starting points on walls/floor/ceiling/furniture) for
  Gaussian-splat training with Brush. Development tool; the Mac app will do this itself later.
- Mac app redesigned for the desktop: "Optimised for Mac" sizing (TARGETED_DEVICE_FAMILY adds 6), a sidebar
  with rooms, search, Settings and sync status, and rooms shown with the plan/3D canvas beside an
  Elements/Review panel. Minimum window 1000×680; Settings at a readable width.
- Room cards line up (every card keeps an address line) and the library background fills the window.
- Dock buttons are icon-only on Mac; the PDF button exports in the default layout, with the other layout
  on press-and-hold (iPhone) or right-click (Mac).
- Fixed: on the Mac, a failed or stray connection attempt dropped the working sync connection; a new
  connection now replaces it only after its encrypted handshake succeeds.
- Each Mac now advertises a unique service name, so two Macs (or test copies) with the same computer name
  are never confused; the friendly name is unchanged.
- Scan photo capture: checks the camera 12×/s and, each time the phone moves ~15 cm or turns ~8°, keeps
  the sharpest frame from the next 0.35 s (up to 900 photos). Sharpness is stored per photo.
- Scans now also save photos for a future photoreal 3D model (Settings → Save photos for the 3D model,
  on by default): keyframes with exact camera pose and intrinsics in RoomPlan's world frame, plus LiDAR
  depth and mesh when the session provides them, in the room's Capture folder. Not yet synced or used;
  the Mac processing comes next.
- Fixed: on the Mac, only the first scroll in the 3D view zoomed; SceneKit's own gestures, attached
  later, took over the rest. They now leave all scrolling to Mensur.
- Sync troubleshooting: if Local Network access is off, both apps now say so and offer Open Settings
  (before, pairing just kept looking); the iPhone shows tips if no Mac appears within 8 seconds. Pairing,
  sync and Mac 3D scroll steps are written to the device's own log (no personal data, nothing sent).
- Mac 3D view: scroll up zooms in, scroll down zooms out, scroll left/right moves the view; dragging
  still rotates. Settings → 3D view → Reverse scroll zoom flips the zoom direction.
- New Mac app (Mac Catalyst) from the same project: view, edit and export rooms; scanning stays on iPhone.
  Exports on the Mac save to Downloads.
- Wi-Fi sync between iPhone and Mac: one-time 6-digit pairing, then automatic, encrypted (TLS with a
  pre-shared key), local-network-only sync while both apps are open. Newest edit wins; the other becomes a
  "(conflicted copy)". Deletions move to Recently Deleted on the other device.
- Settings tab on both: pair/unpair, default units, PDF layout, plan dimensions/furniture, after-scan
  corner squaring, stub hiding and address lookup, accent colour, black-and-white plans.
- New scans get their street address from the phone's location (Apple geocoding; coordinates only), and
  Room details has "Use current location". Editable, and can be turned off.
- Area labels on plans have a light backing so they stay readable over furniture.
- Privacy manifest now declares UserDefaults use (CA92.1); Info.plist adds Local Network, Bonjour and
  location descriptions.
- Fixed: with the phone in dark mode, text turned white on the light screens. The app now always uses
  light appearance (`UIUserInterfaceStyle` = Light), matching the Clean blueprint design.
- Name each enclosed space (Elements → Spaces). Names follow their space through wall edits and appear
  on the plan, the room cards and the PDF summary.
- Rooms can have an address (Room name, address and notes): shown on the room screen and library
  cards, searchable, and printed in the PDF title block (wrapped to two lines).
- Project format: optional `address` and `spaceLabels`; older projects open unchanged and
  schemaVersion stays 1.
- New app icon and logo: a bold white L-shaped plan outline with a square nested in its notch (reads
  as an "r"), on Mensur blue. Drawn by shared code for the app header and PDF title block.
- New 11 × 17 PDF sheet, landscape or portrait: logo and title block, total and per-space area,
  perimeter, average ceiling height, tagged door/window schedule, numbered wall table, and a 2D plan
  squared to the page at a standard architectural scale with a scale bar. The full export's
  Floorplan.pdf now starts with this sheet.
- Area now works for spaces with partitions, T-junctions and stubs: each enclosed space is found and
  summed (the sample scan's 2,582 sq ft = 2,238 + 344). Curved walls still suppress area.
- Plans are turned so walls sit square to the screen and page (RoomPlan's axes are arbitrary).
- UI refresh ("Clean blueprint"): logo header and scan card in the library; cards show area and spaces;
  room screen has Area / Perimeter / Ceiling cards, a framed plan with space areas, and a floating tool
  dock (fit, dimensions, furniture, add, PDF); export and room options moved into toolbar menus.
- New live scanning screen: colour-coded outlines of walls, windows, doors and openings as RoomPlan
  finds them, coaching text, and a live mini-plan with the phone's position. Replaces Apple's
  RoomCaptureView; RoomBuilder now processes the capture.
- Scans can run 10 minutes (warning from 5). Leaving the app, low memory or critical heat now finish
  and save the scan instead of discarding it; processing may take up to 2 minutes.
- New scans have rounded corners squared automatically; Review can square corners in older scans,
  hide short wall stubs, and restore the original pieces. Original RoomPlan files are unchanged.
- Add a window/door/mirror/opening at the tapped spot on a selected wall (for windows behind blinds).
- A capture with an invalid piece is saved without that piece instead of failing to save at all.
- Fixed: saving a wall without changes snapped nearby corners and marked neighbouring walls edited.
- Saving an unchanged element no longer creates an undo step.
- MetricKit crash and hang reports are kept on the device in Documents/Diagnostics.
- Project format: surfaces may carry an optional `autoCleanup` record; older projects open unchanged
  and schemaVersion stays 1.
- Fixed the iOS 27 SDK build: renamed the plan canvas pan handler from
  `move(_:)` to `panPlan(_:)`, which collided with `UIResponder.move(_:)`.
- The empty library no longer shows a search field, which on iOS 26+ floated
  over the "Open sample room" button.
- Tapping a window, door, opening, or mirror on the plan now selects it instead
  of its parent wall.
- Plan and PDF wall dimension labels are aligned with their wall and no longer
  overlap vertical walls or window/mirror outlines. The dimension line sits
  22 pt from the wall (was 17 pt).
- Wall dimensions now always sit on the room side, even when captured walls
  run in mixed directions; near-vertical walls read consistently bottom-to-top;
  dimension ticks stay visible on diagonal walls; labels on short jogs no longer
  cross neighbouring walls.
- Added 6 core tests for tap selection, dimension side, and label angle.
- Recorded the first Mac verification and Simulator smoke test in
  docs/BUILD_STATUS.md.

## 1.0.1 (build 2) — October 20, 2026

- Added START_HERE.md with local Claude Code, Xcode signing, iPhone installation,
  initial scanning/export checks, and troubleshooting instructions.
- Added CLAUDE.md and a ready-to-paste build handoff prompt.
- Expanded the Mac verification script to check Xcode/SDK availability, run
  core tests, build both Simulator and iPhone targets unsigned, and retain logs
  and result bundles. It exits on errors rather than reporting a partial pass.
- Deferred the camera permission request until the capture controller appears,
  so denial errors have a visible controller from which to present alerts.
- Excluded generated build logs and device build artifacts from Git.
- Preserved the project data schema, bundle identifier, and existing features.

This is an updated source handoff. No Apple SDK build or physical scan was
performed in the authoring environment. See docs/BUILD_STATUS.md.
