# Aperture parity — the plan

Goal: Alter matches Aperture 3's basic feature set and its look and feel —
tools, overlays/HUDs, keyboard, viewer behaviour — before any release,
rebrand or packaging talk. Existing Alter behaviour changes where Aperture
did it differently.

Status key: ✅ done · 🔶 partial · ⬜ not started · ➖ deliberately skipped

## 1. Viewer & overlay interface (the "feel")

| Aperture | Alter today | Plan |
|---|---|---|
| Loupe (`): round magnifier with tether, zoom popup in the rim (50–1600%), "Focus on Cursor / Focus on Loupe", colour values, pixel grid at high zoom, resize by dragging the rim | ✅ rebuilt 2026-10-15 | — |
| Zoom (Z) to 100%, pan by drag/space, navigator box, zoom slider | ✅ Z, ⌘+/⌘−, drag/scroll pan, navigator, chip (2026-10-15) | — |
| View modes V cycles Browser → Split → Viewer | ✅ V (+ ⌘1/2/3) | — |
| Full Screen (F) with auto-hiding filmstrip and toolbar, HUD inspector (H) | ✅ (2026-10-15) | — |
| Primary Only (⌥U) / show multiple selected in viewer (up to 12) | ✅ (2026-10-15) | — |
| Quick Preview (P), Show Master (M), Hot & Cold areas (⌥⇧H) | ✅ M shows master, ⌥M compares, hot/cold | P ➖ (previews already fast) |
| Rotate ⌘[ ⌘] | ✅ keys + control bar | — |
| Ratings 1–5, 0 none, 9 reject, +/−, flag /, labels ⌃0–7 | ✅ KeyCommands; Reject hidden by default | — |
| Control bar: ratings, rotate, prev/next, keyword controls, Primary Only | ✅ | — |
| Dark grey theme, viewer background shade preference | ✅ Settings ▸ Viewer | — |

## 2. Adjustment tools (finish the Adjustments inspector)

| Aperture | Alter today | Plan |
|---|---|---|
| Bricks: checkbox / gear / Add Adjustment, sliders w/ numeric + reset | ✅ | — |
| Brush In / Brush Away on every brick's gear; Brush HUD (size, softness, strength, Detect Edges, overlay: none/colour/B&W/mask; feather/erase/apply; Clear) | ✅ (2026-10-16) | 🔶 Detect Edges later |
| Quick Brushes menu (Skin Smoothing, Dodge, Burn, Polarize, Intensify Contrast, Saturate, Desaturate, Blur, Sharpen, Halo Reduction, Noise Reduction, Definition, Vibrancy, Contrast) | ✅ (Halo Reduction ➖) | — |
| Straighten tool (G) with grid overlay, drag to rotate | ✅ (2026-10-16) | — |
| Crop tool (C) HUD: aspect presets, custom size, Show Guides, Constrain | ✅ aspects, Custom W:H, guides, px readout | — |
| Flip (horizontal/vertical) | ✅ | — |
| Red Eye (E) | ✅ (2026-10-16) | — |
| Retouch (X) HUD: Repair/Clone, radius, softness, opacity, Detect Edges, Automatically choose source | ✅ Repair/Clone, radius, softness, opacity | Detect Edges ➖ |
| Chromatic Aberration | ✅ brick + import | — |
| RAW Fine Tuning (Boost, Hue Boost, Sharpening, Moiré, De-noise) | ➖ ImageIO's RAW decoder exposes no boost/moiré controls; Enhance + Noise Reduction cover it | — |
| White Balance eyedropper; Skin Tone mode | ✅ Neutral + Skin Tone, Temp in kelvin | — |
| Auto buttons (Exposure, Enhance, Levels, Curves), Curves/Levels eyedroppers | ✅ Auto + eyedroppers | — |
| Presets menu (built-ins + Save as Preset / Manage) | ✅ | — |
| Lift & Stamp HUD (O): per-category checkboxes incl. metadata, Add/Replace | ✅ | — |
| Edit with external editor (PSD/TIFF round trip) | ✅ Edit With… (TIFF) | — |

## 3. Organisation

| Aperture | Alter today | Plan |
|---|---|---|
| Projects as the primary container, Folders nest, Albums inside Projects | ✅ projects, nested folders, albums inside projects; Aperture import fills all three | — |
| Keywords HUD (⇧H) hierarchical keyword library, keyword controls bar with button sets | ✅ HUD (outline when the library has a hierarchy), controls bar, ⌥1–⌥8 | — |
| Batch Change (⇧⌘B): metadata presets, time adjust, version naming | ✅ sheet (metadata, keywords add/replace, rating, label, flag) | time adjust / version naming ➖ |
| Metadata views & presets (General, EXIF, IPTC Core…) | ✅ Basic / IPTC / All | presets ⬜ |
| Smart album rules: date/calendar, camera, lens, ISO/aperture/shutter, file type, import session, text | ✅ date, file type, camera, lens, ISO, focal length | import session ➖ |
| Stacks: Auto-Stack slider HUD, Open/Close all, pick | ✅ Auto-Stack sheet with live count | — |
| Light Table | ⬜ | ➖ later, if ever |
| Faces | ⬜ | ➖ |
| Places | ✅ GPS set/remove, map in Info | — |

## 4. Output

| Aperture | Alter today | Plan |
|---|---|---|
| Export Versions/Masters with presets, file naming presets, watermark | ✅ (export presets, naming presets, watermark already existed) | — |
| Slideshow (basic + presets) | ✅ basic (dissolve, Ken Burns, seconds, loop) | presets/music ➖ |
| Web pages / journals | ✅ gallery | — |
| Print / Books | ⬜ | ➖ |

## Order of work

1. Viewer & overlays: Loupe → Zoom/pan → keys & control bar → Full Screen + HUD inspector → multi-up / Primary Only → hot/cold.
2. Adjustment tools: per-brick brushing + Brush HUD → Quick Brushes → Straighten/Crop/Flip tools → Red Eye → Retouch HUD → Presets, Auto buttons, Lift & Stamp → Chromatic Aberration, RAW Fine Tuning.
3. Organisation: Projects & folders → Keywords HUD & controls bar → Batch Change → metadata views → smart album rules.
4. Output: export presets & naming → slideshow.

Each step: propose → yes → build → Todd tests → commit.
