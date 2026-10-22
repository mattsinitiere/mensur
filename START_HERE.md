# Mensur — build and test on your iPhone

Source handoff: 1.0.1 (build 2), October 20, 2026.

This ZIP contains a native SwiftUI iOS app, not a website or an installable IPA.
Claude Code can edit and build the source on your Mac; Xcode signs and installs
it on your iPhone. There is no backend, API key, CocoaPods setup, or external
Swift package dependency for the app.

## 1. Prepare your Mac and phone

- Use your Mac Studio. Install full Xcode from the Mac App Store, open it once,
  accept its terms, and install its iOS platform support. Use a stable Xcode
  release that supports your phone's installed iOS version. The project is
  configured for iOS 17 or newer; this does not mean old Xcode can deploy to
  every newer iOS release.
- In Xcode > Settings > Locations, choose that Xcode under Command Line Tools.
- Your iPhone must have LiDAR for scanning. iPhone 12 Pro/Pro Max and later
  LiDAR-equipped Pro models are examples; a newer standard iPhone does not
  automatically have LiDAR. The app checks RoomCaptureSession.isSupported.
- A non-LiDAR phone or Simulator can explore the sample, edit, and export, but
  cannot do a real room scan.
- Have an Apple Account for development signing and a data-capable USB cable.
  Personal Team signing is enough for a first on-device trial. With free
  provisioning, profiles expire after seven days; rebuild and reinstall from
  Xcode when needed. TestFlight/App Store distribution is a separate process.

## 2. Unzip into one working folder

Unzip the archive in Finder and move its `Mensur` folder somewhere permanent,
for example `~/Developer/Mensur`. Inside that folder you should see:

```
Mensur.xcodeproj
Mensur/
Package.swift
CLAUDE.md
START_HERE.md
docs/
scripts/
```

Open the same working folder in Claude and Xcode. If Claude creates a Git
worktree, its edits live in a different directory: either open that worktree's
Xcode project or bring its changes back before building the original folder.
Keep any earlier project folder separate until this version works.

## 3. Have Claude Code build and resolve compiler errors

In Claude Desktop, open the **Code** tab, choose a **Local** environment on your
Mac, then select the extracted `Mensur` folder. Do not just attach the ZIP to
an ordinary Chat conversation. The local environment is what gives Claude
access to your Mac's Xcode tools.

Paste this prompt (also in `docs/CLAUDE_BUILD_PROMPT.md`):

> Work on this existing Mensur iOS app. Read CLAUDE.md, START_HERE.md,
> README.md, docs/BUILD_STATUS.md, and docs/DEVICE_TESTS.md. Confirm you are
> working on my local Mac, print the working directory, and inspect the selected
> Xcode and installed SDKs. Run bash scripts/verify-on-mac.sh. Fix actual
> compiler errors and failing core tests while preserving the native RoomPlan
> capture, local saves, geometry editing, and existing export features. Do not
> replace the app with a web app or a mock scanner. Re-run the checks until the
> core tests, unsigned Simulator build, and unsigned iPhone build pass, or
> report the exact environment blocker. Then open the sample in an installed
> iPhone Simulator and check editing, persistence, and PDF export. Use the
> actual files in your working directory, including any worktree. Preserve my
> signing team and bundle ID if already set; tell me which Xcode project to
> open to select my team and run on my physical iPhone. Update BUILD_STATUS.md
> with commands and results actually observed. Keep hardware scan tests marked
> untested until we perform them. Do not delete scans, publish, or upload them.

If using Claude Code in Terminal instead, run `claude` from the project folder
and paste the same prompt. Follow Anthropic's official setup guide if it is not
installed. The Desktop Code tab does not require the separate CLI installation.

You can run the build script yourself from Terminal in the project folder:

```bash
bash scripts/verify-on-mac.sh
```

It runs the Swift package's core tests, builds for iOS Simulator, and builds
for iPhone with signing disabled. It stops on a failing command and saves logs
and Xcode result bundles in `build-logs/<timestamp>-<process>/`. These unsigned
builds do not install the app or test the camera. The app scheme has no XCTest
target; use `swift test` for core tests, rather than assuming Command-U runs them.

## 4. Sign and install with Xcode

1. Double-click `Mensur.xcodeproj` in the exact folder Claude built. Do not
   create a fresh project or use `Package.swift` as the app project.
2. Go to Xcode > Settings > Apple Accounts (Accounts in some versions) and sign
   in to your Apple Account yourself.
3. Select the blue Mensur project in the navigator, then **TARGETS >
   Mensur > Signing & Capabilities**.
