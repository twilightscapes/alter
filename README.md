# Alter

A photo library for people who never wanted to leave Aperture.

Alter opens Aperture libraries in place — projects, albums, ratings, flags,
labels, keywords, stacks, and adjustments — and never writes to them. It keeps
its own catalog beside your photos, writes metadata into your files when you
ask, and works the way Aperture did, keyboard shortcuts included.

This repository is the open core of Alter: the complete library and editor.
The paid edition, Alter Pro, adds AI-written ALT text and captions, Animate
(memes and a video timeline), web galleries, Bluesky posting, and more. It is
built from this code plus a separate, closed extension.

## Building

Requires macOS 13 or later, a current Xcode, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open Alter.xcodeproj
```

Build the **AlterFree** scheme. It produces **Alter Free.app**, which signs
ad hoc by default; set `DEVELOPMENT_TEAM` in `project.yml` to sign with your own
identity.

## Layout

- `Core/` — the app: models, services, views.
- `Core/Extensions/AlterExtensions.swift` — the hooks an extension uses to add
  menus, toolbar buttons, sidebar sections, inspector tabs, and settings.
  With nothing registered, every hook adds nothing.
- `FreeApp/` — the entry point for the open-source build.
- `Resources/` — icon, asset catalog, Info.plist.
- `Tools/` — ExifTool and cwebp, bundled into the app.

## License

Alter's source is licensed under the [Mozilla Public License 2.0](LICENSE).
You may use, change, and redistribute it, including in larger works under
other licenses, as long as changes to these files stay under the MPL.

The name "Alter" and the Alter icon are not covered by that license. See
[TRADEMARKS.md](TRADEMARKS.md). Bundled tools keep their own licenses. See
[THIRD_PARTY.md](THIRD_PARTY.md).

Aperture is a trademark of Apple Inc. Alter is not affiliated with or endorsed
by Apple.
