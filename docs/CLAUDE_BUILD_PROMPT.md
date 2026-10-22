# Paste into Claude Code in the local Mensur folder

Work on this existing Mensur iOS app. Read CLAUDE.md, START_HERE.md, README.md,
docs/BUILD_STATUS.md, and docs/DEVICE_TESTS.md.

Confirm you are working on my local Mac, print the working directory, and
inspect the selected Xcode and installed SDKs. Run:

```bash
bash scripts/verify-on-mac.sh
```

Fix actual compiler errors and failing core tests while preserving the native
RoomPlan capture, local saves, geometry editing, and existing export features.
Do not replace the app with a web app or a mock scanner. Re-run the checks until
the core tests, unsigned Simulator build, and unsigned iPhone build pass, or
report the exact environment blocker.

Then open the sample in an installed iPhone Simulator and check editing,
persistence, and PDF export. Use the actual files in your working directory,
including any worktree. Preserve my signing team and bundle ID if already set;
tell me which Xcode project to open to select my team and run on my physical
iPhone. Update BUILD_STATUS.md with commands and results actually observed.
Keep hardware scan tests marked untested until we perform them. Do not delete
scans, publish, or upload them.