4. Leave **Automatically manage signing** enabled. Choose your **Personal
   Team** or paid development team. The ZIP intentionally includes no team ID.
5. If the default bundle ID is unavailable, set a unique reverse-domain value,
   such as `com.matthewsinitiere.mensur.dev`. Once testing begins, keep it
   consistent: a different ID installs a different app with separate data.
6. Connect and unlock your phone. Accept **Trust This Computer** on the phone.
   Allow Xcode to finish preparing/pairing the device. Window > Devices and
   Simulators can help if it is not shown.
7. On the phone enable **Settings > Privacy & Security > Developer Mode** if
   required. Restart and confirm when prompted. Pair with Xcode first if this
   setting is not visible.
8. At the top of Xcode, choose the **Mensur** scheme and your actual iPhone
   as the run destination. A generic build destination cannot run an app.
9. Click the Run triangle or press **Command-R**. Resolve any signing messages
   in Xcode. If the phone shows an untrusted-developer prompt, follow its
   Settings > General > VPN & Device Management trust instructions.
10. When Mensur opens, grant camera access when you start scanning.

You do not need an App Store submission for this local test. After a successful
install, you can stop the debugger and launch Mensur from its Home Screen
icon while its development profile remains valid.

## 5. First test: sample, scan, export

1. Choose **Open sample room**. Confirm Plan, 3D, Elements, and Review load.
   If there are already projects, use the library's menu > Add sample room.
2. Edit a sample window, save, close/reopen the app, and verify the saved edit.
3. Export the sample PDF sheet (share button → PDF sheet, 11 × 17 → Landscape) and open it in Files. Sample projects have no original
   RoomPlan USDZ; a successful real capture supplies native files.
4. Start **Scan a room** in a small, well-lit, ordinary room. Slowly cover walls,
   corners, and door/window frames. Finish and wait for processing and saving.
5. Verify exactly one saved room appears. Inspect its Plan and 3D model.
6. Compare room width/depth and a door or window against a tape/laser measure.
   Enter corrections in **meters**, even when display units are feet/inches.
7. Export PDF, DXF, corrected OBJ/MTL, and project JSON. Also check the original
   USDZ from the real scan. Keep OBJ and MTL together; use meters for CAD import.
8. Try a separate scan with windows/mirrors. Inspect for phantom geometry,
   correct or add measured panels, and exclude false walls. Keep some independent
   measurements out of the correction process to check the final result.

This version captures **one room per project**. It produces simplified
architectural geometry, not a textured whole-building digital twin. Mirror and
glass errors require review and corrections; no fixed measurement tolerance is
established. Original USDZ stays unchanged after edits; the corrected 3D export
is OBJ. Full acceptance checks are in `docs/DEVICE_TESTS.md`.

## Troubleshooting

| Symptom | Next action |
|---|---|
| `xcodebuild requires Xcode` | Select full Xcode in Settings > Locations > Command Line Tools; Command Line Tools alone are insufficient. |
| SDK or device support unavailable | Install the iOS platform components and use Xcode compatible with the phone's OS. |
| No development team / provisioning profile | Select your account's team under the app target; enable automatic signing and check the bundle ID. |
| Phone not in destinations | Unlock it, check Trust, use a data cable, and inspect Devices and Simulators. |
| Scan unavailable | Check that this physical device has LiDAR. Simulator cannot replace this test. |
| Camera denied | Enable Mensur camera access in Settings, then start a new scan. |
| Build fails | Give Claude the FIRST compiler error plus the matching build log; do not paste signing credentials. |
| App stops opening after about a week | Free provisioning may have expired. Rebuild/reinstall with the same team and bundle ID. |
| Changes not appearing | Confirm Claude and Xcode use the same folder/worktree and rebuild. |

Back up projects through the app's share sheet or Files > On My iPhone >
Mensur > Rooms before deleting the app. An uninstall can remove local scans.

## Official references

Verified October 20, 2026. UI wording can vary by version.

- [Claude Desktop local Code setup](https://code.claude.com/docs/en/desktop-quickstart)
- [Claude Code CLI quickstart](https://code.claude.com/docs/en/quickstart)
- [Apple: run on a physical device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [Apple: Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple: Personal Team and provisioning limits](https://developer.apple.com/help/account/basics/about-your-developer-account/)
- [Apple: RoomPlan hardware support](https://developer.apple.com/documentation/roomplan/roomcapturesession/issupported)

See `docs/BUILD_STATUS.md` for what was and was not verified before delivery.
