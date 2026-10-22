# Continue Mensur on another Mac

How to set up another Mac (a Mac Studio or the M1 MacBook Pro) from nothing and carry on from GitHub.
It takes about an hour, most of it the Xcode download. The project lives at
**github.com/mattsinitiere/mensur** (public), branch `main`.

## What you need

- The Mac signed in to GitHub (step 2).
- Your iPhone and its USB cable.
- Your Apple Account password, for Xcode signing.

Your scanned rooms don't need copying. They're on your iPhone and sync to the new Mac once it's paired
(step 6). They are never in the repository.

## 1. macOS and Xcode

1. Update the Mac to macOS 27.0 or newer.
2. Install **Xcode** from the Mac App Store. The project was last built with **Xcode 27.0 (27A266a)** and
   Swift 6.4. A newer Xcode is fine.
3. Open Xcode once and accept the licence. When asked, install **iOS** platform support. If you weren't asked,
   use Xcode → Settings → Components.
4. Xcode → Settings → Locations → **Command Line Tools**: choose that Xcode.
5. Xcode → Settings → **Accounts**: sign in with your development Apple Account. The project signs with team
   **KM25U2VHNT**.

## 2. Get the project from GitHub

1. Install the GitHub CLI (it needs [Homebrew](https://brew.sh)), then sign in. Choose SSH when asked:

```bash
brew install gh
```

```bash
gh auth login
```

2. Clone into **`~/Downloads/Mensur`**, the same path as on the other Macs. Any folder works, but the same
   path keeps Claude's saved notes matched to the project (step 7):

```bash
gh repo clone mattsinitiere/mensur ~/Downloads/Mensur
```

3. Tell git who you are in this repository. The noreply address keeps your email off the public history:

```bash
cd ~/Downloads/Mensur && git config user.name sinitiere && git config user.email 81495384+mattsinitiere@users.noreply.github.com
```

4. Check that it builds and the tests pass:

```bash
bash scripts/verify-on-mac.sh
```

Expect `Executed 72 tests, with 0 failures` (or more) and `PASS: core tests and both unsigned builds`.

## 3. Open it in Xcode

1. Double-click **`Mensur.xcodeproj`**. Don't open `Package.swift`, which only holds the core tests.
2. Select the **Mensur** target → **Signing & Capabilities**. Team **KM25U2VHNT** and bundle ID
   `com.matthewsinitiere.Mensur` should already be set. Leave them as they are.
   If it says "No account for team", finish step 1.5. Xcode then creates a development certificate for this Mac
   by itself.

## 4. Run on your iPhone

1. Plug the iPhone into the Mac. Unlock it and tap **Trust** when it asks about this computer.
2. In Xcode's toolbar, choose the **Mensur** scheme and your iPhone as the destination. The first time,
   Xcode spends a few minutes preparing the phone.
3. Press **Run** (⌘R).
4. If the app won't open because of "Untrusted Developer": on the iPhone, go to Settings → General → VPN &
   Device Management → your developer profile → Trust.

Developer Mode is already on. If the phone asks again, turn it on under Settings → Privacy & Security →
Developer Mode.

## 5. Run the Mac app

1. In Xcode's destination menu, choose **My Mac (Mac Catalyst)**, then Run.
2. To keep it like an installed app, drag the built app into Applications. Find it with Product → Show Build
   Folder in Finder → Products/Debug-maccatalyst. Quit the old copy first.

## 6. Sync rooms from the iPhone

The iPhone can be paired with **every** Mac: it syncs with each paired Mac it finds on the Wi-Fi, one at a
time, so a room edited or deleted on one Mac reaches the others through the iPhone. Pairing a new Mac leaves
the others paired. Each Mac pairs with one iPhone.

1. On the Mac: Mensur → Settings → **Pair your iPhone**. A 6-digit code appears.
2. On the iPhone: Mensur → Settings. If it already syncs with another Mac, tap **Pair another Mac**. Choose
   this Mac and enter the code.
3. Allow **Local Network** when either device asks (System Settings → Privacy & Security → Local Network on the
   Mac; Settings → Privacy & Security → Local Network on the iPhone).
4. Keep Mensur open on both, on the same Wi-Fi. Your rooms copy across. iPhone Settings → Paired Macs shows each
   Mac's status and last sync, and unpairs one Mac at a time.

Rooms reach a Mac only through the iPhone, so an edit made on one Mac shows up on another after the iPhone has
synced with both (Mensur open on the iPhone and both Macs, or on each Mac in turn). A Mac paired before this
update stays paired.

## 7. Claude Code

1. Install the **Claude** desktop app (or Claude Code) and sign in.
2. Open a session in the `~/Downloads/Mensur` folder.

Claude picks up from the project's own files: `CLAUDE.md` (rules), `docs/BUILD_STATUS.md` (what was done
in each round and what was tested), `CHANGELOG.md` and `brand/README.md`. Claude's private saved notes live in
`~/.claude/projects/-Users-matthewsinitiere-Downloads-Mensur/memory/` on each Mac and are **not** in the
repository, because it's public. To carry them over, copy that folder to the same path on the new Mac (with
AirDrop, for example).

