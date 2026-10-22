# Mensur developer handoff

## Product

Native SwiftUI iPhone/iPad app, minimum iOS 17. RoomPlan captures a single room;
users review 2D/3D geometry, manually correct measurements and reflective
surfaces, save locally, and export PDF/DXF/OBJ/JSON plus untouched native USDZ.
The app is Mensur (said "MEN-sur"; see brand/README.md), bundle ID com.matthewsinitiere.Mensur.
Renaming the bundle ID, the Documents/Mensur or Application Support/Mensur folders, the `_mensur._tcp`
sync service or the pairing Keychain entry strands saved rooms or pairings, so don't change them casually.
Never use orange as a brand colour. Do not add a
backend, subscription, network SDK, or web wrapper without a new product request.

## Read first

START_HERE.md, README.md, docs/BUILD_STATUS.md, docs/ARCHITECTURE.md,
docs/DEVICE_TESTS.md. The delivered source has not passed an Apple SDK build
in its authoring environment. Do not interpret syntax checks as a successful
Xcode build or declare real-world accuracy based on synthetic data.

## Build

- Open Mensur.xcodeproj, scheme Mensur. No external app dependencies.
- Run `bash scripts/verify-on-mac.sh` on a local Mac with full Xcode selected.
- The script runs `swift test` for MensurCore and unsigned Simulator/iPhone
  builds. `build-logs/` stores command logs and result bundles. A physical
  installation uses the user's signing team through Xcode.
- The app scheme has no embedded XCTest target. Core tests are in Package.swift.
- `python3 scripts/check_structure.py` does portable structural validation;
  Tree-sitter syntax parsing is optional, not a compiler replacement.
- `scripts/generate_project.py` regenerates the project deterministically, but
  it also resets signing settings. Do not run it unnecessarily. If adding files,
  preserve the user's team, bundle ID, and other deliberate Xcode changes.
- Confirm the working directory/worktree and tell the user exactly which
  Xcode project to open; don't build an old checkout while editing a new one.

## Implementation boundaries

- Core geometry has no Apple UI/RoomPlan imports and stays independently testable.
- Internal units, numeric edit fields, DXF/OBJ coordinates are meters. UI may
  display imperial units. Preserve coordinate-frame notes for native exports.
- Preserve original RoomPlan JSON/USDZ. Corrected exports are separate files.
- Project schemaVersion remains 1; a format change needs a migration.
- No claim of guaranteed accuracy, survey certification, automatic mirror
  suppression, photorealistic models, or multi-room merging in this release.
- Support denied camera permission, unsupported hardware, cancellation, and
  failed processing without losing saved scans. Present permission errors only
  after the controller is visible.

## Verification and reporting

Fix observed errors with focused changes. Keep substantive geometry tests;
never disable tests or replace real scan results with sample data to pass a gate.
Update docs/BUILD_STATUS.md with the commands actually run and exact results.
After building, smoke-test sample editing/persistence/PDF sharing in Simulator
when available. Real RoomPlan capture, glass/mirror behavior, and measurement
accuracy require the physical-device checklist and independent measurements.

Keep local room data, originals, and user signing settings intact. Do not commit
credentials, personal scans, build logs containing private paths, or provisioning
profiles. Do not publish to TestFlight/App Store or register paid services as
part of the initial local build. The user enters account credentials in Xcode.
