---
name: progressive-blur-edge
description: Use when implementing a soft or progressive edge where scrolling content passes under fixed chrome such as a header, toolbar, composer, or floating control; especially when readable content must dissolve before reaching the chrome's boundary.
---

# Progressive Blur Edge

## Decision rules

1. Fade the scrolling content itself with one continuous mask. Use a gradient for the arriving edge; stacked translucent opacity bands create visible steps and seams.
2. Start with the shipped arriving-edge values: fully clear until 30 pt, `black.opacity(0.12)` at 48 pt, `black.opacity(0.55)` at 72 pt, and opaque black at 96 pt. Tune this ramp against real content.
3. Make the reach asymmetric. Give the side from which content arrives a substantially longer dissolve than the lateral and trailing edges. Preserve shorter side/bottom reach so fixed chrome still reads as floating rather than a hazy band.
4. Keep the mask non-interactive: apply `.allowsHitTesting(false)` (or the platform equivalent) so it cannot consume scrolling, clicks, focus, or gestures.
5. When clear glass must preserve refracted rows inside the control's shape, combine the arriving gradient with one shape-derived destination-out mask in the same content mask. This is a content mask, not a painted halo: the result stays crisp glass while rows remain visibly present beneath it.
6. Choose the primitive that can actually obscure the content. SwiftUI `Material` is behind-window vibrancy: it can dim the desktop but cannot hide in-window sibling views. Mask or blur the content itself; adding more behind-window material passes will not solve in-window legibility.
7. A shape-derived mask's blur clips at its layer's bounds, so extend the shape past the mask by at least the blur radius on every side. Otherwise the blur is cut off and produces the hard line the technique exists to avoid.
8. Keep concentric radii ordered. A shape nested inside another must step strictly down in corner radius; equal or reversed radii make the corners fight and reveal a hard contour.

## SwiftUI starting recipe

- Apply the mask to the results or transcript scroll view—the content that travels under the fixed chrome—not to a painted plate behind the control. Keep the control above the content (`zIndex(1)` where needed) and leave the mask non-hit-testing.
- Use one `LinearGradient` for the arriving edge with clear, soft, strong, and opaque stops. For the shipped search edge, begin at clear through 30 pt, then 0.12 at 48 pt, 0.55 at 72 pt, and black at 96 pt.
- For a clear glass pill, add one shape-derived destination-out mask inside the same `.mask`/compositing group: the shipped pill uses a 30% under-glass floor, a 22 pt shape expansion, a 14 pt blur, and a 23 pt pill radius. Keep this shape mask away from painted material halos and never use a second surface behind the control.
- Use the existing composer/transcript values as a calibration point: `ChatView.swift` uses a **130 pt** top fade with gradient stops at `0 black`, `0.30 black.opacity(0.75)`, `0.55 black.opacity(0.35)`, `0.76 black.opacity(0.12)`, and `1 clear`; its composer ramp starts at **34 pt** with a clear-to-black gradient and is non-hit-testing.


## Verification

Judge the result visually, not from isolated layout or unit tests. Run the real surface with real text scrolling under the fixed chrome and capture screenshots in both light and dark mode, using bright, busy content and wallpaper as well as dark content. Dark-on-dark is the easy case and proves nothing: verify that text and metadata dissolve before the card/window edge in light appearance and over bright backgrounds, while the pill remains crisp and visibly floating. If text survives, lengthen or reshape the arriving-edge falloff; do not add opacity bands, a second gradient, or a visible material surface behind the control.

Reference implementations:

- `Sources/Hermternal/Views/Search/SearchPanel.swift` — current results scroll-view content mask: clear through 30 pt, `black.opacity(0.12)` at 48 pt, `black.opacity(0.55)` at 72 pt, and opaque black at 96 pt.
- `Sources/Hermternal/Views/ChatView.swift` — transcript/composer `topFade` and `composerHalo`.