A good first message:

> Read CLAUDE.md, docs/BUILD_STATUS.md (latest rounds at the bottom) and CHANGELOG.md, then summarise where
> Mensur stands. Run scripts/verify-on-mac.sh to confirm this Mac builds it.

## Working across three Macs

GitHub is the source of truth, so the habit that matters is: **pull when you sit down, push when you get up.**

```bash
git pull
```

```bash
git add -A && git commit -m "describe the change" && git push
```

- Use one Mac at a time on a given change. If two Macs edit the same files without pulling, git will ask you to
  merge when you next pull.
- **Cloud sessions** (Claude Code on the web, claude.ai/code) can work on this repository from anywhere once the
  Claude GitHub app has access to it. They run on Linux with no Xcode, so they can edit code, update docs and
  push branches, but can't build the iOS app or run the Simulator. Do those steps on a Mac after pulling.
- Never commit `build-logs/`, build folders, provisioning profiles or room scans. `.gitignore` already leaves
  them out. The repository is public, so anything committed is readable by anyone.

## Where things stand

See the latest rounds at the bottom of `docs/BUILD_STATUS.md`. In short:

- **Scanning:** RoomPlan plus LiDAR measurements (labelled mesh points, floor and ceiling levels, window
  close-ups). There are no photos: splats and photoreal 3D were dropped and are archived in `docs/archive/`.
- **After each scan:** walls are fitted to the LiDAR, then the app finds windows and doors from the LiDAR, sets
  the ceiling height, detects window panes, squares walls, joins and merges corners, and tidies windows and
  doors. A per-wall LiDAR check follows (Review tab).
- **Exports:** 11×17 PDF sheet, DXF, OBJ, JSON and the original USDZ.
- **Mac app:** library, room editor, Wi-Fi sync with the iPhone, and PDFs saved to Downloads.
- **Brand:** renamed Mensur on October 22, 2026, with the dot-room icon (`brand/`).

## If something goes wrong

| Problem | Fix |
|---|---|
| `xcodebuild requires Xcode` | Step 1.4: choose full Xcode under Command Line Tools. |
| No account for team / no profile | Step 1.5: sign in to Xcode with your Apple Account. |
| `Permission denied (publickey)` on clone or push | Run `gh auth login` again and choose SSH; it uploads a key for this Mac. |
| `git pull` reports a conflict | Ask Claude to resolve it, or keep the newer version of each file. |
| iPhone "unavailable" or "not paired" in Xcode | Unlock it, replug, tap Trust. Window → Devices and Simulators shows its state. |
| App closes with "Untrusted Developer" | Step 4.4. |
| Mac and iPhone don't find each other | Same Wi-Fi, both apps open, Local Network allowed on both (step 6.3). |
