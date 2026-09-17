# Toastty icon

`toastty-icon.png` is the master buttered-toast icon. It was generated with the
built-in imagegen tool and refined on 2026-09-17. The toast sits small in the upper-left of
the screen, following the composition of Ghostty's original icon. Toastty's
toast, butter, and warm palette identify this independent fork. The CRT treatment
uses a recessed charcoal bezel, curved glass, an amber phosphor grid, and a glowing
toast sprite with butter. The original Ghostty icon was a composition reference.

The exact generation and refinement prompts are in `prompts.txt`. No CLI image
API or API key was used. `scripts/build-icons.py` uses `scripts/pad-icon.swift`
to center the unchanged artwork on a transparent canvas, then macOS
`sips` to export the required asset-catalog sizes. The visible bezel occupies
about 81% of each exported image, keeping its Dock size consistent with other
macOS apps. This is measured from the master alpha bounds rather than assuming
fixed source margins. These packaging steps do not redraw the artwork.

The final asset is installed in the Toastty app icon catalog and About image set.
Keep the original alpha channel and master when exporting additional sizes.
