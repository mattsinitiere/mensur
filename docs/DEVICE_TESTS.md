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
