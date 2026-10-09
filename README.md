# KiCadQuickLook
Finder extension to show previews of KiCad files

Press Space on a file in Finder to preview it; thumbnails show up as file icons.

| Format | Extensions | Rendered by |
| --- | --- | --- |
| KiCad board | `.kicad_pcb` | [KiCanvas](https://kicanvas.org) |
| KiCad schematic | `.kicad_sch` | KiCanvas |
| KiCad project | `.kicad_pro` (shows the board, or the schematic if the board is blank) | KiCanvas |
| STEP model | `.step`, `.stp` | [Open CASCADE](https://dev.opencascade.org) (WebAssembly, via [occt-import-js](https://github.com/kovacsv/occt-import-js)) + [Online 3D Viewer](https://github.com/kovacsv/Online3DViewer) |
| 3MF model | `.3mf` | Online 3D Viewer (three.js) |

3D previews are interactive: drag to orbit, scroll to zoom, right-drag to pan.

STEP files are tessellated on the fly by Open CASCADE running as WebAssembly,
which takes about a second per megabyte, so there are size limits: previews
handle STEP files up to 48 MB and 3MF files up to 24 MB; Finder thumbnails
(which must finish within a few seconds) are generated for STEP files up to
8 MB and 3MF files up to 12 MB. Larger files show a message in the preview and
a generic icon in Finder. KiCad board exports with every drill hole modelled
easily exceed these limits; export without holes, or without components, for
a previewable file.

## Building

Requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open KiCadQuickLook.xcodeproj   # or Scripts/build-release.sh for a signed Release build
```

After installing the app, launch it once so macOS registers the file types,
then enable “KiCad Preview” and “KiCad Thumbnails” in System Settings →
General → Login Items & Extensions → Quick Look. If Finder keeps showing
old previews, run `qlmanage -r && qlmanage -r cache`.

### Without Xcode

`Scripts/build-without-xcode.sh` builds, signs, and (with `--install`)
installs the app using only the Command Line Tools: it compiles each target
with `swiftc`, assembles the `.app` and `.appex` bundles by hand, signs them
with your Developer ID (set `IDENTITY=-` for an ad-hoc signature), and
`--install` also registers the file types and enables both extensions, so
no trip through System Settings is needed.

```sh
Scripts/build-without-xcode.sh --install
```

## Testing the render pipeline without Xcode

`Scripts/test-render.swift` drives the shared rendering code in an
offscreen web view and writes a PNG. `swiftc` only accepts top-level code
in a file named `main.swift` when compiling several files, so copy the
script under that name first:

```sh
mkdir -p /tmp/kiql-harness && cp Scripts/test-render.swift /tmp/kiql-harness/main.swift
swiftc -o /tmp/kiql-test-render Shared/*.swift /tmp/kiql-harness/main.swift -framework WebKit -framework AppKit
/tmp/kiql-test-render path/to/board.kicad_pcb out.png              # thumbnail path
/tmp/kiql-test-render path/to/model.step out.png interactive       # preview path
KIQL_PHASES=1 /tmp/kiql-test-render path/to/model.step out.png      # with phase timings
```
