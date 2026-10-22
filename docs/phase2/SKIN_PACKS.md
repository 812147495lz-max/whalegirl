# Selectable desktop-pet skins

The menu-bar middle-click menu and each desktop character's right-click menu
provide `桌宠皮肤 → 经典鲸鱼娘 / 赤风RED`. Selection is global, persists as
`desktopPetSkin`, and refreshes all existing desktop characters without moving,
resizing or recreating their windows. Tail icons, hover appearances, hearts and
background monitoring retain their existing resources and behavior.

## Data and behavior

- Classic: the existing 106 PC2005 actions plus 27 differently named yanzwzz
  actions (133 total). All 50 yanzwzz source WebM files were downloaded and
  verified against the pinned Git tree. For 23 same-named actions, the existing
  version is retained instead of adding another randomly selectable entry.
  These files are not claimed to be byte-identical.
- RED: all 5 default GIFs and 157 reactions (162 total). Defaults provide skin
  aliases for idle, happy, poke, dragged, greet and return. Random/manual
  selection and stationary claims remain isolated from classic actions.
- RED reactions do not include a continuous walking cycle. RED therefore
  plays its stationary reaction pool without substituting the classic body or
  sliding a nonwalking pose across the desktop. Classic keeps its existing
  0–3 actions followed by a walk and horizontal route constraint.
- Skin refresh cancels pending random scheduling and walking. Displayed poses
  retain their claims until replacement textures actually arrive. New requests
  reserve from the selected skin only. The animator cancels stale loading
  callbacks. Hidden/suppressed desktop characters are refreshed too.
- Existing shared decode queue, active bitmap sharing, 64 MiB inactive LRU and
  shared playback/input clocks are reused. Atlas data is decoded only when
  selected or about to play; the full library is not decoded at launch.

## Playback cadence update

Each stationary action plays once, holds its final pose for one second, then
returns to a static neutral default pose for a random 6–10 seconds before the
next autonomous action. The idle timer starts only after the default bitmap is
actually displayed. Default poses may be shared by resting pets; they are not
treated as exclusive random reactions. Random/manual actions remain exclusive,
and the default clip is excluded from the random shuffle bag. This prevents a
busy default claim from substituting and looping another reaction as "idle".

Held poses do not subscribe to the shared playback clock. Pause, suppression,
manual playback, dragging and skin switches cancel or resume the relevant
return timer so that stale callbacks cannot override a newer action. Classic
still walks after 0–3 completed random actions, with the idle interval between
outings. Menu-bar tail animation timing is unchanged.

## Sources and conversion

Desktop mouse-entry speech now uses the existing 24-line local dialogue library,
excluding both this pet's preceding line and the last line spoken by another
desktop pet. The bubble uses a noneditable, nonselectable transparent NSTextView
and the same TextKit container for measuring and drawing, including CJK fallback
font metrics. Short text determines width; longer text wraps within 240 pt and
the available window width, with height taken from actual laid-out glyphs.
Display time is 2.4–7 seconds according to character count; pointer exit still
hides the bubble. No AI service or new dialogue assets are introduced.

- yanzwzz/dsh-whale-girl-pet:
  `b5ce53cfa87b9fc669eef2aabe64946bb77adb72`, MIT text and upstream README
  retained; previous character/source credits remain in place.
- Aibie07/whale-girl-desktop-pet:
  `584b11f8d654ffcdf675e1ea38801f01c73c8bed`, release v1.0.0/assets.tar.gz.
  Artist: 赤风RED. Upstream's artist permission is not represented as our own
  redistribution permission. Other uses require contacting the artist, as
  stated in the bundled upstream README and `red-ART-NOTICE.md`.

Only image data is imported; upstream installation scripts and application code
are never executed or shipped. `CommunityActions/skin-provenance.json` records
source/release hashes, pinned revisions, reuse decisions and output hashes.

`Scripts/import_skin_packs.py` consumes the verified downloads in
`work/style-review/`. Run using Python with Pillow and ffmpeg available. It
snapshots baseline metadata in `work/style-review/before-skins/`, caches each
conversion, and rebuilds catalog/manifest/layout deterministically. No network
access is performed by this converter or by playback.

New atlases use transparent WebP quality 84, 12 fps timeline sampling and one
common crop per action. Held identical GIF poses are coalesced while retaining
their sampled duration. A 384×216 logical canvas mapping preserves placement;
frames are not individually stretched to their subject bounds. Existing
PC2005 atlases are untouched. Added atlas payload: approximately 53.53 MiB.

## Verification and rollback

Check schema-v1 frame timing/rectangles, normalized hit regions, references,
skin aliases, all 189 added atlas dimensions/alpha and SHA-256. Build Release,
verify its signature, archive without resource forks and verify the extracted
archive. These checks do not establish real desktop switching, perceived
smoothness, multiwindow performance or full-screen behavior.

App XCTest source covers selection persistence, disjoint action pools, alias
resolution, missing RED walk cycles and no eager bitmap decoding. Do not
describe these as passing unless actually executed.

Rollback: use the previous FullScreenBubble application. To remove the import
from source, restore the three JSON files from `before-skins`, remove
`yanz.*.webp`, `red.*.webp`, `skins.json`, `skin-provenance.json` and the new
source notices, then remove the repository/menu/coordinator refresh additions
and supplemental attribution entries. No user-tail or hover resources change.
