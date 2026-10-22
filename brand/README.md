# Mensur brand assets

The app's user-facing name is **Mensur** (said "MEN-sur"). The icon masters below are installed in
`Mensur/Assets.xcassets/AppIcon.appiconset` as AppIcon, AppIcon-Dark and AppIcon-Tinted. After
regenerating, copy them there again. The previous icon is kept at `legacy/previous-icon.png`.

## App icon (E2, even dots)

A faceted room drawn as three planes of evenly sized dots. The left wall is
brightest, the right wall is 60% and the floor is 30%. There is no accent colour.

| File | Mode | Format |
|---|---|---|
| `icon/mensur-icon-light.png` | Default | 1024 px, sRGB, no alpha |
| `icon/mensur-icon-dark.png` | Dark | 1024 px, sRGB, opaque `#0D1424` background |
| `icon/mensur-icon-tinted.png` | Tinted | 1024 px, 8-bit grayscale on black |

The PNGs are full-bleed squares, because iOS applies the rounded mask itself.
Each `.svg` beside its PNG is the vector source for that mode.

The in-app and PDF logo (`BrandMark` in Mensur/PlanDrawing.swift) draws the same geometry. Change
both together. Regenerate the files with:

```bash
swift scripts/make_icons.swift brand/icon
```

## Wordmark and colour

- Wordmark: lowercase `mensur` in Sora SemiBold (OFL), tracking −0.02 em, outlined for final art
- Brand blue `#2961CC` (`BrandMark.blue` in the app), ink `#10172A`, canvas `#F5F6F8`, plus white
- No orange or green in the brand. Green stays reserved for LiDAR-confirmed status in the app
