# Window Factory icon

Version: 1.0
Updated: 2026-10-26

The installed icon is **Sculpted blue**. Build 48 uses the native
`../WindowFactory.icon` document with Apple's asset compiler (`actool`) to generate
`Assets.car` for current macOS and `WindowFactory.icns` as the legacy fallback.
Both `CFBundleIconName` and `CFBundleIconFile` identify `WindowFactory`.

The owner explicitly approved precise local transparency cleanup on 2026-10-25
after the image tool retained stray external pixels. `../../scripts/clean-icon.swift`
uses the original `pane-sculpted-concept.png`, trims only the outer contour with
an antialiased squircle mask and independently verifies the saved PNG. The
unchanged cleaned artwork now lives at
`../WindowFactory.icon/Assets/WindowFactory.png`; the original concept is retained.

The native icon document was created in Apple's Icon Composer after the owner
accepted its first-use licence. The artwork layer has extra glass effects off;
the blue canvas supplies the outer background and the system applies its mask.
This follows Apple's [icon preparation guidance](https://developer.apple.com/videos/play/wwdc2025/361/).

Build 47's legacy-only ICNS path made macOS shrink the already-rounded transparent
artwork onto a pale tile. That observed white surround was a packaging defect,
not an accepted design treatment. Build 48's native assets resolve to blue through
the outer body in macOS's actual app-icon rendering. The approved master pixels
were moved into the native document without repainting the panes.

`../../scripts/package-icon.sh` compiles the native document and verifies the
compiler's icon identity fields. Generated CAR/ICNS and partial plist remain in
the build cache. Xcode's installed asset compiler is required; no new toolchain or
package install was added. The build does not package the Design directory.
The bundle/signing identity is unchanged; the desktop-number badge is independent
of the app icon.

## Material variations — 2026-10-25

Three requested alternatives were generated with the built-in image tool, using
`pane-arrangement-concept.png` as the edit reference. These remain design
explorations; no installed icon, app build, controls or Hammerspoon files changed.

| Asset | Direction |
| --- | --- |
| `pane-outline-concept.png` | Bright icy outlines, unfilled pane interiors showing the cobalt base |
| `pane-glass-concept.png` | Translucent cyan glass, refractive edges and transmitted blue tones |
| `pane-sculpted-concept.png` | Surprise: recessed monochromatic blue architectural wells |

Prompt set: preserve the centered frontal cobalt rounded-square base and exact
one-tall-left/two-stacked-right arrangement, with equal margins/gaps and no text,
chrome, extra panes or rotation; transparent outside the base. Outline variant:
continuous substantial white/icy-blue rounded outlines, empty interiors, minimal
edge highlights. Glass variant: true optical transmission, restrained thin-glass
bevels, cyan tint, controlled reflections and a tonal wave demonstrating refraction.
Sculpted variant: carved negative-space cavities, softened inner bevels, deep
indigo interiors and electric-blue rim lighting, with no white-filled panes.

These concepts preserve the exploration history. The selected sculpted variant
was subsequently reviewed at 16–192px on light/dark backgrounds and cleaned for
production as described above.
