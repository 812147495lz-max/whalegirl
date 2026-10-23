# Notices

## Application code

The WhaleGirl Phase 00/01 implementation in this repository is released under the MIT License in the repository root.

## whale-girl character sprite sheets

The bundled Phase 01 character sheets are copied from [vlln/whale-girl](https://github.com/vlln/whale-girl) at commit `9c32d7a39a45148076f8ad2fdaad2dc2420eedb3`. The upstream repository is licensed under the MIT License, copyright © 2026 Sam Gao (vlln); the required license text is preserved in `licenses/whale-girl-MIT.txt`.

The upstream manifest credits the character to ZipZipPipe, and its README states that the sprites were generated from the “Whale Girl” sticker character design. Preserve both the upstream copyright/license and this character credit when redistributing the app.

The PNG files are byte-for-byte upstream copies. This app selects and crops frames through `sprite-manifest.json`; it does not redraw the source sprites.

## Community action library

All 106 WebM animations from `PC2005-cloud/dsh-pet` at commit `2dc2dfe7796c2ab77edb6f093c5886642d6870f4` have been downloaded from `dsh-pet/assets/webm/` and converted to transparent WebP atlases on a shared 384×216 canvas at 12 fps. Copyright (c) 2026 PC2005-cloud, MIT License. The complete license is bundled in `CommunityActions/LICENSE.txt`; `CommunityActions/provenance.json` records every source path, pinned Git blob, source SHA-256 and converted atlas SHA-256.

Source: https://github.com/PC2005-cloud/dsh-pet/tree/2dc2dfe7796c2ab77edb6f093c5886642d6870f4/dsh-pet/assets/webm

The existing ZipZipPipe character attribution above is retained. No upstream application code, executables, scripts, account access or network integration is included in the app. Runtime playback is entirely local.

## Procedural fallback

`Scripts/generate_placeholder_atlases.py` remains first-party MIT-licensed fallback tooling. Its generated placeholder images are no longer bundled in the Phase 01 application.

Machine-readable attribution is stored in `Assets/attribution.json` and copied into the app bundle.

## Apple frameworks

The application links only Apple system frameworks through AppKit/Foundation/QuartzCore and the Swift runtime. These are supplied by macOS/Xcode and are not redistributed as source in this repository.

## Other external desktop-pet projects

AgentPet, RunRat, and DSH Pet were named as initial research candidates in the development kit. Their application code is not included. The later visual-only import from PC2005-cloud/dsh-pet is documented in the Community action library section above, with its own pinned revision and MIT license.

## Runtime atlas compaction

Community action atlases have been repacked into tighter
transparent rectangles. The original logical canvas placement is retained in
`CommunityActions/render-layout.json`; original image pixels inside each crop are
re-encoded losslessly. Only peripheral alpha <= 1/255 residue is omitted. Frame
order, duration, character scale and position are preserved. Current output hashes
and original atlas hashes are recorded in the respective provenance files. These
processing changes do not alter the upstream license or character attribution.

## Additional skins (2026-10-19)

yanzwzz/dsh-whale-girl-pet at b5ce53cfa87b9fc669eef2aabe64946bb77adb72: all 50 transparent WebM files were downloaded and checked against the pinned Git tree. 27 differently named actions are included as supplements to the existing classic style; 23 same-named actions retain the existing PC2005 version. Full MIT text and upstream README are bundled as CommunityActions/yanzwzz-LICENSE.txt and yanzwzz-UPSTREAM-README.md. Original character and prior source credits are retained.

Aibie07/whale-girl-desktop-pet at 584b11f8d654ffcdf675e1ea38801f01c73c8bed, v1.0.0 assets.tar.gz: 5 default animations and 157 reactions by artist 赤风RED are provided as a separate selectable skin at the user's explicit request. Upstream states it has artist permission and other uses must obtain permission directly from the artist. This app does not claim that upstream's MIT code license grants art redistribution rights. See CommunityActions/red-ART-NOTICE.md and red-UPSTREAM-README.md. No upstream code is used.

New assets only: transparent WebP quality 84, 12 fps sampling, common bounds per action and retained logical canvas coordinates; source timelines retained to sampling precision, repeated GIF holds coalesced. Source/release SHA-256, pinned versions and conversion outputs are in CommunityActions/skin-provenance.json. Earlier cropped PC2005 atlases are not re-encoded by this import.

## User-provided rope information animation

ClickAnimations contains the 93 PNG frames supplied in click.zip (68 fall, 3 show, 22 up), converted offline to lossless WebP atlases. Artist and independent redistribution rights have not been asserted. One common crop/scale preserves rope alignment across the sequence; source paths, archive hash, individual hashes and processing details are retained in ClickAnimations/provenance.json. No application code was imported.

AI quota backend: CodexBarCLI, MIT, Copyright (c) 2026 Peter Steinberger, pinned upstream `9093308f0b79645f6794c2f28f020d87fe06386b`. Full upstream/dependency licenses and attribution are shipped under `Apps/macOS/Resources/AIMonitor/Licenses` and the Core resource bundle's Acknowledgements.json. See `Apps/macOS/Resources/AIMonitor/NOTICE.md`.

## v1.0 publisher confirmation

The publisher has confirmed permission to publicly distribute the additional artwork and user-provided animations included in v1.0. Artwork retains its own rights; the root MIT license covers the application code and does not replace independent asset licenses or permission requirements.

DSH main-agent daily usage now follows MeteorNOX/DeepSeek-Balance-Whale-Widget v0.4.2, commit 5247dd6813d6e4430728f39ccc63d43cda046022 (MIT, Copyright (c) 2026 MeteorNOX). Original Python integration adapts its fixed-point observed-balance accounting and Beijing peak/holiday semantics. Full license is bundled in AIMonitor/Licenses/DeepSeek-Balance-Whale-Widget-MIT.txt. No upstream artwork, audio or browser plugin is bundled or installed. WhaleGirl's private observation book is independent of the plugin's books and never rewrites DSH data. Prior v1.3's token-cost-estimate approach is superseded.

## v1.5 public distribution

The publisher previously confirmed permission to publicly distribute the complete additional artwork and user-provided animations retained in this release. This does not relicense third-party artwork under MIT or grant unrestricted reuse; original credits and independent permission requirements remain.
