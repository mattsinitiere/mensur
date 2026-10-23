# Mac and device acceptance checklist

These are required acceptance checks, **not tests already performed**. Record device model, iOS version, Xcode version, room conditions, and results.

## Build gate

- Run `swift test`: all 20 geometry/export tests pass.
- Run `bash scripts/verify-on-mac.sh`: app compiles with the installed Apple SDK.
- Open the sample on an iPhone-size and an iPad-size simulator.
- Confirm navigation, split-size layouts, dynamic text, rotation, and VoiceOver controls are usable.
- Edit a sample window, close/reopen the app, and confirm the edit is persisted.
- Export all corrected formats. Open PDF in Preview, DXF in a CAD viewer with meter units, and OBJ/MTL in Blender or another 3D tool.
- Confirm the same edited opening exists at the same coordinates/dimensions in plan, schedule, CAD, and corrected OBJ.
- Confirm original USDZ is clearly distinguished from corrected geometry.

## Capture lifecycle

- Supported LiDAR iPhone and/or iPad: grant permission and successfully scan one room.
- Denied camera permission: readable error; close and recover after enabling permission in Settings.
- Unsupported device/simulator: capture button disabled; sample/import remain available.
- Cancel mid-scan: confirmation appears; Keep scanning continues; Discard returns to library.
- Finish: processes exactly once and creates exactly one project.
- A scan with no recognized walls: error instead of an empty success.
- Live scan screen: white outlines appear on walls, cyan on windows, green on doors, yellow on openings, fading in as found; outlines stay attached to their surfaces while walking; the mini-plan (bottom left) grows with the walls and its blue marker follows the phone's position and heading; coaching text (closer, slow down, more light) shows in the top bar.
- Background/interruption: leaving the app mid-scan stops scanning and saves what was captured (no continuation using an invalid tracking origin).
- Long scan: drift warning from 5 minutes, automatic finish at 10 minutes. No indefinite spinner if processing fails (2-minute processing limit).
- Low memory or critical heat during a scan: scan finishes and saves rather than failing.
- Corners: a new scan of a room with boxed or chamfered corners shows sharp corners; Review → Restore original corners and stubs brings back RoomPlan's pieces.
- Covered windows: select the wall in Plan → Add here → Add window here places a window at the tapped spot; adjust and save.
- Crash diagnostics: after any crash or hang, Files → On My iPhone → Mensur → Diagnostics holds a MetricKit report (may take until the next launch).
- Reopen an existing project after app termination: geometry, exclusions, notes, and measurement records remain intact.
- Save/write failure where practical: user sees error and existing files remain intact.

## Geometry and exports

- Scan a rectangular room and an L-shaped room. Area respects the concave outline.
- Scan a space with a partitioned office: total area and each space's area appear in the room stats and on the PDF sheet.
- Mac sync: pair from Mac Settings and iPhone Settings with the code; edit a room on each and confirm it
  appears on the other within seconds; edit the same room on both while apart, then reconnect and confirm a
  "(conflicted copy)" appears; delete a room on one and confirm it moves to Recently Deleted on the other;
  unpair and confirm sync stops.
- Several Macs: pair the iPhone with two Macs (the second through **Pair another Mac**); edit a room on each Mac
  and confirm the edit reaches the other Mac after the iPhone syncs with both; delete a room on one Mac and
  confirm it moves to Recently Deleted on the iPhone and the other Mac and doesn't come back; unpair one Mac and
  confirm the other still syncs. Update a build paired with one Mac and confirm it stays paired without
  conflicted copies.
- Mac exports: PDF sheet and All files save to Downloads; a second export doesn't overwrite.
- Automatic address: scan a room with location allowed, confirm the address fills in shortly after saving
  and can be edited; deny location and confirm the scan still saves without one.
