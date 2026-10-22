#!/usr/bin/env python3
"""Import user-provided click.zip as three lazy, aligned transparent atlases."""
import argparse
import hashlib
import io
import json
from pathlib import Path
from zipfile import ZipFile
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
FALL_SOURCE_FRAME_NUMBERS = [1, 10, 14] + [n for n in range(15, 69) if n not in {59, 61, 63, 65, 67}]
INFORMATION_REVEAL_SOURCE_FRAME = 42


def handoff_alignment(fall, crop):
    """Register the shared hanging pose; exclude the thin ledge at its top."""
    hover_root = ROOT / "Apps/macOS/Resources/HoverAnimations"
    files = sorted((hover_root / "appear").glob("*.png"))
    reference_data = files[-1].read_bytes()
    reference = Image.open(io.BytesIO(reference_data)).convert("RGBA")
    boxes = [Image.open(p).convert("RGBA").getchannel("A").getbbox() for p in hover_root.glob("*/*.png")]
    boxes = [b for b in boxes if b]
    common = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    target = reference.getchannel("A")
    source = fall.getchannel("A")
    ignore_top = common[1] + 64
    def body_center(alpha):
        box = alpha.crop((0, ignore_top, alpha.width, alpha.height)).point(lambda a: 255 if a >= 24 else 0).getbbox()
        return ((box[0] + box[2]) / 2, ignore_top + (box[1] + box[3]) / 2)
    tc, sc = body_center(target), body_center(source)
    roi = (common[0], ignore_top, common[2], common[3])
    size = (max(1, (roi[2] - roi[0]) // 4), max(1, (roi[3] - roi[1]) // 4))
    target_small = target.crop(roi).resize(size, Image.Resampling.BILINEAR)
    sx, sy = (roi[2] - roi[0]) / size[0], (roi[3] - roi[1]) / size[1]
    def evaluate(scale, x, y):
        warped = source.transform(size, Image.Transform.AFFINE,
            (sx / scale, 0, (roi[0] - x) / scale, 0, sy / scale, (roi[1] - y) / scale),
            Image.Resampling.BILINEAR)
        score = sum(i * n for i, n in enumerate(ImageChops.difference(target_small, warped).histogram()))
        return score, scale, x, y
    best = None
    for step in range(25):
        scale = 0.97 + step * 0.0025
        for dx in [-4, -2, 0, 2, 4]:
            for dy in [-4, -2, 0, 2, 4]:
                trial = evaluate(scale, tc[0] - scale * sc[0] + dx, tc[1] - scale * sc[1] + dy)
                if best is None or trial[0] < best[0]: best = trial
    base = best
    for step in range(-5, 6):
        scale = base[1] + step * 0.0005
        for dx in [-1, -0.5, 0, 0.5, 1]:
            for dy in [-1, -0.5, 0, 0.5, 1]:
                trial = evaluate(scale, base[2] + dx, base[3] + dy)
                if trial[0] < best[0]: best = trial
    def rect(box):
        return dict(x=box[0], y=box[1], width=box[2] - box[0], height=box[3] - box[1])
    return dict(hoverCrop=rect(common), fallCrop=rect(crop), sourceScale=best[1], offsetX=best[2], offsetY=best[3],
                hoverLastFrame=files[-1].name, hoverLastSHA256=hashlib.sha256(reference_data).hexdigest(),
                method="Uniform alpha-silhouette registration, excluding the ledge; actual hover bitmap is retained for the boundary frame")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    output = ROOT / "Apps/macOS/Resources/ClickAnimations"
    output.mkdir(parents=True, exist_ok=True)
    frames = {}
    provenance = []
    with ZipFile(args.archive) as archive:
        for kind, expected in [("fall", 68), ("show", 3), ("up", 22)]:
            names = sorted(n for n in archive.namelist() if n.startswith(f"click/{kind}/") and n.endswith(".png"))
            if len(names) != expected:
                raise ValueError(f"Expected {expected} {kind} frames, got {len(names)}")
            frames[kind] = []
            for name in names:
                data = archive.read(name)
                image = Image.open(io.BytesIO(data)).convert("RGBA")
                if image.size != (1280, 720):
                    raise ValueError(f"Unexpected canvas: {name}")
                frames[kind].append(image)
                provenance.append(dict(path=name, sha256=hashlib.sha256(data).hexdigest()))
    boxes = [im.getchannel("A").point(lambda a: 255 if a > 16 else 0).getbbox()
             for group in frames.values() for im in group]
    boxes = [b for b in boxes if b]
    crop = (max(0, min(b[0] for b in boxes) - 2), 0,
            min(1280, max(b[2] for b in boxes) + 2), min(720, max(b[3] for b in boxes) + 2))
    size = (round((crop[2] - crop[0]) * 384 / crop[3]), 384)
    manifest = dict(schemaVersion=1, atlases=[], clips=[])
    for kind, images in frames.items():
        columns = min(8, len(images))
        rows = (len(images) + columns - 1) // columns
        atlas = Image.new("RGBA", (columns * size[0], rows * size[1]))
        entries = []
        for index, image in enumerate(images):
            image.putalpha(image.getchannel("A").point(lambda a: 0 if a <= 1 else a))
            image = image.crop(crop).resize(size, Image.Resampling.LANCZOS)
            x, y = index % columns * size[0], index // columns * size[1]
            atlas.paste(image, (x, y))
            entries.append(dict(rect=dict(x=x, y=y, width=size[0], height=size[1]), duration=1 / 30,
                                anchor=dict(x=0.5, y=0), visualBounds=dict(x=0, y=0, width=1, height=1),
                                hitbox=dict(x=0, y=0, width=1, height=1)))
        path = output / (kind + ".webp")
        atlas.save(path, "WEBP", lossless=True, method=4, exact=True)
        manifest["atlases"].append(dict(id=kind, resource=path.name, pixelWidth=atlas.width, pixelHeight=atlas.height))
        playback_entries = [entries[n - 1] for n in FALL_SOURCE_FRAME_NUMBERS] if kind == "fall" else entries
        manifest["clips"].append(dict(id=kind, atlasID=kind, looping=False, frames=playback_entries))
    (output / "sprite-manifest.json").write_text(json.dumps(manifest, separators=(",", ":")))
    # Rope centre measured on the top row of the supplied static presentation frame.
    alpha = frames["show"][0].getchannel("A")
    rope = alpha.crop((0, 0, 1280, 8)).point(lambda a: 255 if a > 32 else 0).getbbox()
    rope_x = (rope[0] + rope[2]) / 2
    metadata = dict(source="User-provided click.zip", archiveSHA256=hashlib.sha256(args.archive.read_bytes()).hexdigest(),
                    sourceCanvas=[1280, 720], commonCrop=crop, frameSize=size,
                    ropeX=(rope_x - crop[0]) / (crop[2] - crop[0]), showFrame=1,
                    frames=provenance,
                    processing="Single crop and scale across all 93 frames; alpha <= 1 residue cleared; lossless WebP. No redraw.",
                    attribution="User-supplied artwork; original authorship/license not independently asserted.")
    metadata["handoff"] = handoff_alignment(frames["fall"][0], crop)
    metadata["handoff"]["presentationHand"] = dict(x=810, y=402)
    metadata["playback"] = dict(fallSourceFrameNumbers=FALL_SOURCE_FRAME_NUMBERS,
        informationRevealSourceFrame=INFORMATION_REVEAL_SOURCE_FRAME,
        informationRevealFrameIndex=FALL_SOURCE_FRAME_NUMBERS.index(INFORMATION_REVEAL_SOURCE_FRAME),
        frameRate=30,
        reason="Keep exact handoff and all drop/flip/rebound/arm-motion frames; trim initial hold and near-static final hold. Reveal after rebound, before final open-palm pose.")
    (output / "provenance.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
    print(dict(crop=crop, frameSize=size, handoff=metadata["handoff"], frames={k: len(v) for k, v in frames.items()},
               bytes=sum(p.stat().st_size for p in output.glob("*.webp"))))


if __name__ == "__main__":
    main()
