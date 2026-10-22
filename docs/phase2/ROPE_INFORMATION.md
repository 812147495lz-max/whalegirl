# Menu-bar rope information presentation

Pointer hover retains the existing appear/wink/disappear head animation. Plain
right-click replaces the hover with the supplied rope descent. The translucent
ice-blue HUD card begins revealing after the rebound, while the arm animation
continues, and stays beside the outstretched right palm when `show` holds.
Once this presentation is active, left-click opens the existing options menu;
right-click hides the card and plays `up` until the transparent final frame.
Middle-click and Option+right-click still open the options menu in all states.
Ordinary left-click hearts and icon dragging remain available when information
is closed. An active information presentation cannot accidentally spawn a pet
through a left drag.

After ascent, a one-second monotonic cooldown blocks hover and explicit peek,
including pointer exit/re-entry. If the pointer is still over the icon when it
expires, hover resumes automatically. Uninstall cancels the wakeup. Leaving
the menu icon while the card is open does not retract it. A close during loading
cancels without showing a window; a close during descent finishes the descent
and immediately ascends without exposing the card. Repeated closes, uninstall
and cancelled asset loads cannot resurrect old panels. Only one information
presentation exists at a time.

## Assets

The user's `click.zip` contains `fall` (68 PNG), `show` (3 PNG) and `up` (22 PNG),
not a folder named `down`. `fall` is the requested descent. All 93 original
1280×720 canvases share one crop `(347, 0, 953, 720)` and are resized to 323×384
before lossless WebP atlas encoding. The shared hanging pose is registered
against the final hover frame; all fall/show/up frames inherit that same
source-to-screen transform. Each sequence keeps identical geometry, including
the fully transparent last `up` frame. No per-frame fit,
AI redraw or runtime mesh calculation is performed. The shared crop omits the
right-hand peripheral watermark outside the character/rope bounds; alpha <=1
residue is cleared. Original archive and per-PNG SHA-256 are recorded.

`Scripts/import_click_animations.py <archive>` reproduces the three atlases and
metadata in `Apps/macOS/Resources/ClickAnimations/`. It requires Pillow. Payload
is 5,801,884 bytes of atlases, rather than all full-resolution PNGs. Provenance
describes user-provided material without asserting independent art licensing.

## Rendering, data and windows

The final hover pose supplies the handoff's exact bitmap and screen rectangle.
It stays visible while fall loads. Once ready, the new panel displays that same
bitmap at that same screen rectangle for frame zero before replacing the hover
panel; fall frame one and all later frames use the registered canvas. Source
registration uses a uniform silhouette match, excluding the thin ledge, and is
recorded alongside the locked hover PNG hash in provenance.json. A shared helper
computes the hover layout for both controllers. Display clipping crops the
registered canvas instead of moving or rescaling it, and layer offsets use the
actual AppKit window origin to compensate for backing-pixel snapping.

`MenuBarInformationController` owns hidden/loading/descending/showing/ascending
states. A cancellable task decodes one materialized atlas off the main thread;
CALayer selects frames at 30 fps using contentsRect. On reaching static show,
the fall bitmap is replaced and released, the frame timer stops and a 1 Hz
metrics/visibility timer starts. The static show does not loop. Up replaces it
on close; shutdown stops both timers and releases the image reference.

The card displays read-only CPU, memory, upload/download rate and battery
values. A separate SystemMetricsSampler primes delta counters at open and does
not change the existing CPU-driven tail sampler or background dashboard/event
collection. No telemetry is sent, and no new permissions or accounts are used.

Both panels ignore mouse input and preserve the existing all-Spaces/fullscreen
exclusion flags. FullScreenAvoidance's initial snapshot is awaited before first
presentation; detected fullscreen or display removal closes the presentation.
During static show the check runs with the 1 Hz refresh. Near a right display
edge with insufficient card space, the card is positioned below the character
instead of leaving the display or covering the body. Actual multiple-display,
Spaces and fullscreen transitions still need native desktop acceptance.

## Verification and rollback

App XCTest covers lifecycle through real visible panels, held show, card
visibility, ascent cleanup, cancellation/rapid closure, real status click
handler routing (menu presenter intercepted to avoid a modal test menu),
uninstall, negative-coordinate geometry and missing metric formatting. Exported
card render evidence is under `evidence/rope-information/`. Test event methods
are not physical mouse end-to-end testing or performance measurements.

Rollback by opening the prior DialogueFix app. Source rollback removes the new
controller/resource and project references, restores the previous status click
handler and hover gates, removes `waitForInitialSnapshot` and the added asset
credit. Tail, hover PNGs, desktop skins and their provenance are not modified.

The raw show-frame palm anchor (810, 402) is configurable through
`handoff.presentationHand` in provenance; it uses the same registered transform
as all character frames. CPU/memory meters update with the existing 1 Hz sample;
the HUD grid and corner accents are static, with no decorative timer.

The card is 236 pt wide (previously 276), with rounded glass corners and fine
instrument rules. Only its ice-blue gradient is translucent (alpha 0.22–0.36);
all title/label/value colors are opaque pale ink with a subtle dark shadow.
The window and content view are not dimmed after the reveal transition. References, used for visual study
only: https://www.hudsandguis.com/home/2014/07/30/pacific-rim-holographic-uis
and https://www.behance.net/gallery/108733173/Sci-Fi-Interfaces . No reference
art or animation is bundled.

Latest visual revision follows the user-supplied transparent holographic display
reference: round glass edges, alpha 0.22–0.36 cyan glass, thin partial frame and
opaque pale readouts with a dark text shadow. A pink outlined heart/online label
and a tiny vector whale soften the instrumentation style. No decorative timers,
external artwork or extra bitmap assets were added; width stays 236 pt.

## Shortened descent and early reveal

The atlas preserves every original image, but the fall manifest now plays 52 of
68 source frames at 30 fps (1.73 s instead of 2.27 s). Kept source frame numbers:
1, 10, 14, then 15–68 excluding 59/61/63/65/67. Frame 1 remains the exact hover
handoff; all 15–58 drop, turn, rebound and arm motion frames are retained. Only
the initial hold and near-static ending are shortened. Original sources are
untouched, so this is reversible without re-encoding art.

`provenance.playback` records the source-frame map and panel trigger: source 42,
playback index 30 (zero-based, approximately 1.0 s after descent starts). The
panel's 0.24 s reveal overlaps the remaining arm gesture instead of waiting for
static show. Reaching show does not restart that reveal. Closing while the early
panel is visible hides it immediately and prevents it reappearing during the
remaining descent or ascent; the existing deferred-ascent policy is retained.
The importer reproduces the same manifest/metadata without modifying atlas
pixels. The original manifest and inspected contact sheets are recorded in
evidence/fall-timing/.