- Phone in dark mode: every screen, sheet, menu and alert stays light with dark, readable text.
- Name both spaces in a partitioned scan, move the partition, and confirm the names stay with their spaces; add an address and confirm it shows on the room, card, search, and PDF title block.
- PDF sheet, landscape and portrait: print one at 100% on 11 × 17 and check the scale bar and one wall length against a ruler; confirm the logo, totals, door/window tags (D1, W1…), wall numbers and schedules match the plan.
- Delete/exclude a boundary wall: area becomes unavailable; no convex-hull substitute.
- Add a phantom wall: review catches invalid topology; exclusion repairs it.
- Add a mirror on a parent wall: appears in purple on plan and as a panel in 3D, without cutting a wall hole.
- Window/door openings produce holes in corrected 3D walls and matching symbolic plan segments.
- Move wall endpoints with linked corners enabled: adjacent endpoints move; their old length checks are invalidated.
- Move an opening outside its wall: editor refuses it. Imported/captured out-of-bounds openings are flagged and not cut into wall meshes until fixed.
- Toggle excluded/restore and undo: inspect all attached openings and furniture.
- Unit toggle changes display only. Internal coordinates and DXF remain meters.
- Print PDF at 100% on 17×11 paper: verify scale bar with a ruler.
- Import Project.json as a copy: no overwrite of the original project, clear note that native scan files were not imported.

## Window and mirror trials

Use separate scans for an ordinary opaque-walled room, a room with large windows, and a room with a full-height mirror. Keep a reference sketch and laser/tape measurements.

- Inspect window frames and both adjacent wall corners from several viewpoints.
- Verify whether the frame was recognized as a window or opening. Add/correct it if missing.
- Inspect for phantom walls, duplicate furniture, walls beyond the reflection plane, and wrong room depth.
- Mark or add measured mirror panels. Exclude phantom surfaces/objects explicitly.
- Independently check room width, depth, at least one diagonal, opening widths, offset from a corner, sill elevation, and height.
- Record before-correction and after-correction errors.
- Withhold at least some dimensions from the correction process and use those as validation checks.

Do not advertise a fixed accuracy tolerance until these tests have enough representative data. A checkmark on one length is not a survey certification.

## Scan features added October 22, 2026 (not yet run on a device)

The logic behind these is unit-tested; the capture side needs a LiDAR iPhone.

- Coverage heat-map: walls turn from red to yellow to green strip by strip as you walk along them; tapping the
  mini-plan enlarges it.
- Spoken coaching and haptics: with both on, the app names the nearest wall still red ("Move closer to the wall
  on your left") and taps when a wall turns fully green. Check that it doesn't repeat itself more than every
  20 seconds, and that it stays quiet with Spoken coaching off.
- Reveal mode (ruler button): stand beside a door frame and aim at its side. The status line should show a
  reveal within a few seconds. Compare it with a tape across the jamb. After saving, the door's Reveal and the
  wall's thickness (marked "reveal") should match.
- Markers (bolt button): aim at an outlet and choose Outlet. After saving, the R marker should sit on the right
  wall at about the right height, and appear on that wall's elevation in the PDF set.
- Photos (camera button): take two. After saving, two photo pins should appear where you stood, open from the
  plan, sync to the Mac, and appear in the PDF set.
- Ceiling: scan a room with a soffit or beam (or a sloped ceiling) with the camera tilted up at times. Check
  Elements → Ceiling for a detected feature, and its heights against a tape.
- Scan report: after a long scan, Review → Scan quality should list path length, any limited tracking and any
  position corrections.
- Next room or floor: Finish → Next room on this floor, scan a second room, then Finish → Finish scan. Both
  rooms should be saved, in one building, and line up in Building view without aligning.
- Resume: on a saved room, Room options → Continue scanning. Point at walls you scanned before; scanning should
  start once they're recognised, and new walls should join the room without duplicating the old ones.
- Send room: Export → Send room to another device, AirDrop to a second device; the room should open there with
  its photos.
